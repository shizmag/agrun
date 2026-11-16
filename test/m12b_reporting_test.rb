require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/summary"

# Proposed additive M1.2b projection contract, pending parent/adapter review.
# Native step_finish has no provider/model/route observation. Requested profile
# and adapter-authored normalized copies cannot establish observed identity.
class M12bReportingTest < Minitest::Test
  def test_identity_evidence_and_accounting_scope_are_explicit_and_additive
    events = [
      {"type" => "step_finish", "part" => {"providerID" => "gateway", "modelID" => "alias"}},
      {"type" => "step_finish", "part" => {"modelID" => "other"}},
      {"type" => "tool_use", "part" => {"tool" => "read"}},
      {"type" => "tool_use", "part" => {"tool" => "read"}}
    ]
    summary = AgentRuntime::Execution::Summary.telemetry({"model_profile" => {"provider" => "requested", "model" => "configured"}}, events)
    evidence = summary.fetch("model_identity_evidence")
    assert_equal "model_profile", evidence.dig("requested", "source")
    assert_equal "configured", evidence.dig("requested", "identity", "model")
    assert_equal "native_root_step", evidence.dig("cli_observed", "source")
    assert_equal ["alias", "other"], evidence.dig("cli_observed", "observations").map { |item| item["model"] }
    %w[gateway_resolved served_attested].each do |layer|
      assert_equal({"status" => "unknown", "source" => "unavailable", "identity" => nil}, evidence.fetch(layer))
    end
    assert_equal 2, summary.dig("counts", "root_step_observations")
    assert_equal 2, summary.dig("counts", "tool_event_observations")
    assert_equal "unknown", summary.dig("identity", "verification")
    assert_equal "solver_only", summary.dig("accounting_coverage", "usage_scope")
    assert_equal "unknown", summary.dig("accounting_coverage", "grader_overhead")
    assert_equal "unavailable_in_execution_evidence", summary.dig("accounting_coverage", "grader_overhead_source")
  end

  def test_empty_identity_evidence_does_not_invent_observations
    summary = AgentRuntime::Execution::Summary.telemetry({}, [])
    assert_equal "unknown", summary.dig("model_identity_evidence", "requested", "status")
    assert_equal "unknown", summary.dig("model_identity_evidence", "cli_observed", "status")
    assert_empty summary.dig("model_identity_evidence", "cli_observed", "observations")
  end

  def test_requested_identity_is_not_reported_as_actual_observed_identity
    with_summary do |summary|
      assert_equal({"provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "route" => "cx/gpt-6-luna-low", "endpoint" => "http://127.0.0.1:4141/v1"}, summary.dig("identity", "requested"))
      assert_equal({"provider" => nil, "model" => nil, "route" => nil}, summary.dig("identity", "observed"))
      assert_equal "unknown", summary.dig("identity", "verification")
      assert_equal "unknown", summary.dig("identity", "discrepancy")
    end
  end

  def test_observed_identity_cannot_be_forged_by_cached_normalized_evidence
    with_summary do |summary|
      assert_nil summary.dig("identity", "observed", "provider")
      assert_nil summary.dig("identity", "observed", "model")
      assert_nil summary.dig("identity", "observed", "route")
      assert_equal "native_root_step", summary.dig("identity", "observation_basis")
    end
  end

  def test_partial_root_usage_and_unobserved_auxiliary_work_stay_explicit
    with_summary do |summary|
      assert_equal false, summary.dig("accounting_coverage", "complete")
      assert_equal "partial", summary.dig("accounting_coverage", "root_steps")
      %w[auxiliary_usage title_usage compaction_usage child_usage provider_requests provider_retries provider_charges].each do |category|
        assert_equal "unknown", summary.dig("accounting_coverage", category), category
      end
      assert_equal false, summary.dig("completion", "accounting_complete")
      assert_nil summary.dig("usage", "tokens", "input", "total")
    end
  end

  def test_raw_events_deduplicate_without_trusting_persisted_usage_or_compact_report
    with_summary do |summary|
      assert_equal 11, summary.dig("usage", "tokens", "input", "known_subtotal")
      assert_equal 7, summary.dig("usage", "tokens", "output", "known_subtotal")
      assert_equal "native_root_step", summary.dig("identity", "observation_basis")
      refute summary.key?("events")
    end
  end

  def test_cli_native_cost_is_opaque_not_a_charge_and_missing_estimate_is_unknown
    with_summary do |summary|
      assert_nil summary["cost"]
      assert_equal [0.25], summary.fetch("native_cost_observations").map { |cost| cost.fetch("value") }.uniq
      assert_equal ["opaque_cli"], summary.fetch("native_cost_observations").map { |cost| cost.fetch("provenance") }.uniq
      assert_equal "unknown", summary.dig("cost_evidence", "actual_charge_status")
      assert_nil summary.dig("cost_evidence", "actual_charge")
      assert_nil summary.dig("cost_evidence", "estimate")
    end
  end

  def test_raw_stdout_overrides_copied_events_for_observed_identity_and_usage
    with_summary(stdout_identity: true) do |summary|
      assert_equal "native-provider", summary.dig("identity", "observed", "provider")
      assert_equal "native-model", summary.dig("identity", "observed", "model")
      assert_nil summary.dig("identity", "observed", "route")
      assert_equal 2, summary.dig("usage", "tokens", "input", "known_subtotal")
      assert_equal "unknown", summary.dig("identity", "verification")
      assert_equal "observed_requested_mismatch", summary.dig("identity", "discrepancy")
      assert_equal %w[provider model], summary.dig("identity", "mismatched_fields")
    end
  end

  def test_mixed_identity_is_unknown_and_malformed_protocol_cannot_establish_observation
    with_summary(stdout_identity: true, conflicting_identity: true) do |summary|
      assert_nil summary.dig("identity", "observed", "provider")
      assert_nil summary.dig("identity", "observed", "model")
      assert_nil summary.dig("identity", "observed", "route")
    end
    with_summary(stdout_identity: true, malformed: true) do |summary|
      refute_nil summary["protocol_error"]
      assert_equal({"provider" => nil, "model" => nil, "route" => nil}, summary.dig("identity", "observed"))
      assert_equal "unknown", summary.dig("accounting_coverage", "root_steps")
    end
  end

  def test_canonical_tool_policy_route_and_endpoint_take_precedence_over_legacy_fields
    summary = AgentRuntime::Execution::Summary.telemetry({"model_profile" => {
      "provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "route" => "legacy-route", "endpoint" => "legacy-endpoint",
      "tool_policy" => {"route" => "canonical-route", "endpoint" => "canonical-endpoint"}
    }}, [])
    assert_equal "canonical-route", summary.dig("identity", "requested", "route")
    assert_equal "canonical-endpoint", summary.dig("identity", "requested", "endpoint")
    legacy = AgentRuntime::Execution::Summary.telemetry({"model_profile" => {"route" => "legacy-route", "endpoint" => "legacy-endpoint"}}, [])
    assert_equal "legacy-route", legacy.dig("identity", "requested", "route")
    assert_equal "legacy-endpoint", legacy.dig("identity", "requested", "endpoint")
  end

  def test_report_rendering_reconstructs_attempt_telemetry_without_mutating_store
    require_relative "../lib/agent_runtime/benchmarks/reports"
    with_summary do |_summary, store, persisted|
      store.save_report({"run_id" => "solver-run", "status" => "success", "steps" => {"work" => {"status" => "success", "attempts" => [persisted]}}})
      experiment = {"run_id" => "experiment", "manifest" => {"repetitions" => 1}, "cells" => [{"id" => "one", "solver_id" => "offline", "task_id" => "synthetic", "repetition" => 1, "status" => "failed", "execution_status" => "failure", "execution" => {"run_id" => "solver-run"}}]}
      store.save_report(experiment)
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      json = JSON.parse(reports.render(experiment_id: "experiment", format: "json"))
      execution = json.fetch("cells").first.fetch("execution")
      observed = execution.dig("steps", "work", "attempts", 0, "identity", "observed")
      assert_equal({"provider" => nil, "model" => nil, "route" => nil}, observed)
      csv = reports.render(experiment_id: "experiment", format: "csv")
      assert_includes csv, JSON.generate(execution).gsub('"', '""')
      markdown = reports.render(experiment_id: "experiment", format: "markdown")
      assert_includes markdown, "not_provider_billing"
      refute_includes markdown, "must-not-render"
      assert_equal experiment, store.report("experiment")
    end
  end

  def test_cleanup_failure_classifications_survive_reconstruction_without_messages
    with_summary(cleanup_failure: true) do |summary, store, persisted|
      expected = {"status" => "failure", "reaped" => false,
                  "errors" => [{"operation" => "reap", "class" => "RuntimeError"}]}
      assert_equal expected, summary.fetch("process_cleanup")
      assert_equal({"status" => "failure", "errors" => [{"type" => "artifact_collection"}]}, summary.fetch("cleanup"))
      assert_equal "failure", summary.fetch("outcome")
      refute_includes JSON.generate(summary), "secret-cleanup-message"
      store.save_report({"run_id" => "cleanup-run", "status" => "failure", "steps" => {"work" => {"status" => "failure", "attempts" => [persisted]}}})
      reconstructed = AgentRuntime::Execution::Summary.from_run(store: AgentRuntime::Store.new(store.root), run_id: "cleanup-run")
      assert_equal expected, reconstructed.dig("steps", "work", "attempts", 0, "process_cleanup")
    end
  end

  def test_live_qualification_metadata_survives_reload_without_becoming_observation
    with_summary do |summary|
      assert_equal "authorized", summary.dig("preflight", "status")
      assert_equal "unknown", summary.dig("identity", "verification")
      assert_equal false, summary.dig("accounting_coverage", "complete")
      refute summary.fetch("preflight").key?("api_key")
      refute summary.fetch("preflight").key?("environment")
    end
  end

  def test_missing_tokens_are_unknown_not_zero_even_with_successful_process
    with_summary(tokens: {}) do |summary|
      assert_nil summary.dig("usage", "tokens", "input", "total")
      assert_equal "partial", summary.dig("accounting_coverage", "root_steps")
      assert_equal "unknown", summary.dig("identity", "verification")
    end
  end

  private

  def with_summary(stdout_identity: false, conflicting_identity: false, malformed: false, cleanup_failure: false, tokens: {"input" => 11, "output" => 7, "reasoning" => 0, "cache" => {"read" => 3, "write" => 2}})
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      event = {"type" => "step_finish", "sessionID" => "ses_reporting", "part" => {
        "id" => "part_reporting", "messageID" => "msg_reporting", "sessionID" => "ses_reporting",
        "type" => "step-finish", "reason" => "stop", "tokens" => tokens, "cost" => 0.25
      }}
      requested = {"provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "route" => "cx/gpt-6-luna-low"}
      evidence = {"schema_version" => "m12a-execution-v1", "attempt_id" => "reporting-attempt", "launch_observed" => true,
                  "model_profile" => requested.except("route").merge("execution_kind" => "real_provider", "tool_policy" => {"route" => requested.fetch("route"), "endpoint" => "http://127.0.0.1:4141/v1"}),
                  "identity" => {"requested_provider" => requested["provider"], "requested_model" => requested["model"], "requested_route" => requested["route"]},
                  "admission" => {"allowed" => true, "authorization" => {"status" => "authorized", "financial_exposure" => "unbounded_by_operator"}},
                  "preflight" => {"status" => "authorized", "api_key" => "must-not-render", "environment" => {"TOKEN" => "must-not-render"}},
                  "observed_identity" => {"provider" => "forged-provider", "model" => "forged-model", "route" => "forged-route"},
                  "usage" => {"input_tokens" => 999_999}, "requests" => [{"provider" => "forged-provider", "model" => "forged-model"}],
                  "events" => [event, event], "process" => {"status" => "success", "exit_code" => 0}}
      if cleanup_failure
        evidence["cleanup"] = {"errors" => [{"type" => "artifact_collection", "message" => "secret-cleanup-message"}]}
        evidence.fetch("process")["cleanup"] = {"reaped" => false, "errors" => [{"operation" => "reap", "class" => "RuntimeError", "message" => "secret-cleanup-message"}]}
      end
      if stdout_identity
        native = JSON.parse(JSON.generate(event))
        native.fetch("part").merge!("providerID" => "native-provider", "modelID" => "native-model", "tokens" => tokens.merge("input" => 2))
        evidence.fetch("process")["stdout"] = JSON.generate(native)
        if conflicting_identity
          native.fetch("part").merge!("id" => "part_other", "messageID" => "msg_other", "providerID" => "other-provider", "modelID" => "other-model")
          evidence.fetch("process")["stdout"] += "\n" + JSON.generate(native)
        end
        evidence.fetch("process")["stdout"] += "\ninvalid json" if malformed
      end
      log = store.put(type: "text", value: JSON.generate("execution" => evidence), run_id: "reporting-run", step_id: "work", attempt: 1)
      attempt = {"attempt" => 1, "status" => "success", "log" => log,
                 "execution" => {"evidence" => log.fetch("id"), "usage" => {"input_tokens" => 777_777}}}
      store.save_report({"run_id" => "reporting-run", "status" => "success", "steps" => {"work" => {"attempts" => [attempt]}}})
      reloaded = AgentRuntime::Store.new(root)
      persisted = reloaded.report("reporting-run").fetch("steps").fetch("work").fetch("attempts").fetch(0)
      yield AgentRuntime::Execution::Summary.from_attempt(store: reloaded, attempt: persisted), reloaded, persisted
    end
  end
end
