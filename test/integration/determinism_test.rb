require_relative "../test_helper"
require_relative "../support/temporary_repository"

class DeterminismTest < Minitest::Test
  include TemporaryRepository

  def test_repeated_json_bytes_and_sorted_evidence
    with_repository do |dir|
      base = commit(dir, "app/z_job.rb" => "class ZJob; include Sidekiq::Job; def perform(id); end; end\nZJob.perform_async(1)\n",
                         "app/a_job.rb" => "class AJob; include Sidekiq::Job; def perform(id); end; end\nAJob.perform_async(1)\n")
      commit(dir, "app/z_job.rb" => "class ZJob; include Sidekiq::Job; def perform(id, x); end; end\nZJob.perform_async(1)\n",
                  "app/a_job.rb" => "class AJob; include Sidekiq::Job; def perform(id, x); end; end\nAJob.perform_async(1)\n")
      first, _, first_status = check(dir, base, "--format", "json")
      second, _, second_status = check(dir, base, "--format", "json")
      assert_equal 1, first_status.exitstatus
      assert_equal 1, second_status.exitstatus
      assert_equal first, second
      assert first.end_with?("\n")
      refute first.end_with?("\n\n")
      data = JSON.parse(first)
      assert_equal %w[AJob ZJob], data["workers"].map { |item| item["name"] }
      assert_equal %w[AJob ZJob], data["findings"].map { |item| item["worker"] }
      assert_equal data["findings"].count { |item| item["severity"] == "error" }, data["summary"]["errors"]
      text_first, text_error, text_status = check(dir, base)
      text_second, _, repeated_status = check(dir, base)
      assert_equal 1, text_status.exitstatus, text_error
      assert_equal 1, repeated_status.exitstatus
      assert_equal text_first, text_second
    end
  end
end
