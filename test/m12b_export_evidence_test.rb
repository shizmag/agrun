require_relative "test_helper"
require_relative "../script/m12b_export_evidence"

class M12bExportEvidenceTest < Minitest::Test
  def test_actual_cli_experiment_report_shape_preserves_predispatch_evidence
    # ExperimentReport's per-task analytical projection, not runner cells.
    report = {"experiment_id" => "first", "manifest" => {"execution_mode" => "live", "models" => [{"model_profile" => {"provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "tool_policy" => {"executable" => "/secret/bin", "endpoint" => "http://secret"}}}]},
              "per_task_results" => {"retrying" => [{"execution_status" => "error", "score" => nil, "solver_status" => "blocked", "execution" => {"invocation_count" => 0, "steps" => {"solve" => {"attempts" => [{"evidence" => "75634277-efa6-45b9-b417-7984f67aec07", "launch_observed" => false, "admission" => {"admitted" => false, "reason" => "invalid_configuration"}}]}}}}]},
              "execution_counts" => {"planned" => 1, "failed" => 1, "by_status" => {"error" => 1}}, "evaluation_completion" => {"completed" => 0, "planned" => 1, "fraction" => 0.0}}
    exported = M12bExportEvidence.export(report)
    assert_equal "first", exported.dig("report", "experiment_id")
    assert_equal 0, exported.dig("report", "per_task_results", "retrying", 0, "execution", "invocation_count")
    assert_equal false, exported.dig("report", "per_task_results", "retrying", 0, "execution", "steps", "solve", "attempts", 0, "launch_observed")
    assert_equal 1, exported.dig("report", "execution_counts", "by_status", "error")
    assert_equal "not_resolved_from_report", exported.dig("raw_artifact_digests", "status")
    refute_includes JSON.generate(exported), "secret"
    refute_includes JSON.generate(exported), "75634277"
  end

  def test_export_is_deterministic_allowlisted_and_does_not_mutate_input
    digest = "a" * 64
    report = {"run_id" => "pilot", "manifest_digest" => digest, "api_key" => "secret", "cells" => [{
      "task_id" => "retrying", "score" => 3.0 / 23, "passed" => 3, "total" => 23,
      "execution" => {"steps" => {"solve" => {"attempts" => [{"evidence" => digest,
                                                              "identity" => {"requested" => {"model" => "cx/gpt-6-luna-low", "endpoint" => "http://secret"}, "observed" => {"model" => nil}},
                                                              "cleanup" => {"status" => "failure", "errors" => [{"operation" => "reap", "message" => "secret"}]},
                                                              "stdout" => "secret", "workspace" => "/secret/path", "hidden_tests" => "secret"}]}}}
    }]}
    before = JSON.generate(report)
    exported = M12bExportEvidence.export(report)
    assert_equal exported, M12bExportEvidence.export(report.to_a.reverse.to_h)
    assert_equal before, JSON.generate(report)
    assert_equal digest, exported.dig("report", "manifest_digest")
    assert_equal 3, exported.dig("report", "cells", 0, "passed")
    assert_equal digest, exported.dig("report", "cells", 0, "execution", "steps", "solve", "attempts", 0, "evidence")
    refute_includes JSON.generate(exported), "secret"
    refute_includes JSON.generate(exported), "hidden_tests"
  end
end
