require_relative "../test_helper"
require_relative "../support/source_snapshot"

class ExplanationTest < Minitest::Test
  def setup
    @head_call = lambda do |mode, arity, attributed, worker|
      raw = Jobcompat::Call.new("head", "app/p.rb", nil, attributed, mode, false, nil, [], "perform_async", arity, nil, [])
      {worker: worker, attributed_worker: attributed, identity_known: !worker.nil?, identity_reason: nil,
       location: Jobcompat::Location.new("head", "app/p.rb", 5, 1, "producer", nil), locations: [], arity: arity, reason: nil, raw: raw}
    end
  end

  def test_explanation_value_object_is_immutable
    explanation = Jobcompat::ExplanationBuilder.jc003(arity: 2, head_contract: contract("ExportJob", 1, 1), aliases: [])
    assert_equal ["HEAD producer emits 2 positional arguments.",
                  "HEAD consumer accepts 1 positional argument, rejecting 2."], explanation.evidence
    assert_equal "HEAD's own producer and consumer disagree on payload arity.", explanation.decision
    assert_equal "Static arity evidence within HEAD; base-revision evidence does not affect this finding.", explanation.boundary
    assert_predicate explanation, :frozen?
    assert_predicate explanation.evidence, :frozen?
  end

  def test_jc001_witness_variation
    without = Jobcompat::ExplanationBuilder.jc001(arity: 1, base_contract: contract("W", 1, 1),
                                                  head_contract: contract("W", 2, 2), head_witness: false, aliases: [])
    with = Jobcompat::ExplanationBuilder.jc001(arity: 1, base_contract: contract("W", 1, 2),
                                                head_contract: contract("W", 2, 2), head_witness: true, aliases: [])
    refute_includes without.evidence.join, "HEAD producer also emits"
    refute_includes without.decision, "HEAD producers still enqueue"
    assert_includes with.evidence.join, "HEAD producer also emits 1 positional argument"
    assert_includes with.decision, "HEAD producers still enqueue the same arity."
    assert_includes without.boundary, "retained queue contents are not inspected"
  end

  def test_jc005_identity_lines
    calls = [@head_call.call("lexical_constant", 1, "OldJob", "NewJob"), @head_call.call("exact_string", 1, "NewJob", "NewJob")]
    explanation = Jobcompat::ExplanationBuilder.jc005(worker: "NewJob", head_contract: contract("NewJob", 1, 1),
                                                      head_calls: calls, aliases: [])
    text = explanation.evidence.join("\n")
    assert_includes text, "HEAD Class-object producer OldJob serializes as the terminal identity NewJob."
    assert_includes text, "HEAD Client String producer keeps the exact identity NewJob."
    assert_includes text, "Known HEAD payload arities for this identity: 1."
    assert_includes text, "BASE conservative presence check across tracked Ruby source proved NewJob absent."
    assert_includes explanation.decision, "If an old Sidekiq process consumes this job's queue"
    assert_includes explanation.boundary, "does not prove unconditional failure"
  end

  def test_jc005_omits_unknown_arities
    call = @head_call.call("client_constant", nil, "ExportJob", "ExportJob")
    call[:reason] = "dynamic_client_args"
    explanation = Jobcompat::ExplanationBuilder.jc005(worker: "ExportJob", head_contract: contract("ExportJob", 1, 1),
                                                      head_calls: [call], aliases: [])
    refute_includes explanation.evidence.join, "Known HEAD payload arities"
  end

  def test_jc006_arity_labels
    single = Jobcompat::ExplanationBuilder.jc006(worker: "W", base_contract: contract("W", 1, 2),
                                                 head_contract: contract("W", 2, 2), removed: ["1"], aliases: [])
    range = Jobcompat::ExplanationBuilder.jc006(worker: "W", base_contract: contract("W", 1, nil),
                                                head_contract: contract("W", 1, 2), removed: ["3..∞"], aliases: [])
    assert_includes single.evidence.join, "HEAD no longer accepts arity 1."
    assert_includes range.evidence.join, "HEAD no longer accepts arities 3..∞."
    assert_includes single.boundary, "does not prove that no queued, scheduled, retried, historical, or externally enqueued payload exists"
  end

  def test_presence_unknown_statuses_never_claim_absence
    statuses = {"defined_unrecognized" => "is defined in HEAD selected source, but is not recognized",
                "outside_scan_scope" => "is declared only outside the scan scope in HEAD",
                "unverified" => "could not be verified within the analysis budget"}
    statuses.each do |status, fragment|
      explanation = Jobcompat::ExplanationBuilder.presence_unknown(worker: "W", status: status, revision: "head")
      assert_includes explanation.evidence.join, fragment
      refute_includes explanation.evidence.join, "proved W absent"
      assert_includes explanation.boundary, "Unknown is not a proof of compatibility"
    end
  end

  def test_unknown_group_roots
    roots = [
      {revision: "head", kind: "consumer_alias", reason: "alias_cycle", worker: "OldJob", chain: %w[OldJob MiddleJob OldJob], locations: [], offset: 0},
      {revision: "head", kind: "producer_arity", reason: "splat_arguments", worker: "OldJob", locations: [], offset: [3, 1]}
    ]
    explanation = Jobcompat::ExplanationBuilder.unknown_group(roots: roots, message: "Compatibility alias resolution for OldJob enters a constant-alias cycle.")
    text = explanation.evidence.join("\n")
    assert_includes text, "Alias (HEAD): OldJob -> MiddleJob -> OldJob (alias_cycle)."
    assert_includes text, "HEAD: the payload arity for OldJob could not be determined (splat_arguments)."
    assert_equal "Compatibility alias resolution for OldJob enters a constant-alias cycle.", explanation.decision
    unresolved = Jobcompat::ExplanationBuilder.unknown_group(
      roots: [{revision: "base", kind: "consumer_alias", reason: "alias_target_unresolved", worker: "OldJob", chain: ["OldJob"], locations: [], offset: 0}],
      message: "OldJob is bound as a compatibility alias, but its target cannot be resolved to a supported Sidekiq worker.")
    assert_includes unresolved.evidence.join, "Alias (BASE): unresolved (alias_target_unresolved)."
  end

  def test_consumer_fact_grammar
    known = Jobcompat::ExplanationBuilder.consumer_fact("head", "W", contract("W", 1, 1))
    variadic = Jobcompat::ExplanationBuilder.consumer_fact("head", "W", contract("W", 1, nil))
    unknown = Jobcompat::ExplanationBuilder.consumer_fact("base", "W", Jobcompat::Contract.new("W", nil, nil, nil, nil, "keyword_parameters", [], [], []))
    assert_equal "HEAD consumer W accepts 1 positional argument.", known
    assert_equal "HEAD consumer W accepts 1..∞ positional arguments.", variadic
    assert_equal "BASE consumer W has an unknown contract (keyword_parameters).", unknown
  end

  def test_formatter_renders_explanation_only_with_sidecar
    finding = finding_hash
    body = envelope([finding])
    plain = Jobcompat::Formatter.text(body)
    assert_equal plain, Jobcompat::Formatter.text(body, explanations: nil)
    assert_equal plain, Jobcompat::Formatter.text(body, explanations: {}.compare_by_identity)
    refute_includes plain, "Explanation:"
    explanations = {}.compare_by_identity
    explanations[finding] = Jobcompat::Explanation.new(["Fact one."], "Decision text.", "Boundary text.")
    explained = Jobcompat::Formatter.text(body, explanations: explanations)
    expected_block = "  Explanation:\n    Evidence:\n      Fact one.\n    Decision:\n      Decision text.\n    Boundary:\n      Boundary text.\n"
    assert_includes explained, expected_block
    insertion = explained.index("  Explanation:")
    assert insertion > explained.index("(consumer)")
    assert insertion < explained.index("  Suggested migration:")
    other = finding_hash
    explanations.delete(finding)
    explanations[other] = Jobcompat::Explanation.new(["Fact."], "D.", "B.")
    refute_includes Jobcompat::Formatter.text(body, explanations: explanations), "Explanation:"
  end

  def test_formatter_sanitizes_explanation_lines
    finding = finding_hash
    explanations = {}.compare_by_identity
    explanations[finding] = Jobcompat::Explanation.new(["bad\nline\e[31m"], "D", "B")
    explained = Jobcompat::Formatter.text(envelope([finding]), explanations: explanations)
    assert_includes explained, "\\x0A"
    assert_includes explained, "\\x1B"
    refute explained.include?("bad\nline")
  end

  private

  def contract(name, min, max)
    Jobcompat::Contract.new(name, min, max, "positional", "perform(id)", nil,
                            [Jobcompat::Location.new("head", "app/w.rb", 2, 3, "consumer", nil)],
                            [Jobcompat::Location.new("head", "app/w.rb", 1, 0, "worker_declaration", nil)], [])
  end

  def finding_hash
    {rule_id: "JC001", title: "Old payload rejected by new worker", severity: "error", worker: "ExportJob",
     revisions: %w[base head], directions: %w[base_to_head], unknown_reason: nil,
     message: "Base emits 1 argument, but the HEAD worker accepts 2.",
     risk: "Jobs queued by the base revision may fail after deployment.",
     remediation: ["Make the HEAD worker accept old payloads."], payload_arity: 1,
     locations: [Jobcompat::Location.new("base", "app/export_job.rb", 4, 3, "consumer", nil)]}
  end

  def envelope(findings)
    {schema_version: 3, tool: {name: "jobcompat", version: Jobcompat::VERSION}, status: "completed",
     comparison: {deployment_model: "rolling", base: {ref: "b" * 40, sha: "0" * 40}, head: {ref: "HEAD", sha: "1" * 40}},
     configuration: {path: nil}, findings: findings, suppressions: [], workers: [], diagnostics: [],
     summary: {errors: findings.length, warnings: 0, suppressed: 0, files_scanned: {base: 1, head: 1},
               workers: {base: 1, head: 1}, enqueue_calls: {base: 1, head: 1, unknown: 0}}}
  end
