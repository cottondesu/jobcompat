require "psych"

module Jobcompat
  class Config
    DEFAULT_INCLUDE = ["**/*.rb"].freeze
    DEFAULT_EXCLUDE = %w[vendor/** tmp/** log/** coverage/** .bundle/** test/** spec/** features/** examples/**].freeze
    RULES = (1..7).map { |number| format("JC%03d", number) }.freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

    attr_reader :include_patterns, :exclude_patterns, :ignore, :display_path

    def self.load(root:, explicit: nil, invocation_dir: Dir.pwd)
      path = explicit ? File.expand_path(explicit, invocation_dir) : File.join(root, ".jobcompat.yml")
      unless File.file?(path)
        raise Error.new("Config file is not a readable file: #{path}", category: "config_error") if explicit || File.exist?(path) || File.symlink?(path)
        return new(DEFAULT_INCLUDE, DEFAULT_EXCLUDE, [], nil)
      end

      document = Psych.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
      validate(document, path == File.join(root, ".jobcompat.yml") ? ".jobcompat.yml" : path)
    rescue Psych::Exception, EncodingError, SystemCallError => e
      raise Error.new("Invalid config: #{e.message}", category: "config_error")
    end

    def self.validate(data, display_path)
      fields!(data, %w[version scan ignore], "config")
      raise Error.new("version must be integer 1", category: "config_error") unless data["version"] == 1 && data["version"].instance_of?(Integer)
      scan = data.fetch("scan", {})
      fields!(scan, %w[include exclude], "scan")
      includes = patterns!(scan.fetch("include", DEFAULT_INCLUDE), "scan.include", empty: false)
      excludes = patterns!(scan.fetch("exclude", DEFAULT_EXCLUDE), "scan.exclude", empty: true)
      ignores = data.fetch("ignore", [])
      raise Error.new("ignore must be an array", category: "config_error") unless ignores.is_a?(Array)
      seen = {}
      ignores.each_with_index do |item, index|
        fields!(item, %w[rule worker reason], "ignore[#{index}]")
        raise Error.new("ignore[#{index}] must have rule, worker, reason", category: "config_error") unless item.keys.sort == %w[reason rule worker]
        raise Error.new("ignore[#{index}].rule is invalid", category: "config_error") unless RULES.include?(item["rule"])
        worker = item["worker"]
        valid_worker = worker.is_a?(String) && !worker.empty? && !worker.start_with?("::") && worker.split("::", -1).all? do |segment|
          first = segment.each_char.first
          first && (first.match?(/[A-Z]/) || (first.ord > 127 && first.match?(/\p{L}/))) && segment.match?(/\A[\p{Alnum}_]+\z/)
        end
        raise Error.new("ignore[#{index}].worker is invalid", category: "config_error") unless valid_worker
        raise Error.new("ignore[#{index}].reason must be non-blank", category: "config_error") unless item["reason"].is_a?(String) && !item["reason"].strip.empty?
        key = [item["rule"], item["worker"]]
        raise Error.new("duplicate ignore for #{key.join(' ')}", category: "config_error") if seen[key]
        seen[key] = true
      end
      new(includes, excludes, ignores, display_path)
    end

    def self.fields!(value, allowed, label)
      raise Error.new("#{label} must be a mapping", category: "config_error") unless value.is_a?(Hash)
      unknown = value.keys - allowed
      raise Error.new("#{label} has unknown keys: #{unknown.join(', ')}", category: "config_error") unless unknown.empty?
    end

    def self.patterns!(value, label, empty:)
      raise Error.new("#{label} must be #{empty ? 'an array' : 'a non-empty array'}", category: "config_error") unless value.is_a?(Array) && (empty || !value.empty?)
      value.each_with_index do |glob, index|
        valid = glob.is_a?(String) && !glob.empty? && !glob.start_with?("/") && !glob.include?("\0") && !glob.split("/").include?("..")
        raise Error.new("#{label}[#{index}] is not a repository-relative glob", category: "config_error") unless valid
      end
      value
    end

    def initialize(includes, excludes, ignore, display_path)
      @include_patterns, @exclude_patterns, @ignore, @display_path = includes.freeze, excludes.freeze, ignore.freeze, display_path
    end

    def scan?(path)
      include_patterns.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) } &&
        exclude_patterns.none? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }
    end

    def suppressions(findings)
      matched = []
      remaining = findings.reject do |finding|
        entry = ignore.find { |item| item["rule"] == finding[:rule_id] && item["worker"] == finding[:worker] }
        next false unless entry
        record = matched.find { |item| item[:rule_id] == entry["rule"] && item[:worker] == entry["worker"] }
        record ? record[:finding_count] += 1 : matched << {rule_id: entry["rule"], worker: entry["worker"], reason: entry["reason"], finding_count: 1}
        true
      end
      [remaining, matched.sort_by { |item| [item[:rule_id], item[:worker]] }]
    end
  end
end
