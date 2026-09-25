module TemporaryRepository
  def with_repository
    Dir.mktmpdir("jobcompat-test-") do |directory|
      git(directory, "init", "-q")
      git(directory, "config", "user.name", "Test")
      git(directory, "config", "user.email", "test@example.com")
      yield directory
    end
  end

  def git(directory, *args)
    output, status = Open3.capture2e("git", "-C", directory, *args)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?
    output.strip
  end

  def commit(directory, files)
    files.each do |path, content|
      target = File.join(directory, path)
      if content.nil?
        FileUtils.rm_f(target)
      else
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, content)
      end
    end
    git(directory, "add", "-A")
    git(directory, "commit", "-qm", "fixture")
    git(directory, "rev-parse", "HEAD")
  end

  def check(directory, base, *options)
    root = File.expand_path("../..", __dir__)
    Open3.capture3(RbConfig.ruby, "-I#{File.join(root, 'lib')}", File.join(root, "exe/jobcompat"), "check", "--base", base, *options, chdir: directory)
  end

  def json_check(directory, base, *options)
    stdout, stderr, status = check(directory, base, "--format", "json", *options)
    [JSON.parse(stdout), stderr, status.exitstatus]
  end

  def worker(signature = "id", include_module: "Sidekiq::Job")
    "class ExportJob\n  include #{include_module}\n  def perform(#{signature}); end\nend\n"
  end
end
