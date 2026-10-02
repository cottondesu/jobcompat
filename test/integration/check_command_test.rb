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

  UNICODE_WORKER = "A\u0301Job"

  def unicode_worker(name, namespace: nil)
    body = "class #{name}\n  include Sidekiq::Job\n\n  def perform(id)\n  end\nend\n"
    namespace ? "module #{namespace}\n#{body.gsub(/^(?=.)/, '  ')}end\n" : body
  end

  def client_push(name, args)
    "Sidekiq::Client.push(\n  \"class\" => \"#{name}\",\n  \"args\" => #{args}\n)\n"
  end

  def unicode_suppression(worker, rule: "JC003")
    "version: 1\n\nignore:\n  - rule: #{rule}\n    worker: #{worker}\n    reason: intentional migration\n"
  end

  def test_unicode_worker_suppression_end_to_end_with_audit_and_determinism
    assert_equal [0x41, 0x301, 0x4a, 0x6f, 0x62], UNICODE_WORKER.codepoints
    with_repository do |dir|
      base = commit(dir, "app/jobs/unicode_job.rb" => unicode_worker(UNICODE_WORKER))
      commit(dir, "app/jobs/unicode_job.rb" => unicode_worker(UNICODE_WORKER) + "\n" + client_push(UNICODE_WORKER, "[1, 2]"))
      data, error, code = json_check(dir, base)
      assert_equal 1, code, error
      assert_equal [["JC003", UNICODE_WORKER, 2]], data["findings"].map { |item| [item["rule_id"], item["worker"], item["payload_arity"]] }
      assert_equal UNICODE_WORKER.codepoints, data["findings"][0]["worker"].codepoints
      assert_equal 0, data["summary"]["suppressed"]

      File.write(File.join(dir, ".jobcompat.yml"), unicode_suppression(UNICODE_WORKER))
      data, error, code = json_check(dir, base)
      assert_equal 0, code, error
      assert_empty error
      assert_equal 2, data["schema_version"]
      assert_equal "completed", data["status"]
      assert_empty data["findings"]
      assert_equal 0, data["summary"]["errors"]
      assert_equal 1, data["summary"]["suppressed"]
      assert_equal [{"rule_id" => "JC003", "worker" => UNICODE_WORKER, "reason" => "intentional migration", "finding_count" => 1}], data["suppressions"]
      assert_equal UNICODE_WORKER.codepoints, data["suppressions"][0]["worker"].codepoints

      output, error, status = check(dir, base)
      assert_equal 0, status.exitstatus, error
      assert_includes output, "Suppressed findings:\n  JC003 #{UNICODE_WORKER} (1): intentional migration\n"
      assert_match(/^Summary: 0 errors, .*, 1 suppressed$/, output)

      json_runs = Array.new(2) { check(dir, base, "--format", "json").first }
      text_runs = Array.new(2) { check(dir, base).first }
      assert_equal json_runs[0].b, json_runs[1].b
      assert_equal text_runs[0].b, text_runs[1].b
      assert_equal output.b, text_runs[0].b
      assert_includes json_runs[0].b, UNICODE_WORKER.b
    end
  end

  def test_unicode_suppression_matches_exact_codepoints_only
    precomposed = "\u00C1Job"
    refute_equal precomposed, UNICODE_WORKER
    [[UNICODE_WORKER, precomposed], [precomposed, UNICODE_WORKER]].each do |finding_worker, suppressed_worker|
      with_repository do |dir|
        base = commit(dir, "app/jobs/unicode_job.rb" => unicode_worker(finding_worker))
        commit(dir, "app/jobs/unicode_job.rb" => unicode_worker(finding_worker) + client_push(finding_worker, "[1, 2]"),
                    ".jobcompat.yml" => unicode_suppression(suppressed_worker))
        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_equal [["JC003", finding_worker]], data["findings"].map { |item| [item["rule_id"], item["worker"]] }
        assert_equal finding_worker.codepoints, data["findings"][0]["worker"].codepoints
        assert_equal 0, data["summary"]["suppressed"]
        assert_empty data["suppressions"]
      end
    end
  end

  def test_qualified_unicode_suppression_is_exact
    qualified = "Admin::#{UNICODE_WORKER}"
    with_repository do |dir|
      source = unicode_worker(UNICODE_WORKER, namespace: "Admin")
      base = commit(dir, "app/jobs/unicode_job.rb" => source)
      commit(dir, "app/jobs/unicode_job.rb" => source + client_push(qualified, "[1, 2]"))
      File.write(File.join(dir, ".jobcompat.yml"), unicode_suppression(UNICODE_WORKER))
      data, error, code = json_check(dir, base)
      assert_equal 1, code, error
      assert_equal [["JC003", qualified]], data["findings"].map { |item| [item["rule_id"], item["worker"]] }
      assert_equal 0, data["summary"]["suppressed"]
      File.write(File.join(dir, ".jobcompat.yml"), unicode_suppression(qualified))
      data, error, code = json_check(dir, base)
      assert_equal 0, code, error
      assert_empty data["findings"]
      assert_equal 1, data["summary"]["suppressed"]
      assert_equal [{"rule_id" => "JC003", "worker" => qualified, "reason" => "intentional migration", "finding_count" => 1}], data["suppressions"]
    end
  end

  def test_noncanonical_and_invalid_byte_suppression_workers_are_config_errors
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1, 2)\n")
      {
        "version: 1\nignore:\n  - rule: JC003\n    worker: \"ExportJob()\"\n    reason: x\n" => "ignore[0].worker is invalid",
        "version: 1\nignore:\n  - rule: JC003\n    worker: \"::ExportJob\"\n    reason: x\n" => "ignore[0].worker is invalid",
        "version: 1\nignore:\n  - rule: JC003\n    worker: \" ExportJob\"\n    reason: x\n" => "ignore[0].worker is invalid",
        "version: 1\nignore:\n  - rule: JC003\n    worker: !!binary wUpvYg==\n    reason: x\n" => "ignore[0].worker is invalid",
        "version: 1\nignore:\n  - rule: JC003\n    worker: A\xFFJob\n    reason: x\n".b => /\AInvalid config: /
      }.each do |config, message|
        File.binwrite(File.join(dir, ".jobcompat.yml"), config)
        data, error, code = json_check(dir, base)
        assert_equal 2, code, config.inspect
        assert_empty error
        assert_equal "failed", data["status"]
        assert_equal [["config_error"]], data["diagnostics"].map { |item| [item["category"]] }
        message.is_a?(Regexp) ? assert_match(message, data["diagnostics"][0]["message"]) : assert_equal(message, data["diagnostics"][0]["message"])
        output, error, status = check(dir, base)
        assert_equal 2, status.exitstatus
        assert_empty output
        assert_match(/\Aconfig_error: /, error)
        refute_match(/internal_error|ArgumentError|EncodingError|\.rb:\d+/, error)
      end
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
