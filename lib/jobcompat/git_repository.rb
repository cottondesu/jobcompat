require "open3"

module Jobcompat
  TreeEntry = Data.define(:path, :oid, :size)

  class GitRepository
    GIT_ENV = {"GIT_OPTIONAL_LOCKS" => "0", "GIT_NO_LAZY_FETCH" => "1"}.freeze
    attr_reader :root

    def initialize(directory)
      output, _error, status = Open3.capture3(GIT_ENV, "git", "rev-parse", "--show-toplevel", chdir: directory)
      raise Error.new("Not inside a Git repository.", category: "git_error") unless status.success?
      @root = output.delete_suffix("\n")
    end

    def resolve(ref, label)
      output, status = command("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}")
      raise Error.new("#{label.capitalize} ref '#{ref}' does not resolve to a commit.", category: "git_error") unless status.success? && output.strip.match?(/\A[0-9a-f]{40,64}\z/)
      output.strip
    end

    def entries(sha)
      output, status = command("ls-tree", "-r", "-l", "-z", "--full-tree", sha)
      raise Error.new("Could not read Git tree #{sha}.", category: "git_error") unless status.success?
      output.split("\0").filter_map do |record|
        metadata, path = record.split("\t", 2)
        next unless path
        mode, type, oid, size = metadata.split(" ")
        next unless %w[100644 100755].include?(mode) && type == "blob"
        raise Error.new("Git tree contains an unavailable blob.", category: "git_error") unless size&.match?(/\A\d+\z/)
        TreeEntry.new(path, oid, Integer(size))
      end.sort_by(&:path)
    end

    def read_blobs(entries)
      result = {}
      each_blob(entries) { |entry, data| result[entry.path] = data }
      result
    end

    def each_blob(entries)
      return if entries.empty?
      Open3.popen3(GIT_ENV, "git", "cat-file", "--batch", chdir: root) do |input, output, error, wait|
        error_reader = Thread.new do
          error.read
        rescue IOError
          ""
        end
        begin
          entries.each do |entry|
            input.write("#{entry.oid}\n")
            input.flush
            header = output.gets
            match = header&.match(/\A([0-9a-f]{40,64}) blob (\d+)\n\z/)
            raise Error.new("Invalid Git blob response.", category: "git_error") unless match && match[1] == entry.oid
            data = output.read(match[2].to_i)
            delimiter = output.read(1)
            raise Error.new("Incomplete Git blob response.", category: "git_error") unless data&.bytesize == match[2].to_i && delimiter == "\n"
            break if yield(entry, data) == :stop
          end
        ensure
          input.close unless input.closed?
        end
        error_reader.value
        raise Error.new("Git blob reader failed.", category: "git_error") unless wait.value.success?
      end
    rescue IOError, Errno::EPIPE
      raise Error.new("Git blob reader failed.", category: "git_error")
    end

    private

    def command(*args)
      output, _error, status = Open3.capture3(GIT_ENV, "git", *args, chdir: root)
      [output, status]
    end
  end
end
