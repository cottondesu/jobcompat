require "prism"

module Jobcompat
  # Internal: the single authority for canonical String worker names, shared by
  # producer analysis (Client String "class" values) and Config (ignore[].worker).
  # Prism decides what a Ruby constant path is; no handwritten identifier grammar.
  module CanonicalWorkerName
    # Returns the canonical UTF-8 name when value is exactly one complete,
    # non-root-qualified static constant path, or nil otherwise. The input is
    # never trimmed or Unicode-normalized.
    def self.parse(value)
      return unless value.is_a?(String)
      name = value.encode(Encoding::UTF_8)
      return unless name.valid_encoding?
      result = Prism.parse(name)
      return unless result.errors.empty? && result.value.statements.body.one?
      segments = segments(result.value.statements.body.first)
      return unless segments
      canonical = segments.join("::")
      canonical if canonical == name
    rescue EncodingError
      nil
    end

    def self.segments(node)
      case node
      when Prism::ConstantReadNode then [node.name.to_s.encode(Encoding::UTF_8)]
      when Prism::ConstantPathNode
        parent = node.parent && segments(node.parent)
        parent && parent + [node.name.to_s.encode(Encoding::UTF_8)]
      end
    end
    private_class_method :segments
  end
end
