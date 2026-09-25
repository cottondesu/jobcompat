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
    unicode = Jobcompat::Config.validate({"version" => 1, "ignore" => [{"rule" => "JC005", "worker" => "管理::輸出", "reason" => "gated"}]}, ".jobcompat.yml")
    assert_equal "管理::輸出", unicode.ignore.first["worker"]
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
       "version: 1\nignore: !ruby/object:Object {}\n", "version: [\n"].each do |source|
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
