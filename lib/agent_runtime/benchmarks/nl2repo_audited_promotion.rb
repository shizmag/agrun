require "digest"

module AgentRuntime
  module Benchmarks
    # Scoped quality policy. Only an injected transport's single-use receipt can
    # enter this boundary; structured-looking candidate output is not a receipt.
    class NL2RepoAuditedPromotion
      SOURCE_PATH = File.expand_path(__FILE__).freeze
      SOURCE_SHA256 = Digest::SHA256.file(SOURCE_PATH).hexdigest.freeze
      PROTOCOL = "nl2repo-audited-v2"
      OUTCOMES = %w[passed failed error skipped xfailed xpassed].freeze

      def initialize(transport:)
        @transport = transport
      end

      def call(request:, evidence:)
        record = @transport.consume_evidence(request: request, evidence: evidence)
        return unavailable("unissued or replayed transport evidence", category: "protocol_violation") unless record.is_a?(Hash)
        execution = record["execution_status"]
        return unavailable(record["error"] || "evaluation did not complete", execution) unless execution == "success"
        return unavailable("unsupported audited protocol", execution, category: "protocol_violation") unless record["protocol"] == PROTOCOL
        expected = request["audited_binding"]
        unless expected.is_a?(Hash) && !expected.empty? &&
            expected["submission_digest"] == request["submission_digest"] &&
            record["expected_binding"] == expected && record["binding"] == expected
          return unavailable("audited binding mismatch", execution, category: "protocol_violation")
        end
        ids = request["expected_nodeids"]
        unless ids.is_a?(Array) && !ids.empty? && ids.all? { |id| id.is_a?(String) && !id.empty? } &&
            ids.uniq == ids && record["expected_nodeids"] == ids
          return unavailable("invalid frozen case inventory", execution, category: "protocol_violation")
        end
        reference = record["reference"]
        unless complete?(reference, ids) && reference["tests"].values.all? { |outcome| outcome == "passed" }
          category = complete?(reference, ids) ? "infrastructure" : evidence_failure_category(reference)
          return unavailable("fresh reference preflight did not pass", execution, category: category)
        end
        candidate = record["candidate"]
        if complete?(candidate, ids)
          passed = candidate["tests"].values.count("passed")
          basis = "validated_quality_result"
        elsif absent_candidate?(request, record)
          passed = 0
          basis = "candidate_collection_failure"
        else
          return unavailable("incomplete or ambiguously attributed candidate results", execution,
            category: evidence_failure_category(candidate))
        end
        {"status" => "success", "execution_status" => execution,
         "verdict" => (passed == ids.length) ? "pass" : "fail", "trust" => "audited",
         "trust_scope" => "benign_ordinary_submissions", "protocol" => PROTOCOL,
         "quality_basis" => basis, "score" => passed.fdiv(ids.length),
         "passed" => passed, "total" => ids.length,
         "expected" => ids.length, "collected" => (basis == "candidate_collection_failure") ? 0 : ids.length,
         "executed" => (basis == "candidate_collection_failure") ? 0 : candidate["executed"],
         "failed" => (basis == "candidate_collection_failure") ? 0 : candidate["counts"]["failed"] + candidate["counts"]["error"],
         "skipped" => (basis == "candidate_collection_failure") ? 0 : candidate["counts"]["skipped"],
         "artifacts" => record["artifacts"] || record.slice("candidate_evidence", "reference_evidence")}
      end

      private

      def complete?(result, ids)
        return false unless result.is_a?(Hash) && result["status"] == "valid"
        tests = result["tests"]
        counts = result["counts"]
        tests.is_a?(Hash) && tests.keys.sort == ids.sort && tests.values.all? { |outcome| OUTCOMES.include?(outcome) } &&
          result["executed"].is_a?(Integer) && (0..ids.length).cover?(result["executed"]) &&
          counts.is_a?(Hash) && counts.keys.sort == OUTCOMES.sort &&
          OUTCOMES.all? { |outcome| counts[outcome].is_a?(Integer) && counts[outcome] == tests.values.count(outcome) }
      end

      def absent_candidate?(request, record)
        return false unless request["task_id"] == "retrying"
        inventory = record["candidate_inventory"]
        return false unless inventory.is_a?(Hash) && inventory["submission_digest"] == request["submission_digest"] &&
          inventory["missing_required_module"] == true && inventory["checked_paths"] == %w[retrying.py retrying]
        candidate = record["candidate"]
        return false unless candidate.is_a?(Hash) && candidate["status"] == "collection_failure"
        return false if candidate.key?("tests") || candidate.key?("counts")
        return false unless candidate["collected"] == []
        errors = candidate["collection_errors"]
        errors.is_a?(Array) && !errors.empty? && errors.all? do |error|
          next false unless error.is_a?(Hash)
          exception = error["exception"]
          error["nodeid"] == "test_retrying.py" && exception.is_a?(Hash) &&
            exception["type"] == "ModuleNotFoundError" && exception["module"] == "retrying" &&
            exception["frames"].is_a?(Array) && !exception["frames"].empty?
        end
      end

      def evidence_failure_category(result)
        (result.is_a?(Hash) && result["status"] == "invalid") ? "protocol_violation" : "unavailable"
      end

      def unavailable(reason, execution = "unavailable", category: "unavailable")
        {"status" => "unavailable", "execution_status" => execution,
         "protocol" => PROTOCOL, "failure_category" => category, "quality_basis" => nil,
         "verdict" => "untrusted", "trust" => "untrusted", "score" => nil, "reason" => reason}
      end
    end
  end
end
