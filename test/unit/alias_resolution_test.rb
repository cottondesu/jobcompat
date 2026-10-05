require_relative "../test_helper"
require_relative "../support/source_snapshot"

class AliasResolutionTest < Minitest::Test
  include SourceSnapshot

  def test_supported_ast_forms_and_contexts
    cases = {
      "OldJob = NewJob" => ["OldJob", "NewJob"],
      "OldJob = (NewJob)" => ["OldJob", "NewJob"],
      "::OldJob = ::NewJob" => ["OldJob", "NewJob"],
      "Admin::OldJob = Admin::NewJob" => ["Admin::OldJob", "Admin::NewJob"],
      "module Admin; OldJob = NewJob; end" => ["Admin::OldJob", "Admin::NewJob"],
      "module Admin; OldJob = ::NewJob; end" => ["Admin::OldJob", "NewJob"],
      "module Admin; module Jobs; OldJob = NewJob; end; end" => ["Admin::Jobs::OldJob", "Admin::NewJob"],
      "class Holder; OldJob = ::NewJob; end" => ["Holder::OldJob", "NewJob"]
    }
    cases.each do |assignment, (name, target)|
      snapshot = source_snapshot(direct_job + direct_job("Admin::NewJob") + assignment)
      binding = snapshot.aliases.fetch(name)
      assert_equal ["resolved", target, [name, target], nil], binding.as_json.values, assignment
      assert_equal "resolved_alias", snapshot.presence(name)
      assert_equal 1, snapshot.consumer(name).min_arity
    end
  end

  def test_unsupported_assignment_forms_and_contexts
    sources = [
      "OldJob ||= NewJob", "OldJob &&= NewJob", "OldJob += NewJob",
      "OldJob = worker_class", "OldJob = enabled? ? NewJob : OtherJob",
      "OldJob = [NewJob].first", "OldJob = build_worker()", "OldJob = Class.new",
      "OldJob = Class.new { include Sidekiq::Job }", "OldJob, Other = NewJob, 1",
      "OldJob = NewJob if enabled?", "OldJob = NewJob unless enabled?",
      "if enabled?; OldJob = NewJob; end", "case flag; when true; OldJob = NewJob; end",
      "while enabled?; OldJob = NewJob; end", "until enabled?; OldJob = NewJob; end",
      "for x in xs; OldJob = NewJob; end", "jobs.each { OldJob = NewJob }",
      "-> { OldJob = NewJob }", "begin; OldJob = NewJob; rescue; end",
      "begin; OldJob = NewJob; end", "class << self; OldJob = NewJob; end",
      "(OldJob = NewJob)", "if flag; class Holder; OldJob = NewJob; end; end",
      "module Admin; OldJob = Other::NewJob; end"
    ]
    sources.each do |assignment|
      snapshot = source_snapshot(direct_job + assignment)
      binding = snapshot.aliases.values.find { |item| item.name.end_with?("OldJob") }
      refute_nil binding, assignment
      assert_equal "unsupported_alias_assignment", binding.unknown_reason, assignment
      assert_nil snapshot.consumer(binding.name), assignment
    end
  end

  def test_dynamic_constant_apis_are_not_aliases
    snapshot = source_snapshot(direct_job + "Object.const_set(:OldJob, NewJob)\nautoload(:OldJob, 'old_job')\n")
    assert_empty snapshot.aliases
  end

  def test_cross_file_chains_and_source_order_independence
    sources = {"app/c.rb" => "OldJob = MiddleJob\n", "app/b.rb" => "MiddleJob = NewJob\n", "app/a.rb" => direct_job}
    first = source_snapshot(sources)
    second = source_snapshot(sources.to_a.reverse.to_h)
    assert_equal %w[OldJob MiddleJob NewJob], first.aliases["OldJob"].chain
    assert_equal first.aliases.transform_values(&:as_json), second.aliases.transform_values(&:as_json)
    assert_equal %w[app/a.rb app/b.rb app/c.rb], first.consumer("OldJob").locations.map(&:path).uniq.sort
  end

  def test_lookup_uses_namespace_stack_and_unknown_shadowing
    source = direct_job + direct_job("Admin::NewJob") + direct_job("Admin::Jobs::NewJob") +
             "module Admin; module Jobs; OldJob = NewJob; end; end"
    assert_equal "Admin::Jobs::NewJob", source_snapshot(source).aliases["Admin::Jobs::OldJob"].target
    source = direct_job + "module Admin; NewJob = choose_job; OldJob = NewJob; end"
    binding = source_snapshot(source).aliases["Admin::OldJob"]
    assert_equal "unsupported_alias_assignment", binding.unknown_reason
    assert_equal %w[Admin::OldJob Admin::NewJob], binding.chain
  end

  def test_cycles_close_the_chain_and_dependent_aliases_remain_unknown
    {"AJob = BJob\nBJob = AJob" => %w[AJob BJob AJob],
     "AJob = BJob\nBJob = CJob\nCJob = AJob" => %w[AJob BJob CJob AJob]}.each do |source, chain|
      snapshot = source_snapshot(source + "\nOldJob = AJob")
      assert_equal chain, snapshot.aliases["AJob"].chain
      assert_equal "alias_cycle", snapshot.aliases["OldJob"].unknown_reason
      assert_equal ["OldJob"] + chain, snapshot.aliases["OldJob"].chain
    end
  end

  def test_long_chain_is_iterative_without_a_small_cap
    source = direct_job + (0...1200).map { |i| "Alias#{i} = #{i == 1199 ? 'NewJob' : "Alias#{i + 1}"}\n" }.join
    binding = source_snapshot(source).aliases.fetch("Alias0")
    assert binding.resolved?
    assert_equal 1201, binding.chain.length
  end

  def test_binding_conflicts_do_not_choose_a_winner
    ["OldJob = NewJob\nOldJob = NewJob", "OldJob = NewJob\nOldJob = OtherJob",
     "OldJob = NewJob\nclass OldJob; end", "OldJob = NewJob\nmodule OldJob; end",
     "OldJob = NewJob\nOldJob ||= NewJob", "OldJob = NewJob\n" + direct_job("OldJob")].each do |bindings|
      snapshot = source_snapshot(direct_job + bindings)
      assert_equal "alias_binding_conflict", snapshot.aliases["OldJob"].unknown_reason, bindings
      assert_equal ["OldJob"], snapshot.aliases["OldJob"].chain
      assert_nil snapshot.consumer("OldJob")
      assert_equal "defined_unrecognized", snapshot.presence("OldJob")
    end
    snapshot = source_snapshot(direct_job + "NewJob = choose_job\nOldJob = NewJob")
    assert_equal "alias_binding_conflict", snapshot.aliases["OldJob"].unknown_reason
  end

  def test_unresolved_targets_and_excluded_sources
    ["", "class MissingJob; end"].each do |target|
      binding = source_snapshot(target + "\nOldJob = MissingJob").aliases["OldJob"]
      assert_equal "alias_target_unresolved", binding.unknown_reason
      assert_equal %w[OldJob MissingJob], binding.chain
    end
    snapshot = source_snapshot("app/a.rb" => "OldJob = NewJob", "vendor/b.rb" => direct_job)
    assert_equal "alias_target_unresolved", snapshot.aliases["OldJob"].unknown_reason
    assert_empty source_snapshot("app/a.rb" => direct_job, "vendor/b.rb" => "OldJob = NewJob").aliases
  end

  def test_selected_ambiguous_bindings_block_aliases_and_terminals
    %w[OldJob NewJob].each do |name|
      blockers = ["self::#{name} = OtherJob", "object::#{name} = OtherJob",
                  "self::#{name} ||= OtherJob", "self::#{name} &&= OtherJob", "self::#{name} += OtherJob",
                  "self::#{name}, Extra = OtherJob, 1", "class self::#{name}; end", "module self::#{name}; end"]
      blockers.each do |blocker|
        sources = {"app/jobs.rb" => direct_job + direct_job("OtherJob", "id, other") + "OldJob = NewJob",
                   "app/blocker.rb" => blocker}
        snapshot = source_snapshot(sources)
        binding = snapshot.aliases.fetch("OldJob")
        assert_equal "alias_binding_conflict", binding.unknown_reason, blocker
        assert_nil snapshot.consumer("OldJob"), blocker
        assert binding.locations.any? { |location| location.path == "app/blocker.rb" }, blocker
        assert_equal snapshot.aliases.transform_values(&:as_json), source_snapshot(sources.to_a.reverse.to_h).aliases.transform_values(&:as_json)
      end
    end
  end

  def test_excluded_and_unrelated_ambiguous_writes_do_not_block_aliases
    snapshot = source_snapshot("app/jobs.rb" => direct_job + "OldJob = NewJob\nself::Unrelated = OtherJob",
                               "vendor/blocker.rb" => "self::OldJob = OtherJob\nself::NewJob = OtherJob")
    assert snapshot.aliases.fetch("OldJob").resolved?
    assert snapshot.consumer("OldJob").accepts?(1)
  end

  def test_terminal_class_module_behavior_preserves_direct_worker_scope
    sources = {"app/job.rb" => direct_job + "OldJob = NewJob",
               "app/module.rb" => "module NewJob; end"}
    snapshot = source_snapshot(sources)
    assert snapshot.aliases.fetch("OldJob").resolved?
    assert snapshot.consumer("OldJob").accepts?(1)
    assert snapshot.workers.fetch("NewJob").known?
    assert_empty source_snapshot(direct_job + "module NewJob; end").aliases
    assert source_snapshot(direct_job + "class NewJob; end\nOldJob = NewJob").aliases.fetch("OldJob").resolved?
  end

  def test_reopened_terminal_and_unknown_contracts_are_not_resolution_errors
    source = "class NewJob; include Sidekiq::Job; end\nclass NewJob; def perform(id); end; end\nOldJob = NewJob"
    snapshot = source_snapshot(source)
    assert snapshot.aliases["OldJob"].resolved?
    assert snapshot.consumer("OldJob").known?
    {"id:" => "keyword_parameters", nil => "missing_perform"}.each do |signature, reason|
      source = signature ? direct_job("NewJob", signature) : "class NewJob; include Sidekiq::Job; end\n"
      snapshot = source_snapshot(source + "OldJob = NewJob")
      assert snapshot.aliases["OldJob"].resolved?
      assert_equal reason, snapshot.consumer("OldJob").unknown_reason
    end
    snapshot = source_snapshot(direct_job + "class NewJob; def perform(other); end; end\nOldJob = NewJob")
    assert snapshot.aliases["OldJob"].resolved?
    assert_equal "multiple_perform_definitions", snapshot.consumer("OldJob").unknown_reason
  end

  def test_unicode_identity_is_exact_and_fingerprints_ignore_location
    source = direct_job("A\u0301NewJob") + direct_job("ÁNewJob", "id, other") + "A\u0301OldJob = A\u0301NewJob\nÁOldJob = ÁNewJob"
    snapshot = source_snapshot(source)
    assert_equal 1, snapshot.consumer("A\u0301OldJob").min_arity
    assert_equal 2, snapshot.consumer("ÁOldJob").min_arity
    first = source_snapshot("app/old.rb" => "OldJob = MissingJob").aliases["OldJob"]
    second = source_snapshot("app/new.rb" => "# moved\nOldJob = MissingJob").aliases["OldJob"]
    assert_equal first.fingerprint_parts, second.fingerprint_parts
  end
end
