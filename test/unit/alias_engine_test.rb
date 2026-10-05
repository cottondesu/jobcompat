require_relative "../test_helper"
require_relative "../support/source_snapshot"

class AliasEngineTest < Minitest::Test
  include SourceSnapshot

  def evaluate(base, head)
    Jobcompat::Engine.new(source_snapshot(base, "base"), source_snapshot(head)).evaluate
  end

  def test_dormant_non_alias_writes_do_not_become_common_alias_warnings
    result = evaluate("VERSION = '1'\nLIMIT = 10", "VERSION = '2'\nLIMIT = 10")
    assert_empty result[:workers]
    assert_empty result[:findings]
  end

  def test_changed_control_flow_is_distinct_alias_evidence
    first = source_snapshot("if one?; OldJob = NewJob; end").aliases["OldJob"]
    second = source_snapshot("if two?; OldJob = NewJob; end").aliases["OldJob"]
    refute_equal first.fingerprint_parts, second.fingerprint_parts
  end

  def test_unknown_cross_revision_class_alias_keeps_diagnostic_attribution
    result = evaluate(direct_job + "OldJob = NewJob", "OldJob.perform_async(1)")
    unknown = result[:findings].find { |item| item[:rule_id] == "JC007" }
    assert_equal "OldJob", unknown[:worker]
    assert_equal "alias_target_unresolved", unknown[:unknown_reason]
    refute result[:findings].any? { |item| item[:rule_id] == "JC005" }
  end

  def test_unknown_alias_matrix_and_directions_use_serialized_producer_identity
    base = direct_job("OldJob") + "OldJob.perform_async(1)"
    head = "OldJob = MissingJob\nSidekiq::Client.push('class' => 'OldJob', 'args' => [1])"
    result = evaluate(base, head)
    worker = result[:workers].find { |item| item[:name] == "OldJob" }
    assert_equal "unknown", worker[:compatibility][:base_to_head]
    assert_equal "unknown", worker[:compatibility][:head_to_head]
    assert_equal %w[base_to_head head_to_head], result[:findings].first[:directions]
  end

  def test_alias_to_direct_and_direct_to_direct_metadata
    result = evaluate(direct_job + "OldJob = NewJob", direct_job + direct_job("OldJob"))
    worker = result[:workers].find { |item| item[:name] == "OldJob" }
    assert_equal "resolved_alias", worker[:base_presence]
    assert_equal "recognized_worker", worker[:head_presence]
    assert_equal "NewJob", worker[:base_alias][:target]
    assert_nil worker[:head_alias]
    assert_equal worker[:base_contract], worker[:head_contract]
    result[:workers].each { |item| assert_equal "not_applicable", item[:compatibility][:head_to_head] }
    assert_empty result[:findings]
  end

  def test_local_alias_normalization_preserves_required_current_mismatch
    base = direct_job("Admin::OldJob") + direct_job
    head = direct_job("NewJob", "id, other") + "OldJob = NewJob\nmodule Admin; OldJob.perform_async(1); end"
    result = evaluate(base, head)
    assert result[:findings].any? { |item| item[:rule_id] == "JC003" && item[:worker] == "NewJob" }
  end

  def test_opposite_alias_does_not_hide_new_local_worker_enqueues
    base = direct_job("ExistingJob") + "module Admin; OldJob = ::ExistingJob; end"
    head = direct_job("OldJob") + "module Admin; OldJob.perform_async(1); end"
    result = evaluate(base, head)
    assert result[:findings].any? { |item| item[:rule_id] == "JC005" && item[:worker] == "OldJob" }
  end

  def test_local_non_worker_shadow_does_not_manufacture_alias_errors
    head = direct_job + "OldJob = NewJob\nmodule Admin; class OldJob; end; " +
           "Sidekiq::Client.push('class' => OldJob, 'args' => [1, 2]); end"
    result = evaluate(direct_job, head)
    refute result[:findings].any? { |item| item[:severity] == "error" }
    warning = result[:findings].find { |item| item[:rule_id] == "JC007" }
    refute_nil warning
    assert_equal "Admin::OldJob", warning[:worker]
    assert_equal "worker_not_recognized", warning[:unknown_reason]
  end

  def test_ambiguous_binding_cannot_prove_retained_payload_compatibility
    base = direct_job("OldJob") + "OldJob.perform_async(1)"
    ["self::OldJob = OtherJob", "self::NewJob = OtherJob"].each do |blocker|
      head = direct_job + direct_job("OtherJob", "id, other") + "OldJob = NewJob\n#{blocker}"
      result = evaluate(base, head)
      worker = result[:workers].find { |item| item[:name] == "OldJob" }
      assert_equal "unknown", worker[:compatibility][:base_to_head], blocker
      assert result[:findings].any? { |item| item[:rule_id] == "JC007" && item[:worker] == "OldJob" && item[:unknown_reason] == "alias_binding_conflict" }
      refute result[:findings].any? { |item| item[:rule_id] == "JC004" && item[:worker] == "OldJob" }
    end
  end

  def test_unknown_alias_target_reports_selected_declaration_proof
    sources = {"app/alias.rb" => "OldJob = PlainJob", "app/plain.rb" => "class PlainJob; end"}
    result = evaluate(sources, sources)
    warning = result[:findings].find { |item| item[:worker] == "OldJob" && item[:unknown_reason] == "alias_target_unresolved" }
    assert_equal %w[app/alias.rb app/plain.rb], warning[:locations].map(&:path).uniq.sort
    assert_equal %w[base head], warning[:revisions]
  end

  def test_normalized_alias_producer_reports_terminal_identity_proof
    head = {"app/alias.rb" => "OldJob = NewJob\nOldJob.perform_async(1)",
            "app/job.rb" => "class NewJob\n  include Sidekiq::Job\n  def perform(id, other); end\nend"}
    finding = evaluate(direct_job, head)[:findings].find { |item| item[:rule_id] == "JC003" }
    assert_equal [1, 2, 3], finding[:locations].select { |location| location.path == "app/job.rb" }.map(&:line).uniq.sort
    assert_equal [1, 2], finding[:locations].select { |location| location.path == "app/alias.rb" }.map(&:line).uniq.sort
  end
end
