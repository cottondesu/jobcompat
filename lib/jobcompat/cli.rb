require "optparse"

module Jobcompat
  class CLI
    def self.start(args, stdout: $stdout, stderr: $stderr, directory: Dir.pwd)
      new(args, stdout, stderr, directory).run
    end

    def initialize(args, stdout, stderr, directory)
      @args, @stdout, @stderr, @directory = args.dup, stdout, stderr, directory
      @base, @head, @format, @config_path = nil, "HEAD", "text", nil
      @base_sha = @head_sha = @loaded_config = nil
    end

    def run
      return help if @args.empty? || %w[-h --help].include?(@args.first)
      return version if @args == ["--version"]
      raise Error.new("Unknown command: #{@args.first}", category: "config_error") unless @args.shift == "check"
      parser = OptionParser.new do |options|
        options.banner = "Usage: jobcompat check --base REF [options]"
        options.on("--base REF", "Base commit-ish (required)") { |value| @base = value }
        options.on("--head REF", "Head commit-ish (default HEAD)") { |value| @head = value }
        options.on("--format FORMAT", "text or json") { |value| @format = value }
        options.on("--config PATH", "Config YAML path") { |value| @config_path = value }
        options.on("-h", "--help", "Show help") { @stdout.puts(options); return 0 }
      end
      parser.parse!(@args)
      raise Error.new("Unexpected arguments: #{@args.join(' ')}", category: "config_error") unless @args.empty?
      raise Error.new("--base is required", category: "config_error") unless @base && !@base.empty?
      raise Error.new("--format must be text or json", category: "config_error") unless %w[text json].include?(@format)
      repository = GitRepository.new(@directory)
      config = Config.load(root: repository.root, explicit: @config_path, invocation_dir: @directory)
      @loaded_config = config.display_path
      @base_sha = repository.resolve(@base, "base")
      @head_sha = repository.resolve(@head, "head")
      builder = SnapshotBuilder.new(repository, config)
      snapshots = {}
      parse_diagnostics = []
      [["base", @base, @base_sha], ["head", @head, @head_sha]].each do |label, ref, sha|
        begin
          snapshots[label] = builder.build(label, ref, sha)
        rescue Error => error
          raise unless error.category == "parse_error"
          parse_diagnostics.concat(error.diagnostics || [{category: error.category, message: error.message, location: error.location}])
        end
      end
      unless parse_diagnostics.empty?
        parse_diagnostics.sort_by! do |item|
          location = item[:location] || {}
          [location.fetch(:revision, ""), location.fetch(:path, ""), location.fetch(:line, 0), location.fetch(:column, 0), item[:message]]
        end
        raise Error.new(parse_diagnostics.first[:message], category: "parse_error", location: parse_diagnostics.first[:location], diagnostics: parse_diagnostics)
      end
      base = snapshots.fetch("base")
      head = snapshots.fetch("head")
      engine = Engine.new(base, head)
      requests = engine.presence_requests
      head.check_presence(requests["head"], repository, config)
      base.check_presence(requests["base"], repository, config)
      result = engine.evaluate
      findings, suppressions = config.suppressions(result[:findings])
      summary = {
        errors: findings.count { |item| item[:severity] == "error" }, warnings: findings.count { |item| item[:severity] == "warning" },
        suppressed: suppressions.sum { |item| item[:finding_count] },
        files_scanned: {base: base.files_scanned, head: head.files_scanned},
        workers: {base: base.workers.length, head: head.workers.length},
        enqueue_calls: {base: base.calls.length, head: head.calls.length,
                        unknown: engine.calls.values.flatten.count { |call| call[:reason] }}
      }
      @stdout.write(Formatter.public_send(@format, envelope("completed", findings, suppressions, result[:workers], [], summary)))
      summary[:errors].positive? ? 1 : 0
    rescue OptionParser::ParseError => error
      failure(Error.new(error.message, category: "config_error"))
    rescue Error => error
      failure(error)
    rescue StandardError => error
      @stderr.puts(Formatter.safe_line("#{error.class}: #{error.message}"))
      failure(Error.new("Internal analysis error.", category: "internal_error"))
    end

    private

    def help
      @stdout.puts("jobcompat #{VERSION}\nUsage: jobcompat check --base REF [options]\n       jobcompat --help\n       jobcompat --version")
      0
    end

    def version
      @stdout.puts("jobcompat #{VERSION}")
      0
    end

    def failure(error)
      diagnostics = error.diagnostics || [{category: error.category, message: error.message, location: error.location}]
      output = Formatter.public_send(@format == "json" ? :json : :text, envelope("failed", [], [], [], diagnostics, nil))
      (@format == "json" ? @stdout : @stderr).write(output)
      2
    end

    def envelope(status, findings, suppressions, workers, diagnostics, summary)
      {schema_version: 1, tool: {name: "jobcompat", version: VERSION}, status: status,
       comparison: {deployment_model: "rolling", base: {ref: @base, sha: @base_sha}, head: {ref: @head, sha: @head_sha}},
       configuration: {path: @loaded_config}, findings: findings, suppressions: suppressions, workers: workers,
       diagnostics: diagnostics, summary: summary}
    end
  end
end
