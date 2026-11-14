require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/audited_results"

# Independent contract fixtures: these are not produced by the collector under test.
class NL2RepoAuditedResultsTest < Minitest::Test
  SUBJECT = AgentRuntime::Benchmarks::AuditedResults
  NODEIDS = ["test_retrying.py::TestRetrying::test_stop[one]", "test_retrying.py::TestRetrying::test_stop[two]"].freeze
  BINDING = {"submission_digest" => "a" * 64, "specification_digest" => "b" * 64,
             "procedure_digest" => "c" * 64, "environment_digest" => "d" * 64,
             "collector_digest" => "e" * 64}.freeze
  OUTCOMES = %w[passed failed error skipped xfailed xpassed].freeze

  def report(phase, outcome = "passed", **extra)
    {"when" => phase, "outcome" => outcome}.merge(extra.transform_keys(&:to_s))
  end

  def document
    {"schema" => "agru.pytest-results.v1", "pytest_version" => "8.4.1", "binding" => BINDING.dup,
     "collected" => NODEIDS.dup, "collection_errors" => [], "tests" => NODEIDS.map { |nodeid|
       {"nodeid" => nodeid, "reports" => [report("setup"), report("call"), report("teardown")]}
     }, "exit_code" => 0, "finished" => true}
  end

  def parse(doc = document, bytes: nil, process: {}, expected_nodeids: NODEIDS, expected_binding: BINDING)
    code = doc.fetch("exit_code", 0)
    SUBJECT.parse(bytes: bytes || JSON.generate(doc), expected_nodeids: expected_nodeids,
      expected_binding: expected_binding,
      process: {"status" => (code == 0) ? "success" : "failure", "exit_code" => code,
                "stdout_truncated" => false, "stderr_truncated" => false}.merge(process))
  end

  def assert_invalid(result)
    assert_equal "invalid", result.fetch("status")
    refute_empty result.fetch("reason")
    refute result.key?("tests"), "invalid evidence must not leak partial outcomes"
    refute result.key?("counts"), "invalid evidence must not leak partial counts"
  end

  def test_exact_nodeids_and_all_phase_outcomes_produce_scoreless_evidence
    result = parse
    assert_equal "valid", result.fetch("status")
    assert_equal NODEIDS.to_h { |id| [id, "passed"] }, result.fetch("tests")
    assert_equal 2, result.fetch("executed")
    assert_equal OUTCOMES.to_h { |outcome| [outcome, (outcome == "passed") ? 2 : 0] }, result.fetch("counts")
    refute result.key?("score")
    refute result.key?("result_authority")
    refute result.key?("verdict")
  end

  def test_collection_order_is_not_identity
    doc = document
    doc["collected"].reverse!
    doc["tests"].reverse!
    assert_equal "valid", parse(doc).fetch("status")
  end

  def test_identity_is_complete_unique_and_not_a_junit_name_projection
    %w[missing extra duplicate renamed].each do |mutation|
      doc = document
      case mutation
      when "missing" then doc["tests"].pop
      when "extra" then doc["tests"] << {"nodeid" => "test_other.py::test_stop[one]", "reports" => []}
      when "duplicate" then doc["tests"][1] = doc["tests"][0]
      when "renamed" then doc["tests"][0]["nodeid"] = "TestRetrying.test_stop"
      end
      assert_invalid parse(doc)
    end
    doc = document
    doc["collected"] = [NODEIDS.first, NODEIDS.first]
    assert_invalid parse(doc)
    assert_invalid parse(expected_nodeids: [NODEIDS.first, NODEIDS.first])
    assert_invalid parse(expected_nodeids: [])
  end

  def test_native_skip_xfail_and_nonstrict_xpass_are_distinct_from_passed
    [[report("call", "skipped"), "skipped"],
      [report("call", "skipped", wasxfail: "known defect"), "xfailed"],
      [report("call", "passed", wasxfail: "unexpected fix"), "xpassed"]].each do |phase, expected|
      doc = document
      doc["tests"][0]["reports"][1] = phase
      result = parse(doc)
      assert_equal "valid", result.fetch("status")
      assert_equal expected, result.fetch("tests").fetch(NODEIDS.first)
      assert_equal 1, result.fetch("counts").fetch("passed")
    end
  end

  def test_setup_xfail_has_no_call_but_still_has_teardown
    doc = document
    doc["tests"][0]["reports"] = [report("setup", "skipped", wasxfail: "fixture defect"), report("teardown")]
    result = parse(doc)
    assert_equal "valid", result.fetch("status")
    assert_equal "xfailed", result.fetch("tests").fetch(NODEIDS.first)
    assert_equal 1, result.fetch("executed"), "setup xfail has no call phase"
  end

  def test_failed_call_including_strict_xpass_is_a_test_failure_not_transport_error
    doc = document
    doc["tests"][0]["reports"][1] = report("call", "failed")
    doc["exit_code"] = 1
    result = parse(doc)
    assert_equal "valid", result.fetch("status")
    assert_equal "failed", result.fetch("tests").fetch(NODEIDS.first)
  end

  def test_fixture_failure_overrides_a_successful_or_xfailed_call
    [report("call"), report("call", "skipped", wasxfail: "known defect")].each do |call|
      doc = document
      doc["tests"][0]["reports"] = [report("setup"), call, report("teardown", "failed")]
      doc["exit_code"] = 1
      result = parse(doc)
      assert_equal "valid", result.fetch("status")
      assert_equal "error", result.fetch("tests").fetch(NODEIDS.first)
    end
    doc = document
    doc["tests"][0]["reports"] = [report("setup", "failed"), report("teardown")]
    doc["exit_code"] = 1
    assert_equal "error", parse(doc).fetch("tests").fetch(NODEIDS.first)
  end

  def test_phase_reports_must_be_complete_unique_ordered_and_coherent
    [[], [report("setup"), report("call")], [report("setup"), report("teardown")],
      [report("setup"), report("call"), report("call"), report("teardown")],
      [report("call"), report("setup"), report("teardown")],
      [report("setup", "skipped"), report("call"), report("teardown")],
      [report("setup"), report("call", "unknown"), report("teardown")],
      [report("setup", "passed", wasxfail: "invalid"), report("call"), report("teardown")]].each do |reports|
      doc = document
      doc["tests"][0]["reports"] = reports
      assert_invalid parse(doc)
    end
  end

  def test_collection_errors_and_incomplete_sessions_reject_even_complete_passes
    doc = document
    doc["collection_errors"] = ["test_broken.py"]
    assert_invalid parse(doc)
    doc = document
    doc["finished"] = false
    assert_invalid parse(doc)
  end

  def test_structured_collection_failure_preserves_exception_without_partial_score
    [1, 2].each do |exit_code|
      doc = document
      doc["collected"] = []
      doc["tests"] = []
      doc["exit_code"] = exit_code
      doc["collection_errors"] = [{"nodeid" => "test_retrying.py", "exception" => {
        "type" => "ModuleNotFoundError", "module" => "retrying", "message" => "No module named 'retrying'",
        "frames" => [{"path" => "/candidate/test_retrying.py", "lineno" => 7, "name" => "<module>"}]
      }}]
      result = parse(doc)
      assert_equal "collection_failure", result.fetch("status")
      assert_equal doc.fetch("collection_errors"), result.fetch("collection_errors")
      assert_equal [], result.fetch("collected")
      refute result.key?("tests")
      refute result.key?("counts")
      refute result.key?("score")
      refute result.key?("candidate_failure")
    end
  end

  def test_binding_and_collector_runtime_are_exact
    doc = document
    doc["binding"]["submission_digest"] = "f" * 64
    assert_invalid parse(doc)
    doc = document
    doc["pytest_version"] = "8.4.2"
    assert_invalid parse(doc)
    doc = document
    doc["schema"] = "agru.pytest-results.v2"
    assert_invalid parse(doc)
  end

  def test_exit_status_must_match_reports_and_real_process
    [1, 2, 3, 4, 5, nil, "0"].each do |code|
      doc = document
      doc["exit_code"] = code
      assert_invalid parse(doc)
    end
    assert_invalid parse(process: {"exit_code" => 1})
    assert_invalid parse(process: {"status" => "failure"})
    doc = document
    doc["tests"][0]["reports"][1] = report("call", "failed")
    assert_invalid parse(doc)
  end

  def test_transport_failures_and_truncation_cannot_establish_evidence
    %w[timeout cancelled unknown blocked].each do |status|
      assert_invalid parse(process: {"status" => status})
    end
    %w[stdout_truncated stderr_truncated].each do |flag|
      assert_invalid parse(process: {flag => true})
    end
  end

  def test_corrupt_truncated_duplicate_key_and_oversize_documents_fail_closed
    ["", "{}", "[]", JSON.generate(document)[0...-1], JSON.generate(document) + "junk",
      "{\"schema\":\"wrong\",\"schema\":\"agru.pytest-results.v1\"}",
      "\xFF".b, " " * (4 * 1024 * 1024 + 1)].each do |bytes|
      assert_invalid parse(bytes: bytes)
    end
    doc = document
    doc["score"] = 1
    assert_invalid parse(doc)
  end

  def test_duplicate_keys_cannot_override_otherwise_valid_protocol_fields
    bytes = JSON.generate(document)
    assert_invalid parse(bytes: bytes.sub('"finished":true', '"finished":false,"finished":true'))
    assert_invalid parse(bytes: bytes.sub('"outcome":"passed"', '"outcome":"failed","outcome":"passed"'))
    assert_invalid parse(process: {"exit_code" => 0.0})
  end

  def test_collection_failure_metadata_must_be_structured_and_transport_complete
    doc = document
    doc["collected"] = []
    doc["tests"] = []
    doc["exit_code"] = 2
    error = {"nodeid" => "test_retrying.py", "exception" => {
      "type" => "ModuleNotFoundError", "module" => "retrying", "message" => "missing",
      "frames" => [{"path" => "/candidate/test_retrying.py", "lineno" => 1, "name" => "<module>"}]
    }}
    doc["collection_errors"] = [error]
    assert_invalid parse(doc, process: {"status" => "timeout"})
    assert_invalid parse(doc, process: {"stderr_truncated" => true})
    doc["collection_errors"] = [error, error]
    assert_invalid parse(doc)
    doc["collection_errors"] = [error]
    error["exception"]["frames"] = []
    assert_invalid parse(doc)
  end

  def test_collection_failure_still_requires_unique_authorized_collection_identity
    doc = document
    doc["exit_code"] = 2
    doc["collection_errors"] = [{"nodeid" => "test_broken.py", "exception" => {
      "type" => "SyntaxError", "module" => nil, "message" => "syntax error",
      "frames" => [{"path" => "/private/test_broken.py", "lineno" => 1, "name" => "<module>"}]
    }}]
    doc["tests"] = [doc["tests"].first]
    doc["collected"] = [NODEIDS.first, NODEIDS.first]
    assert_invalid parse(doc)
    doc["collected"] = [NODEIDS.first, "test_unauthorized.py::test_injected"]
    assert_invalid parse(doc)
    doc["collected"] = [NODEIDS.first]
    result = parse(doc)
    assert_equal "collection_failure", result.fetch("status")
    assert_equal [NODEIDS.first], result.fetch("collected")
    refute result.key?("tests")
    refute result.key?("counts")
  end

  def test_stdout_claims_are_not_test_results
    result = parse(process: {"stdout" => "999 passed, 0 failed\n", "stderr" => "1 failed\n"})
    assert_equal 2, result.fetch("counts").fetch("passed")
  end
end
