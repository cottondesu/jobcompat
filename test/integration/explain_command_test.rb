require_relative "../test_helper"
require_relative "../support/temporary_repository"

class ExplainCommandTest < Minitest::Test
  include TemporaryRepository

  def test_cli_contract
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      plain, error, status = check(dir, base, "--explain")
      assert_equal 1, status.exitstatus, error
      variants = [["--explain"], ["--explain", "--format", "text"], ["--format", "text", "--explain"]]
      outputs = variants.map { |options| check(dir, base, *options) }
      outputs.each { |output, err, st| assert_equal [plain, "", 1], [output, err, st.exitstatus], err }
      assert_includes plain, "Explanation:"
      [["--format", "json", "--explain"], ["--explain", "--format", "json"]].each do |options|
        stdout, err, st = check(dir, base, *options)
        assert_equal 2, st.exitstatus, err
        assert_empty err
        data = JSON.parse(stdout)
        assert_equal 3, data.fetch("schema_version")
        assert_equal "failed", data.fetch("status")
        assert_equal "--explain is supported only with --format text", data.dig("diagnostics", 0, "message")
        assert_equal "config_error", data.dig("diagnostics", 0, "category")
      end
      help, = check(dir, base, "--help")
      assert_includes help, "--explain"
      assert_includes help, "Explain the evidence behind each finding (text only)"
      version, = Open3.capture3(RbConfig.ruby, "-I#{File.join(File.expand_path("../..", __dir__), "lib")}",
                                File.join(File.expand_path("../..", __dir__), "exe/jobcompat"), "--version")
      assert_equal "jobcompat 0.3.1\n", version
    end
  end

  def test_default_output_parity_without_explain
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      default, = check(dir, base)
      json, = check(dir, base, "--format", "json")
      explained, = check(dir, base, "--explain")
      refute_includes default, "Explanation:"
      refute_includes json, "explanation"
      stripped = explained.gsub(/^  Explanation:\n(?:(?:    |      ).*\n)+/, "")
      assert_equal default, stripped
      assert_equal default, check(dir, base, "--format", "text")[0]
    end
  end

  def test_jc001_variants_and_alias_provenance
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "BASE producer emits 1 positional argument."
      assert_includes explained, "HEAD producer also emits 1 positional argument"
      assert_includes explained, "HEAD producers still enqueue the same arity."
      assert_includes explained, "actual retained queue contents are not inspected"
      data, = json_check(dir, base)
      assert_equal ["JC001"], data.fetch("findings").map { |item| item.fetch("rule_id") }
    end
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "BASE producer emits 1 positional argument."
      refute_includes explained, "HEAD producer also emits"
      refute_includes explained, "HEAD producers still enqueue"
    end
    with_repository do |dir|
      base = commit(dir, "app/old_job.rb" => worker("id", name: "OldJob") + "OldJob.perform_async(1)\n")
      commit(dir, "app/old_job.rb" => nil,
             "app/new_job.rb" => worker("id, format", name: "NewJob") + "OldJob = NewJob\nOldJob.perform_async(1)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "Alias (HEAD): OldJob -> NewJob (resolved)."
      assert_includes explained, "HEAD Class-object producer OldJob serializes as the terminal identity NewJob."
    end
  end

  def worker(signature = "id", name: "ExportJob")
    "class #{name}\n  include Sidekiq::Job\n  def perform(#{signature}); end\nend\n"
  end

  def test_jc002_conditional_and_jc003_no_base_leakage
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format=nil") + "ExportJob.perform_async(1, 'csv')\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "BASE consumer accepts 1 positional argument, rejecting 2."
      assert_includes explained, "if an old process executes it during the rolling deployment"
      assert_includes explained, "Whether an old process consumes this queue, and when it retires, is not determined by static analysis."
    end
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD's own producer and consumer disagree on payload arity."
      explanation_block = explained[/^  Explanation:\n(?:(?:    |      ).*\n)+/]
      assert_includes explanation_block, "HEAD producer emits 1 positional argument."
      refute_match(/^      BASE /, explanation_block)
    end
  end

  def test_jc004_absence_only_and_outside_scope
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => nil)
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD conservative presence check across tracked Ruby source proved ExportJob absent."
      assert_includes explained, "Static absence does not prove the queue is empty"
    end
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/export_job.rb" => nil, "vendor/export_job.rb" => worker)
      explained, = check(dir, base, "--explain")
      assert_includes explained, "outside_analysis_scope"
      block = explained[/^  Explanation:\n(?:(?:    |      ).*\n)+/]
      assert_includes block, "ExportJob is declared only outside the scan scope in HEAD."
      refute_includes block, "proved ExportJob absent"
      refute_includes explained, "Static absence does not prove the queue is empty"
    end
  end

  def test_jc005_identity_and_conditional_risk
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/new_job.rb" => worker("id", name: "NewJob") + "OldJob = NewJob\nOldJob.perform_async(1)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD Class-object producer OldJob serializes as the terminal identity NewJob."
      assert_includes explained, "BASE conservative presence check across tracked Ruby source proved NewJob absent."
      assert_includes explained, "If an old Sidekiq process consumes this job's queue"
      assert_includes explained, "does not prove unconditional failure"
    end
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/export_job.rb" => worker,
             "app/producer.rb" => "Sidekiq::Client.push(\"class\" => \"ExportJob\", \"args\" => [1])\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD Client String producer keeps the exact identity ExportJob."
      assert_includes explained, "Known HEAD payload arities for this identity: 1."
    end
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/export_job.rb" => worker,
             "app/producer.rb" => "args = [1]\nSidekiq::Client.push(\"class\" => \"ExportJob\", \"args\" => args)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD Client String producer keeps the exact identity ExportJob."
      refute_includes explained, "Known HEAD payload arities"
    end
  end

  def test_jc006_and_jc007_variants
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("id, format=nil"))
      commit(dir, "app/export_job.rb" => worker("id"))
      explained, = check(dir, base, "--explain")
      assert_includes explained, "BASE consumer ExportJob accepts 1..2 positional arguments."
      assert_includes explained, "HEAD no longer accepts arity 2."
      assert_includes explained, "No qualifying producer witness was found"
      assert_includes explained, "does not prove that no queued, scheduled, retried, historical, or externally enqueued payload exists"
      assert_includes explained, "HEAD consumer ExportJob accepts 1 positional argument."
    end
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/jobs.rb" => worker("id", name: "NewJob") + "OldJob = MiddleJob\nMiddleJob = OldJob\nOldJob.perform_async(1)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "Alias (HEAD): OldJob -> MiddleJob -> OldJob (alias_cycle)."
      assert_includes explained, "Unknown or unsupported evidence is not a proof of compatibility"
      _, error, status = check(dir, base, "--explain")
      assert_equal 0, status.exitstatus, error
      assert_includes explained, "PASS WITH WARNINGS"
    end
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/jobs.rb" => worker("id", name: "NewJob") + "OldJob = MissingJob\nOldJob.perform_async(1)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "Alias (HEAD): OldJob -> MissingJob (alias_target_unresolved)."
    end
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/export_job.rb" => worker + "args = [1]\nExportJob.perform_async(*args)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD: the payload arity for ExportJob could not be determined (splat_arguments)."
      assert_includes explained, "splat_arguments prevents a complete positional compatibility check."
    end
  end

  def test_suppression_scopes_explanations
    config = <<~YAML
      version: 1
      ignore:
        - rule: JC003
          worker: ExportJob
          reason: "tracked elsewhere"
    YAML
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n",
             ".jobcompat.yml" => config)
      suppressed, error, status = check(dir, base, "--explain")
      assert_equal 0, status.exitstatus, error
      refute_includes suppressed, "Explanation:"
      assert_includes suppressed, "Suppressed findings:"
      assert_includes suppressed, "JC003 ExportJob (1): tracked elsewhere"
    end
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      unsuppressed, error, status = check(dir, base, "--explain")
      assert_equal 1, status.exitstatus, error
      assert_includes unsuppressed, "Explanation:"
      refute_includes unsuppressed, "Suppressed findings:"
    end
  end

  def test_explain_keeps_existing_failure_contracts
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_async(1)\n")
      invalid_ref, err_ref, status_ref = check(dir, "no-such-ref", "--explain")
      expected_ref, _, _ = check(dir, "no-such-ref")
      assert_equal 2, status_ref.exitstatus, err_ref
      assert_equal expected_ref, invalid_ref
      refute_includes invalid_ref, "Explanation:"
      bad_config = <<~YAML
        version: 2
      YAML
      File.binwrite(File.join(dir, ".jobcompat.yml"), bad_config)
      invalid_config, = check(dir, base, "--explain")
      expected_config, = check(dir, base)
      assert_equal expected_config, invalid_config
      refute_includes invalid_config, "Explanation:"
    end
  end

  def test_no_findings_and_warning_only
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_async(1)\n")
      commit(dir, "app/other.rb" => "x = 1\n")
      plain, error, status = check(dir, base)
      explained, error2, status2 = check(dir, base, "--explain")
      assert_equal 0, status.exitstatus, error
      assert_equal 0, status2.exitstatus, error2
      assert_equal plain, explained
      refute_includes explained, "Explanation:"
    end
  end

  def test_determinism_dirty_worktree_and_unicode
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format") + "ÁJob = Class.new\nExportJob.perform_async(1)\n" +
               "class ÁJob\n  include Sidekiq::Job\n  def perform(id, format); end\nend\nÁJob.perform_async(1)\n")
      File.binwrite(File.join(dir, "app/dirty.rb"), "uncommitted garbage\n")
      first_out, first_err, first_status = check(dir, base, "--explain")
      second_out, second_err, second_status = check(dir, base, "--explain")
      assert_equal first_out, second_out
      assert_equal first_err, second_err
      assert_equal first_status.exitstatus, second_status.exitstatus
      assert_includes first_out, "ÁJob"
      assert_operator first_out.lines.count { |line| line.start_with?("  Explanation:") }, :>=, 1
    end
  end

  def test_bulk_call_site_counts_end_to_end
    bulk_worker = <<~RUBY
      class W
        include Sidekiq::Job
        def perform(a, *rest); end
      end
      args = [9]
      W.perform_bulk([[1], [1, 2], args])
    RUBY
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/w.rb" => bulk_worker)
      explained, error, status = check(dir, base, "--explain")
      assert_equal 1, status.exitstatus, error
      assert_includes explained, "HEAD producer can enqueue the serialized worker identity W (1 call site)."
      refute_includes explained, "(3 call sites)"
      data, = json_check(dir, base)
      assert_includes data.fetch("findings").map { |item| item.fetch("rule_id") }, "JC005"
      first_out, first_err, first_status = check(dir, base, "--explain")
      assert_equal [explained, error, status.exitstatus], [first_out, first_err, first_status.exitstatus]
    end
    with_repository do |dir|
      base = commit(dir, "README.md" => "x\n")
      commit(dir, "app/w.rb" => "class W\n  include Sidekiq::Job\n  def perform(a, *rest); end\nend\n" +
               "W.perform_async(1); W.perform_async(1, 2)\n")
      explained, = check(dir, base, "--explain")
      assert_includes explained, "HEAD producer can enqueue the serialized worker identity W (2 call sites)."
    end
  end
end
