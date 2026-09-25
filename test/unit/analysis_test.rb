require_relative "../test_helper"

class AnalysisTest < Minitest::Test
  def analyze(source, path = "app/job.rb")
    index = Jobcompat::DefinedConstantIndex.new
    [Jobcompat::Analyzer.new("head", path, source, index: index).analyze, index]
  end

  def test_worker_forms_and_presence_index
    source = <<~RUBY
      module Admin
        class ExportJob
          include(::Sidekiq::Job)
          def perform(id); end
        end
      end
      class Admin::LegacyWorker
        include Sidekiq::Worker
        def perform(*args); end
      end
      class Plain; end
    RUBY
    analysis, index = analyze(source)
    assert_equal %w[Admin::ExportJob Admin::LegacyWorker Plain], index.selected.keys.sort - ["Admin"]
    assert_equal %w[Admin::ExportJob Admin::LegacyWorker], analysis.fragments.select { |fragment| !fragment.includes.empty? }.map(&:name).sort
  end

  def test_root_qualified_worker_and_multi_argument_include
    analysis, index = analyze("class ::Admin::ExportJob; include OtherConcern, Sidekiq::Job; def perform(id); end; end\n")
    assert_equal ["Admin::ExportJob"], analysis.fragments.map(&:name)
    assert_equal 1, analysis.fragments.first.includes.length
    assert_equal "defined_unrecognized", index.status("Admin::ExportJob")
  end

  def test_arity_shapes
    {
      "" => [0, 0], "a" => [1, 1], "a, b" => [2, 2], "a, b=nil" => [1, 2],
      "a, b=nil, c=nil" => [1, 3], "*args" => [0, nil], "a, *args" => [1, nil],
      "a, *args, z" => [2, nil], "..." => [0, nil], "a, ..." => [1, nil],
      "a=nil, b=nil" => [0, 2], "(a, b)" => [1, 1], "a, &block" => [1, 1]
    }.each do |signature, expected|
      analysis, = analyze("class ExportJob; include Sidekiq::Job; def perform(#{signature}); end; end")
      fragment = analysis.fragments.first
      node = fragment.performs.first.first
      params = node.parameters
      actual = [params ? params.requireds.length + params.posts.length : 0,
                params && (params.rest || params.keyword_rest.is_a?(Prism::ForwardingParameterNode)) ? nil : (params ? params.requireds.length + params.posts.length + params.optionals.length : 0)]
      assert_equal expected, actual, signature
    end
  end

  def test_producer_payload_slots_and_unknowns
    source = <<~RUBY
      ExportJob.perform_async
      ExportJob.perform_async(id, {"format" => "csv"})
      ExportJob.perform_async([id, other])
      ExportJob.perform_in(5, id, "csv")
      ExportJob.perform_at(time)
      ExportJob.set(queue: :critical).perform_async(id)
      ExportJob.perform_async(*args)
      job_class.perform_async(id)
      ExportJob&.set(queue: :critical).perform_async(id)
      job_class&.perform_async(id)
      job_class&.perform_async(*args)
      self::ExportJob&.perform_async(id)
    RUBY
    analysis, = analyze(source)
    assert_equal [0, 2, 1, 2, 0, 1, nil, 1, 1, 1, nil, 1], analysis.calls.map(&:arity)
    assert_equal ["splat_arguments", "dynamic_receiver", "safe_navigation_receiver", "dynamic_receiver", "splat_arguments", "unsupported_constant_path"],
                 analysis.calls.last(6).map(&:unknown_reason)
  end

  def test_forwarding_missing_schedule_and_keyword_hash_payload
    source = <<~RUBY
      def enqueue(...)
        ExportJob.perform_async(...)
      end
      ExportJob.perform_in
      ExportJob.perform_async(id, format: "csv")
    RUBY
    analysis, = analyze(source)
    assert_equal [nil, nil, 2], analysis.calls.map(&:arity)
    assert_equal %w[forwarded_arguments missing_schedule_argument], analysis.calls.first(2).map(&:unknown_reason)
    assert_nil analysis.calls.last.unknown_reason
  end

  def test_valid_non_utf8_ruby_source_with_encoding_declaration
    source = "# coding: Shift_JIS\nclass ExportJob; include Sidekiq::Job; def perform(id, label=\"日本語\"); end; end\n".encode("Shift_JIS").b
    analysis, = analyze(source)
    assert_equal "ExportJob", analysis.fragments.first.name
  end

  def test_presence_finds_later_eligible_declaration_before_budget_boundary
    entry = Struct.new(:path, :size)
    tracked = [entry.new("vendor/reference.rb", 24), entry.new("vendor/definition.rb", 32),
               entry.new("vendor/oversize.rb", Jobcompat::DefinedConstantIndex::BUDGET)]
    contents = {"vendor/reference.rb" => "ExportJob.perform_async(1)\n",
                "vendor/definition.rb" => "class ExportJob; end\n"}
    repository = Struct.new(:contents) do
      def each_blob(entries)
        entries.each { |item| yield item, contents.fetch(item.path) }
      end
    end.new(contents)
    config = Object.new
    def config.scan?(_path) = false
    index = Jobcompat::DefinedConstantIndex.new
    snapshot = Jobcompat::RevisionSnapshot.new(label: "head", ref: "HEAD", sha: "x", workers: {}, calls: [], unknowns: [],
                                               index: index, files_scanned: 0, tracked_ruby: tracked)
    snapshot.check_presence(["ExportJob"], repository, config)
    assert_equal "outside_scan_scope", index.status("ExportJob")
    assert_equal ["vendor/definition.rb"], index.locations("ExportJob").select { |loc| loc.role == "worker_declaration" }.map(&:path).uniq
  end
end
