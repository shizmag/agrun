require_relative "adapter"

module AgentRuntime
  module Benchmarks
    class ExperimentManifest
      FIELDS = %w[schema_version experiment_id benchmark solver_ids models repetitions limits execution_mode subset_role].freeze
      attr_reader :data, :digest

      def initialize(value, catalog: nil)
        normalized = IR.normalize_json(value)
        if catalog
          normalized["models"].each do |model|
            snapshot = catalog.resolve(model.fetch("catalog_route"))
            model["model_resolution"] = snapshot
            profile = model.fetch("model_profile")
            route = snapshot.fetch("route")
            raise ArgumentError, "catalog route mismatch" unless profile["provider"] == route["provider"] && profile["model"] == route["wire_id"]
            raise ArgumentError, "catalog endpoint mismatch" unless profile.dig("tool_policy", "endpoint") == route["endpoint"]
            raise ArgumentError, "catalog inference parameters mismatch" unless profile.fetch("inference_parameters", {}) == snapshot.fetch("variant").fetch("parameters")
            if !snapshot.fetch("variant").fetch("parameters").empty? && route["parameter_delivery"] != "wire_id"
              raise ArgumentError, "unsupported catalog inference parameter delivery"
            end
          end
        end
        validate!(normalized)
        @data = Adapter.freeze_json(JSON.parse(IR.dump(normalized)))
        @digest = IR.digest(@data).freeze
      rescue AgentRuntime::Error, JSON::GeneratorError => error
        raise ArgumentError, error.message
      end

      def cells
        data.fetch("benchmark").fetch("task_ids").product(data.fetch("solver_ids"), data.fetch("models"), (1..data.fetch("repetitions")).to_a).map do |task, solver, model, repetition|
          coordinates = {"task_id" => task, "solver_id" => solver, "model_id" => model.fetch("id"), "repetition" => repetition}
          Adapter.freeze_json(coordinates.merge("id" => IR.digest(coordinates.merge("manifest_digest" => digest)), "status" => "not_started"))
        end.freeze
      end

      private

      def nonempty_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def unique_ids!(values)
        raise ArgumentError, "IDs must be a nonempty unique list" unless values.is_a?(Array) && !values.empty? && values.all? { |id| nonempty_string?(id) } && values.uniq.length == values.length
      end

      def validate!(value)
        if value.is_a?(Hash) && value["models"].is_a?(Array)
          value["models"].each do |model|
            next unless model.is_a?(Hash) && model.key?("model_profile")
            profile = model["model_profile"]
            raise ArgumentError, "model_profile must explicitly select a model" unless profile.is_a?(Hash) && nonempty_string?(profile["model"]) && profile["model"] != "default"
          end
        end
        raise ArgumentError, "manifest fields do not match schema" unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort
        raise ArgumentError, "unsupported manifest schema" unless value["schema_version"] == 1
        raise ArgumentError, "experiment identity required" unless nonempty_string?(value["experiment_id"])
        benchmark = value["benchmark"]
        raise ArgumentError, "benchmark requires exact name/revision/task_ids" unless benchmark.is_a?(Hash) && benchmark.keys.sort == %w[name revision task_ids] && %w[name revision].all? { |key| nonempty_string?(benchmark[key]) }
        unique_ids!(benchmark["task_ids"])
        unique_ids!(value["solver_ids"])
        models = value["models"]
        raise ArgumentError, "models must be objects" unless models.is_a?(Array) && models.all? { |model| model.is_a?(Hash) }
        unique_ids!(models.map { |model| model["id"] })
        raise ArgumentError, "repetitions must be a positive integer" unless value["repetitions"].is_a?(Integer) && value["repetitions"].positive?
        limits = value["limits"]
        raise ArgumentError, "limits must be positive finite numbers" unless limits.is_a?(Hash) && !limits.empty? && limits.values.all? { |limit| limit.is_a?(Numeric) && limit.finite? && limit.positive? }
        raise ArgumentError, "execution_mode must be offline or live" unless %w[offline live].include?(value["execution_mode"])
        if value["execution_mode"] == "live"
          raise ArgumentError, "live pilot requires retrying and single-agent" unless benchmark["name"] == "nl2repo" && benchmark["task_ids"] == ["retrying"] && value["solver_ids"] == ["single-agent"]
          raise ArgumentError, "live pilot requires one explicit real-provider model" unless models.length == 1 && models.first.dig("model_profile", "execution_kind") == "real_provider"
          raise ArgumentError, "live execution requires a finite timeout and sequential cells" unless limits["timeout"] && limits.fetch("max_parallelism", 1) == 1
        end
        raise ArgumentError, "subset_role required" unless nonempty_string?(value["subset_role"])
      end
    end
  end
end
