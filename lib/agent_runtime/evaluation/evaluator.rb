require "digest"
require "json"
require "rbconfig"
require "tmpdir"
require_relative "../adapters/process_runner"

module AgentRuntime
  module Evaluation
    class Evaluator
      def initialize(store:, process_runner: nil)
        @store = store
        @process_runner = process_runner || Adapters::ProcessRunner.new
      end

      def evaluate(task:, repository:, run_id:, timeout: 30)
        snapshot = @store.put(type: "repository", value: repository, run_id: run_id,
          step_id: "evaluation", attempt: 1)
        spec = persist_json(task.spec.merge("dataset_revision" => task.dataset_revision,
          "base_commit" => task.base_commit), run_id)
        procedure = @store.put(type: "text", value: File.binread(task.hidden_test), run_id: run_id,
          step_id: "evaluation", attempt: 1)
        environment = persist_json({"ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM,
          "executable" => RbConfig.ruby, "environment" => {"LANG" => "C", "TZ" => "UTC"},
          "inherited_environment_digest" => Digest::SHA256.hexdigest(JSON.generate(ENV.to_h.sort.to_h))}, run_id)
        bindings = {"artifact" => snapshot.fetch("digest"), "specification" => spec.fetch("digest"),
                    "procedure" => procedure.fetch("digest"), "environment" => environment.fetch("digest")}

        # Evaluate a disposable copy, preserving the exact submitted Store snapshot.
        execution = Dir.mktmpdir("agru-evaluation-") do |directory|
          target = File.join(directory, "repository")
          FileUtils.cp_r(@store.value(snapshot), target)
          procedure_path = File.join(directory, "hidden_test.rb")
          File.binwrite(procedure_path, @store.value(procedure))
          @process_runner.call(argv: [RbConfig.ruby, "--disable-gems", procedure_path],
            cwd: directory, timeout: timeout,
            env: {"TARGET_REPOSITORY" => target, "LANG" => "C", "TZ" => "UTC"})
        end
        # A completed test command may fail its assertions. This is not an
        # infrastructure failure; timeout/cancellation/spawn failures are.
        completed = !execution["exit_code"].nil? && %w[success failure].include?(execution["status"])
        marker = execution.fetch("stdout", "").lines.rfind { |line| line.start_with?("AGRU_VERDICT=") }
        declared = begin
          marker && JSON.parse(marker.delete_prefix("AGRU_VERDICT="))["verdict"]
        rescue JSON::ParserError
          nil
        end
        valid = completed && ((execution["exit_code"] == 0 && declared == "pass") ||
          (execution["exit_code"] == 1 && declared == "fail"))
        execution_status = if valid
          "completed"
        else
          (completed ? "error" : execution.fetch("status", "unknown"))
        end
        report = {"execution_status" => execution_status,
                  "verdict" => valid ? declared : "not_evaluated",
                  "bindings" => bindings, "artifacts" => {"repository" => snapshot, "spec" => spec,
                                                          "procedure" => procedure, "environment" => environment}, "execution" => execution}
        report["report_artifact"] = @store.put(type: "evaluation_report", value: bindings.merge(report),
          run_id: run_id, step_id: "evaluation", attempt: 1)
        report
      end

      private

      def persist_json(value, run_id)
        @store.put(type: "json", value: value, run_id: run_id, step_id: "evaluation", attempt: 1)
      end
    end
  end
end
