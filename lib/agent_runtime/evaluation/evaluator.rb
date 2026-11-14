require "digest"
require "json"
require "rbconfig"
require "tmpdir"
require_relative "../adapters/process_runner"

module AgentRuntime
  module Evaluation
    class Evaluator
      SOURCE_PATH = File.expand_path(__FILE__).freeze
      SOURCE_DIGEST = Digest::SHA256.hexdigest(File.binread(SOURCE_PATH)).freeze

      def initialize(store:, process_runner: nil, evaluator_version: AgentRuntime::VERSION)
        @store = store
        @process_runner = process_runner || Adapters::ProcessRunner.new
        @evaluator_version = evaluator_version
      end

      def evaluate(task:, repository:, run_id:, timeout: 30, generation: nil)
        raise Error, "invalid submitted generation" unless generation.nil? || generation.is_a?(Hash)
        timeout = normalized_timeout(timeout)
        expected = evidence_values(task, repository, timeout)
        validate_generation!(generation, repository, run_id) if generation
        evaluation_id = SecureRandom.uuid
        metadata = {"evaluation_id" => evaluation_id}
        snapshot = persist("repository", repository, run_id, metadata, generation ? [generation] : [])
        producer = generation || snapshot
        artifacts = {"artifact" => snapshot,
                     "specification" => persist("json", expected.fetch("specification"), run_id, metadata),
                     "procedure" => persist("text", expected.fetch("procedure"), run_id, metadata),
                     "environment" => persist("json", expected.fetch("environment"), run_id, metadata)}
        execution = Dir.mktmpdir("agru-evaluation-") do |directory|
          target = File.join(directory, "repository")
          FileUtils.cp_r(@store.value(snapshot), target)
          procedure_path = File.join(directory, "hidden_test.rb")
          File.binwrite(procedure_path, @store.value(artifacts.fetch("procedure")))
          @process_runner.call(argv: [RbConfig.ruby, "--disable-gems", procedure_path],
            cwd: directory, timeout: timeout,
            env: {"TARGET_REPOSITORY" => target, "LANG" => "C", "TZ" => "UTC"})
        end
        verdict, status = classify(execution)
        report = {"execution_status" => status, "verdict" => verdict,
                  "evaluation_id" => evaluation_id, "identity_mode" => generation ? "submitted" : "standalone",
                  "generation" => producer, "bindings" => artifacts.transform_values { |a| a.fetch("digest") },
                  "artifacts" => artifacts, "execution" => execution}
        report["report_artifact"] = persist("json", report, run_id, metadata, artifacts.values)
        report
      rescue => error
        raise error if error.is_a?(Error)
        raise Error, "evaluation failed: #{error.class}: #{error.message}"
      end

      # Verification only reads canonical records and bytes; it never repairs or
      # re-evaluates evidence. Equal content does not replace submitted identity.
      def verify!(report:, task:, repository:, run_id:, timeout: 30, generation: nil)
        raise Error, "invalid submitted generation" unless generation.nil? || generation.is_a?(Hash)
        expected = evidence_values(task, repository, normalized_timeout(timeout))
        raise Error, "invalid evaluation report" unless report.is_a?(Hash)
        id = report.fetch("evaluation_id")
        raise Error, "invalid evaluation identity" unless id.is_a?(String) && !id.empty?
        artifacts = report.fetch("artifacts")
        types = {"artifact" => "repository", "specification" => "json", "procedure" => "text", "environment" => "json"}
        raise Error, "invalid evidence set" unless artifacts.is_a?(Hash) && artifacts.keys.sort == types.keys.sort
        artifacts.each do |name, artifact|
          validate_owned!(artifact, types.fetch(name), run_id, id)
        end
        snapshot = artifacts.fetch("artifact")
        producer = report.fetch("generation")
        case report.fetch("identity_mode")
        when "submitted"
          raise Error, "submitted generation required" unless generation && generation == producer
          validate_generation!(generation, repository, run_id)
          raise Error, "invalid generation provenance" unless snapshot.fetch("inputs") == [generation]
        when "standalone"
          raise Error, "standalone identity mismatch" if generation || producer != snapshot || snapshot.fetch("inputs") != []
        else
          raise Error, "invalid identity mode"
        end
        artifacts.each do |name, artifact|
          next if name == "artifact"
          raise Error, "unexpected evidence provenance" unless artifact.fetch("inputs") == []
          raise Error, "stale #{name} evidence" unless @store.value(artifact) == expected.fetch(name)
        end
        current_digest = Digest::SHA256.hexdigest(IR.dump(Store.manifest(repository)))
        raise Error, "stale repository evidence" unless snapshot.fetch("digest") == current_digest
        raise Error, "invalid bindings" unless report.fetch("bindings") == artifacts.transform_values { |a| a.fetch("digest") }
        verdict, status = classify(report.fetch("execution"))
        raise Error, "invalid evaluation outcome" unless report.fetch("verdict") == verdict && report.fetch("execution_status") == status
        report_artifact = report.fetch("report_artifact")
        validate_owned!(report_artifact, "json", run_id, id)
        raise Error, "invalid report provenance" unless report_artifact.fetch("inputs") == artifacts.values
        raise Error, "report payload mismatch" unless @store.value(report_artifact) == report.except("report_artifact")
        report
      rescue => error
        raise error if error.is_a?(Error)
        raise Error, "evidence verification failed: #{error.class}: #{error.message}"
      end

      private

      def normalized_timeout(timeout)
        raise Error, "invalid evaluation timeout" unless timeout.is_a?(Numeric)
        value = Float(timeout)
        raise Error, "invalid evaluation timeout" unless value.finite? && value.positive?
        value
      end

      def evidence_values(task, repository, timeout)
        unless Digest::SHA256.hexdigest(File.binread(SOURCE_PATH)) == SOURCE_DIGEST
          raise Error, "evaluator source changed since load"
        end
        # Read all required inputs before execution; inaccessible source/public
        # tests cannot silently produce weaker bindings.
        Store.manifest(repository)
        {"specification" => task.spec.merge("dataset_revision" => task.dataset_revision,
          "base_commit" => task.base_commit, "instruction" => task.instruction,
          "public_tests" => task.public_tests.map { |path| {"path" => path, "sha256" => Digest::SHA256.hexdigest(File.binread(path))} }),
         "procedure" => File.binread(task.hidden_test),
         "environment" => {"ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM,
                           "executable" => RbConfig.ruby, "environment" => {"LANG" => "C", "TZ" => "UTC"},
                           "inherited_environment_digest" => Digest::SHA256.hexdigest(JSON.generate(ENV.to_h.sort.to_h)),
                           "evaluator" => {"version" => @evaluator_version, "source_sha256" => SOURCE_DIGEST, "timeout" => timeout}}}
      end

      def validate_generation!(generation, repository, run_id)
        @store.value(generation)
        digest = Digest::SHA256.hexdigest(IR.dump(Store.manifest(repository)))
        unless generation.fetch("type") == "repository" && generation.fetch("run_id") == run_id && generation.fetch("digest") == digest
          raise Error, "submitted generation mismatch"
        end
      end

      def validate_owned!(artifact, type, run_id, evaluation_id)
        @store.value(artifact)
        unless artifact.fetch("type") == type && artifact.fetch("run_id") == run_id &&
            artifact.fetch("step_id") == "evaluation" && artifact.fetch("attempt") == 1 &&
            artifact.fetch("metadata") == {"evaluation_id" => evaluation_id}
          raise Error, "evaluation evidence identity mismatch"
        end
      end

      def persist(type, value, run_id, metadata, inputs = [])
        @store.put(type: type, value: value, run_id: run_id, step_id: "evaluation",
          attempt: 1, inputs: inputs, metadata: metadata)
      end

      def classify(execution)
        raise Error, "invalid evaluation execution" unless execution.is_a?(Hash)
        status = execution["status"]
        return ["not_evaluated", status] if %w[timeout cancelled].include?(status)
        return ["not_evaluated", "error"] unless ["success", "failure"].include?(status)
        return ["not_evaluated", "error"] if execution["stdout_truncated"] || execution["stderr_truncated"]
        stdout = execution["stdout"]
        return ["not_evaluated", "error"] unless stdout.is_a?(String)
        markers = stdout.lines.grep(/^AGRU_VERDICT=/)
        return ["not_evaluated", "error"] unless markers.length == 1
        result = JSON.parse(markers.first.delete_prefix("AGRU_VERDICT="))
        return ["not_evaluated", "error"] unless result.is_a?(Hash)
        verdict = result["verdict"]
        valid = (verdict == "pass" && execution["exit_code"] == 0 && status == "success") ||
          (verdict == "fail" && execution["exit_code"] == 1 && status == "failure")
        valid ? [verdict, "completed"] : ["not_evaluated", "error"]
      rescue JSON::ParserError
        ["not_evaluated", "error"]
      end
    end
  end
end
