module Jobcompat
  ConstantBinding = Data.define(:name, :kind, :location, :fingerprint_parts)
  AliasCandidate = Data.define(:name, :reference, :root, :namespace, :supported, :location, :fingerprint_parts)
  AliasResolution = Data.define(:name, :status, :target, :chain, :unknown_reason, :locations, :fingerprint_parts, :static_reference) do
    def resolved? = status == "resolved"
    def as_json
      {status: status, target: target, chain: chain, unknown_reason: unknown_reason}
    end
  end

  module ConstantLookup
    def self.candidates(reference, root, namespace)
      return [reference] if root
      return [] if namespace.nil?
      (namespace.reverse.map { |prefix| "#{prefix}::#{reference}" } + [reference]).uniq
    end
  end

  class AliasResolver
    def initialize(workers, bindings, candidates, ambiguous_bindings = [])
      @workers = workers
      @bindings = bindings.group_by(&:name)
      @candidates = candidates.group_by(&:name)
      @ambiguous_bindings = ambiguous_bindings.group_by(&:name)
    end

    def resolve
      @candidates.keys.sort.to_h { |name| [name, resolve_identity(name)] }.freeze
    end

    private

    def resolve_identity(name)
      chain, locations, parts, visited = [], [], [], {}
      current = name
      reason = nil
      loop do
        chain << current
        if visited[current]
          reason = "alias_cycle"
          break
        end
        visited[current] = true
        candidates = @candidates.fetch(current, [])
        bindings = @bindings.fetch(current, []).sort_by { |item| [item.location.path, item.location.line, item.location.column] }
        ambiguous = @ambiguous_bindings.fetch(current.split("::").last, []).reject { |item| bindings.any? { |binding| binding.location == item.location } }
        if candidates.empty? && @workers.key?(current) && ambiguous.empty?
          return resolution(name, current, chain, nil, locations, parts)
        end
        locations.concat((bindings + ambiguous).map(&:location))
        parts << [current, (bindings + ambiguous).map(&:fingerprint_parts).sort_by(&:inspect)]
        unless ambiguous.empty?
          reason = "alias_binding_conflict"
          break
        end
        if candidates.empty?
          reason = "alias_target_unresolved"
          break
        end
        if bindings.length != 1
          reason = "alias_binding_conflict"
          break
        end
        candidate = candidates.first
        unless candidate.supported
          reason = "unsupported_alias_assignment"
          break
        end
        lookup = ConstantLookup.candidates(candidate.reference, candidate.root, candidate.namespace)
        target = lookup.find { |identity| @bindings.key?(identity) || @workers.key?(identity) }
        unless target
          chain << lookup.first
          reason = "alias_target_unresolved"
          break
        end
        current = target
      end
      resolution(name, nil, chain, reason, locations, parts)
    end

    def resolution(name, target, chain, reason, locations, parts)
      AliasResolution.new(name, reason ? "unknown" : "resolved", target, chain.freeze, reason,
                          locations.uniq.freeze, parts.freeze, @candidates.fetch(name).any? { |candidate| candidate.reference })
    end
  end
end
