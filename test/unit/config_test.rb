require_relative "../test_helper"

class ConfigTest < Minitest::Test
  def test_defaults_and_globs
    config = Jobcompat::Config.load(root: Dir.mktmpdir)
    assert config.scan?("foo.rb")
    assert config.scan?("app/jobs/export_job.rb")
    refute config.scan?("test/foo.rb")
    refute config.scan?("vendor/foo.rb")
  end

  def test_strict_validation
    valid = {"version" => 1, "ignore" => [{"rule" => "JC005", "worker" => "Admin::ExportJob", "reason" => "gated"}]}
    config = Jobcompat::Config.validate(valid, ".jobcompat.yml")
    assert_equal 1, config.ignore.length
    unicode = Jobcompat::Config.validate({"version" => 1, "ignore" => [{"rule" => "JC005", "worker" => "Job管理::E輸出", "reason" => "gated"}]}, ".jobcompat.yml")
    assert_equal "Job管理::E輸出", unicode.ignore.first["worker"]
    [valid.merge("unexpected" => true), {"version" => "1"},
     nil, [], {"version" => 1, "scan" => {"unknown" => []}},
     {"version" => 1, "scan" => {"include" => []}},
     {"version" => 1, "scan" => {"include" => "**/*.rb"}},
     {"version" => 1, "scan" => {"exclude" => ["../foo"]}},
     {"version" => 1, "ignore" => "JC005"},
     {"version" => 1, "ignore" => [{"rule" => "JC999", "worker" => "ExportJob", "reason" => "gated"}]},
     {"version" => 1, "ignore" => [{"rule" => "JC005", "worker" => "bad-worker", "reason" => "gated"}]},
     {"version" => 1, "ignore" => [{"rule" => "JC005", "worker" => "ExportJob"}]},
     {"version" => 1, "ignore" => [valid["ignore"].first.merge("reason" => " ")]},
     {"version" => 1, "ignore" => valid["ignore"] * 2}].each do |data|
      assert_raises(Jobcompat::Error) { Jobcompat::Config.validate(data, "x") }
    end
  end

  def ignore_config(*entries)
    {"version" => 1, "ignore" => entries.map { |rule, worker, reason| {"rule" => rule, "worker" => worker, "reason" => reason || "intentional migration"} }}
  end

  def assert_invalid_worker(worker)
    error = assert_raises(Jobcompat::Error, worker.inspect) { Jobcompat::Config.validate(ignore_config(["JC003", worker]), ".jobcompat.yml") }
    assert_equal ["config_error", "ignore[0].worker is invalid"], [error.category, error.message], worker.inspect
  end

  def test_canonical_unicode_suppression_workers_are_accepted_exactly
    decomposed = "A\u0301Job"
    assert_equal [0x41, 0x301, 0x4a, 0x6f, 0x62], decomposed.codepoints
    [decomposed, "Admin::#{decomposed}", "\u00C1Job", "ΔJob", "ЖJob", "Job管理", "A\u{1F600}Job", "Admin::ExportJob"].each do |worker|
      config = Jobcompat::Config.validate(ignore_config(["JC003", worker]), ".jobcompat.yml")
      assert_equal worker.codepoints, config.ignore.first["worker"].codepoints, worker.inspect
    end
  end

  def test_noncanonical_suppression_workers_remain_config_errors
    # 管理::輸出 was accepted by the v0.2.0 regex, but Ruby/Prism parse it as method calls, not constants,
    # so producer analysis can never report it and the shared validator rejects it.
    [nil, 1, [], "", "exportJob", "管理::輸出", "::Admin::ExportJob", "Admin::", "Admin::::Job", "ExportJob()",
     "ExportJob; OtherJob", "ExportJob\nOtherJob", "ExportJob # comment", " ExportJob", "ExportJob ",
     "Admin :: ExportJob", "Admin:: ExportJob", "(ExportJob)", "ExportJob + OtherJob", "ExportJob rescue OtherJob",
     "self::ExportJob", "[ExportJob]", "\u0301Job"].each { |worker| assert_invalid_worker(worker) }
  end

  def test_invalid_byte_suppression_workers_are_config_errors
    ["A\xFFJob".dup.force_encoding(Encoding::UTF_8), "\xFF".dup.force_encoding(Encoding::UTF_8), "\xC1Job".b].each do |worker|
      refute worker.encoding == Encoding::UTF_8 && worker.valid_encoding?
      assert_invalid_worker(worker)
    end
  end

  def test_duplicate_suppressions_use_exact_worker_identity
    decomposed = "A\u0301Job"
    error = assert_raises(Jobcompat::Error) do
      Jobcompat::Config.validate(ignore_config(["JC003", decomposed, "one"], ["JC003", decomposed.dup, "two"]), ".jobcompat.yml")
    end
    assert_equal "config_error", error.category
    assert_match(/\Aduplicate ignore for JC003 /, error.message)
    config = Jobcompat::Config.validate(ignore_config(["JC003", decomposed, "one"], ["JC003", "\u00C1Job", "two"]), ".jobcompat.yml")
    assert_equal [decomposed, "\u00C1Job"], config.ignore.map { |item| item["worker"] }
  end

  def test_suppression_matching_is_exact_without_unicode_normalization
    decomposed = "A\u0301Job"
    precomposed = "\u00C1Job"
    findings = [{rule_id: "JC003", worker: decomposed}, {rule_id: "JC003", worker: "Admin::#{decomposed}"}]
    config = Jobcompat::Config.validate(ignore_config(["JC003", precomposed]), ".jobcompat.yml")
    remaining, matched = config.suppressions(findings)
    assert_equal findings, remaining
    assert_empty matched
    config = Jobcompat::Config.validate(ignore_config(["JC003", decomposed]), ".jobcompat.yml")
    remaining, matched = config.suppressions(findings)
    assert_equal [findings.last], remaining
    assert_equal [{rule_id: "JC003", worker: decomposed, reason: "intentional migration", finding_count: 1}], matched
    config = Jobcompat::Config.validate(ignore_config(["JC003", "Admin::#{decomposed}"], ["JC005", decomposed]), ".jobcompat.yml")
    remaining, matched = config.suppressions(findings)
    assert_equal [findings.first], remaining
    assert_equal ["Admin::#{decomposed}"], matched.map { |item| item[:worker] }
  end

  def test_default_config_path_is_a_directory
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".jobcompat.yml"))
      error = assert_raises(Jobcompat::Error) { Jobcompat::Config.load(root: root) }
      assert_equal "config_error", error.category
    end
  end

  def test_config_rejects_unsafe_yaml_and_accepts_empty_exclusions
    Dir.mktmpdir do |root|
      path = File.join(root, ".jobcompat.yml")
      ["", "---\n- version: 1\n", "version: 1\nignore: &entry []\nscan: *entry\n",
       "version: 1\nignore: !ruby/object:Object {}\n", "version: [\n",
       "version: 1\nignore:\n  - rule: JC003\n    worker: A\xFFJob\n    reason: x\n".b,
       "version: 1\nignore:\n  - rule: JC003\n    worker: !!binary wUpvYg==\n    reason: x\n"].each do |source|
        File.write(path, source)
        error = assert_raises(Jobcompat::Error) { Jobcompat::Config.load(root: root) }
        assert_equal "config_error", error.category
      end
      File.write(path, "version: 1\nscan:\n  include: ['app/**/*.rb']\n  exclude: []\n")
      config = Jobcompat::Config.load(root: root)
      assert config.scan?("app/vendor/job.rb")
      refute config.scan?("test/job.rb")
    end
  end
end
