require_relative "reports"
require_relative "resource_report"

module AgentRuntime
  module Benchmarks
    # Descriptive pilot analysis. Missing measurements never become zeroes.
    class ScientificReport
      def initialize(store:)
        @store = store
      end

      def render(experiment_id:, evidence_kind:)
        raise ArgumentError, "unknown evidence kind" unless %w[simulated_relay live_provider offline_fixture local_transport_simulation].include?(evidence_kind)
        if evidence_kind == "live_provider"
          report = @store.report(experiment_id)
          provenance = report.dig("provenance", "solver_execution")
          local_live = report["transport"] == "local-token-gateway" && report["live_provider"] == true &&
            report["offline_injected_provider"] == false && report.dig("manifest", "execution_mode") == "live" &&
            report.fetch("solver_configurations", {}).values.then { |configs| !configs.empty? && configs.all? { |config| config["live"] == true } }
          raise ArgumentError, "live report requires live execution provenance" unless provenance == "live" || local_live
        end
        summary = Reports.new(store: @store).summary(experiment_id: experiment_id)
        manifest = summary.fetch("manifest")
        cells = summary.fetch("per_task_results").values.flatten
        simulation_notice = (evidence_kind == "local_transport_simulation") ? "Synthetic in-process responses only; no live API calls. These outcomes validate infrastructure, not model quality or served-model identity." : nil
        lines = ["# AGRU comparative research pilot", "", "Experiment: `#{safe(experiment_id)}`",
          "Evidence: **#{evidence_kind}**", simulation_notice, "",
          "Execution failures and unobserved stages remain in the planned-cell denominator. Live configuration is not evidence that every cell reached a provider, nor attestation of served-model identity.", "",
          "## Research question and setup", "",
          "How do complete-task, fixed role workflow, and typed compositional execution differ in observed quality, reliability and resource use on the frozen task?",
          "", "The operational comparison shares tools, public task information, model route and sandbox policy. Single agent has one inference stage; both multi-stage architectures have three. The DSL additionally branches repository inventory and validates artifact manifests. These are distinct interventions, not equal-compute treatments.",
          "", "Frozen manifest (requested configuration, not served-model attestation):", "", "```json", JSON.pretty_generate(manifest), "```", "",
          "## Per-cell outcomes", "", "Every planned cell remains in the denominator, including infrastructure failures.", "",
          "| Cell | Architecture | Execution | Evaluation | Score | Regrade attempts | Wall seconds |",
          "|---|---|---|---|---:|---:|---:|"]
        cells.each do |cell|
          lines << "| #{safe(cell["id"])} | #{safe(cell["solver_id"])} | #{safe(cell["execution_status"] || cell["status"])} | #{safe(cell["verdict"] || cell["status"])} | #{measurement(cell["score"])} | #{Array(cell["grading_attempts"]).size} | #{measurement(cell["agent_duration"])} |"
        end
        lines += ["", "## Descriptive comparison", "", "| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |", "|---|---:|---:|---:|---:|---:|---:|"]
        cells.group_by { |cell| cell.fetch("solver_id") }.each do |solver, rows|
          scores = rows.filter_map { |row| row["score"] if row["score"].is_a?(Numeric) }
          durations = rows.filter_map { |row| row["agent_duration"] if row["agent_duration"].is_a?(Numeric) }
          successes = rows.count { |row| (row["execution_status"] || row["status"]) == "success" }
          lines << "| #{safe(solver)} | #{rows.size} | #{successes}/#{rows.size} | #{scores.size}/#{rows.size} | #{average(scores)} | #{average(durations)} | #{rows.count { |row| row["usage"].nil? }}/#{rows.size} |"
        end
        lines += ["", "Means use observed numeric values only; observation counts are shown explicitly. Failed/missing grades are not silently scored as zero or removed from reliability denominators. Inspect JSON for execution failure categories, tool activity, request timing, retries, usage completeness and provider errors. Null is unknown, not zero. Cached tokens must not be added to inclusive input-token totals. Estimated costs are not verified billing.", "",
          "## Regrading and interpretation", "", "Separate grading attempts evaluate the saved immutable submission. Agreement validates reproducibility of this grader on that submission, not independence of grader implementation or benchmark validity. The accompanying verification record, not this narrative, determines regrade agreement.", ""]
        unless evidence_kind == "live_provider"
          lines += ["**Simulator/fixture scores are pipeline observations only, not genuine model-quality observations. No architectural superiority can be inferred from them.**", ""]
        end
        lines += ["## Validity limitations", "",
          "* Three repetitions and one task support descriptive analysis only, not statistically generalizable superiority.",
          "* Different inference-stage counts confound operational quality/resource comparisons. An equal-compute study must freeze aggregate request/token caps across all stages; per-stage limits alone are insufficient. Do not interpret greater inference expenditure as architectural improvement.",
          "* Model nondeterminism remains even with frozen requested inference settings. Provider route identity is not actual served-model attestation.",
          "* Provider telemetry can be incomplete; unknown tokens, reasoning, cache usage and prices prevent complete compute/cost comparisons. Missing usage counts above do not imply every non-null usage record is complete.",
          "* Client-emitted zero cache/reasoning observations are not independently verified provider measurements. The controlled simulator reports only input, output and total tokens.",
          "* The audited grader is a trusted evaluator with its own environment and trust boundary; solver-directory separation alone is not a security sandbox.",
          "* Role prompts, textual handoffs, deterministic inventory and validation overhead are architecture-specific confounders. No claim is made about all possible agent architectures.",
          "* A hash freeze detects alteration relative to its recorded digest, not authenticity against an attacker able to replace both evidence and digest.", ""]
        lines << ResourceReport.new.render(cells: cells, evidence_kind: evidence_kind)
        lines.join("\n")
      end

      private

      def safe(value) = value.to_s.gsub(/[|\r\n]/, " ")
      def measurement(value) = value.is_a?(Numeric) ? value.round(6).to_s : "unknown"
      def average(values) = values.empty? ? "unknown" : measurement(values.sum.to_f / values.size)
    end
  end
end
