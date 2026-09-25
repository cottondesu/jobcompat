require_relative "../test_helper"
require_relative "../support/temporary_repository"
require "stringio"

class CheckCommandTest < Minitest::Test
  include TemporaryRepository

  def test_help_and_version
    root = File.expand_path("../..", __dir__)
    [["--help"], ["--version"], ["check", "--help"]].each do |args|
      output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.join(root, 'lib')}", File.join(root, "exe/jobcompat"), *args)
      assert_equal 0, status.exitstatus, error
      assert_empty error
      assert_match(/jobcompat|Usage/, output)
    end
  end

  def test_jc001_precedence_and_current_mismatch
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      data, error, exit_code = json_check(dir, base)
      assert_equal 1, exit_code, error
      assert_equal ["JC001"], data.fetch("findings").map { |finding| finding.fetch("rule_id") }
      assert_equal %w[base_to_head head_to_head], data["findings"][0]["directions"]
    end
  end

  def test_optional_expansion_and_new_producer
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format=nil") + "ExportJob.perform_async(1)\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 0, exit_code
      assert_empty data["findings"]
      commit(dir, "app/export_job.rb" => worker("id, format=nil") + "ExportJob.perform_async(1, 'csv')\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 1, exit_code
      assert_equal ["JC002"], data["findings"].map { |finding| finding["rule_id"] }
    end
  end

  def test_deletion_scope_move_and_rename
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => nil)
      data, _, exit_code = json_check(dir, base)
      assert_equal 1, exit_code
      assert_equal "JC004", data["findings"][0]["rule_id"]
      assert_equal %w[base head], data["findings"][0]["revisions"]
      commit(dir, "vendor/export_job.rb" => "class ExportJob; include MyConcern; end\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 0, exit_code
      assert_equal ["JC007"], data["findings"].map { |finding| finding["rule_id"] }
      assert_equal "outside_analysis_scope", data["findings"][0]["unknown_reason"]
    end
  end

  def test_new_worker_and_targeted_suppression
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 1, exit_code
      assert_equal ["JC005"], data["findings"].map { |finding| finding["rule_id"] }
      assert_equal %w[base head], data["findings"][0]["revisions"]
      File.write(File.join(dir, ".jobcompat.yml"), "version: 1\nignore:\n  - rule: JC005\n    worker: ExportJob\n    reason: rollout gated\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 0, exit_code
      assert_empty data["findings"]
      assert_equal 1, data["summary"]["suppressed"]
    end
  end

  def test_unknown_dedup_and_warning_only
    with_repository do |dir|
      source = worker + "ExportJob.perform_async(*args)\n"
      base = commit(dir, "app/export_job.rb" => source)
      commit(dir, "app/export_job.rb" => source + "# unrelated\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 0, exit_code
      assert_equal ["JC007"], data["findings"].map { |finding| finding["rule_id"] }
      assert_equal %w[base head], data["findings"][0]["revisions"]
    end
  end

  def test_narrowing_without_producer_and_errors
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("id, format=nil"))
      commit(dir, "app/export_job.rb" => worker)
      data, _, exit_code = json_check(dir, base)
      assert_equal 0, exit_code
      assert_equal ["JC006"], data["findings"].map { |finding| finding["rule_id"] }
      assert_match(/No repository producer callsite/, data["findings"][0]["risk"])
      data, _, exit_code = json_check(dir, "missing-ref")
      assert_equal 2, exit_code
      assert_equal "failed", data["status"]
      commit(dir, "app/broken.rb" => "class Broken; def ; end\n")
      data, _, exit_code = json_check(dir, base)
      assert_equal 2, exit_code
      assert_equal "parse_error", data["diagnostics"][0]["category"]
    end
  end

  def test_head_only_mismatch
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1, 2)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC003"], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["head_to_head"], data["findings"][0]["directions"]
    end
  end

  def test_reopened_fragments_and_file_move_are_identity_preserving
    with_repository do |dir|
      base = commit(dir, "app/worker.rb" => "class ExportJob; include Sidekiq::Job; end\n",
                         "app/perform.rb" => "class ExportJob; def perform(id); end; end\n")
      commit(dir, "app/worker.rb" => nil, "app/perform.rb" => nil,
                  "app/jobs/include.rb" => "class ExportJob; include Sidekiq::Job; end\n",
                  "app/jobs/method.rb" => "class ExportJob; def perform(account_id); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_empty data["findings"]
      assert_equal 1, data["summary"]["workers"]["head"]
    end
  end

  def test_indirect_include_and_keyword_perform_are_unknown_not_removed
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => "class ExportJob; include MyConcern; def perform(id); end; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "worker_not_recognized", data["findings"][0]["unknown_reason"]
      commit(dir, "app/export_job.rb" => worker("id:"))
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "keyword_parameters", data["findings"][0]["unknown_reason"]
    end
  end

  def test_canonical_rename_with_new_enqueue
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => nil,
                  "app/generate_export_job.rb" => "class GenerateExportJob; include Sidekiq::Job; def perform(id); end; end\nGenerateExportJob.perform_async(1)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal %w[JC004 JC005], data["findings"].map { |item| item["rule_id"] }
      assert_match(/If an old Sidekiq process can consume/, data["findings"][1]["risk"])
    end
  end

  def test_distinct_unknown_calls_and_duplicate_occurrences
    with_repository do |dir|
      source = worker + "ExportJob.perform_async(*args)\nExportJob.perform_async(*args)\n"
      base = commit(dir, "app/export_job.rb" => source)
      commit(dir, "app/export_job.rb" => source + "# body-independent edit\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal 2, data["findings"].length
      assert data["findings"].all? { |item| item["revisions"] == %w[base head] }
    end
  end

  def test_unparseable_excluded_candidate_blocks_jc004
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => nil, "vendor/possible.rb" => "class ExportJob; def ; end\n")
      data, _, code = json_check(dir, base)
      assert_equal 0, code
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "presence_unverified", data["findings"][0]["unknown_reason"]
    end
  end

  def test_dirty_worktree_is_unchanged_and_text_is_human_readable
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format=nil") + "ExportJob.perform_async(1, 'csv')\n")
      dirty_path = File.join(dir, "notes.txt")
      File.write(dirty_path, "keep me\n")
      before = git(dir, "status", "--porcelain")
      output, error, status = check(dir, base)
      assert_equal 1, status.exitstatus, error
      assert_match(/ERROR JC002 ExportJob/, output)
      assert_match(/HEAD producer -> base consumer/, output)
      assert_match(/Suggested migration:/, output)
      assert_equal before, git(dir, "status", "--porcelain")
      assert_equal "keep me\n", File.read(dirty_path)
    end
  end

  def test_invalid_config_and_ref_streams
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      File.write(File.join(dir, ".jobcompat.yml"), "version: 2\n")
      data, error, code = json_check(dir, base)
      assert_equal 2, code
      assert_empty error
      assert_equal "config_error", data["diagnostics"][0]["category"]
      File.delete(File.join(dir, ".jobcompat.yml"))
      data, error, code = json_check(dir, base, "--head", "bad-ref")
      assert_equal 2, code
      assert_empty error
      assert_equal base, data["comparison"]["base"]["sha"]
      assert_nil data["comparison"]["head"]["sha"]
    end
  end

  def test_parse_errors_from_both_revisions_are_reported_together
    with_repository do |dir|
      base = commit(dir, "app/base_broken.rb" => "class BaseBroken; def ; end\n")
      commit(dir, "app/base_broken.rb" => nil, "app/head_broken.rb" => "class HeadBroken; def ; end\n")
      data, error, code = json_check(dir, base)
      assert_equal 2, code
      assert_empty error
      assert_equal %w[base head], data["diagnostics"].map { |item| item["location"]["revision"] }.uniq
      assert_equal %w[app/base_broken.rb app/head_broken.rb], data["diagnostics"].map { |item| item["location"]["path"] }.uniq
    end
  end

  def test_unexpected_internal_error_is_sanitized_in_json_and_detailed_on_stderr
    stdout = StringIO.new
    stderr = StringIO.new
    singleton = Jobcompat::GitRepository.singleton_class
    singleton.define_method(:new) { |_directory| raise "sensitive crash detail" }
    begin
      code = Jobcompat::CLI.start(["check", "--base", "HEAD", "--format", "json"], stdout: stdout, stderr: stderr)
      assert_equal 2, code
    ensure
      singleton.remove_method(:new)
    end
    data = JSON.parse(stdout.string)
    assert_equal "internal_error", data["diagnostics"][0]["category"]
    refute_includes stdout.string, "sensitive crash detail"
    assert_includes stderr.string, "sensitive crash detail"
    refute_includes stderr.string, "test/integration"
  end

  def test_text_error_escapes_control_characters_in_ref
    with_repository do |dir|
      commit(dir, "app/export_job.rb" => worker)
      _output, error, status = check(dir, "missing\e[31m\nref")
      assert_equal 2, status.exitstatus
      refute_includes error, "\e"
      assert_includes error, "\\x1B"
      assert_includes error, "\\x0A"
    end
  end

  def test_text_error_escapes_unicode_format_controls_in_ref
    with_repository do |dir|
      commit(dir, "app/export_job.rb" => worker)
      _output, error, status = check(dir, "missing\u202Etxt")
      assert_equal 2, status.exitstatus
      refute_includes error, "\u202E"
      assert_includes error, "\\u{202E}"
    end
  end
end
