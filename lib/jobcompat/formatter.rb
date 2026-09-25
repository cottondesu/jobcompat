require "json"

module Jobcompat
  module Formatter
    def self.json(envelope)
      JSON.pretty_generate(primitive(envelope)) + "\n"
    end

    def self.primitive(value)
      case value
      when Array then value.map { |item| primitive(item) }
      when Hash then value.transform_values { |item| primitive(item) }
      when Location then value.as_json
      else value
      end
    end

    def self.text(envelope)
      return envelope[:diagnostics].map { |item| safe_line("#{item[:category]}: #{item[:message]}") }.join("\n") + "\n" if envelope[:status] == "failed"
      base = envelope[:comparison][:base]
      head = envelope[:comparison][:head]
      summary = envelope[:summary]
      lines = ["jobcompat #{VERSION}", "Comparing #{base[:ref]} (#{base[:sha][0, 7]}) -> #{head[:ref]} (#{head[:sha][0, 7]})", "Deployment model: rolling", ""]
      if envelope[:findings].empty?
        lines << (summary[:warnings].positive? ? "PASS WITH WARNINGS" : "PASS: no compatibility errors or warnings found.")
      else
        envelope[:findings].each do |finding|
          lines << "#{finding[:severity].upcase} #{finding[:rule_id]} #{finding[:worker] || '(unknown worker)'}"
          lines << "  #{finding[:message]}"
          lines << "  Revisions: #{finding[:revisions].join(', ')}"
          lines << "  Reason: #{finding[:unknown_reason]}" if finding[:unknown_reason]
          lines << "  Affected directions:"
          finding[:directions].each { |direction| lines << "    #{direction_label(direction)}" }
          lines << "  Risk: #{finding[:risk]}"
          finding[:locations].each do |location|
            lines << "  #{location.revision} #{location.path}:#{location.line}:#{location.column} (#{location.role})"
          end
          lines << "  Suggested migration:"
          finding[:remediation].each_with_index { |step, index| lines << "    #{index + 1}. #{step}" }
          lines << ""
        end
        lines << "PASS WITH WARNINGS" if summary[:errors].zero?
      end
      unless envelope[:suppressions].empty?
        lines << "Suppressed findings:"
        envelope[:suppressions].each { |item| lines << "  #{item[:rule_id]} #{item[:worker]} (#{item[:finding_count]}): #{item[:reason]}" }
        lines << ""
      end
      lines << "Summary: #{summary[:errors]} #{summary[:errors] == 1 ? 'error' : 'errors'}, #{summary[:warnings]} #{summary[:warnings] == 1 ? 'warning' : 'warnings'}, #{summary[:suppressed]} suppressed"
      lines.map { |line| safe_line(line) }.join("\n") + "\n"
    end

    def self.safe_line(line)
      line.to_s.gsub(/[[:cntrl:]\p{Cf}]/) do |character|
        character.ord <= 0xFF ? format("\\x%02X", character.ord) : format("\\u{%04X}", character.ord)
      end
    end

    def self.direction_label(value)
      {"base_to_head" => "base producer -> HEAD consumer", "head_to_base" => "HEAD producer -> base consumer",
       "head_to_head" => "HEAD producer -> HEAD consumer"}.fetch(value)
    end
  end
end
