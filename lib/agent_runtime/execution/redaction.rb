require "json"

module AgentRuntime
  module Execution
    # Explicitly lossy persistence boundary. Never mutates the source evidence.
    # Not a universal secret detector: callers must supply known secret values.
    module Redaction
      SENSITIVE_KEY = /token|secret|password|credential|authorization|api.?key/i
      REPLACEMENT = "[REDACTED]"

      def self.redact(value, secrets: [])
        literals = secrets.select { |secret| secret.is_a?(String) && !secret.empty? && secret != REPLACEMENT }.uniq.sort_by { |secret| -secret.length }
        transform(value, literals)
      end

      def self.transform(value, secrets)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            safe_key = key.is_a?(String) ? replace_literals(key, secrets) : key
            sensitive = SENSITIVE_KEY.match?(key.to_s) && !safe_accounting?(key.to_s, item)
            result[safe_key] = sensitive ? REPLACEMENT : transform(item, secrets)
          end
        when Array
          value.map { |item| transform(item, secrets) }
        when String
          # Decode JSON/JSONL before redacting keyed data, including structured
          # values; plain replacement inside JSON could corrupt its framing.
          value.lines.map do |line|
            parsed = JSON.parse(line)
            if parsed.is_a?(Hash) || parsed.is_a?(Array)
              JSON.generate(transform(parsed, secrets)) + (line.end_with?("\n") ? "\n" : "")
            else
              redact_text(line, secrets)
            end
          rescue JSON::ParserError
            redact_text(line, secrets)
          end.join
        else
          value
        end
      end

      def self.replace_literals(value, secrets)
        secrets.reduce(value.dup) { |text, secret| text.gsub(secret, REPLACEMENT) }
      end

      def self.safe_accounting?(key, value)
        return counter?(value) if key.end_with?("_tokens")
        return false unless key == "tokens" && value.is_a?(Hash)
        value.all? do |field, count|
          if field == "cache"
            count.is_a?(Hash) && count.all? { |cache_field, cache_count| %w[read write].include?(cache_field) && counter?(cache_count) }
          else
            %w[input output reasoning cache_read cache_write].include?(field) && counter?(count)
          end
        end
      end

      def self.counter?(value)
        value.nil? || (value.is_a?(Numeric) && value.finite? && value >= 0)
      end

      def self.redact_text(value, secrets)
        text = replace_literals(value, secrets)
        text.gsub(/\b([\w.-]*(?:token|secret|password|credential|authorization|api.?key)[\w.-]*\s*[=:]\s*)[^\r\n]*/i) do
          "#{$1}#{REPLACEMENT}"
        end
      end

      private_class_method :transform, :replace_literals, :redact_text, :safe_accounting?, :counter?
    end
  end
end
