require_relative "../test_helper"

class ProducerV02Test < Minitest::Test
  def analyze(source)
    index = Jobcompat::DefinedConstantIndex.new
    Jobcompat::Analyzer.new("head", "app/job.rb", source, index: index).analyze
  end

  def test_perform_bulk_normalizes_distinct_arities_and_preserves_unknown_rows
    analysis = analyze(<<~RUBY)
      ExportJob.perform_bulk([[1], [2], [3, "csv"], [], [id, *rest], row], at: times)
      ExportJob.perform_bulk([])
      ExportJob.perform_bulk(rows)
      ExportJob.perform_bulk([[1]], **options)
      ExportJob&.perform_bulk([[1]])
    RUBY

    first = analysis.calls.select { |call| call.location.line == 1 }
    assert_equal [0, 1, 2], first.filter_map(&:arity)
    assert_equal ["dynamic_bulk_arguments"], first.filter_map(&:unknown_reason)
    assert_empty analysis.calls.select { |call| call.location.line == 2 }
    assert_equal "dynamic_bulk_arguments", analysis.calls.find { |call| call.location.line == 3 }.unknown_reason
    assert_equal "dynamic_bulk_options", analysis.calls.find { |call| call.location.line == 4 }.unknown_reason
    assert_equal "safe_navigation_receiver", analysis.calls.find { |call| call.location.line == 5 }.unknown_reason
  end

  def test_large_bulk_literal_emits_one_fact_per_distinct_arity
    rows = Array.new(1_000, "[1]").join(", ")
    analysis = analyze("ExportJob.perform_bulk([#{rows}])\n")
    assert_equal [1], analysis.calls.map(&:arity)
  end

  def test_set_chains_use_async_scheduled_and_bulk_payload_semantics
    analysis = analyze(<<~RUBY)
      ExportJob.set(queue: :critical).perform_async(id)
      ExportJob.set(queue: :critical).perform_in(5, id)
      ExportJob.set(queue: :critical).perform_at(time, id, format)
      ExportJob.set(queue: :critical).perform_bulk([[1], [2, "csv"]], batch_size: 10)
      ExportJob.set(queue: :critical).perform_in(*args)
    RUBY

    assert_equal [1, 1, 2, 1, 2, nil], analysis.calls.map(&:arity)
    assert_equal "splat_arguments", analysis.calls.last.unknown_reason
  end

  def test_client_push_extracts_only_static_string_key_payloads
    analysis = analyze(<<~RUBY)
      Sidekiq::Client.push("class" => ExportJob, "args" => [])
      ::Sidekiq::Client.push("class" => ::Admin::ExportJob, "args" => [id], "queue" => "critical")
      Sidekiq::Client.push("class" => "Admin::ExportJob", "args" => [id, format])
      Sidekiq::Client.push(payload)
      Sidekiq::Client.push("class" => worker_class, "args" => [id])
      Sidekiq::Client.push("class" => ExportJob, "args" => args)
      Sidekiq::Client.push("class" => ExportJob, "args" => [id], **options)
      Sidekiq::Client.push(class: ExportJob, args: [id])
      Sidekiq::Client.push("class" => ExportJob)
      Sidekiq::Client.push("args" => [id])
      MyClient.push("class" => ExportJob, "args" => [id])
      Sidekiq::Client.new.push("class" => ExportJob, "args" => [id])
    RUBY

    assert_equal [0, 1, 2], analysis.calls.first(3).map(&:arity)
    assert_equal "client_constant", analysis.calls[1].resolution_mode
    assert analysis.calls[1].root
    assert_equal "exact_string", analysis.calls[2].resolution_mode
    assert_equal %w[dynamic_client_payload dynamic_client_class dynamic_client_args dynamic_client_class unsupported_client_payload
                    unsupported_client_payload unsupported_client_payload],
                 analysis.calls.drop(3).map(&:unknown_reason)
    assert_equal 10, analysis.calls.length
  end

  def test_client_push_bulk_reuses_bulk_semantics_and_supported_options
    analysis = analyze(<<~RUBY)
      Sidekiq::Client.push_bulk("class" => ExportJob, "args" => [[1], [2, "csv"], [3], row], at: times)
      Sidekiq::Client.push_bulk("class" => "ExportJob", "args" => [], batch_size: 100, spread_interval: 60)
      Sidekiq::Client.push_bulk("class" => ExportJob, "args" => rows)
      Sidekiq::Client.push_bulk("class" => worker_class, "args" => [[1]])
      Sidekiq::Client.push_bulk("class" => ExportJob, "args" => [[1]], **options)
    RUBY

    first = analysis.calls.select { |call| call.location.line == 1 }
    assert_equal [1, 2], first.filter_map(&:arity)
    assert_equal ["dynamic_bulk_arguments"], first.filter_map(&:unknown_reason)
    assert_empty analysis.calls.select { |call| call.location.line == 2 }
    assert_equal "dynamic_bulk_arguments", analysis.calls.find { |call| call.location.line == 3 }.unknown_reason
    assert_equal "dynamic_client_class", analysis.calls.find { |call| call.location.line == 4 }.unknown_reason
    assert_equal "dynamic_client_class", analysis.calls.find { |call| call.location.line == 5 }.unknown_reason
  end

  def test_client_hash_splat_before_required_keys_cannot_override_them
    analysis = analyze(<<~RUBY)
      Sidekiq::Client.push({**options, "class" => ExportJob, "args" => [id]})
      Sidekiq::Client.push_bulk({**options, "class" => ExportJob, "args" => [[1], [2, "csv"]]})
    RUBY

    assert_equal [1], analysis.calls.select { |call| call.location.line == 1 }.map(&:arity)
    assert_equal [1, 2], analysis.calls.select { |call| call.location.line == 2 }.map(&:arity)
    assert_empty analysis.calls.filter_map(&:unknown_reason)
  end

  def test_client_hash_splats_track_class_and_args_certainty_independently
    analysis = analyze(<<~RUBY)
      Sidekiq::Client.push({"args" => [id], **payload, "class" => ExportJob})
      Sidekiq::Client.push({"class" => ExportJob, **payload, "args" => [id]})
      Sidekiq::Client.push({**payload, "class" => ExportJob, "args" => [id]})
      Sidekiq::Client.push({"class" => ExportJob, "args" => [id], **payload})
      Sidekiq::Client.push({**a, "args" => [id], **b, "class" => ExportJob})
      Sidekiq::Client.push({"args" => [id], **payload, "class" => "Admin::ExportJob"})
      Sidekiq::Client.push_bulk({"args" => [[id]], **payload, "class" => ExportJob})
      Sidekiq::Client.push({"class" => OldJob, **payload, "class" => ExportJob, "args" => [id]})
      Sidekiq::Client.push({"class" => OldJob, "class" => ExportJob, "args" => [id]})
      Sidekiq::Client.push({**a, "class" => ExportJob, **b, "args" => [id]})
      Sidekiq::Client.push_bulk({"class" => ExportJob, **payload, "args" => [[id]]})
    RUBY

    blocker = analysis.calls.find { |call| call.location.line == 1 }
    assert_equal "ExportJob", blocker.receiver
    assert_nil blocker.arity
    assert_equal "dynamic_client_args", blocker.unknown_reason

    opposite = analysis.calls.find { |call| call.location.line == 2 }
    assert_nil opposite.receiver
    assert_nil opposite.arity
    assert_equal "dynamic_client_class", opposite.unknown_reason

    leading = analysis.calls.find { |call| call.location.line == 3 }
    assert_equal "ExportJob", leading.receiver
    assert_equal 1, leading.arity
    assert_nil leading.unknown_reason

    trailing = analysis.calls.find { |call| call.location.line == 4 }
    assert_nil trailing.receiver
    assert_equal "dynamic_client_class", trailing.unknown_reason

    multiple = analysis.calls.find { |call| call.location.line == 5 }
    assert_equal "ExportJob", multiple.receiver
    assert_equal "dynamic_client_args", multiple.unknown_reason

    string_worker = analysis.calls.find { |call| call.location.line == 6 }
    assert_equal "Admin::ExportJob", string_worker.receiver
    assert_equal "exact_string", string_worker.resolution_mode
    assert_equal "dynamic_client_args", string_worker.unknown_reason

    bulk = analysis.calls.find { |call| call.location.line == 7 }
    assert_equal "ExportJob", bulk.receiver
    assert_nil bulk.arity
    assert_equal "dynamic_bulk_arguments", bulk.unknown_reason

    after_splat, duplicate, class_unknown, bulk_class_unknown = analysis.calls.select { |call| call.location.line >= 8 }
    assert_equal ["ExportJob", 1, nil], [after_splat.receiver, after_splat.arity, after_splat.unknown_reason]
    assert_equal ["ExportJob", 1, nil], [duplicate.receiver, duplicate.arity, duplicate.unknown_reason]
    assert_nil class_unknown.receiver
    assert_equal "dynamic_client_class", class_unknown.unknown_reason
    assert_nil bulk_class_unknown.receiver
    assert_equal "dynamic_client_class", bulk_class_unknown.unknown_reason
  end

  %w[push push_bulk].each do |method|
    define_method("test_#{method}_dynamic_keys_preserve_only_final_per_key_evidence") do
      args = method == "push" ? "[id]" : "[[id]]"
      cases = [
        ['dynamic_key => value, "class" => ExportJob, "args" => ARGS', :known, :known],
        ['"class" => ExportJob, dynamic_key => value, "args" => ARGS', :unsupported, :known],
        ['"args" => ARGS, dynamic_key => value, "class" => ExportJob', :known, :unsupported],
        ['"class" => ExportJob, "args" => ARGS, dynamic_key => value', :unsupported, :unsupported],
        ['"class" => OldJob, dynamic_key => value, "class" => ExportJob, "args" => ARGS', :known, :known],
        ['"class" => OldJob, "class" => ExportJob, dynamic_key => value, "args" => ARGS', :unsupported, :known],
        ['**a, "class" => ExportJob, dynamic_key => value, "args" => ARGS', :unsupported, :known],
        ['dynamic_key => value, "args" => ARGS, **b, "class" => ExportJob', :known, :unknown],
        ['**a, dynamic_key => value, **b, "class" => ExportJob, "args" => ARGS', :known, :known],
        ['"class" => ExportJob, "args" => ARGS, **a, dynamic_key => value, **b', :unknown, :unknown],
        ['"class" => ExportJob, "args" => ARGS, "queue" => "critical"', :known, :known],
        ['"queue" => "critical", "class" => ExportJob, "args" => ARGS', :known, :known],
        ['dynamic_key => value, ("class") => (ExportJob), ("args") => (ARGS)', :known, :known],
        ['("class") => (ExportJob), (dynamic_key) => value, ("args") => (ARGS)', :unsupported, :known],
        ['"class" => ExportJob, dynamic_key => value, "class" => worker_class, "args" => ARGS', :known, :known],
        ['"class" => ExportJob, "args" => ARGS, "args" => rows, dynamic_key => value, "class" => ExportJob', :known, :unsupported]
      ]

      cases.each do |entries, class_status, args_status|
        source = "Sidekiq::Client.#{method}({#{entries.gsub('ARGS', args)}})"
        analysis = analyze(source)
        payload = Prism.parse(source).value.statements.body.first.arguments.arguments.first
        class_node, actual_class_status = analysis.send(:client_hash_value, payload.elements, "class")
        args_node, actual_args_status = analysis.send(:client_hash_value, payload.elements, "args")
        assert_equal [class_status, args_status], [actual_class_status, actual_args_status], source
        if args_status == :known
          if method == "push"
            assert_equal 1, Jobcompat::Analyzer.unwrap_parentheses(args_node).elements.length, source
          else
            assert_equal [[1], false], analysis.send(:extract_bulk_arities, args_node), source
          end
        else
          assert_nil args_node, source
        end
        dynamic_class = class_node && class_node.location.slice == "worker_class"
        expected_worker = class_status == :known && !dynamic_class ? "ExportJob" : nil
        reason = if [class_status, args_status].include?(:unsupported)
                   "unsupported_client_payload"
                 elsif class_status != :known || dynamic_class
                   "dynamic_client_class"
                 elsif args_status != :known
                   method == "push" ? "dynamic_client_args" : "dynamic_bulk_arguments"
                 end
        call = analysis.calls.fetch(0)
        assert_equal 1, analysis.calls.length, source
        assert_equal [expected_worker, expected_worker && "client_constant", reason ? nil : 1, reason],
                     [call.receiver, call.resolution_mode, call.arity, call.unknown_reason], source
      end
    end
  end

  def test_dynamic_key_ordering_preserves_exact_string_targets_in_namespaces
    %w[push push_bulk].each do |method|
      %w[ExportJob Admin::ExportJob].each do |name|
        args = method == "push" ? "[id]" : "[[id]]"
        analysis = analyze(<<~RUBY)
          module Admin
            Sidekiq::Client.#{method}({dynamic_key => value, "class" => "#{name}", "args" => #{args}})
            Sidekiq::Client.#{method}({"args" => #{args}, dynamic_key => value, "class" => "#{name}"})
            Sidekiq::Client.#{method}({"class" => "#{name}", dynamic_key => value, "args" => #{args}})
            Sidekiq::Client.#{method}({"class" => "#{name}", "args" => #{args}, dynamic_key => value})
          end
        RUBY
        assert_equal [
          [name, "exact_string", 1, nil],
          [name, "exact_string", nil, "unsupported_client_payload"],
          [nil, nil, nil, "unsupported_client_payload"],
          [nil, nil, nil, "unsupported_client_payload"]
        ], analysis.calls.map { |call| [call.receiver, call.resolution_mode, call.arity, call.unknown_reason] }
        assert analysis.calls.all? { |call| call.namespace == ["Admin"] }
      end
    end
  end

  def test_static_non_string_keys_remain_unsupported_without_overwriting_string_keys
    %w[push push_bulk].each do |method|
      args = method == "push" ? "[id]" : "[[id]]"
      [':class', '(:class)', '1', 'nil', '[1]'].each do |key|
        call = analyze("Sidekiq::Client.#{method}({\"class\" => ExportJob, \"args\" => #{args}, #{key} => value})").calls.fetch(0)
        assert_equal ["ExportJob", "client_constant", nil, "unsupported_client_payload"],
                     [call.receiver, call.resolution_mode, call.arity, call.unknown_reason]
      end
      call = analyze("Sidekiq::Client.#{method}({class: ExportJob, args: #{args}})").calls.fetch(0)
      assert_equal [nil, nil, nil, "unsupported_client_payload"],
                   [call.receiver, call.resolution_mode, call.arity, call.unknown_reason]
    end
  end

  def test_non_static_key_expressions_and_keyword_hashes_use_the_same_ordering
    ['"#{key}"', ':"#{key}"', 'key.to_s', '("class"; dynamic_key)'].each do |key|
      %w[push push_bulk].each do |method|
        args = method == "push" ? "[id]" : "[[id]]"
        analysis = analyze(<<~RUBY)
          Sidekiq::Client.#{method}(#{key} => value, "class" => ExportJob, "args" => #{args})
          Sidekiq::Client.#{method}("class" => ExportJob, "args" => #{args}, #{key} => value)
        RUBY
        assert_equal [["ExportJob", "client_constant", 1, nil], [nil, nil, nil, "unsupported_client_payload"]],
                     analysis.calls.map { |call| [call.receiver, call.resolution_mode, call.arity, call.unknown_reason] }
      end
    end
  end

  def test_supported_bulk_symbol_options_do_not_erase_known_dynamic_key_evidence
    analysis = analyze(<<~RUBY)
      Sidekiq::Client.push_bulk({dynamic_key => value, "class" => ::Admin::ExportJob, "args" => [[id]], at: times, batch_size: 10, spread_interval: 60})
      Sidekiq::Client.push_bulk({"args" => [[id]], dynamic_key => value, "class" => ::Admin::ExportJob, at: times})
    RUBY
    assert_equal [["Admin::ExportJob", "client_constant", 1, nil], ["Admin::ExportJob", "client_constant", nil, "unsupported_client_payload"]],
                 analysis.calls.map { |call| [call.receiver, call.resolution_mode, call.arity, call.unknown_reason] }
    assert analysis.calls.all?(&:root)
  end

  def test_missing_client_keys_are_distinct_from_possible_dynamic_writes
    cases = [
      ['"class" => ExportJob', :known, :missing, "ExportJob"],
      ['"args" => [id]', :missing, :known, nil],
      ['dynamic_key => value', :unsupported, :unsupported, nil],
      ['**payload', :unknown, :unknown, nil],
      ['dynamic_key => value, "class" => ExportJob', :known, :unsupported, "ExportJob"]
    ]
    cases.each do |entries, class_status, args_status, worker|
      source = "Sidekiq::Client.push({#{entries}})"
      analysis = analyze(source)
      elements = Prism.parse(source).value.statements.body.first.arguments.arguments.first.elements
      assert_equal class_status, analysis.send(:client_hash_value, elements, "class").last
      assert_equal args_status, analysis.send(:client_hash_value, elements, "args").last
      call = analysis.calls.fetch(0)
      reason = entries == "**payload" ? "dynamic_client_class" : "unsupported_client_payload"
      assert_equal [worker, worker && "client_constant", nil, reason],
                   [call.receiver, call.resolution_mode, call.arity, call.unknown_reason]
    end
  end

  def test_parenthesized_static_client_and_bulk_values_remain_known
    analysis = analyze(<<~RUBY)
      (ExportJob).perform_bulk(([[1], ([2, "csv"])]))
      (Sidekiq::Client).push("class" => (ExportJob), "args" => ([id, format]))
      Sidekiq::Client.push_bulk("class" => "ExportJob", "args" => ([([1]), ([2, "csv"])]))
    RUBY

    assert_equal [1, 2], analysis.calls.select { |call| call.location.line == 1 }.map(&:arity)
    assert_equal [2], analysis.calls.select { |call| call.location.line == 2 }.map(&:arity)
    assert_equal [1, 2], analysis.calls.select { |call| call.location.line == 3 }.map(&:arity)
    assert_empty analysis.calls.filter_map(&:unknown_reason)
  end

  def test_perform_bulk_retains_namespace_and_root_resolution_metadata
    analysis = analyze(<<~RUBY)
      module Admin
        ExportJob.perform_bulk([[1]])
      end
      ::Admin::ExportJob.perform_bulk([[1, "csv"]])
    RUBY

    lexical, rooted = analysis.calls
    assert_equal "ExportJob", lexical.receiver
    assert_equal ["Admin"], lexical.namespace
    refute lexical.root
    assert_equal "Admin::ExportJob", rooted.receiver
    assert rooted.root
    assert_equal [1, 2], analysis.calls.map(&:arity)
  end

  def test_client_string_workers_use_ruby_constant_syntax_without_normalization
    names = ["A\u0301Job", "Admin::A\u0301Job", "ÁJob", "ΔJob", "ЖJob", "Job管理", "A\u{1F600}Job"]
    assert_equal [0x41, 0x301, 0x4a, 0x6f, 0x62], names.first.codepoints
    %w[push push_bulk].each do |method|
      args = method == "push" ? "[1, 2]" : "[[1, 2]]"
      names.each do |name|
        call = analyze("Sidekiq::Client.#{method}(\"class\" => #{name.dump}, \"args\" => #{args})").calls.fetch(0)
        assert_equal [name, "exact_string", false, 2, nil],
                     [call.receiver, call.resolution_mode, call.root, call.arity, call.unknown_reason], name
      end
    end
  end

  def test_client_string_workers_reject_noncanonical_complete_inputs
    names = ["", "exportJob", "Admin::", "Admin::::Job", "::Admin::ExportJob", "ExportJob()",
             "ExportJob; OtherJob", "ExportJob\nOtherJob", "ExportJob # comment", "# comment\nExportJob",
             " ExportJob", "ExportJob ", "ExportJob\n", "Admin :: ExportJob", "Admin:: ExportJob",
             "(ExportJob)", "ExportJob + OtherJob", "ExportJob rescue OtherJob", "self::ExportJob",
             "[ExportJob]", "ExportJob\0", "ExportJob\n__END__\njunk"]
    %w[push push_bulk].each do |method|
      args = method == "push" ? "[1]" : "[[1]]"
      names.each do |name|
        call = analyze("Sidekiq::Client.#{method}(\"class\" => #{name.dump}, \"args\" => #{args})").calls.fetch(0)
        assert_equal [nil, nil, nil, "unsupported_client_payload"],
                     [call.receiver, call.resolution_mode, call.arity, call.unknown_reason], name.dump
      end
    end
  end

  def test_client_string_workers_with_invalid_bytes_are_unsupported
    %w[push push_bulk].each do |method|
      args = method == "push" ? "[]" : "[[]]"
      ['"\\xFF"', '"A\\xFFJob"'].each do |value|
        call = analyze("Sidekiq::Client.#{method}(\"class\" => #{value}, \"args\" => #{args})").calls.fetch(0)
        assert_equal [nil, nil, nil, "unsupported_client_payload"],
                     [call.receiver, call.resolution_mode, call.arity, call.unknown_reason]
      end
    end
  end

  def test_client_string_workers_preserve_valid_source_encoding
    source = 'Sidekiq::Client.push("class" => "Job管理", "args" => [1])'
    call = analyze(("# coding: Shift_JIS\n" + source).encode("Shift_JIS").b).calls.fetch(0)
    assert_equal ["Job管理", "exact_string", 1, nil],
                 [call.receiver, call.resolution_mode, call.arity, call.unknown_reason]
  end
end
