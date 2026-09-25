require_relative "../test_helper"
require_relative "../support/temporary_repository"

class SpecFreezeTest < Minitest::Test
  include TemporaryRepository

  def test_supported_reopened_perform_conflict_uses_existing_jc007_reason
    with_repository do |dir|
      base = commit(dir, "app/include.rb" => "class ExportJob; include Sidekiq::Job; end\n",
                         "app/perform.rb" => "class ExportJob; def perform(id); end; end\n")
      commit(dir, "app/second_perform.rb" => "class ExportJob; def perform(id, format); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "multiple_perform_definitions", data["findings"][0]["unknown_reason"]
      assert_equal "unknown", data["workers"][0]["head_contract"]["status"]
      assert_equal 1, data["summary"]["workers"]["head"]
    end
  end

  def test_class_module_disagreement_does_not_add_general_fragment_conflict_finding
    with_repository do |dir|
      base = commit(dir, "app/job.rb" => worker)
      commit(dir, "app/reopen.rb" => "module ExportJob; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal "known", data["workers"][0]["head_contract"]["status"]
    end
  end

  def test_different_superclasses_do_not_add_general_fragment_conflict_finding
    with_repository do |dir|
      source = "class ExportJob < BaseA; include Sidekiq::Job; def perform(id); end; end\n"
      base = commit(dir, "app/job.rb" => source)
      commit(dir, "app/reopen.rb" => "class ExportJob < BaseB; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal "known", data["workers"][0]["head_contract"]["status"]
    end
  end

  def test_supported_include_and_perform_fragments_merge_without_conflict
    with_repository do |dir|
      source = {"app/include.rb" => "class ExportJob; include Sidekiq::Job; end\n",
                "app/perform.rb" => "class ExportJob; def perform(id); end; end\n"}
      sha = commit(dir, source)
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal 1, data["summary"]["workers"]["head"]
      assert_equal [1, 1], data["workers"][0]["head_contract"].values_at("min_arity", "max_arity")
    end
  end

  def test_file_rename_and_outside_scope_move
    with_repository do |dir|
      base = commit(dir, "app/jobs/export_job.rb" => worker)
      commit(dir, "app/jobs/export_job.rb" => nil, "app/workers/export_job.rb" => worker)
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_empty data["findings"]
      commit(dir, "app/workers/export_job.rb" => nil, "vendor/export_job.rb" => worker)
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "outside_analysis_scope", data["findings"][0]["unknown_reason"]
    end
  end

  def test_reopened_perform_moves_outside_scope
    with_repository do |dir|
      base = commit(dir, "app/include.rb" => "class ExportJob; include Sidekiq::Job; end\n",
                         "app/perform.rb" => "class ExportJob; def perform(id); end; end\n")
      commit(dir, "app/perform.rb" => nil, "vendor/perform.rb" => "class ExportJob; def perform(id); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "missing_perform", data["findings"][0]["unknown_reason"]
    end
  end

  def test_new_worker_without_enqueue_does_not_query_base_presence
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/export_job.rb" => worker)
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal "not_checked", data["workers"].find { |item| item["name"] == "ExportJob" }["base_presence"]
    end
  end

  def test_new_worker_with_base_class_binding_is_not_jc005
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "ExportJob = Class.new\n")
      commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "worker_not_recognized", data["findings"][0]["unknown_reason"]
    end
  end

  def test_ambiguous_head_class_path_blocks_removal_error
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => "class self::ExportJob; include Sidekiq::Job; def perform(id); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      refute_includes data["findings"].map { |item| item["rule_id"] }, "JC004"
      assert data["findings"].any? { |item| item["rule_id"] == "JC007" }
    end
  end

  def test_static_constant_update_bindings_block_absence_errors
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      ["ExportJob ||= Class.new\n", "ExportJob, Other = Class.new, 1\n"].each do |source|
        commit(dir, "app/export_job.rb" => source)
        data, _, code = json_check(dir, base)
        assert_equal 0, code
        assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      end
    end
  end

  def test_ambiguous_qualified_multiassignment_blocks_removal_error
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => "self::ExportJob, Other = Class.new, 1\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "presence_unverified", data["findings"][0]["unknown_reason"]
    end
  end

  def test_unknown_consumer_lexical_declaration_change_is_distinct_evidence
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "module Admin; class ExportJob; include Sidekiq::Job; def perform(id:); end; end; end\n")
      commit(dir, "app/export_job.rb" => "class Admin::ExportJob; include Sidekiq::Job; def perform(id:); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_irrelevant_reopened_fragment_move_does_not_split_consumer_unknown
    with_repository do |dir|
      base = commit(dir, "app/job.rb" => worker("id:"), "app/a.rb" => "class ExportJob; end\n")
      commit(dir, "app/a.rb" => nil, "app/b.rb" => "class ExportJob; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 1, data["findings"].length
      assert_equal %w[base head], data["findings"][0]["revisions"]
      assert_equal ["app/job.rb"], data["findings"][0]["locations"].map { |item| item["path"] }.uniq
    end
  end

  def test_singleton_class_scope_changes_unknown_call_identity
    with_repository do |dir|
      base = commit(dir, "app/job.rb" => worker + "class Host; ExportJob.perform_async(*args); end\n")
      commit(dir, "app/job.rb" => worker + "class Host; class << self; ExportJob.perform_async(*args); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_unknown_call_moved_from_parameter_default_to_body_is_distinct
    with_repository do |dir|
      source = worker + "def enqueue(id = ExportJob.perform_async(*args)); end\n"
      base = commit(dir, "app/export_job.rb" => source)
      commit(dir, "app/export_job.rb" => worker + "def enqueue(id = nil); ExportJob.perform_async(*args); end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_optional_to_required_without_witness_warns
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("id, format=nil"))
      commit(dir, "app/export_job.rb" => worker("id, format"))
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC006"], data["findings"].map { |item| item["rule_id"] }
      assert_match(/removed arit(?:y|ies).*1/i, data["findings"][0]["message"])
    end
  end

  def test_jc006_names_both_disjoint_removed_arity_ranges
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("a=nil, b=nil, c=nil, d=nil"))
      commit(dir, "app/export_job.rb" => worker("a, b=nil, c=nil"))
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC006"], data["findings"].map { |item| item["rule_id"] }
      assert_match(/removed arities.*0.*4/i, data["findings"][0]["message"])
    end
  end

  def test_baseline_mismatch_is_not_promoted
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("id") + "ExportJob.perform_async(1, 2)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1, 2)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal %w[JC002 JC006], data["findings"].map { |item| item["rule_id"] }
      refute_includes data["findings"].map { |item| item["rule_id"] }, "JC001"
    end
  end

  def test_head_only_current_mismatch_suppresses_jc006
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("id, format=nil"))
      commit(dir, "app/export_job.rb" => worker("id") + "ExportJob.perform_async(1, 2)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC003"], data["findings"].map { |item| item["rule_id"] }
    end
  end

  def test_unknown_consumer_dedup_ignores_body_changes
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "class ExportJob; include Sidekiq::Job; def perform(id:); one; end; end\n")
      commit(dir, "app/export_job.rb" => "class ExportJob; include Sidekiq::Job; def perform(id:); two; end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 1, data["findings"].length
      assert_equal %w[base head], data["findings"][0]["revisions"]
    end
  end

  def test_different_duplicate_perform_signature_is_distinct_unknown_evidence
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "class ExportJob; include Sidekiq::Job; def perform(id); end; def perform(id, x); end; end\n")
      commit(dir, "app/export_job.rb" => "class ExportJob; include Sidekiq::Job; def perform(id); end; def perform(id, x, y); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 2, data["findings"].length
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_changed_include_for_missing_perform_is_distinct_unknown_evidence
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "class ExportJob; include Sidekiq::Job; end\n")
      commit(dir, "app/export_job.rb" => "class ExportJob; include Sidekiq::Worker; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 2, data["findings"].length
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_multiline_include_changes_are_distinct_unknown_evidence
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "class ExportJob\n include(\n  Sidekiq::Job\n )\nend\n")
      commit(dir, "app/export_job.rb" => "class ExportJob\n include(\n  Sidekiq::Worker\n )\nend\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 2, data["findings"].length
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_changed_include_for_unknown_worker_identity_is_distinct
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => "class self::ExportJob; include Sidekiq::Job; end\n")
      commit(dir, "app/export_job.rb" => "class self::ExportJob; include Sidekiq::Worker; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 2, data["findings"].length
      assert_equal [%w[base], %w[head]], data["findings"].map { |item| item["revisions"] }.sort
    end
  end

  def test_unknown_calls_with_different_scope_do_not_merge
    with_repository do |dir|
      source = worker + "def first; ExportJob.perform_async(*args); end\ndef second; ExportJob.perform_async(*args); end\n"
      base = commit(dir, "app/export_job.rb" => source)
      commit(dir, "app/export_job.rb" => source + "# edit\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 2, data["findings"].length
      assert data["findings"].all? { |item| item["revisions"] == %w[base head] }
    end
  end

  def test_namespaced_worker_and_lexical_producer_resolution
    with_repository do |dir|
      source = "module Admin; class ExportJob; include Sidekiq::Worker; def perform(id); end; end; ExportJob.perform_async(1); end\n"
      base = commit(dir, "app/admin.rb" => source)
      commit(dir, "app/admin.rb" => source.sub("def perform(id)", "def perform(id, format)"))
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal "Admin::ExportJob", data["findings"][0]["worker"]
    end
  end

  def test_same_worker_basename_in_different_namespaces_is_not_conflated
    with_repository do |dir|
      source = <<~RUBY
        module Admin; class ExportJob; include Sidekiq::Job; def perform(id); end; end; end
        module Sales; class ExportJob; include Sidekiq::Job; def perform(id); end; end; end
        Admin::ExportJob.perform_async(1)
        Sales::ExportJob.perform_async(1)
      RUBY
      base = commit(dir, "app/jobs.rb" => source)
      commit(dir, "app/jobs.rb" => source.sub("module Admin; class ExportJob; include Sidekiq::Job; def perform(id)",
                                               "module Admin; class ExportJob; include Sidekiq::Job; def perform(id, format)"))
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC001"], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["Admin::ExportJob"], data["findings"].map { |item| item["worker"] }
    end
  end

  def test_new_worker_with_unknown_arity_keeps_jc005_and_limits_jc007_direction
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/job.rb" => worker + "ExportJob.perform_async(*args)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal %w[JC005 JC007], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["head_to_base"], data["findings"][0]["directions"]
      assert_equal ["head_to_head"], data["findings"][1]["directions"]
    end
  end

  def test_explicit_module_path_does_not_invent_parent_lexical_scope
    with_repository do |dir|
      source = <<~RUBY
        module A; end
        class A::ExportJob; include Sidekiq::Job; def perform(id, format); end; end
        module A::B
          ExportJob.perform_async(1)
        end
      RUBY
      sha = commit(dir, "app/jobs.rb" => source)
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal 0, data["workers"].find { |item| item["name"] == "A::ExportJob" }["producer_arities"]["head"].length
    end
  end

  def test_ambiguous_outer_path_does_not_assign_name_to_nested_worker
    with_repository do |dir|
      source = <<~RUBY
        module Tenant
          class Admin::Container
            class InnerJob
              include Sidekiq::Job
              def perform(id); end
            end
          end
        end
      RUBY
      sha = commit(dir, "app/jobs.rb" => source)
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_empty data["workers"]
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_nil data["findings"][0]["worker"]
    end
  end

  def test_producer_under_ambiguous_outer_path_warns_without_crashing
    with_repository do |dir|
      source = <<~RUBY
        module Tenant
          class Admin::Container
            ExportJob.perform_async(1)
          end
        end
      RUBY
      sha = commit(dir, "app/jobs.rb" => source)
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "unsupported_constant_path", data["findings"][0]["unknown_reason"]
      assert_nil data["findings"][0]["worker"]
    end
  end

  def test_same_commit_still_checks_head_internal_mismatch
    with_repository do |dir|
      sha = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1, 2)\n")
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 1, code
      assert_equal ["JC003"], data["findings"].map { |item| item["rule_id"] }
    end
  end

  def test_calls_in_method_defaults_and_superclass_expressions_are_discovered
    with_repository do |dir|
      source = worker + <<~RUBY
        def enqueue(id = ExportJob.perform_async(1)); end
        class Other < (ExportJob.perform_async(1); Object); end
      RUBY
      base = commit(dir, "app/jobs.rb" => source)
      commit(dir, "app/jobs.rb" => source.sub("def perform(id)", "def perform(id, format)"))
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC001"], data["findings"].map { |item| item["rule_id"] }
      assert_equal %w[base_to_head head_to_head], data["findings"][0]["directions"]
      assert_equal 4, data["findings"][0]["locations"].count { |location| location["role"] == "producer" }
    end
  end

  def test_unknown_static_constant_is_not_a_sidekiq_producer
    with_repository do |dir|
      source = worker + "Plain.perform_async(*args)\n"
      sha = commit(dir, "app/jobs.rb" => source)
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal [], data["workers"][0]["producer_arities"]["head"]
    end
  end

  def test_safe_navigation_does_not_serialize_a_known_producer_arity
    with_repository do |dir|
      sha = commit(dir, "app/jobs.rb" => worker + "ExportJob&.perform_async(1)\n")
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal [], data["workers"][0]["producer_arities"]["head"]
      assert_equal 1, data["workers"][0]["producer_arities"]["head_unknown_calls"]
    end
  end

  def test_unknown_worker_identity_has_consumer_directions
    with_repository do |dir|
      sha = commit(dir, "app/jobs.rb" => "class self::ExportJob; include Sidekiq::Job; end\n")
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal %w[base_to_head head_to_base head_to_head], data["findings"][0]["directions"]
    end
  end

  def test_qualified_multiple_assignment_blocks_removal_error
    with_repository do |dir|
      base = commit(dir, "app/jobs.rb" => "module Admin; class ExportJob; include Sidekiq::Job; def perform(id); end; end; end\n")
      commit(dir, "app/jobs.rb" => "module Admin; end\nAdmin::ExportJob, Other = Class.new, 1\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "worker_not_recognized", data["findings"][0]["unknown_reason"]
    end
  end

  def test_new_worker_current_mismatch_is_reported_alongside_jc005
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/jobs.rb" => worker + "ExportJob.perform_async(1, 2)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal %w[JC003 JC005], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["head_to_head"], data["findings"][0]["directions"]
      assert_equal ["head_to_base"], data["findings"][1]["directions"]
    end
  end

  def test_head_current_mismatch_is_reported_when_base_contract_is_unknown
    with_repository do |dir|
      base = commit(dir, "app/jobs.rb" => worker("id:"))
      commit(dir, "app/jobs.rb" => worker + "ExportJob.perform_async(1, 2)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal %w[JC003 JC007], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["head_to_head"], data["findings"][0]["directions"]
    end
  end
end
