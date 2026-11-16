module AgentRuntime
  module Execution
    # Declarative resolution only: never rewrites a provider wire identifier.
    class ModelCatalog
      def initialize(data)
        @data = copy(data)
        raise ArgumentError, "catalog must be an object" unless @data.is_a?(Hash)
        %w[revision models variants routes pricing].each { |key| @data.fetch(key) }
        %w[models variants routes pricing].each { |key| raise ArgumentError, "catalog #{key} must be an object" unless @data[key].is_a?(Hash) }
        raise ArgumentError, "catalog revision required" unless @data["revision"].is_a?(String) && !@data["revision"].empty?
      rescue KeyError => error
        raise ArgumentError, error.message
      end

      def resolve(route_id)
        route = @data.fetch("routes").fetch(route_id)
        raise ArgumentError, "route must be an object" unless route.is_a?(Hash)
        variant = @data.fetch("variants").fetch(route.fetch("variant"))
        raise ArgumentError, "variant must be an object with parameters" unless variant.is_a?(Hash) && variant["parameters"].is_a?(Hash)
        model_id = variant.fetch("model")
        model = @data.fetch("models").fetch(model_id)
        raise ArgumentError, "model must be an object" unless model.is_a?(Hash)
        if variant["pricing"] && !@data["pricing"].key?(variant["pricing"])
          raise ArgumentError, "unknown pricing reference"
        end
        %w[provider endpoint wire_id].each { |key| raise ArgumentError, "route #{key} required" unless route[key].is_a?(String) && !route[key].empty? }
        copy({"catalog_revision" => @data["revision"], "catalog_digest" => IR.digest(@data),
              "route_id" => route_id, "route" => route, "variant_id" => route["variant"], "variant" => variant,
              "model_id" => model_id, "model" => model, "pricing" => @data["pricing"][variant["pricing"]]})
      rescue KeyError => error
        raise ArgumentError, "unknown catalog reference: #{error.message}"
      end

      def attribute(snapshot, gateway_model: nil, gateway_provider: nil, gateway_endpoint: nil, served: nil)
        route = snapshot.fetch("route")
        mismatch = (gateway_provider && gateway_provider != route.fetch("gateway_provider", route["provider"])) ||
          (gateway_endpoint && gateway_endpoint != route["endpoint"]) ||
          (gateway_model && gateway_model != route["gateway_model"])
        copy({"requested" => snapshot, "gateway" => {"model" => gateway_model, "provider" => gateway_provider, "endpoint" => gateway_endpoint},
              "gateway_status" => if mismatch
                                    "mismatch"
                                  else
                                    ((gateway_model && gateway_provider && gateway_endpoint) ? "match" : "unknown")
                                  end, "served" => served})
      end

      # An estimate of supplied usage, never an actual charge or a completeness claim.
      def cost(snapshot, usage:, attribution: nil)
        semantics = snapshot.dig("route", "accounting")
        unknown = {"amount" => nil, "kind" => "estimate", "completeness" => "unknown"}
        return unknown unless attribution.is_a?(Hash)
        if attribution
          return unknown unless attribution["requested"] == snapshot && attribution["gateway_status"] == "match"
          gateway = attribution["gateway"]
          return unknown unless gateway.is_a?(Hash)
          checked = attribute(snapshot, gateway_model: gateway["model"], gateway_provider: gateway["provider"], gateway_endpoint: gateway["endpoint"])
          return unknown unless checked["gateway_status"] == "match"
          served = attribution["served"]
          return unknown if served && (!served.is_a?(Hash) || served["model"] != snapshot["model_id"] || served["provider"] != snapshot.dig("route", "provider"))
        end
        tariff = snapshot["pricing"]
        return unknown unless tariff.is_a?(Hash) && tariff["rates"].is_a?(Hash) && semantics.is_a?(Hash) && semantics["provenance"] &&
          [true, false].include?(semantics["input_includes_cached"]) && [true, false].include?(semantics["output_includes_reasoning"])
        %w[revision provenance currency].each { |key| return unknown unless tariff[key].is_a?(String) && !tariff[key].empty? }
        categories = %w[input cached_input output reasoning]
        return unknown unless usage.is_a?(Hash) && (usage.keys - categories).empty?
        counts = categories.to_h { |key| [key, decimal(usage[key])] }
        return unknown if counts.values.any?(&:nil?) || counts.values.any? { |n| n.denominator != 1 }
        counts["input"] -= counts["cached_input"] if semantics["input_includes_cached"]
        counts["output"] -= counts["reasoning"] if semantics["output_includes_reasoning"]
        return unknown if counts.values.any?(&:negative?)
        rates = categories.to_h { |key| [key, decimal(tariff.fetch("rates", {})[key])] }
        denominator = decimal(tariff["per_tokens"])
        return unknown if rates.values.any?(&:nil?) || !denominator || denominator.zero?
        amount = categories.sum(Rational(0)) { |key| counts[key] * rates[key] } / denominator
        {"amount" => amount.to_s, "amount_encoding" => "exact_rational", "currency" => tariff["currency"], "kind" => "estimate",
         "identity_basis" => "configured_tariff_not_served_attestation",
         "completeness" => "supplied_categories_only", "tariff_revision" => tariff["revision"], "provenance" => tariff["provenance"]}
      end

      private

      def decimal(value)
        return nil unless value.is_a?(String) || value.is_a?(Integer)
        return nil unless /\A\d+(?:\.\d+)?\z/.match?(value.to_s)
        result = Rational(value.to_s)
        result unless result.negative?
      rescue ArgumentError
        nil
      end

      def copy(value)
        freeze_value(JSON.parse(JSON.generate(value)))
      end

      def freeze_value(value)
        if value.is_a?(Hash)
          value.each { |key, item|
            key.freeze
            freeze_value(item)
          }
        end
        value.each { |item| freeze_value(item) } if value.is_a?(Array)
        value.freeze
      end
    end
  end
end
