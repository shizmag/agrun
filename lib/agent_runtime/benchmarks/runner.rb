require "json"
require "fileutils"
require "securerandom"
require "digest"
require "time"

module AgentRuntime
  module Benchmarks
    class Runner
      def initialize(store:, root:, evaluator: nil)
        @store, @root = store, File.expand_path(root)
        @evaluator = evaluator || Evaluation::Evaluator.new(store: store)
      end

      def matrix(tasks:, solvers:, models: [nil], repetitions: 1, budget: {})
        raise ArgumentError, "repetitions must be positive" unless repetitions.is_a?(Integer) && repetitions.positive?
        tasks.flat_map do |task|
          solvers.flat_map do |identity, solver|
            models.flat_map do |model|
              (1..repetitions).map { |repetition| run(task: task, solver: solver, solver_id: identity, model: model, repetition: repetition, budget: budget) }
            end
          end
        end
      end

      def run(task:, solver:, model: nil, budget: {}, solver_id: nil, repetition: 1)
        budget = (task.limits || {}).merge(budget)
        run_id = "benchmark-#{SecureRandom.uuid}"
        configuration = {"solver" => solver_id || solver.class.name, "solver_version" => AgentRuntime::VERSION,
                         "requested_model" => model, "budget" => budget,
                         "solver_config" => solver.respond_to?(:configuration) ? solver.configuration : {}}
        report = {"run_id" => run_id, "kind" => "benchmark", "task_id" => task.id,
                  "dataset" => task.dataset || task.id.split("/").first, "dataset_revision" => task.dataset_revision,
                  "base_commit" => task.base_commit, "solver_id" => configuration["solver"],
                  "solver_version" => AgentRuntime::VERSION, "repetition" => repetition,
                  "started_at" => Time.now.utc.iso8601(6), "requested_model" => model,
                  "budget" => budget, "configuration" => configuration,
                  "configuration_digest" => IR.digest(configuration), "ir_digest" => nil, "artifact_refs" => {}}
        directory = File.join(@root, run_id)
        workspace = File.join(directory, "solver")
        FileUtils.mkdir_p(workspace)
        # Do not give solvers Task: it carries the evaluator-only procedure path.
        public_task = Task.new(id: task.id, instruction: task.instruction, repository: task.repository,
          base_commit: task.base_commit, dataset_revision: task.dataset_revision, spec: task.spec.dup,
          dataset: task.dataset, public_tests: task.public_tests, limits: task.limits, metadata: task.metadata)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        solution = solver.solve(task: public_task, model: model, budget: budget, workspace: workspace)
        evaluation = if solution["status"] == "success" && solution["repository"]
          # Retain the submitted generation independently from content identity.
          generation = @store.put(value: solution.fetch("repository"), type: "repository", run_id: run_id,
            step_id: "solver", attempt: 1, metadata: {"solver_id" => configuration["solver"]})
          @evaluator.evaluate(task: task, repository: solution.fetch("repository"), run_id: run_id,
            timeout: budget.fetch("evaluation_timeout", 30), generation: generation)
        else
          {"execution_status" => "not_started", "verdict" => "not_evaluated"}
        end
        report.merge!({
          "status" => solution["status"], "model" => solution["model"], "requested_model" => model,
          "budget" => budget, "solution" => solution, "evaluation" => evaluation,
          "duration" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          "ended_at" => Time.now.utc.iso8601(6), "ir_digest" => solution["ir_digest"],
          "artifact_refs" => evaluation.fetch("artifacts", {}).merge("generation" => generation,
            "evaluation_report" => evaluation["report_artifact"]).compact
        })
        persist(report, directory)
      rescue => error
        raise unless directory
        persist(report.merge({
          "status" => solution ? solution.fetch("status", "failure") : "failure", "error" => "#{error.class}: #{error.message}",
          "solution" => solution, "model" => solution && solution["model"],
          "ir_digest" => solution && solution["ir_digest"],
          "artifact_refs" => {"generation" => generation}.compact,
          "ended_at" => Time.now.utc.iso8601(6),
          "duration" => started && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          "evaluation" => {"execution_status" => "error", "verdict" => "not_evaluated"}
        }), directory)
      end

      private

      def persist(report, directory)
        @store.save_report(report)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, "result.json"), JSON.pretty_generate(report) + "\n")
        rows = [%w[run_id task_id status model execution_status verdict duration cost],
          [report["run_id"], report["task_id"], report["status"], report["model"],
            report.dig("evaluation", "execution_status"), report.dig("evaluation", "verdict"),
            report["duration"], report.dig("solution", "cost")]]
        File.write(File.join(directory, "result.csv"), rows.map { |row|
          row.map { |value| '"' + value.to_s.gsub('"', '""') + '"' }.join(",") + "\r\n"
        }.join)
        report
      end
    end
  end
end