end

class BulkCallSiteCountTest < Minitest::Test
  include SourceSnapshot

  def explained_evidence(base_source, head_source, rule)
    engine = Jobcompat::Engine.new(source_snapshot(base_source, "base"), source_snapshot(head_source, "head"))
    result = engine.evaluate(with_explanations: true)
    finding = result[:findings].find { |item| item[:rule_id] == rule }
    refute_nil finding, "expected a #{rule} finding"
    [engine, result, result[:explanations].fetch(finding).evidence]
  end

  def test_jc005_worker_bulk_counts_one_source_call_site
    head = direct_job("W", "a, *rest") + "args = [9]\nW.perform_bulk([[1], [1, 2], args])\n"
    engine, result, evidence = explained_evidence("# empty\n", head, "JC005")
    assert_equal 1, engine.calls["head"].map { |call| [call[:location].revision, call[:location].path, call[:location].line, call[:location].column] }.uniq.length
    assert_includes evidence.join("\n"), "HEAD producer can enqueue the serialized worker identity W (1 call site)."
  end

  def test_jc004_worker_bulk_counts_one_source_call_site
    evidence = explained_evidence(direct_job("W", "a, *rest"), "args = [9]\nW.perform_bulk([[1], [1, 2], args])\n", "JC004")[2]
    assert_includes evidence.join("\n"), "HEAD still contains 1 call site referencing this identity."
  end

  def test_jc005_client_bulk_counts_one_source_call_site
    head = direct_job("W", "a, *rest") + "args = [9]\nSidekiq::Client.push_bulk(\"class\" => \"W\", \"args\" => [[1], [1, 2], args])\n"
    evidence = explained_evidence("# empty\n", head, "JC005")[2]
    assert_includes evidence.join("\n"), "HEAD producer can enqueue the serialized worker identity W (1 call site)."
  end

  def test_known_unknown_overlap_counts_one_site
    head = direct_job("W", "a, *rest") + "args = [9]\nW.perform_bulk([[1], args])\n"
    evidence = explained_evidence("# empty\n", head, "JC005")[2]
    assert_includes evidence.join("\n"), "HEAD producer can enqueue the serialized worker identity W (1 call site)."
    assert_includes evidence.join("\n"), "Known HEAD payload arities for this identity: 1."
  end

  def test_two_independent_bulk_calls_count_two_sites
    head = direct_job("W", "a, *rest") + "W.perform_bulk([[1]])\nW.perform_bulk([[2]])\n"
    evidence = explained_evidence("# empty\n", head, "JC005")[2]
    assert_includes evidence.join("\n"), "HEAD producer can enqueue the serialized worker identity W (2 call sites)."
  end

  def test_same_line_independent_calls_count_two_sites
    head = direct_job("W", "a, *rest") + "W.perform_async(1); W.perform_async(1, 2)\n"
    evidence = explained_evidence("# empty\n", head, "JC005")[2]
    assert_includes evidence.join("\n"), "HEAD producer can enqueue the serialized worker identity W (2 call sites)."
  end

  def test_non_bulk_single_call_still_counts_one
    head = direct_job("W", "a, *rest") + "W.perform_async(1)\n"
    evidence = explained_evidence("# empty\n", head, "JC005")[2]
    assert_includes evidence.join("\n"), "HEAD producer can enqueue the serialized worker identity W (1 call site)."
  end

  def test_distinct_call_sites_ignores_role_and_declaration_locations
    calls = [
      {location: Jobcompat::Location.new("head", "app/p.rb", 4, 1, "producer", nil), arity: 1, reason: nil, attributed_worker: "W", raw: nil},
      {location: Jobcompat::Location.new("head", "app/p.rb", 4, 1, "unknown_call", nil), arity: nil, reason: "dynamic_bulk_arguments", attributed_worker: "W", raw: nil},
      {location: Jobcompat::Location.new("head", "app/p.rb", 4, 1, "worker_declaration", nil), arity: 2, reason: nil, attributed_worker: "W", raw: nil}
    ]
    assert_equal 1, Jobcompat::ExplanationBuilder.distinct_call_sites(calls)
    calls << {location: Jobcompat::Location.new("base", "app/p.rb", 4, 1, "producer", nil), arity: 1, reason: nil, attributed_worker: "W", raw: nil}
    assert_equal 2, Jobcompat::ExplanationBuilder.distinct_call_sites(calls)
  end
end
