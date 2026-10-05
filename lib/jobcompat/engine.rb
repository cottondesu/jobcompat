module Jobcompat
  class Engine
    DIRECTIONS = %w[base_to_head head_to_base head_to_head].freeze
    REVISIONS = %w[base head].freeze
    TITLES = {
      "JC001" => "Old payload rejected by new worker", "JC002" => "New payload rejected by old worker",
      "JC003" => "Current producer/consumer mismatch", "JC004" => "Worker identity absent from HEAD source",
      "JC005" => "New worker enqueued before old fleet can understand it", "JC006" => "Worker contract narrowed without sufficient producer evidence",
      "JC007" => "Compatibility could not be proven"
    }.freeze

    attr_reader :base, :head, :calls

    def initialize(base, head)
      @base, @head = base, head
      @lookup_names = (base.workers.keys + head.workers.keys + base.aliases.keys + head.aliases.keys).uniq
      @calls = {"base" => resolve(base), "head" => resolve(head)}
      referenced = calls.values.flatten.flat_map { |call| [call[:worker], call[:attributed_worker]] }.compact
      shared_aliases = (base.aliases.keys & head.aliases.keys).select { |name| base.aliases[name].static_reference || head.aliases[name].static_reference }
      @names = (base.workers.keys + head.workers.keys +
                base.aliases.values.select(&:resolved?).map(&:name) +
                shared_aliases + referenced).uniq.sort
      @calls_by_worker = {"base" => calls["base"].group_by { |call| call[:worker] },
                          "head" => calls["head"].group_by { |call| call[:worker] }}
      @presence_requests = {
        "head" => @names.select { |name| base.consumer(name) && !head.consumer(name) },
        "base" => @names.select { |name| head.consumer(name) && !base.consumer(name) && @calls_by_worker["head"].key?(name) }
      }
    end

    def presence_requests
      @presence_requests
    end

    def evaluate
      findings = []
      workers = @names.map do |name|
        b = base.consumer(name)
        h = head.consumer(name)
        bc = @calls_by_worker["base"].fetch(name, [])
        hc = @calls_by_worker["head"].fetch(name, [])
        base_presence = presence(base, name, b, presence_requests["base"].include?(name))
        head_presence = presence(head, name, h, presence_requests["head"].include?(name))
        if b && !h
          if head_presence == "absent"
            findings << finding("JC004", name, ["base", "head"], ["base_to_head"], nil, nil,
                                "The serialized worker identity is absent from HEAD tracked Ruby source.",
                                "Queued, retried, or scheduled jobs may still reference this class name.",
                                ["Keep the worker class or a supported compatibility alias until retained jobs can no longer run."],
                                b.declaration_locations + contract_proof(b) + producer_proof(hc))
          else
            findings << presence_unknown(name, head_presence, b.declaration_locations + head.index.locations(name), "base_to_head", "head") unless head.aliases.key?(name)
          end
        elsif h && !b && !hc.empty?
          if base_presence == "absent"
            findings << finding("JC005", name, ["base", "head"], ["head_to_base"], nil, nil,
                                "HEAD can enqueue a serialized worker identity absent from base tracked Ruby source.",
                                "If an old Sidekiq process can consume this job during the rolling deployment, it cannot resolve the new worker class.",
                                ["Deploy the worker class or compatibility alias before activating its producer."], h.declaration_locations + producer_proof(hc))
          else
            findings << presence_unknown(name, base_presence, h.declaration_locations + base.index.locations(name), "head_to_base", "base") unless base.aliases.key?(name)
          end
        end

        base_groups = bc.select { |call| !call[:reason] && !call[:arity].nil? }.group_by { |call| call[:arity] }
        head_groups = hc.select { |call| !call[:reason] && !call[:arity].nil? }.group_by { |call| call[:arity] }
        proven_narrow = false
        if b&.known? && h&.known?
          base_groups.sort.each do |arity, group|
            next unless b.accepts?(arity) && !h.accepts?(arity)
            head_same = head_groups.fetch(arity, []).select { |call| !h.accepts?(call[:arity]) }
            directions = ["base_to_head"]
            directions << "head_to_head" unless head_same.empty?
            locations = producer_proof(group) + contract_proof(b) + contract_proof(h) + producer_proof(head_same)
            findings << finding("JC001", name, head_same.empty? ? ["base", "head"] : ["base", "head"], directions, arity, nil,
                                "Base emits #{arity} #{argument_word(arity)}, but the HEAD worker accepts #{h.display_range}.",
                                "Jobs queued by the base revision may fail after deployment.",
                                ["Make the HEAD worker accept old payloads.", "Narrow only after queue, retry, and schedule retention is handled."], locations)
            proven_narrow = true
          end
        end
        current_removed_witness = false
        if h&.known?
          head_groups.sort.each do |arity, group|
            if !h.accepts?(arity)
              next if findings.any? { |item| item[:rule_id] == "JC001" && item[:worker] == name && item[:payload_arity] == arity }
              findings << finding("JC003", name, ["head"], ["head_to_head"], arity, nil,
                                  "HEAD emits #{arity} #{argument_word(arity)}, but its worker accepts #{h.display_range}.",
                                  "Current HEAD jobs can fail when executed.", ["Align the enqueue payload with the HEAD perform signature."],
                                  producer_proof(group) + contract_proof(h))
              current_removed_witness ||= b&.known? && b.accepts?(arity)
            elsif b&.known? && !b.accepts?(arity)
              findings << finding("JC002", name, ["base", "head"], ["head_to_base"], arity, nil,
                                  "HEAD emits #{arity} #{argument_word(arity)}, but the base worker accepts #{b.display_range}.",
                                  "A new producer can enqueue work that an old worker cannot execute during a rolling deploy.",
                                  ["Deploy the optional worker argument first.", "Start enqueueing the new argument in a later release."],
                                  producer_proof(group) + contract_proof(b) + contract_proof(h))
            end
          end
        end
        if b&.known? && h&.known?
          unless h.superset_of?(b) || proven_narrow || current_removed_witness
            removed = removed_arity_ranges(b, h)
            label = removed.length == 1 && removed.first.match?(/\A\d+\z/) ? "arity" : "arities"
            findings << finding("JC006", name, ["base", "head"], ["base_to_head"], nil, nil,
                                "The HEAD worker removed #{label} #{removed.join(', ')} from the base contract; no qualifying producer witness was found.",
                                "No repository producer callsite found does not prove that no queued, scheduled, retried, historical, or externally enqueued payload exists.",
                                ["Keep the broader signature through the retention window, or document a proven drain."],
                                contract_proof(b) + contract_proof(h))
          end
        end

        {
          name: name, base_presence: base_presence, head_presence: head_presence,
          base_alias: base.aliases[name]&.as_json, head_alias: head.aliases[name]&.as_json,
          base_contract: b&.as_json, head_contract: h&.as_json,
          producer_arities: {base: bc.filter_map { |call| call[:arity] unless call[:reason] }.uniq.sort,
                             head: hc.filter_map { |call| call[:arity] unless call[:reason] }.uniq.sort,
                             base_unknown_calls: bc.count { |call| call[:reason] }, head_unknown_calls: hc.count { |call| call[:reason] }},
          compatibility: {base_to_base: cell(bc, b, base_presence), base_to_head: cell(bc, h, head_presence),
                          head_to_base: cell(hc, b, base_presence), head_to_head: cell(hc, h, head_presence)}
        }
      end
      findings.concat(unknown_findings)
      findings = findings.sort_by { |item| finding_sort_key(item) }
      {findings: findings, workers: workers}
    end

    private

    def resolve(snapshot)
      snapshot.calls.sort_by { |call| [call.path, call.location.line, call.location.column, call.method,
                                  call.arity.nil? ? Float::INFINITY : call.arity, call.unknown_reason.to_s] }.filter_map do |call|
        worker = nil
        attributed_worker = nil
        binding = nil
        binding_locations = []
        identity_reason = nil
        if call.receiver
          candidates = if call.resolution_mode == "exact_string" || call.root
                         [call.receiver]
                       else
                         ConstantLookup.candidates(call.receiver, false, call.namespace)
                       end
          worker = producer_identity(snapshot, candidates, call.resolution_mode)
          attributed_worker = worker
          if worker && call.resolution_mode != "exact_string" && snapshot.aliases.key?(worker)
            binding = snapshot.aliases[worker]
            worker = binding.resolved? ? binding.target : nil if binding
            binding_locations = snapshot.workers.fetch(binding.target).locations if binding.resolved?
          elsif worker && alias_lookup?(candidates, call.resolution_mode) && snapshot.bindings.key?(worker) && !snapshot.workers.key?(worker)
            binding_locations = snapshot.bindings.fetch(worker).map(&:location)
            identity_reason = "worker_not_recognized"
            worker = nil
          elsif worker && call.resolution_mode != "exact_string" && !snapshot.workers.key?(worker) && (base.aliases.key?(worker) || head.aliases.key?(worker))
            worker = nil
          end
          client_target = %w[client_constant exact_string].include?(call.resolution_mode)
          next unless worker || attributed_worker || client_target || (!call.root && call.namespace.nil?)
        end
        identity_reason ||= binding && !binding.resolved? ? binding.unknown_reason : nil
        identity_reason ||= "alias_target_unresolved" if worker.nil? && attributed_worker
        reason = identity_reason || call.unknown_reason
        reason ||= "dynamic_client_class" if call.receiver && worker.nil? && %w[client_constant exact_string].include?(call.resolution_mode)
        reason ||= call.namespace.nil? ? "unsupported_constant_path" : "dynamic_receiver" if worker.nil?
        {worker: worker, attributed_worker: attributed_worker, identity_known: !worker.nil?, identity_reason: identity_reason,
         location: call.location, locations: [call.location] + (binding&.locations || []) + binding_locations,
         arity: call.arity, reason: reason, raw: call}
      end
    end

    def producer_identity(snapshot, candidates, mode)
      if alias_lookup?(candidates, mode)
        local = candidates.find { |name| snapshot.bindings.key?(name) || snapshot.workers.key?(name) || snapshot.aliases.key?(name) }
        return local if local
      end
      candidates.find { |name| @lookup_names.include?(name) }
    end

    def alias_lookup?(candidates, mode)
      mode != "exact_string" && candidates.any? { |name| base.aliases.key?(name) || head.aliases.key?(name) }
    end

    def presence(snapshot, name, contract, queried)
      return snapshot.presence(name) if contract || snapshot.aliases.key?(name)
      return "not_checked" unless queried
      snapshot.index.status(name)
    end

    def producer_proof(group) = group.flat_map { |call| call[:locations] }

    def contract_proof(contract)
      return contract.locations if base.aliases.key?(contract.name) || head.aliases.key?(contract.name)
      contract.locations.select { |location| location.role == "consumer" }
    end

    def cell(producers, consumer, status)
      return "not_applicable" if producers.empty?
      known = producers.filter_map { |call| call[:arity] unless call[:reason] }
      return "fail" if consumer&.known? && known.any? { |arity| !consumer.accepts?(arity) }
      return "unknown" if !consumer&.known? && status != "absent"
      return "unknown" if producers.any? { |call| call[:reason] }
      return "not_applicable" if status == "absent"
      "pass"
    end

    def argument_word(number) = number == 1 ? "argument" : "arguments"

    def removed_arity_ranges(base_contract, head_contract)
      ranges = []
      if head_contract.min_arity > base_contract.min_arity
        last = [head_contract.min_arity - 1, base_contract.max_arity].compact.min
        ranges << [base_contract.min_arity, last]
      end
      if head_contract.max_arity && (base_contract.max_arity.nil? || head_contract.max_arity < base_contract.max_arity)
        first = [base_contract.min_arity, head_contract.max_arity + 1].max
        ranges << [first, base_contract.max_arity]
      end
      ranges.map do |first, last|
        last.nil? ? "#{first}..∞" : (first == last ? first.to_s : "#{first}..#{last}")
      end
    end

    def finding(rule, worker, revisions, directions, arity, reason, message, risk, remediation, locations)
      sorted_locations = locations.compact.uniq.sort_by { |loc| [REVISIONS.index(loc.revision), loc.path, loc.line, loc.column, loc.role] }
      {rule_id: rule, title: TITLES.fetch(rule), severity: rule <= "JC005" ? "error" : "warning", worker: worker,
       revisions: revisions.sort_by { |revision| REVISIONS.index(revision) }, directions: directions.sort_by { |direction| DIRECTIONS.index(direction) },
       unknown_reason: reason, message: message, risk: risk, remediation: remediation, payload_arity: arity, locations: sorted_locations}
    end

    def presence_unknown(name, status, locations, direction, revision)
      reason = {"defined_unrecognized" => "worker_not_recognized", "outside_scan_scope" => "outside_analysis_scope", "unverified" => "presence_unverified"}.fetch(status)
      finding("JC007", name, [revision], [direction], nil, reason,
              "#{name} is present or cannot be proven absent, but its Sidekiq contract is not recognized.",
              "Compatibility for this class transition cannot be proven from selected source.",
              ["Restore a directly recognized worker declaration, or inspect the deployment manually."], locations)
    end

    def unknown_findings
      roots = []
      [base, head].each do |snapshot|
        @names.each do |name|
          contract = snapshot.consumer(name)
          next if !contract || contract.known?
          parts = ["consumer_contract", contract.unknown_reason, name, contract.fingerprint_parts]
          roots << {revision: snapshot.label, kind: "consumer_contract", reason: contract.unknown_reason, worker: name,
                    locations: contract.locations, parts: parts, offset: contract.locations.first&.line || 0}
        end
        snapshot.aliases.each do |name, binding|
          next if binding.resolved? || !@names.include?(name)
          producer_locations = calls[snapshot.label].select { |call| call[:identity_reason] && call[:attributed_worker] == name }.flat_map { |call| call[:locations] }
          roots << {revision: snapshot.label, kind: "consumer_alias", reason: binding.unknown_reason, worker: name,
                    locations: binding.locations + producer_locations,
                    parts: ["consumer_alias", binding.unknown_reason, name, binding.fingerprint_parts, binding.chain], offset: 0}
        end
        snapshot.unknowns.each do |item|
          roots << {revision: snapshot.label, kind: item.kind, reason: item.reason, worker: item.worker,
                    locations: item.locations, parts: [item.kind, item.reason, item.worker, item.fingerprint_parts], offset: item.locations.first&.line || 0}
        end
        calls[snapshot.label].each do |call|
          next unless call[:reason]
          next if call[:identity_reason] && snapshot.aliases.key?(call[:attributed_worker])
          raw = call[:raw]
          kind = call[:identity_reason] || %w[dynamic_receiver unsupported_constant_path safe_navigation_receiver].include?(call[:reason]) ? "producer_receiver" : "producer_arity"
          diagnostic_worker = call[:worker] || (call[:identity_reason] && call[:attributed_worker])
          roots << {revision: snapshot.label, kind: kind, reason: call[:reason], worker: diagnostic_worker,
                    locations: call[:locations], parts: [kind, call[:reason], diagnostic_worker, raw.fingerprint_parts],
                    offset: [call[:location].line, call[:location].column]}
        end
      end
      groups = roots.group_by { |root| [root[:revision], root[:parts]] }
      groups.each_value do |group|
        ordered = group.sort_by { |item| item[:offset] }
        ordered.each_with_index { |root, index| root[:fingerprint] = [root[:parts], ordered.length, index + 1] }
      end
      roots.group_by { |root| root[:fingerprint] }.values.map do |group|
        first = group.first
        directions = group.flat_map do |root|
          case [root[:kind], root[:revision]]
          when ["producer_arity", "base"], ["producer_receiver", "base"] then ["base_to_head"]
          when ["producer_arity", "head"], ["producer_receiver", "head"] then ["head_to_base", "head_to_head"]
          when ["consumer_contract", "base"], ["worker_identity", "base"] then ["head_to_base"]
          when ["consumer_alias", "base"] then ["head_to_base"]
          when ["consumer_alias", "head"]
            @calls_by_worker["head"].key?(root[:worker]) ? ["base_to_head", "head_to_head"] : ["base_to_head"]
          else ["base_to_head", "head_to_head"]
          end
        end.uniq
        if first[:kind] == "producer_arity" && first[:worker]
          head_only_new = head.consumer(first[:worker]) && !base.consumer(first[:worker])
          directions.delete("head_to_base") if head_only_new && group.any? { |root| root[:revision] == "head" } && base.index.status(first[:worker]) == "absent"
        end
        alias_reason = %w[alias_target_unresolved alias_cycle alias_binding_conflict unsupported_alias_assignment].include?(first[:reason])
        message = alias_reason ? alias_message(first[:worker], first[:reason]) : "#{first[:reason]} prevents a complete positional compatibility check."
        risk = alias_reason ? "Compatibility for jobs serialized as #{first[:worker]} cannot be proven from selected source." : "The affected producer or consumer contract is unknown."
        remediation = alias_reason ? ["Use one explicit static alias if it matches runtime behavior, or inspect the deployment manually."] : ["Use supported explicit syntax or inspect this call manually."]
        finding("JC007", first[:worker], group.map { |root| root[:revision] }.uniq, directions, nil, first[:reason],
                message, risk, remediation,
                group.flat_map { |root| root[:locations] })
      end
    end

    def alias_message(name, reason)
      case reason
      when "alias_target_unresolved" then "#{name} is bound as a compatibility alias, but its target cannot be resolved to a supported Sidekiq worker."
      when "alias_cycle" then "Compatibility alias resolution for #{name} enters a constant-alias cycle."
      when "alias_binding_conflict" then "#{name} has multiple or conflicting constant bindings, so its runtime job class cannot be proven."
      when "unsupported_alias_assignment" then "#{name} is assigned through syntax or control flow that does not prove one unconditional static compatibility alias."
      end
    end

    def finding_sort_key(item)
      loc = item[:locations].first
      [item[:severity] == "error" ? 0 : 1, item[:rule_id], item[:worker] || "\u{10ffff}", item[:payload_arity] || Float::INFINITY,
       loc&.path.to_s, loc&.line || 0, item[:directions], item[:revisions], item[:unknown_reason].to_s]
    end
  end
end
