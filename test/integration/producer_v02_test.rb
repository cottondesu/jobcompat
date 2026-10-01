require_relative "../test_helper"
require_relative "../support/temporary_repository"

class ProducerV02IntegrationTest < Minitest::Test
  include TemporaryRepository

  def test_perform_bulk_mixed_known_unknown_emits_existing_error_and_warning
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_bulk([[1], row])\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.perform_bulk([[1], [2, 'csv'], row])\n")

      data, error, code = json_check(dir, base)
      assert_equal 1, code, error
      assert_equal 2, data["schema_version"]
      assert_equal %w[JC001 JC002 JC007 JC007], data["findings"].map { |item| item["rule_id"] }
      assert_equal [1, 2], data["workers"][0]["producer_arities"]["head"]
      assert data["findings"].last(2).all? { |item| item["unknown_reason"] == "dynamic_bulk_arguments" }
    end
  end

  def test_bulk_producers_feed_jc002_and_jc003_without_new_rules
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format=nil") + "ExportJob.perform_bulk([[1, 'csv']])\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC002"], data["findings"].map { |item| item["rule_id"] }

      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push_bulk("class" => ExportJob, "args" => [[1], [2, "csv"]])
      RUBY
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC003"], data["findings"].map { |item| item["rule_id"] }
      assert_equal 2, data["findings"][0]["payload_arity"]
    end
  end

  def test_scheduled_set_chain_excludes_schedule_argument
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + "ExportJob.set(queue: :critical).perform_in(60, 1)\n")
      commit(dir, "app/export_job.rb" => worker("id, format") + "ExportJob.set(queue: :critical).perform_at(Time.now, 1)\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC001"], data["findings"].map { |item| item["rule_id"] }
      assert_equal 1, data["findings"][0]["payload_arity"]
    end
  end

  def test_client_push_supports_constant_and_exact_string_resolution
    with_repository do |dir|
      source = <<~RUBY
        module Admin
          class ExportJob
            include Sidekiq::Job
            def perform(id); end
          end
          Sidekiq::Client.push("class" => ExportJob, "args" => [1])
          Sidekiq::Client.push("class" => "Admin::ExportJob", "args" => [1])
          Sidekiq::Client.push("class" => "ExportJob", "args" => [1])
        end
      RUBY
      sha = commit(dir, "app/export_job.rb" => source)
      data, _, code = json_check(dir, sha, "--head", sha)
      assert_equal 0, code
      assert_equal [1], data["workers"][0]["producer_arities"]["head"]
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_equal "dynamic_client_class", data["findings"][0]["unknown_reason"]
    end
  end

  def test_client_push_and_push_bulk_feed_existing_directional_rules
    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push("class" => ExportJob, "args" => [1])
      RUBY
      commit(dir, "app/export_job.rb" => worker("id, format") + <<~RUBY)
        Sidekiq::Client.push("class" => ExportJob, "args" => [1])
      RUBY
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC001"], data["findings"].map { |item| item["rule_id"] }
      assert_equal %w[base_to_head head_to_head], data["findings"][0]["directions"]
    end

    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker("id, format=nil") + <<~RUBY)
        Sidekiq::Client.push_bulk("class" => ExportJob, "args" => [[1, "csv"]])
      RUBY
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC002"], data["findings"].map { |item| item["rule_id"] }
    end

    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker)
      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push_bulk("class" => ExportJob, "args" => [[1], [2, "csv"]])
      RUBY
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC003"], data["findings"].map { |item| item["rule_id"] }
      assert_equal 2, data["findings"][0]["payload_arity"]
    end
  end

  def test_new_worker_client_push_uses_jc005_and_bulk_witness_uses_jc001
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push("class" => ExportJob, "args" => [1])
      RUBY
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC005"], data["findings"].map { |item| item["rule_id"] }
    end

    with_repository do |dir|
      base = commit(dir, "app/export_job.rb" => worker("id, format=nil") + "ExportJob.perform_bulk([[1, 'csv']])\n")
      commit(dir, "app/export_job.rb" => worker + "ExportJob.perform_bulk([[1]])\n")
      data, _, code = json_check(dir, base)
      assert_equal 1, code
      assert_equal ["JC001"], data["findings"].map { |item| item["rule_id"] }
      refute_includes data["findings"].map { |item| item["rule_id"] }, "JC006"
    end
  end

  def test_new_worker_client_hash_partial_certainty_preserves_jc005_and_jc007
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push({"args" => [id], **payload, "class" => ExportJob})
      RUBY

      data, error, code = json_check(dir, base)
      assert_equal 1, code, error
      assert_equal %w[JC005 JC007], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["ExportJob", "ExportJob"], data["findings"].map { |item| item["worker"] }
      assert_equal ["head_to_base"], data["findings"][0]["directions"]
      assert_equal "dynamic_client_args", data["findings"][1]["unknown_reason"]
      assert_equal 1, data["workers"][0]["producer_arities"]["head_unknown_calls"]
    end
  end

  def test_new_worker_client_push_bulk_partial_certainty_preserves_jc005
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push_bulk({"args" => [[id]], **payload, "class" => ExportJob})
      RUBY

      data, error, code = json_check(dir, base)
      assert_equal 1, code, error
      assert_equal %w[JC005 JC007], data["findings"].map { |item| item["rule_id"] }
      assert_equal ["ExportJob", "ExportJob"], data["findings"].map { |item| item["worker"] }
      assert_equal "dynamic_bulk_arguments", data["findings"][1]["unknown_reason"]
    end
  end

  def test_client_hash_unknown_class_does_not_emit_false_jc005
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "class Other; end\n")
      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push({"class" => ExportJob, **payload, "args" => [id]})
      RUBY

      data, error, code = json_check(dir, base)
      assert_equal 0, code, error
      assert_equal ["JC007"], data["findings"].map { |item| item["rule_id"] }
      assert_nil data["findings"][0]["worker"]
      assert_equal "dynamic_client_class", data["findings"][0]["unknown_reason"]
    end
  end

  def test_bulk_output_is_byte_deterministic_with_same_location_facts
    with_repository do |dir|
      source = worker("id, format=nil") + "ExportJob.perform_bulk([[1], [2, 'csv'], row])\n"
      sha = commit(dir, "app/export_job.rb" => source)
      first_json, _, first_status = check(dir, sha, "--head", sha, "--format", "json")
      second_json, _, second_status = check(dir, sha, "--head", sha, "--format", "json")
      first_text, _, text_status = check(dir, sha, "--head", sha)
      second_text, _, repeated_text_status = check(dir, sha, "--head", sha)
      assert_equal 0, first_status.exitstatus
      assert_equal 0, second_status.exitstatus
      assert_equal 0, text_status.exitstatus
      assert_equal 0, repeated_text_status.exitstatus
      assert_equal first_json, second_json
      assert_equal first_text, second_text
      data = JSON.parse(first_json)
      assert_equal [1, 2], data["workers"][0]["producer_arities"]["head"]
      assert data["findings"].all? { |item| item["payload_arity"].nil? || item["payload_arity"].is_a?(Integer) }
    end
  end

  %w[push push_bulk].each do |method|
    define_method("test_#{method}_trailing_dynamic_key_does_not_create_false_jc005") do
      with_repository do |dir|
        base = commit(dir, "app/other.rb" => "# no ExportJob\n")
        args = method == "push" ? "[id]" : "[[id]]"
        commit(dir, "app/export_job.rb" => worker + <<~RUBY)
          Sidekiq::Client.#{method}({"class" => ExportJob, "args" => #{args}, dynamic_key => value})
          Sidekiq::Client.#{method}({"class" => ExportJob, dynamic_key => value, "args" => #{args}})
        RUBY

        data, error, code = json_check(dir, base)
        assert_equal 0, code, error
        assert_equal 2, data["schema_version"]
        refute data["findings"].any? { |item| item["rule_id"] == "JC005" && item["worker"] == "ExportJob" }
        assert_equal %w[JC007 JC007], data["findings"].map { |item| item["rule_id"] }
        assert data["findings"].all? { |item| item["worker"].nil? && item["unknown_reason"] == "unsupported_client_payload" }
        assert_equal "not_checked", data["workers"].fetch(0)["base_presence"]
        assert_equal 0, data["workers"].fetch(0)["producer_arities"]["head_unknown_calls"]
        text, stderr, status = check(dir, base)
        assert_equal 0, status.exitstatus, stderr
        refute_match(/ERROR|JC005/, text)
      end
    end

    define_method("test_#{method}_dynamic_key_before_final_class_retains_positive_jc005") do
      with_repository do |dir|
        base = commit(dir, "app/other.rb" => "# no ExportJob\n")
        args = method == "push" ? "[id]" : "[[id]]"
        commit(dir, "app/export_job.rb" => worker + <<~RUBY)
          Sidekiq::Client.#{method}({"args" => #{args}, dynamic_key => value, "class" => ExportJob})
        RUBY

        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_equal %w[JC005 JC007], data["findings"].map { |item| item["rule_id"] }
        assert_equal ["ExportJob", "ExportJob"], data["findings"].map { |item| item["worker"] }
        assert_equal "unsupported_client_payload", data["findings"].fetch(1)["unknown_reason"]
        assert_equal "absent", data["workers"].fetch(0)["base_presence"]
        assert_equal 1, data["workers"].fetch(0)["producer_arities"]["head_unknown_calls"]
        text, stderr, status = check(dir, base)
        assert_equal 1, status.exitstatus, stderr
        assert_match(/ERROR JC005 ExportJob/, text)
      end
    end
  end

  def test_dynamic_key_partial_certainty_keeps_exact_strings_and_lexical_constants
    ['"ExportJob"', '"Admin::ExportJob"', 'ExportJob'].each do |class_value|
      with_repository do |dir|
        base = commit(dir, "app/other.rb" => "# no workers\n")
        commit(dir, "app/export_job.rb" => worker + <<~RUBY)
          module Admin
            class ExportJob
              include Sidekiq::Job
              def perform(id); end
            end
            Sidekiq::Client.push({"args" => [id], dynamic_key => value, "class" => #{class_value}})
          end
        RUBY

        data, error, code = json_check(dir, base)
        expected = class_value == '"ExportJob"' ? "ExportJob" : "Admin::ExportJob"
        assert_equal 1, code, error
        assert_equal %w[JC005 JC007], data["findings"].map { |item| item["rule_id"] }
        assert_equal [expected, expected], data["findings"].map { |item| item["worker"] }
        assert_equal "unsupported_client_payload", data["findings"].fetch(1)["unknown_reason"]
      end
    end
  end

  def test_ordered_client_hash_outputs_are_byte_deterministic
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "# no ExportJob\n")
      commit(dir, "app/export_job.rb" => worker + <<~RUBY)
        Sidekiq::Client.push({dynamic_key => value, "class" => OldJob, "class" => ExportJob, "args" => [id]})
        Sidekiq::Client.push({"class" => ExportJob, "args" => [id], dynamic_key => value})
        Sidekiq::Client.push({"class" => ExportJob, dynamic_key => value, "args" => [id]})
        Sidekiq::Client.push({"args" => [id], dynamic_key => value, "class" => "ExportJob"})
        Sidekiq::Client.push_bulk({**a, "class" => ExportJob, dynamic_key => value, "args" => [[id]]})
        Sidekiq::Client.push_bulk({dynamic_key => value, "args" => [[id]], **b, "class" => ExportJob})
        Sidekiq::Client.push({**a, "class" => OldJob, **b, "class" => ExportJob, "args" => [id]})
      RUBY

      %w[text json].each do |format|
        outputs = Array.new(3) do
          stdout, stderr, status = check(dir, base, "--format", format)
          assert_equal 1, status.exitstatus, stderr
          stdout
        end
        assert_equal outputs.first, outputs[1]
        assert_equal outputs.first, outputs[2]
      end
    end
  end

  %w[push push_bulk].each do |method|
    define_method("test_#{method}_unicode_string_worker_mismatch_uses_exact_names") do
      with_repository do |dir|
        name = "A\u0301Job"
        source = <<~RUBY
          class #{name}; include Sidekiq::Job; def perform(id); end; end
          class ÁJob; include Sidekiq::Job; def perform(id, format); end; end
          module Admin
            class #{name}; include Sidekiq::Job; def perform(id); end; end
          end
          module Outer
            class #{name}; include Sidekiq::Job; def perform(id, format); end; end
          end
        RUBY
        base = commit(dir, "app/jobs.rb" => source)
        args = method == "push" ? "[1, 2]" : "[[1, 2]]"
        commit(dir, "app/jobs.rb" => source + <<~RUBY)
          module Outer
            Sidekiq::Client.#{method}("class" => #{name.dump}, "args" => #{args})
            Sidekiq::Client.#{method}("class" => "Admin::#{name}", "args" => #{args})
            Sidekiq::Client.#{method}("class" => "ÁJob", "args" => #{args})
          end
        RUBY

        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_empty error
        assert_equal %w[JC003 JC003], data["findings"].map { |item| item["rule_id"] }
        assert_equal [name, "Admin::#{name}"].sort, data["findings"].map { |item| item["worker"] }.sort
        assert data["findings"].all? { |item| item["payload_arity"] == 2 && item["unknown_reason"].nil? }
        workers = data["workers"].to_h { |item| [item["name"], item] }
        assert_equal [], workers.fetch("Outer::#{name}")["producer_arities"]["head"]
        assert_equal "pass", workers.fetch("ÁJob")["compatibility"]["head_to_head"]
        %w[text json].each do |format|
          outputs = Array.new(3) do
            stdout, stderr, status = check(dir, base, "--format", format)
            assert_equal 1, status.exitstatus, stderr
            stdout
          end
          assert_equal 1, outputs.uniq.length
        end
      end
    end

    define_method("test_#{method}_invalid_string_workers_warn_without_crashing") do
      with_repository do |dir|
        base = commit(dir, "app/jobs.rb" => worker)
        args = method == "push" ? "[]" : "[[]]"
        values = ['"\\xFF"', '""', '"exportJob"', '"ExportJob; OtherJob"', '"ExportJob # comment"', '" ExportJob"']
        calls = values.map { |value| "Sidekiq::Client.#{method}(\"class\" => #{value}, \"args\" => #{args})\n" }.join
        commit(dir, "app/jobs.rb" => worker + calls)

        data, error, code = json_check(dir, base)
        assert_equal 0, code, error
        assert_empty error
        assert_equal "completed", data["status"]
        assert_empty data["diagnostics"]
        assert_equal values.length, data["findings"].length
        assert(data["findings"].all? do |item|
          item["rule_id"] == "JC007" && item["worker"].nil? && item["unknown_reason"] == "unsupported_client_payload"
        end)
        %w[text json].each do |format|
          outputs = Array.new(3) do
            stdout, stderr, status = check(dir, base, "--format", format)
            assert_equal 0, status.exitstatus, stderr
            assert_empty stderr
            stdout
          end
          assert_equal 1, outputs.uniq.length
        end

        commit(dir, "app/jobs.rb" => worker + calls + "ExportJob.perform_async(1, 2)\n")
        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_empty error
        assert_equal "JC003", data["findings"].first["rule_id"]
        assert_equal values.length, data["findings"].count { |item| item["rule_id"] == "JC007" }
      end
    end

    define_method("test_#{method}_unicode_string_workers_use_existing_rolling_rules") do
      with_repository do |dir|
        name = "A\u0301Job"
        source = "class #{name}; include Sidekiq::Job; def perform(id); end; end\n"
        one_arg = method == "push" ? "[1]" : "[[1]]"
        two_args = method == "push" ? "[1, 2]" : "[[1, 2]]"
        call = "Sidekiq::Client.#{method}(\"class\" => #{name.dump}, \"args\" => #{one_arg})\n"
        base = commit(dir, "app/job.rb" => source + call)
        commit(dir, "app/job.rb" => source.sub("perform(id)", "perform(id, format)") + call)
        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_equal ["JC001"], data["findings"].map { |item| item["rule_id"] }
        assert_equal name, data["findings"].first["worker"]
        assert_equal %w[base_to_head head_to_head], data["findings"].first["directions"]

        commit(dir, "app/job.rb" => source.sub("perform(id)", "perform(id, format=nil)") +
               "Sidekiq::Client.#{method}(\"class\" => #{name.dump}, \"args\" => #{two_args})\n")
        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_equal ["JC002"], data["findings"].map { |item| item["rule_id"] }
        assert_equal name, data["findings"].first["worker"]
        assert_equal ["head_to_base"], data["findings"].first["directions"]
      end
    end
  end

  def test_new_unicode_string_worker_can_request_base_presence_and_emit_jc005
    with_repository do |dir|
      base = commit(dir, "app/other.rb" => "# no workers\n")
      name = "A\u0301Job"
      %w[push push_bulk].each do |method|
        args = method == "push" ? "[1]" : "[[1]]"
        commit(dir, "app/job.rb" => <<~RUBY)
          class #{name}; include Sidekiq::Job; def perform(id); end; end
          Sidekiq::Client.#{method}("class" => #{name.dump}, "args" => #{args})
        RUBY
        data, error, code = json_check(dir, base)
        assert_equal 1, code, error
        assert_equal ["JC005"], data["findings"].map { |item| item["rule_id"] }
        assert_equal name, data["findings"].first["worker"]
        assert_equal "absent", data["workers"].first["base_presence"]
      end
    end
  end
end
