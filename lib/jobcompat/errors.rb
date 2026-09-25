module Jobcompat
  class Error < StandardError
    attr_reader :category, :location, :diagnostics

    def initialize(message, category:, location: nil, diagnostics: nil)
      super(message)
      @category = category
      @location = location
      @diagnostics = diagnostics
    end
  end
end
