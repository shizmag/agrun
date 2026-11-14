require_relative "../../agent_runtime"

module AgentRuntime
  module Benchmarks
    class Adapter
      OPERATIONS = %i[identity list_tasks load_task prepare_solver_workspace prepare_grading_request grade_submission normalize_score].freeze
      PUBLIC_TASK_FIELDS = %w[id benchmark instruction specification_digest metadata availability unavailable_reason].freeze

      def self.verify!(adapter)
        missing = OPERATIONS.reject do |name|
          adapter.respond_to?(name) && adapter.method(name).owner != Adapter
        end
        raise ArgumentError, "adapter missing operations: #{missing.join(", ")}" unless missing.empty?
        adapter
      end

      def self.freeze_json(value)
        case value
        when Hash then value.each { |key, entry|
          key.freeze
          freeze_json(entry)
        }
        when Array then value.each { |entry| freeze_json(entry) }
        end
        value.freeze
      end

      def self.public_task(value)
        task = IR.normalize_json(value)
        raise ArgumentError, "public task must be an object" unless task.is_a?(Hash)
        raise ArgumentError, "private or unknown public task field" unless (task.keys - PUBLIC_TASK_FIELDS).empty?
        required = %w[id benchmark instruction specification_digest metadata availability]
        raise ArgumentError, "missing public task fields" unless (required - task.keys).empty?
        freeze_json(JSON.parse(IR.dump(task)))
      rescue AgentRuntime::Error => error
        raise ArgumentError, error.message
      end

      OPERATIONS.each do |operation|
        define_method(operation) { |*args, **kwargs| raise NotImplementedError, operation.to_s }
      end
    end
  end
end
