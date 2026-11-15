require "json"
require "digest"
require "date"

module AgentRuntime
  module Execution
    module Usage
      TOKEN_FIELDS = %w[input output reasoning cache_read cache_write].freeze
      RELATIONS = %w[disjoint subset unknown].freeze
      REQUEST_FIELDS = %w[request_id identity_kind identity_scope provider model tokens input_cache_relation output_reasoning_relation reported_cost].freeze
      PRICING_FIELDS = %w[schema_version id provider model currency source effective_date rates_per_million].freeze

      def self.normalize(requests:, complete:, pricing: nil)
        raise ArgumentError, "requests must be an array and complete a boolean" unless requests.is_a?(Array) && [true, false].include?(complete)
        validate_pricing!(pricing) if pricing
        issues = []
        add_issue(issues, "incomplete_stream") unless complete
        add_issue(issues, "empty_stream") if requests.empty?
        records = requests.map { |record| sanitize(record, issues) }
        groups = records.group_by { |record| [record["identity_scope"], record["identity_kind"], record["request_id"]] }
        accepted, retained = [], []
        duplicates = conflicts = unidentified = identified = 0
        groups.sort_by { |key, _| key.map { |value| value || "" } }.each do |key, observations|
          scope, kind, id = key
          if id.nil?
            unidentified += observations.size
            add_issue(issues, "unidentified_request")
            observations.each { |record| retained << {"identity_scope" => scope, "identity_kind" => kind, "request_id" => nil, "observations" => [record]} }
            next
          end
          identified += 1
          variants = observations.uniq { |record| canonical(record) }.sort_by { |record| canonical(record) }
          duplicates += observations.size - variants.size
          retained << {"identity_scope" => scope, "identity_kind" => kind, "request_id" => id, "observations" => variants}
          if variants.size > 1
            conflicts += 1
            add_issue(issues, "conflicting_request", id)
          else
            accepted << variants.first
          end
        end
        totals_allowed = complete && !records.empty? && conflicts.zero? && unidentified.zero?
        tokens = TOKEN_FIELDS.to_h do |field|
          values = accepted.filter_map { |record| record.fetch("tokens")[field] }
          [field, aggregate(values, accepted.size, totals_allowed)]
        end
        costs = accepted.filter_map { |record| record["reported_cost"] }
        currencies = costs.map { |cost| cost.fetch("currency") }.uniq
        cost_values = costs.map { |cost| decimal(cost.fetch("amount")) }
        reported = aggregate(cost_values, accepted.size, totals_allowed, decimal: true)
        reported["currency"] = currencies.one? ? currencies.first : nil
        if currencies.size > 1
          reported["total"] = reported["known_subtotal"] = nil
          add_issue(issues, "mixed_currency")
        end
        estimate = estimate(accepted, totals_allowed, pricing, issues) if pricing
        kinds = records.map { |record| record.fetch("identity_kind") }.uniq
        kind = if kinds.empty?
          nil
        elsif kinds.one?
          kinds.first
        else
          "mixed"
        end
        coverage = {"stream_complete" => complete,
                    "complete" => totals_allowed && tokens.values.all? { |field| !field["total"].nil? },
                    "identity_kind" => kind,
                    "observations" => records.size, "identified_requests" => identified,
                    "accepted_requests" => accepted.size, "duplicate_observations" => duplicates,
                    "conflicting_requests" => conflicts, "unidentified_observations" => unidentified}
        cost = reported["total"]&.to_f
        cost = nil unless cost&.finite?
        {"usage" => {"schema_version" => 1, "requests" => retained, "coverage" => coverage,
                     "tokens" => tokens, "reported_cost" => reported, "estimate" => estimate,
                     "issues" => issues.uniq.sort_by { |issue| canonical(issue) }}, "cost" => cost}
      end

      def self.sanitize(record, issues)
        raise ArgumentError, "canonical request fields do not match schema" unless record.is_a?(Hash) && record.keys.sort == REQUEST_FIELDS.sort
        %w[request_id provider model].each do |field|
          raise ArgumentError, "invalid #{field}" if !record[field].nil? && !nonempty?(record[field])
        end
        raise ArgumentError, "invalid observation identity" unless %w[provider_request root_step_observation].include?(record["identity_kind"]) && nonempty?(record["identity_scope"])
        %w[input_cache_relation output_reasoning_relation].each do |field|
          raise ArgumentError, "invalid #{field}" unless RELATIONS.include?(record[field])
        end
        raise ArgumentError, "invalid token fields" unless record["tokens"].is_a?(Hash) && record["tokens"].keys.sort == TOKEN_FIELDS.sort
        copy = record.dup
        copy["tokens"] = record.fetch("tokens").to_h do |field, value|
          valid = value.nil? || (value.is_a?(Integer) && value >= 0)
          unless valid
            add_issue(issues, "invalid_token_count", record["request_id"], field)
            value = nil
          end
          [field, value]
        end
        cost = record["reported_cost"]
        unless cost.nil?
          valid = cost.is_a?(Hash) && cost.keys.sort == %w[amount currency provenance] &&
            decimal(cost["amount"]) && nonempty?(cost["currency"]) && cost["provenance"] == "provider_reported"
          if valid
            copy["reported_cost"] = cost.merge("amount" => decimal_string(decimal(cost["amount"])))
          else
            copy["reported_cost"] = nil
            add_issue(issues, "invalid_reported_cost", record["request_id"], "reported_cost")
          end
        end
        copy
      end

      def self.validate_pricing!(pricing)
        valid = pricing.is_a?(Hash) && pricing.keys.sort == PRICING_FIELDS.sort && pricing["schema_version"] == 1 &&
          %w[id provider model currency source effective_date].all? { |field| nonempty?(pricing[field]) }
        raise ArgumentError, "invalid pricing schema or provenance" unless valid
        begin
          date = pricing.fetch("effective_date")
          raise Date::Error unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(date).iso8601 == date
        rescue Date::Error
          raise ArgumentError, "invalid pricing effective date"
        end
        rates = pricing["rates_per_million"]
        raise ArgumentError, "invalid pricing rates" unless rates.is_a?(Hash) && rates.keys.sort == TOKEN_FIELDS.sort && rates.values.all? { |rate| decimal(rate) }
      end

      def self.estimate(records, totals_allowed, pricing, issues)
        values = records.filter_map do |record|
          id = record["request_id"]
          unless %w[provider model].all? { |field| record[field] == pricing[field] }
            add_issue(issues, "pricing_identity_mismatch", id)
            next
          end
          counts = record.fetch("tokens")
          unless counts.values.none?(&:nil?)
            add_issue(issues, "missing_pricing_evidence", id)
            next
          end
          input_relation = record.fetch("input_cache_relation")
          output_relation = record.fetch("output_reasoning_relation")
          add_issue(issues, "unknown_cache_relation", id) if input_relation == "unknown"
          add_issue(issues, "unknown_reasoning_relation", id) if output_relation == "unknown"
          next if [input_relation, output_relation].include?("unknown")
          buckets = counts.dup
          buckets["input"] -= counts["cache_read"] + counts["cache_write"] if input_relation == "subset"
          buckets["output"] -= counts["reasoning"] if output_relation == "subset"
          if buckets.values.any?(&:negative?)
            add_issue(issues, "inconsistent_subset", id)
            next
          end
          TOKEN_FIELDS.sum { |field| buckets.fetch(field) * decimal(pricing.fetch("rates_per_million").fetch(field)) } / 1_000_000
        end
        summary = aggregate(values, records.size, totals_allowed, decimal: true)
        {"kind" => "estimate", "amount" => summary.fetch("total"),
         "known_subtotal" => summary.fetch("known_subtotal"), "known_requests" => values.size,
         "currency" => pricing.fetch("currency"), "pricing" => JSON.parse(canonical(pricing)),
         "pricing_digest" => Digest::SHA256.hexdigest(canonical(pricing))}
      end

      def self.aggregate(values, count, totals_allowed, decimal: false)
        subtotal = values.empty? ? nil : values.sum
        subtotal = decimal_string(subtotal) if decimal && subtotal
        {"total" => (totals_allowed && values.size == count) ? subtotal : nil,
         "known_subtotal" => subtotal, "known_requests" => values.size}
      end

      def self.decimal(value)
        return unless value.is_a?(String) && value.match?(/\A\d+(?:\.\d+)?\z/)
        Rational(value)
      end

      def self.decimal_string(value)
        integer, remainder = value.numerator.divmod(value.denominator)
        return integer.to_s if remainder.zero?
        fraction = +""
        until remainder.zero?
          digit, remainder = (remainder * 10).divmod(value.denominator)
          fraction << digit.to_s
        end
        "#{integer}.#{fraction}"
      end

      def self.nonempty?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def self.add_issue(issues, code, request_id = nil, field = nil)
        issues << {"code" => code, "request_id" => request_id, "field" => field}
      end

      def self.canonical(value)
        sorted = case value
        when Hash then value.keys.sort.to_h { |key| [key, JSON.parse(canonical(value.fetch(key)))] }
        when Array then value.map { |entry| JSON.parse(canonical(entry)) }
        else value
        end
        JSON.generate(sorted)
      end

      private_class_method :sanitize, :validate_pricing!, :estimate, :aggregate,
        :decimal, :decimal_string, :nonempty?, :add_issue, :canonical
    end
  end
end
