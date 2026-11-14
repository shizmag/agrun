require_relative "adapter"

module AgentRuntime
  module Benchmarks
    # This checks fixture data, never Ruby or shell code from a submission.
    class FixtureAdapter < Adapter
      REVISION = "fixture-v1".freeze
      PROCEDURE = {"version" => 1, "operation" => "read answer.json score", "allowed_scores" => [0, 0.5, 1]}.freeze

      def initialize(store:)
        @store = store
        @requests = {}
      end

      def identity
        Adapter.freeze_json({"name" => "fixture", "revision" => REVISION, "provenance" => "fixture"})
      end

      def list_tasks
        %w[zero half one failure unavailable].map { |id| load_task(id) }
      end

      def load_task(id)
        raise KeyError, "unknown fixture task #{id}" unless %w[zero half one failure unavailable].include?(id)
        task = {"id" => id, "benchmark" => "fixture", "instruction" => "Write answer.json with fixture score (0, 0.5 or 1).",
                "specification_digest" => IR.digest(specification(id)), "metadata" => {"provenance" => "fixture"},
                "availability" => (id == "unavailable") ? "unavailable" : "available"}
        task["unavailable_reason"] = "fixture intentionally unavailable" if id == "unavailable"
        Adapter.public_task(task)
      end

      def prepare_solver_workspace(task:, workspace:)
        validate_task!(task)
        repository = File.join(File.expand_path(workspace), "repository")
        FileUtils.mkdir_p(repository)
        {"repository" => repository}
      end

      def prepare_grading_request(task:, submission:, limits:)
        validate_task!(task)
        artifact = submission.is_a?(String) ? @store.artifact(submission) : submission
        raise ArgumentError, "submission must be a Store repository artifact" unless artifact.is_a?(Hash) && artifact["type"] == "repository"
        @store.value(artifact)
        spec = persist("json", specification(task.fetch("id")))
        procedure = persist("json", PROCEDURE)
        environment = persist("json", environment_contract)
        raise ArgumentError, "invalid grading limits" unless limits.is_a?(Hash) && limits.values.all? { |limit| limit.is_a?(Numeric) && limit.finite? && limit.positive? }
        request = JSON.parse(IR.dump({"task_id" => task.fetch("id"), "benchmark" => identity,
          "specification_digest" => spec.fetch("digest"), "specification_id" => spec.fetch("id"),
          "submission_id" => artifact.fetch("id"), "submission_digest" => artifact.fetch("digest"),
          "procedure_id" => procedure.fetch("id"), "procedure_digest" => procedure.fetch("digest"),
          "environment_id" => environment.fetch("id"), "environment_digest" => environment.fetch("digest"),
          "limits" => limits}))
        request["request_digest"] = IR.digest(request)
        request = Adapter.freeze_json(request)
        @requests[request.fetch("request_digest")] = request
        request
      end

      def grade_submission(request)
        raise ArgumentError, "unrecognized or modified grading request" unless request.is_a?(Hash) && @requests[request["request_digest"]] == request
        task = load_task(request.fetch("task_id"))
        raise ArgumentError, "grading benchmark mismatch" unless request["benchmark"] == identity
        raise ArgumentError, "grading specification mismatch" unless request["specification_digest"] == task["specification_digest"]
        %w[submission specification procedure environment].each do |kind|
          artifact = @store.artifact(request.fetch("#{kind}_id"))
          raise ArgumentError, "grading #{kind} digest mismatch" unless artifact["digest"] == request["#{kind}_digest"]
          @store.value(artifact)
        end
        raise ArgumentError, "grading procedure mismatch" unless request["procedure_digest"] == IR.digest(PROCEDURE)
        raise ArgumentError, "grading environment mismatch" unless request["environment_digest"] == IR.digest(environment_contract)
        artifact = @store.artifact(request.fetch("submission_id"))
        raise ArgumentError, "submission must be a repository" unless artifact["type"] == "repository"
        if task["id"] == "failure"
          return {"status" => "failure", "score" => nil, "verdict" => "error", "provenance" => "fixture", "error" => "intentional fixture grading failure", "evidence" => request}
        end
        score = Dir.mktmpdir("fixture-grade") do |snapshot|
          source = @store.value(artifact)
          Store.materialize(Store.manifest(source), snapshot)
          raise Error, "fixture snapshot digest mismatch" unless IR.digest(Store.manifest(snapshot)) == artifact["digest"]
          raw = JSON.parse(File.read(File.join(snapshot, "answer.json"))).fetch("score")
          @store.value(artifact)
          raise Error, "fixture snapshot changed" unless IR.digest(Store.manifest(snapshot)) == artifact["digest"]
          normalize_score(raw)
        end
        {"status" => "success", "score" => score, "verdict" => (score >= 1) ? "pass" : "fail", "provenance" => "fixture", "evidence" => request}
      rescue JSON::ParserError, Errno::ENOENT, KeyError => error
        {"status" => "failure", "score" => nil, "verdict" => "error", "provenance" => "fixture", "error" => error.message, "evidence" => request}
      end

      def normalize_score(raw)
        raise ArgumentError, "fixture score must be 0, 0.5 or 1" unless raw.is_a?(Numeric) && raw.finite? && [0, 0.5, 1].include?(raw)
        raw.to_f
      end

      private

      def specification(id)
        {"task_id" => id, "benchmark" => "fixture", "revision" => REVISION, "format" => "answer.json", "scores" => [0, 0.5, 1]}
      end

      def environment_contract
        {"engine" => RUBY_ENGINE, "ruby_version" => RUBY_VERSION, "fixture_protocol" => 1}
      end

      def validate_task!(task)
        raise ArgumentError, "public task mismatch" unless task.is_a?(Hash) && task == load_task(task["id"])
      end

      def persist(type, value)
        @store.put(type: type, value: value, run_id: "fixture-contract", step_id: "grading-contract", attempt: 0)
      end
    end
  end
end
