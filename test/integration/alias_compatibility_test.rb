require_relative "../test_helper"
require_relative "../support/temporary_repository"
require_relative "../support/source_snapshot"

class AliasCompatibilityTest < Minitest::Test
  include TemporaryRepository
  include SourceSnapshot

  def compare_sources(base_source, head_source)
    with_repository do |dir|
      base = commit(dir, "app/jobs.rb" => base_source)
      commit(dir, "app/jobs.rb" => head_source)
      data, error, code = json_check(dir, base)
      assert_empty error
      assert_equal 3, data.fetch("schema_version")
      assert_equal "completed", data.fetch("status")
      yield data, code, dir, base
    end
  end

  def rules(data) = data["findings"].map { |item| [item["rule_id"], item["worker"]] }
  def identity(data, name = "OldJob") = data["workers"].find { |item| item["name"] == name }

  def test_safe_rename_and_staged_new_name_activation
    compare_sources(direct_job("OldJob") + "OldJob.perform_async(1)", direct_job + "OldJob = NewJob") do |data, code, dir, base|
      assert_equal 0, code
      assert_empty data["findings"]
      old = identity(data)
      assert_equal "recognized_worker", old["base_presence"]
      assert_equal "resolved_alias", old["head_presence"]
      assert_nil old["base_alias"]
      assert_equal({"status" => "resolved", "target" => "NewJob", "chain" => %w[OldJob NewJob], "unknown_reason" => nil}, old["head_alias"])
      assert_equal({"base" => 1, "head" => 1}, data["summary"]["workers"])
      assert_equal [1], old["producer_arities"]["base"]
      assert_equal "pass", old["compatibility"]["base_to_head"]
      assert_equal 1, old["head_contract"]["min_arity"]
      %w[NewJob OldJob].each do |receiver|
        commit(dir, "app/jobs.rb" => direct_job + "OldJob = NewJob\n#{receiver}.perform_async(1)")
        stage, _, exit_code = json_check(dir, base)
        assert_equal 1, exit_code
        assert_equal [["JC005", "NewJob"]], rules(stage)
      end
    end
  end

  def test_jc001_with_exact_string_precedence_and_complete_alias_proof
    base = direct_job("OldJob") + "OldJob.perform_async(1)"
    head = direct_job("NewJob", "id, format") + "OldJob = MiddleJob\nMiddleJob = NewJob\nSidekiq::Client.push('class' => 'OldJob', 'args' => [1])"
    compare_sources(base, head) do |data, code|
      assert_equal 1, code
      assert_equal [["JC001", "OldJob"]], rules(data)
      finding = data["findings"].first
      assert_equal %w[base_to_head head_to_head], finding["directions"]
      assert_equal [1, 2, 3], finding["locations"].select { |loc| loc["revision"] == "head" && loc["role"] == "worker_declaration" }.map { |loc| loc["line"] }.uniq.sort
      assert_equal %w[OldJob MiddleJob NewJob], identity(data)["head_alias"]["chain"]
    end
  end

  def test_class_object_alias_producer_creates_distinct_jc003_terminal
    compare_sources(direct_job("OldJob") + "OldJob.perform_async(1)", direct_job("NewJob", "id, format") + "OldJob = NewJob\nOldJob.perform_async(1)") do |data, code|
      assert_equal 1, code
      assert_equal [["JC001", "OldJob"], ["JC003", "NewJob"], ["JC005", "NewJob"]], rules(data)
      assert_equal ["base_to_head"], data["findings"].first["directions"]
      assert_equal [1], identity(data, "NewJob")["producer_arities"]["head"]
      assert_empty identity(data)["producer_arities"]["head"]
    end
  end

  def test_jc002_and_jc003_for_exact_string_alias_identity
    [["id, format=nil", "JC002"], ["id", "JC003"]].each do |signature, expected|
      compare_sources(direct_job("OldJob"), direct_job("NewJob", signature) + "OldJob = NewJob\nSidekiq::Client.push('class' => 'OldJob', 'args' => [1, 2])") do |data, code|
        assert_equal 1, code
        assert_equal [[expected, "OldJob"]], rules(data)
      end
    end
  end

  def test_jc004_no_alias_and_base_alias_removal
    compare_sources(direct_job("OldJob"), direct_job) do |data, code|
      assert_equal 1, code
      assert_equal [["JC004", "OldJob"]], rules(data)
    end
    compare_sources(direct_job + "OldJob = NewJob", direct_job) do |data, code|
      assert_equal 1, code
      assert_equal [["JC004", "OldJob"]], rules(data)
      assert_equal "resolved_alias", identity(data)["base_presence"]
      assert_equal "absent", identity(data)["head_presence"]
    end
  end

  def test_unknown_alias_reasons_block_removal_and_dormant_noise
    {"OldJob = MissingJob" => ["alias_target_unresolved", %w[OldJob MissingJob]],
     "OldJob = MiddleJob\nMiddleJob = OldJob" => ["alias_cycle", %w[OldJob MiddleJob OldJob]],
     "OldJob = NewJob\nOldJob = NewJob" => ["alias_binding_conflict", ["OldJob"]],
     "OldJob = NewJob if flag" => ["unsupported_alias_assignment", ["OldJob"]]}.each do |assignment, (reason, chain)|
      compare_sources(direct_job("OldJob"), direct_job + assignment + "\nDormantJob = missing_job") do |data, code|
        assert_equal 0, code
        assert_equal [["JC007", "OldJob"]], rules(data)
        finding = data["findings"].first
        assert_equal reason, finding["unknown_reason"]
        assert_equal ["base_to_head"], finding["directions"]
        old = identity(data)
        assert_equal "defined_unrecognized", old["head_presence"]
        assert_nil old["head_contract"]
        assert_equal({"status" => "unknown", "target" => nil, "chain" => chain, "unknown_reason" => reason}, old["head_alias"])
        assert_nil identity(data, "DormantJob")
        assert_equal "not_applicable", old["compatibility"]["base_to_head"]
      end
    end
  end

  def test_direct_worker_conflict_masks_effective_contract
    compare_sources(direct_job("OldJob"), direct_job("OldJob") + direct_job + "OldJob = NewJob\nOldJob.perform_async(1)") do |data, code|
      assert_equal 0, code
      assert_equal [["JC007", "OldJob"]], rules(data)
      assert_equal "alias_binding_conflict", data["findings"].first["unknown_reason"]
      assert_nil identity(data)["head_contract"]
      assert_empty identity(data)["producer_arities"]["head"]
      assert_empty identity(data, "NewJob")["producer_arities"]["head"]
    end
  end

  def test_jc005_exact_string_vs_class_object_and_base_alias
    [["Sidekiq::Client.push('class' => 'OldJob', 'args' => [1])", [["JC005", "OldJob"]]],
     ["Sidekiq::Client.push_bulk('class' => 'OldJob', 'args' => [[1]])", [["JC005", "OldJob"]]],
     ["OldJob.perform_async(1)", []]].each do |producer, expected|
      compare_sources(direct_job, direct_job + "OldJob = NewJob\n#{producer}") do |data, code|
        assert_equal expected.empty? ? 0 : 1, code
        assert_equal expected, rules(data)
      end
    end
    compare_sources(direct_job + "OldJob = NewJob", direct_job + "OldJob = NewJob\nSidekiq::Client.push('class' => 'OldJob', 'args' => [1])") do |data, code|
      assert_equal 0, code
      assert_empty rules(data)
    end
    compare_sources("OldJob = choose_job", direct_job + "OldJob = NewJob\nSidekiq::Client.push('class' => 'OldJob', 'args' => [1])") do |data, code|
      assert_equal 0, code
      assert_equal [["JC007", "OldJob"]], rules(data)
      assert_equal "unsupported_alias_assignment", data["findings"].first["unknown_reason"]
      assert_equal ["head_to_base"], data["findings"].first["directions"]
    end
  end

  def test_known_identity_unknown_arity_can_drive_jc005
    compare_sources("class Plain; end", direct_job + "OldJob = NewJob\nOldJob.perform_async(*args)") do |data, code|
      assert_equal 1, code
      assert_equal [["JC005", "NewJob"], ["JC007", "NewJob"]], rules(data)
      assert_equal "splat_arguments", data["findings"].last["unknown_reason"]
    end
    compare_sources("class Plain; end", "OldJob = choose_job\nOldJob.perform_async(1)") do |data, code|
      assert_equal 0, code
      assert_equal [["JC007", "OldJob"]], rules(data)
      assert_equal "unsupported_alias_assignment", data["findings"].first["unknown_reason"]
    end
  end

  def test_jc006_and_terminal_changes_under_persisted_alias
    compare_sources(direct_job("OldJob", "id=nil, format=nil"), direct_job + "OldJob = NewJob") do |data, code|
      assert_equal 0, code
      assert_equal [["JC006", "OldJob"]], rules(data)
    end
    ["id", "id, other"].each do |signature|
      compare_sources(direct_job("MiddleJob") + "OldJob = MiddleJob", direct_job("NewJob", signature) + "OldJob = NewJob") do |data, code|
        assert_equal 1, code
        assert_includes rules(data), ["JC004", "MiddleJob"]
        assert_equal signature == "id" ? [] : [["JC006", "OldJob"]], rules(data).select { |_, name| name == "OldJob" }
        assert_equal "MiddleJob", identity(data)["base_alias"]["target"]
        assert_equal "NewJob", identity(data)["head_alias"]["target"]
      end
    end
  end

  def test_resolved_alias_with_keyword_terminal_is_unknown_not_removed
    compare_sources(direct_job("OldJob"), direct_job("NewJob", "id:") + "OldJob = NewJob") do |data, code|
      assert_equal 0, code
      assert_equal [["JC007", "NewJob"], ["JC007", "OldJob"]], rules(data)
      assert data["findings"].all? { |item| item["unknown_reason"] == "keyword_parameters" }
      assert_equal "resolved", identity(data)["head_alias"]["status"]
      assert_equal "unknown", identity(data)["head_contract"]["status"]
    end
  end

  def test_excluded_alias_and_excluded_terminal_remain_unknown
    with_repository do |dir|
      base = commit(dir, "app/jobs.rb" => direct_job("OldJob"))
      commit(dir, "app/jobs.rb" => direct_job, "vendor/old.rb" => "OldJob = NewJob")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal [["JC007", "OldJob"]], rules(data)
      assert_equal "outside_analysis_scope", data["findings"].first["unknown_reason"]
      assert_nil identity(data)["head_alias"]
      commit(dir, "app/jobs.rb" => "OldJob = NewJob", "vendor/new.rb" => direct_job, "vendor/old.rb" => nil)
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal "alias_target_unresolved", data["findings"].first["unknown_reason"]
    end
  end

  def test_dedup_across_revision_and_file_movement_preserves_all_locations
    with_repository do |dir|
      base = commit(dir, "app/old.rb" => "OldJob = MissingJob", "app/other.rb" => "OtherJob = MissingJob")
      commit(dir, "app/old.rb" => nil, "app/new.rb" => "# moved\nOldJob = MissingJob")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal [["JC007", "OldJob"], ["JC007", "OtherJob"]], rules(data)
      old = data["findings"].find { |item| item["worker"] == "OldJob" }
      assert_equal %w[base head], old["revisions"]
      assert_equal %w[app/new.rb app/old.rb], old["locations"].map { |loc| loc["path"] }.sort
    end
  end

  def test_determinism_unicode_suppression_and_worktree_non_execution
    ["OldJob = MiddleJob\nMiddleJob = NewJob", "OldJob = MiddleJob\nMiddleJob = OldJob",
     "OldJob = NewJob\nOldJob = NewJob", "A\u0301OldJob = NewJob"].each do |alias_source|
      compare_sources(direct_job("OldJob") + direct_job("A\u0301OldJob"), direct_job + alias_source + "\nraise 'source must never execute'\n") do |_data, _code, dir, base|
        File.write(File.join(dir, "app/uncommitted.rb"), "raise 'never load source'\n")
        git(dir, "add", "app/uncommitted.rb")
        commit_source = File.join(dir, "app/jobs.rb")
        File.write(commit_source, "invalid uncommitted Ruby (\n")
        before = [git(dir, "status", "--porcelain=v1"), git(dir, "write-tree"), File.binread(commit_source)]
        %w[text json].each do |format|
          first, error, status = check(dir, base, "--format", format)
          second, second_error, second_status = check(dir, base, "--format", format)
          assert_empty error
          assert_empty second_error
          assert_equal status.exitstatus, second_status.exitstatus
          assert_equal first, second
        end
        assert_equal before, [git(dir, "status", "--porcelain=v1"), git(dir, "write-tree"), File.binread(commit_source)]
      end
    end
    name = "A\u0301OldJob"
    compare_sources(direct_job(name) + "#{name}.perform_async(1)", direct_job("NewJob", "id, other") + "#{name} = NewJob") do |_data, _code, dir, base|
      File.write(File.join(dir, ".jobcompat.yml"), "version: 1\nignore:\n  - rule: JC001\n    worker: #{name}\n    reason: rollout gated\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal name.codepoints, data["suppressions"].first["worker"].codepoints
      File.write(File.join(dir, ".jobcompat.yml"), "version: 1\nignore:\n  - rule: JC001\n    worker: ÁOldJob\n    reason: distinct identity\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal [["JC001", name]], rules(data)
    end
  end

  def test_schema_three_failures_and_config_version_one
    compare_sources(direct_job, direct_job + "OldJob = NewJob") do |data, _code, dir, base|
      assert data["workers"].all? { |item| item.key?("base_alias") && item.key?("head_alias") }
      failed, _, code = json_check(dir, "missing-ref")
      assert_equal 2, code
      assert_equal 3, failed["schema_version"]
      assert_equal "failed", failed["status"]
      File.write(File.join(dir, ".jobcompat.yml"), "version: 2\n")
      failed, _, code = json_check(dir, base)
      assert_equal 2, code
      assert_equal 3, failed["schema_version"]
      assert_equal "config_error", failed["diagnostics"].first["category"]
    end
  end
end
