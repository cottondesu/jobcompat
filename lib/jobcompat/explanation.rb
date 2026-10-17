module Jobcompat
  Explanation = Data.define(:evidence, :decision, :boundary)

  module ExplanationBuilder
    REVISION_LABELS = {"base" => "BASE", "head" => "HEAD"}.freeze

    module_function

    def jc001(arity:, base_contract:, head_contract:, head_witness:, aliases:)
      evidence = [
        "BASE producer emits #{arity} positional #{argument_word(arity)}.",
        "BASE consumer accepts #{arity} positional #{argument_word(arity)} (#{range(base_contract)}).",
        "HEAD consumer accepts #{range(head_contract)} positional #{range_word(head_contract)}, rejecting #{arity}."
      ]
      evidence << "HEAD producer also emits #{arity} positional #{argument_word(arity)}, enqueuing the same payload shape." if head_witness
      decision = "A payload accepted in BASE (#{arity} positional #{argument_word(arity)}) is rejected by the HEAD worker (#{range(head_contract)})."
      decision << " HEAD producers still enqueue the same arity." if head_witness
      build(evidence + aliases, decision,
            "Static arity evidence; actual retained queue contents are not inspected.")
    end

    def jc002(arity:, base_contract:, head_contract:, aliases:)
      evidence = [
        "HEAD producer emits #{arity} positional #{argument_word(arity)}.",
        "HEAD consumer accepts #{range(head_contract)} positional #{range_word(head_contract)}.",
        "BASE consumer accepts #{range(base_contract)} positional #{range_word(base_contract)}, rejecting #{arity}."
      ]
      build(evidence + aliases,
            "A payload enqueued by HEAD (#{arity} positional #{argument_word(arity)}) would be rejected by the base worker if an old process executes it during the rolling deployment.",
            "Whether an old process consumes this queue, and when it retires, is not determined by static analysis.")
    end

    def jc003(arity:, head_contract:, aliases:)
      evidence = [
        "HEAD producer emits #{arity} positional #{argument_word(arity)}.",
        "HEAD consumer accepts #{range(head_contract)} positional #{range_word(head_contract)}, rejecting #{arity}."
      ]
      build(evidence + aliases,
            "HEAD's own producer and consumer disagree on payload arity.",
            "Static arity evidence within HEAD; base-revision evidence does not affect this finding.")
    end

    def jc004(worker:, base_contract:, head_producers:, aliases:)
      evidence = [consumer_fact("base", worker, base_contract),
                  "HEAD conservative presence check across tracked Ruby source proved #{worker} absent."]
      evidence << "HEAD still contains #{call_sites(distinct_call_sites(head_producers))} referencing this identity." if head_producers.any?
      build(evidence + aliases,
            "A retained job serialized as #{worker} cannot be resolved to a worker by HEAD tracked Ruby source.",
            "Static absence does not prove the queue is empty; queued, retried, scheduled, historical, or externally enqueued jobs may still reference this identity.")
    end

    def jc005(worker:, head_contract:, head_calls:, aliases:)
      evidence = ["HEAD producer can enqueue the serialized worker identity #{worker} (#{call_sites(distinct_call_sites(head_calls))})."]
      head_calls.map { |call| call[:attributed_worker] }.compact.uniq.sort.reject { |name| name == worker }.each do |name|
        evidence << "HEAD Class-object producer #{name} serializes as the terminal identity #{worker}."
      end
      evidence << "HEAD Client String producer keeps the exact identity #{worker}." if head_calls.any? { |call| call[:raw].resolution_mode == "exact_string" }
      known = head_calls.filter_map { |call| call[:arity] unless call[:reason] }.uniq.sort
      evidence << "Known HEAD payload arities for this identity: #{known.join(', ')}." if known.any?
      evidence << consumer_fact("head", worker, head_contract)
      evidence << "BASE conservative presence check across tracked Ruby source proved #{worker} absent."
      build(evidence + aliases,
            "If an old Sidekiq process consumes this job's queue during the rolling deployment, it cannot resolve the serialized identity #{worker}.",
            "This does not prove unconditional failure; the risk is conditional on an old process consuming the relevant queue before retirement, which static analysis cannot determine.")
    end

    def jc006(worker:, base_contract:, head_contract:, removed:, aliases:)
      evidence = [
        consumer_fact("base", worker, base_contract),
        consumer_fact("head", worker, head_contract),
        "HEAD no longer accepts #{removed.length == 1 && removed.first.match?(/\A\d+\z/) ? "arity" : "arities"} #{removed.join(', ')}.",
        "No qualifying producer witness was found for the removed range in either revision."
      ]
      build(evidence + aliases,
            "The worker contract narrowed from #{range(base_contract)} to #{range(head_contract)} without a qualifying producer witness.",
            "No repository producer witness does not prove that no queued, scheduled, retried, historical, or externally enqueued payload exists.")
    end

    def presence_unknown(worker:, status:, revision:)
      label = REVISION_LABELS.fetch(revision)
      fact = case status
             when "defined_unrecognized" then "#{worker} is defined in #{label} selected source, but is not recognized as a Sidekiq worker."
             when "outside_scan_scope" then "#{worker} is declared only outside the scan scope in #{label}."
             when "unverified" then "Presence of #{worker} in #{label} could not be verified within the analysis budget."
             end
      build([fact],
            "The Sidekiq contract for #{worker} is not recognized, so this transition cannot be proven.",
            "Unknown is not a proof of compatibility; the affected evidence was excluded from the compatibility decision.")
    end

    def unknown_group(roots:, message:)
      build(roots.map { |root| root_fact(root) }, message,
            "Unknown or unsupported evidence is not a proof of compatibility; the affected calls or contracts were excluded from the compatibility decision.")
    end

    def root_fact(root)
      label = REVISION_LABELS.fetch(root[:revision])
      case root[:kind]
      when "consumer_contract" then "#{label}: the consumer contract for #{root[:worker]} is unknown (#{root[:reason]})."
      when "consumer_alias"
        chain = root[:chain]
        path = chain && chain.length > 1 ? chain.join(" -> ") : "unresolved"
        "Alias (#{label}): #{path} (#{root[:reason]})."
      when "worker_identity" then "#{label}: a Sidekiq-including class is declared through an unsupported constant path."
      when "producer_receiver"
        root[:worker] ? "#{label}: the producer receiver for #{root[:worker]} could not be resolved (#{root[:reason]})." :
          "#{label}: a producer receiver could not be resolved (#{root[:reason]})."
      when "producer_arity"
        root[:worker] ? "#{label}: the payload arity for #{root[:worker]} could not be determined (#{root[:reason]})." :
          "#{label}: a producer payload arity could not be determined (#{root[:reason]})."
      end
    end

    def consumer_fact(revision, worker, contract)
      contract.known? ?
        "#{REVISION_LABELS.fetch(revision)} consumer #{worker} accepts #{range(contract)} positional #{range_word(contract)}." :
        "#{REVISION_LABELS.fetch(revision)} consumer #{worker} has an unknown contract (#{contract.unknown_reason})."
    end

    def range_word(contract)
      contract.display_range.match?(/\A\d+\z/) ? argument_word(contract.display_range.to_i) : "arguments"
    end

    def range(contract)
      contract.display_range
    end

    def argument_word(number)
      number == 1 ? "argument" : "arguments"
    end

    def call_sites(number)
      "#{number} call site#{number == 1 ? '' : 's'}"
    end

    def distinct_call_sites(calls)
      calls.map { |call| call[:location] }.uniq { |location| [location.revision, location.path, location.line, location.column] }.length
    end

    def build(evidence, decision, boundary)
      Explanation.new(evidence.freeze, decision, boundary).freeze
    end
  end
end
