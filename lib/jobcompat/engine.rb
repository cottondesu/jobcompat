module Jobcompat
  class Engine
    DIRECTIONS = %w[base_to_head head_to_base head_to_head].freeze
    REVISIONS = %w[base head].freeze
    TITLES = {
      "JC001" => "Old payload rejected by new worker", "JC002" => "New payload rejected by old worker",
      "JC003" => "Current producer/consumer mismatch", "JC004" => "Worker class absent from HEAD source",
      "JC005" => "New worker enqueued before old fleet can understand it", "JC006" => "Worker contract narrowed without sufficient producer evidence",
      "JC007" => "Compatibility could not be proven"
    }.freeze

    attr_reader :base, :head, :calls

    def initialize(base, head)
      @base, @head = base, head
      @names = (base.workers.keys + head.workers.keys).uniq.sort
      @calls = {"base" => resolve(base.calls), "head" => resolve(head.calls)}
      @calls_by_worker = {"base" => calls["base"].group_by { |call| call[:worker] },
                          "head" => calls["head"].group_by { |call| call[:worker] }}
      @presence_requests = {
        "head" => (base.workers.keys - head.workers.keys).sort,
        "base" => (head.workers.keys - base.workers.keys).select { |name| @calls_by_worker["head"].key?(name) }.sort
      }
    end

    def presence_requests
      @presence_requests
    end

    def evaluate
      findings = []
      workers = @names.map do |name|
        b = base.workers[name]
        h = head.workers[name]
        bc = @calls_by_worker["base"].fetch(name, [])
        hc = @calls_by_worker["head"].fetch(name, [])
        base_presence = presence(base, name, b, presence_requests["base"].include?(name))
        head_presence = presence(head, name, h, presence_requests["head"].include?(name))
        if b && !h
          if head_presence == "absent"
            findings << finding("JC004", name, ["base", "head"], ["base_to_head"], nil, nil,
                                "The worker class is absent from HEAD tracked Ruby source.",
                                "Queued, retried, or scheduled jobs may still reference this class name.",
                                ["Keep a compatibility class until retained jobs can no longer run."],
                                b.declaration_locations + b.locations.select { |loc| loc.role == "consumer" } + hc.map { |call| call[:location] })
          else
            findings << presence_unknown(name, head_presence, b.declaration_locations + head.index.locations(name), "base_to_head", "head")
          end
        elsif h && !b && !hc.empty?
          if base_presence == "absent"
            findings << finding("JC005", name, ["base", "head"], ["head_to_base"], nil, nil,
                                "HEAD can enqueue a worker class absent from base tracked Ruby source.",
                                "If an old Sidekiq process can consume this job during the rolling deployment, it cannot resolve the new worker class.",
                                ["Deploy the worker class before activating its producer."], h.declaration_locations + hc.map { |call| call[:location] })
          else
            findings << presence_unknown(name, base_presence, h.declaration_locations + base.index.locations(name), "head_to_base", "base")
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
            locations = group.map { |call| call[:location] } + b.locations.select { |loc| loc.role == "consumer" } + h.locations.select { |loc| loc.role == "consumer" } + head_same.map { |call| call[:location] }
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
                                  group.map { |call| call[:location] } + h.locations.select { |loc| loc.role == "consumer" })
              current_removed_witness ||= b&.known? && b.accepts?(arity)
            elsif b&.known? && !b.accepts?(arity)
              findings << finding("JC002", name, ["base", "head"], ["head_to_base"], arity, nil,
                                  "HEAD emits #{arity} #{argument_word(arity)}, but the base worker accepts #{b.display_range}.",
                                  "A new producer can enqueue work that an old worker cannot execute during a rolling deploy.",
                                  ["Deploy the optional worker argument first.", "Start enqueueing the new argument in a later release."],
                                  group.map { |call| call[:location] } + b.locations.select { |loc| loc.role == "consumer" } + h.locations.select { |loc| loc.role == "consumer" })
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
                                b.locations.select { |loc| loc.role == "consumer" } + h.locations.select { |loc| loc.role == "consumer" })
          end
        end

        {
          name: name, base_presence: base_presence, head_presence: head_presence,
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

    def resolve(raw_calls)
      raw_calls.sort_by { |call| [call.path, call.location.line, call.location.column] }.filter_map do |call|
        worker = nil
        if call.receiver
          candidates = if call.root
                         [call.receiver]
                       elsif call.namespace.nil?
                         []
                       else
                         (call.namespace.reverse.map { |prefix| "#{prefix}::#{call.receiver}" } + [call.receiver]).uniq
                       end
          worker = candidates.find { |name| @names.include?(name) }
          next unless worker || (!call.root && call.namespace.nil?)
        end
        reason = call.unknown_reason
        reason ||= call.namespace.nil? ? "unsupported_constant_path" : "dynamic_receiver" if worker.nil?
        {worker: worker, location: call.location, arity: call.arity, reason: reason, raw: call}
      end
    end

    def presence(snapshot, name, contract, queried)
      return "recognized_worker" if contract
      return "not_checked" unless queried
      snapshot.index.status(name)
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
        snapshot.workers.each do |name, contract|
          next if contract.known?
          parts = ["consumer_contract", contract.unknown_reason, name, contract.fingerprint_parts]
          roots << {revision: snapshot.label, kind: "consumer_contract", reason: contract.unknown_reason, worker: name,
                    locations: contract.locations, parts: parts, offset: contract.locations.first&.line || 0}
        end
        snapshot.unknowns.each do |item|
          roots << {revision: snapshot.label, kind: item.kind, reason: item.reason, worker: item.worker,
                    locations: item.locations, parts: [item.kind, item.reason, item.worker, item.fingerprint_parts], offset: item.locations.first&.line || 0}
        end
        calls[snapshot.label].each do |call|
          next unless call[:reason]
          raw = call[:raw]
          kind = %w[dynamic_receiver unsupported_constant_path safe_navigation_receiver].include?(call[:reason]) ? "producer_receiver" : "producer_arity"
          roots << {revision: snapshot.label, kind: kind, reason: call[:reason], worker: call[:worker],
                    locations: [call[:location]], parts: [kind, call[:reason], call[:worker], raw.fingerprint_parts],
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
          else ["base_to_head", "head_to_head"]
          end
        end.uniq
        if first[:kind] == "producer_arity" && first[:worker]
          head_only_new = head.workers.key?(first[:worker]) && !base.workers.key?(first[:worker])
          directions.delete("head_to_base") if head_only_new && group.any? { |root| root[:revision] == "head" } && base.index.status(first[:worker]) == "absent"
        end
        finding("JC007", first[:worker], group.map { |root| root[:revision] }.uniq, directions, nil, first[:reason],
                "#{first[:reason]} prevents a complete positional compatibility check.",
                "The affected producer or consumer contract is unknown.", ["Use supported explicit syntax or inspect this call manually."],
                group.flat_map { |root| root[:locations] })
      end
    end

    def finding_sort_key(item)
      loc = item[:locations].first
      [item[:severity] == "error" ? 0 : 1, item[:rule_id], item[:worker] || "\u{10ffff}", item[:payload_arity] || Float::INFINITY,
       loc&.path.to_s, loc&.line || 0, item[:directions], item[:revisions], item[:unknown_reason].to_s]
    end
  end
end
