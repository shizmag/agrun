# frozen_string_literal: true

require "digest"
require "json"

module AgentRuntime
  module Tracing
    # Projects preserved observations, never reruns, grades, or repairs evidence.
    class Historical
      CELL_FIELDS = %w[id task_id solver_id model_id repetition execution_status status verdict score passed failed total expected executed collected skipped agent_duration actual_model cost].freeze
      ATTEMPT_FIELDS = %w[status attempt attempt_id session_id availability counts accounting_coverage completion].freeze

      def initialize(store:)
        @store = store
      end

      # evidence_paths are existing files, not directories or inferred artifact IDs.
      # Their bytes are hashed, never copied into the tracing store.
      def import(report_path:, evidence_paths: [])
        source, bytes = read_reference(report_path)
        document = JSON.parse(bytes)
        report = document.fetch("report", document)
        cells = report.fetch("cells")
        raise ArgumentError, "historical cells must be an array" unless cells.is_a?(Array)
        references = evidence_paths.map { |path| read_reference(path).first }
        root = @store.start(kind: "historical_import", attributes: {
          "historical_run_id" => report["run_id"], "raw" => false,
          "evidence" => references, "accounting_complete" => false
        }, provenance: {"source" => source, "basis" => "preserved_observations_not_reexecution"})
        cells.each_with_index do |cell, index|
          cell_id = @store.start(kind: "historical_cell", parent_id: root,
            attributes: select(cell, CELL_FIELDS),
            provenance: {"source" => source, "pointer" => "#{"/report" if document.key?("report")}/cells/#{index}"})
          (cell.dig("execution", "steps") || {}).each do |name, step|
            step_id = @store.start(kind: "historical_step", parent_id: cell_id,
              attributes: {"name" => name, "historical_status" => step["status"]})
            (step["attempts"] || []).each do |attempt|
              attributes = select(attempt, ATTEMPT_FIELDS)
              # An old Store artifact ID is a reference, not proof bytes are present.
              if attempt["evidence"]
                attributes["historical_evidence_id"] = attempt["evidence"]
                attributes["evidence_resolution"] = "not_resolved"
              end
              @store.event(kind: "historical_attempt", parent_id: step_id, attributes: attributes)
            end
            @store.finish(step_id, status: step["status"] || "unknown")
          end
          @store.finish(cell_id, status: cell["execution_status"] || "unknown")
        end
        @store.finish(root, status: "success", attributes: {"cells" => cells.length,
                                                            "status_basis" => "import_completed_not_historical_evaluation"})
        root
      end

      private

      def select(value, keys)
        keys.each_with_object({}) { |key, result| result[key] = value[key] if value.key?(key) }
      end

      def read_reference(path)
        path = File.expand_path(path)
        raise ArgumentError, "historical evidence must be a regular file: #{path}" unless File.file?(path)
        bytes = File.binread(path)
        [{"path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize}, bytes]
      end
    end
  end
end
