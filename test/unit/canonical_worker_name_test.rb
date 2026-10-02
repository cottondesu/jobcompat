require_relative "../test_helper"

class CanonicalWorkerNameTest < Minitest::Test
  DECOMPOSED = "ÁJob"
  PRECOMPOSED = "ÁJob"

  ACCEPTED = {
    "ascii" => "ExportJob",
    "qualified ascii" => "Admin::ExportJob",
    "deeply qualified" => "Admin::Exports::ExportJob",
    "decomposed combining mark" => DECOMPOSED,
    "qualified decomposed" => "Admin::#{DECOMPOSED}",
    "precomposed" => PRECOMPOSED,
    "Greek capital" => "ΔJob",
    "Cyrillic capital" => "ЖJob",
    "CJK after uppercase start" => "Job管理",
    "qualified CJK after uppercase start" => "Job管理::E輸出",
    "emoji after uppercase start" => "A\u{1F600}Job",
    "digits and underscore" => "Export_Job2"
  }.freeze

  REJECTED = {
    "empty String" => "",
    "lowercase identifier" => "exportJob",
    "lowercase qualified segment" => "Admin::exportJob",
    "CJK-only segments (not Ruby constants)" => "管理::輸出",
    "leading ::" => "::Admin::ExportJob",
    "trailing ::" => "Admin::",
    "malformed ::" => "Admin::::Job",
    "method call" => "ExportJob()",
    "dot call" => "Admin.ExportJob",
    "multiple statements" => "ExportJob; OtherJob",
    "newline + second statement" => "ExportJob\nOtherJob",
    "trailing newline" => "ExportJob\n",
    "comment" => "ExportJob # comment",
    "leading comment" => "# comment\nExportJob",
    "leading whitespace" => " ExportJob",
    "trailing whitespace" => "ExportJob ",
    "spaced ::" => "Admin :: ExportJob",
    "space after ::" => "Admin:: ExportJob",
    "parenthesized expression" => "(ExportJob)",
    "parenthesized parent" => "(Admin)::ExportJob",
    "binary expression" => "ExportJob + OtherJob",
    "rescue modifier" => "ExportJob rescue OtherJob",
    "self:: constant" => "self::ExportJob",
    "array expression" => "[ExportJob]",
    "NUL byte" => "ExportJob\0",
    "__END__ data" => "ExportJob\n__END__\njunk",
    "byte order mark" => "﻿ExportJob",
    "leading combining mark" => "́Job",
    "invalid UTF-8" => "A\xFFJob".dup.force_encoding(Encoding::UTF_8),
    "truncated UTF-8" => "Job\xC3".dup.force_encoding(Encoding::UTF_8),
    "unconvertible binary bytes" => "\xC1Job".b
  }.freeze

  def parse(value)
    Jobcompat::CanonicalWorkerName.parse(value)
  end

  def test_combining_mark_fixture_uses_exact_codepoints
    assert_equal [0x41, 0x301, 0x4a, 0x6f, 0x62], DECOMPOSED.codepoints
    assert_equal [0xc1, 0x4a, 0x6f, 0x62], PRECOMPOSED.codepoints
  end

  def test_accepted_canonical_names_round_trip_exactly
    ACCEPTED.each do |label, name|
      result = parse(name)
      assert_equal name, result, label
      assert_equal Encoding::UTF_8, result.encoding, label
      assert_equal name.codepoints, result.codepoints, label
    end
  end

  def test_rejected_names_matrix
    REJECTED.each do |label, value|
      assert_nil parse(value), label
    end
  end

  def test_non_string_values_are_unsupported
    [nil, 1, :ExportJob, ["ExportJob"], {"ExportJob" => true}].each { |value| assert_nil parse(value), value.inspect }
  end

  def test_precomposed_and_decomposed_names_are_not_normalized
    refute_equal parse(DECOMPOSED), parse(PRECOMPOSED)
    assert_equal DECOMPOSED.codepoints, parse(DECOMPOSED).codepoints
    assert_equal PRECOMPOSED.codepoints, parse(PRECOMPOSED).codepoints
  end

  def test_valid_non_utf8_encodings_convert_to_canonical_utf8
    assert_equal PRECOMPOSED, parse("\xC1Job".dup.force_encoding(Encoding::ISO_8859_1))
    assert_equal "Job管理", parse("Job管理".encode(Encoding::Shift_JIS))
    assert_equal "ExportJob", parse("ExportJob".b)
    assert_nil parse("\x81".dup.force_encoding(Encoding::Shift_JIS))
  end

  def test_validator_loads_without_analyzer_or_config
    root = File.expand_path("../..", __dir__)
    script = <<~RUBY
      require "jobcompat/canonical_worker_name"
      abort "Analyzer loaded" if defined?(Jobcompat::Analyzer)
      abort "Config loaded" if defined?(Jobcompat::Config)
      puts Jobcompat::CanonicalWorkerName.parse("Admin::A\\u0301Job").codepoints.inspect
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.join(root, 'lib')}", "-e", script)
    assert status.success?, error
    assert_equal "Admin::ÁJob".codepoints.inspect, output.strip
  end

  def test_producer_analysis_and_config_accept_the_same_names
    ACCEPTED.merge(REJECTED).each do |label, name|
      source = "Sidekiq::Client.push(\"class\" => #{name.dump}, \"args\" => [1])"
      call = Jobcompat::Analyzer.new("head", "app/job.rb", source, index: Jobcompat::DefinedConstantIndex.new).analyze.calls.fetch(0)
      producer = call.resolution_mode == "exact_string" ? call.receiver : nil
      config = {"version" => 1, "ignore" => [{"rule" => "JC003", "worker" => name, "reason" => "x"}]}
      if parse(name)
        assert_equal name, Jobcompat::Config.validate(config, "x").ignore.first["worker"], label
        assert_equal [name, nil], [producer, call.unknown_reason], label
      else
        error = assert_raises(Jobcompat::Error, label) { Jobcompat::Config.validate(config, "x") }
        assert_equal ["config_error", "ignore[0].worker is invalid"], [error.category, error.message], label
        assert_equal [nil, "unsupported_client_payload"], [producer, call.unknown_reason], label
      end
    end
  end

  def test_analyzer_and_config_share_the_validator
    refute Jobcompat::Analyzer.private_method_defined?(:canonical_client_string_worker_name)
    root = File.expand_path("../..", __dir__)
    script = <<~RUBY
      require "jobcompat/errors"
      require "jobcompat/config"
      abort "Analyzer loaded" if defined?(Jobcompat::Analyzer)
      config = Jobcompat::Config.validate({"version" => 1, "ignore" => [{"rule" => "JC003", "worker" => "A\\u0301Job", "reason" => "x"}]}, "x")
      puts config.ignore.first["worker"].codepoints.inspect
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.join(root, 'lib')}", "-e", script)
    assert status.success?, error
    assert_equal DECOMPOSED.codepoints.inspect, output.strip
  end
end
