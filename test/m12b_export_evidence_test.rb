require_relative "test_helper"
require_relative "../script/m12b_export_evidence"

class M12bExportEvidenceTest < Minitest::Test
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
