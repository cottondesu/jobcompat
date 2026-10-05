module SourceSnapshot
  Entry = Data.define(:path, :size)
  SourceRepository = Data.define(:sources) do
    def entries(_sha)
      sources.map { |path, source| Entry.new(path, source.bytesize) }
    end

    def each_blob(entries)
      entries.each do |entry|
        break if yield(entry, sources.fetch(entry.path)) == :stop
      end
    end
  end

  def source_snapshot(source, label = "head")
    sources = source.is_a?(Hash) ? source : {"app/jobs.rb" => source}
    config = Jobcompat::Config.new(Jobcompat::Config::DEFAULT_INCLUDE, Jobcompat::Config::DEFAULT_EXCLUDE, [], nil)
    Jobcompat::SnapshotBuilder.new(SourceRepository.new(sources), config).build(label, label, label)
  end

  def direct_job(name = "NewJob", signature = "id")
    "class #{name}; include Sidekiq::Job; def perform(#{signature}); end; end\n"
  end
end
