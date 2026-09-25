require_relative "../test_helper"
require_relative "../support/temporary_repository"
require "timeout"

class GitRepositoryTest < Minitest::Test
  include TemporaryRepository

  def test_committed_snapshots_and_unusual_paths_without_mutation
    with_repository do |dir|
      base = commit(dir, "root.rb" => "base\n", "space name.rb" => "space\n", "tab\tname.rb" => "tab\n",
                         "line\nname.rb" => "line\n", "日本語.rb" => "unicode\n")
      head = commit(dir, "root.rb" => "head\n", "added.rb" => "added\n", "space name.rb" => nil)
      File.write(File.join(dir, "root.rb"), "dirty\n")
      File.write(File.join(dir, "untracked.rb"), "untracked\n")
      before = git(dir, "status", "--porcelain")
      repository = Jobcompat::GitRepository.new(dir)
      assert_equal base, repository.resolve(base, "base")
      assert_equal head, repository.resolve("HEAD", "head")
      base_entries = repository.entries(base)
      assert_includes base_entries.map(&:path), "space name.rb"
      assert_includes base_entries.map(&:path), "tab\tname.rb"
      assert_includes base_entries.map(&:path), "line\nname.rb"
      assert_includes base_entries.map(&:path), "日本語.rb"
      assert_equal "base\n", repository.read_blobs(base_entries).fetch("root.rb")
      assert_equal "head\n", repository.read_blobs(repository.entries(head)).fetch("root.rb")
      assert_equal before, git(dir, "status", "--porcelain")
      assert_equal "dirty\n", File.read(File.join(dir, "root.rb"))
    end
  end

  def test_invalid_ref_and_symlink_exclusion
    with_repository do |dir|
      commit(dir, "a.rb" => "class A; end\n")
      File.symlink("a.rb", File.join(dir, "link.rb"))
      git(dir, "add", "link.rb")
      git(dir, "commit", "-qm", "symlink")
      repository = Jobcompat::GitRepository.new(dir)
      refute_includes repository.entries(repository.resolve("HEAD", "head")).map(&:path), "link.rb"
      assert_raises(Jobcompat::Error) { repository.resolve("--exec=anything", "base") }
    end
  end

  def test_git_root_preserves_trailing_space
    Dir.mktmpdir("jobcompat-parent-") do |parent|
      directory = File.join(parent, "repo ")
      FileUtils.mkdir_p(directory)
      git(directory, "init", "-q")
      git(directory, "config", "user.name", "Test")
      git(directory, "config", "user.email", "test@example.com")
      sha = commit(directory, "app/job.rb" => "class Job; end\n")
      repository = Jobcompat::GitRepository.new(directory)
      assert_equal File.realpath(directory), repository.root
      assert_equal ["app/job.rb"], repository.entries(sha).map(&:path)
    end
  end

  def test_git_stderr_does_not_corrupt_protocol_output
    with_repository do |dir|
      sha = commit(dir, "app/job.rb" => "class Job; end\n")
      root = File.expand_path("../..", __dir__)
      output, error, status = Open3.capture3({"GIT_TRACE" => "1"}, RbConfig.ruby, "-I#{File.join(root, 'lib')}",
                                             File.join(root, "exe/jobcompat"), "check", "--base", sha, "--format", "json", chdir: dir)
      assert_equal 0, status.exitstatus, error
      assert_empty error
      assert_equal "completed", JSON.parse(output).fetch("status")
    end
  end

  def test_partial_clone_does_not_fetch_missing_blobs
    Dir.mktmpdir("jobcompat-promisor-") do |parent|
      source = File.join(parent, "source")
      clone = File.join(parent, "clone")
      FileUtils.mkdir_p(source)
      git(source, "init", "-q")
      git(source, "config", "user.name", "Test")
      git(source, "config", "user.email", "test@example.com")
      git(source, "config", "uploadpack.allowFilter", "true")
      commit(source, "app/job.rb" => "class Job; end\n")
      output, status = Open3.capture2e("git", "clone", "-q", "--filter=blob:none", "--no-checkout", "file://#{source}", clone)
      assert status.success?, output
      trace = File.join(parent, "git-trace")
      root = File.expand_path("../..", __dir__)
      result, _error, exit_status = Open3.capture3({"GIT_TRACE" => trace}, RbConfig.ruby, "-I#{File.join(root, 'lib')}",
                                                   File.join(root, "exe/jobcompat"), "check", "--base", "HEAD", "--format", "json", chdir: clone)
      assert_equal 2, exit_status.exitstatus
      assert_equal "git_error", JSON.parse(result).fetch("diagnostics").first.fetch("category")
      refute_match(/fetch origin|upload-pack/, File.read(trace))
    end
  end

  def test_batch_reader_can_stop_after_first_blob
    with_repository do |dir|
      sha = commit(dir, "a.rb" => "a\n", "b.rb" => "b\n")
      repository = Jobcompat::GitRepository.new(dir)
      yielded = []
      repository.each_blob(repository.entries(sha)) do |entry, _bytes|
        yielded << entry.path
        :stop
      end
      assert_equal ["a.rb"], yielded
    end
  end

  def test_batch_reader_closes_input_when_consumer_raises
    with_repository do |dir|
      sha = commit(dir, "a.rb" => "a\n")
      repository = Jobcompat::GitRepository.new(dir)
      _stdout, stderr = capture_io do
        error = assert_raises(RuntimeError) do
          Timeout.timeout(5) do
            repository.each_blob(repository.entries(sha)) { raise "consumer failed" }
          end
        end
        assert_equal "consumer failed", error.message
      end
      assert_empty stderr
    end
  end
end
