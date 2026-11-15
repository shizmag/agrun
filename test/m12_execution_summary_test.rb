require_relative "test_helper"

summary_path = File.expand_path("../lib/agent_runtime/execution/summary.rb", __dir__)
require summary_path if File.file?(summary_path)

class M12ExecutionSummaryTest < Minitest::Test
  def test_legacy_attempt_is_unavailable_not_zero
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      summary = summary_api.from_attempt(store: store, attempt: {"attempt" => 1, "status" => "success", "usage" => {"input_tokens" => 999}})
      assert_equal "unavailable", summary.fetch("availability")
      assert_nil summary["usage"]
      assert_nil summary["cost"]
    end
  end

  def test_reconstructs_raw_events_instead_of_trusting_embedded_usage
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      attempt = recorded_attempt(store)
      summary = summary_api.from_attempt(store: store, attempt: attempt)
      assert_equal 11, summary.dig("usage", "tokens", "input", "known_subtotal")
      assert_equal 7, summary.dig("usage", "tokens", "output", "known_subtotal")
      assert_equal 3, summary.dig("usage", "tokens", "cache_read", "known_subtotal")
      assert_equal 2, summary.dig("usage", "tokens", "cache_write", "known_subtotal")
      assert_nil summary.dig("usage", "tokens", "input", "total")
      assert_equal false, summary.dig("usage", "coverage", "complete")
      assert_nil summary["cost"]
      refute_equal true, summary.dig("completion", "session_reported_complete"), "step_finish is a model step, not a native session terminal"
      refute summary.key?("events"), "raw events must not be duplicated in compact summaries"
    end
  end

  def test_rejects_corrupt_log_object_without_repair
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      attempt = recorded_attempt(store)
      path = File.join(root, "objects", attempt.fetch("log").fetch("digest"))
      File.chmod(0o644, path)
      File.binwrite(path, "tampered")
      assert_raises(AgentRuntime::Error) { summary_api.from_attempt(store: store, attempt: attempt) }
      assert_equal "tampered", File.binread(path)
    end
  end

  def test_rejects_missing_log_object_not_legacy_unavailable
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      attempt = recorded_attempt(store)
      File.unlink(File.join(root, "objects", attempt.fetch("log").fetch("digest")))
      assert_raises(AgentRuntime::Error) { summary_api.from_attempt(store: store, attempt: attempt) }
    end
  end

  def test_legacy_run_reopens_without_workspace_and_does_not_fabricate_usage
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      store.save_report({"run_id" => "old-run", "status" => "success", "steps" => {"work" => {"status" => "success", "attempts" => [{"attempt" => 1, "status" => "success"}]}}})
      reopened = AgentRuntime::Store.new(root)
      summary = summary_api.from_run(store: reopened, run_id: "old-run")
      assert_equal "old-run", summary.fetch("run_id")
      assert_equal "unavailable", summary.fetch("availability")
      assert_nil summary["usage"]
      assert_nil summary["cost"]
    end
  end

  def test_unknown_run_is_not_legacy_absence
    in_tmp do |root|
      assert_raises(AgentRuntime::Error) { summary_api.from_run(store: AgentRuntime::Store.new(root), run_id: "missing") }
    end
  end

  def test_reopened_truncated_stream_is_not_reported_complete
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      trace = {"schema_version" => "m12a-execution-v1", "outcome" => "success", "usage" => {"input_tokens" => 999},
               "process" => {"stdout" => '{"type":"step_finish"', "stderr" => "", "exit_code" => 0}}
      log = store.put(type: "text", value: JSON.generate("execution" => trace), run_id: "partial", step_id: "work", attempt: 1)
      attempt = {"attempt" => 1, "status" => "success", "log" => log, "execution" => {"evidence" => log.fetch("id")}}
      summary = summary_api.from_attempt(store: AgentRuntime::Store.new(root), attempt: attempt)
      refute_nil summary["protocol_error"]
      refute_equal "success", summary["outcome"]
      refute_equal true, summary.dig("completion", "operationally_complete")
      assert_nil summary.dig("usage", "tokens", "input", "total")
    end
  end

  def test_process_timeout_overrides_coherent_finish_and_preserves_truncation
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      original = recorded_attempt(store)
      logs = JSON.parse(store.value(original.fetch("log")))
      logs.fetch("execution").fetch("process").merge!("status" => "timeout", "stdout_truncated" => true, "stderr_truncated" => true)
      log = store.put(type: "text", value: JSON.generate(logs), run_id: "timeout", step_id: "work", attempt: 1)
      summary = summary_api.from_attempt(store: store, attempt: {"attempt" => 1, "status" => "timeout", "log" => log, "execution" => {"evidence" => log.fetch("id")}})
      assert_equal "timeout", summary.fetch("outcome")
      assert_equal false, summary.dig("completion", "operationally_complete")
      refute_nil summary["protocol_error"]
    end
  end

  def test_rejected_attempt_without_process_is_inspectable_and_zero_launches
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      trace = {"schema_version" => "m12a-execution-v1", "outcome" => "blocked", "launch_observed" => false, "admission" => {"allowed" => false}}
      log = store.put(type: "text", value: JSON.generate("execution" => trace), run_id: "rejected", step_id: "work", attempt: 1)
      attempt = {"attempt" => 1, "status" => "blocked", "log" => log, "execution" => {"evidence" => log.fetch("id")}}
      store.save_report({"run_id" => "rejected", "status" => "failure", "steps" => {"work" => {"attempts" => [attempt]}}})
      summary = summary_api.from_run(store: AgentRuntime::Store.new(root), run_id: "rejected")
      assert_equal 0, summary.fetch("invocation_count")
      assert_nil summary["usage"]
      assert_equal "blocked", summary.dig("steps", "work", "attempts", 0, "outcome")
    end
  end

  def test_artifact_collection_failure_overrides_successful_native_process
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      original = recorded_attempt(store)
      logs = JSON.parse(store.value(original.fetch("log")))
      trace = logs.fetch("execution")
      trace["outcome"] = "failure"
      trace["cleanup"] = {"errors" => [{"type" => "artifact_collection", "message" => "repository collection failed"}]}
      log = store.put(type: "text", value: JSON.generate(logs), run_id: "artifact-failure", step_id: "work", attempt: 1)
      summary = summary_api.from_attempt(store: store, attempt: {"attempt" => 1, "status" => "failure", "log" => log, "execution" => {"outcome" => "success"}})
      assert_equal "failure", summary.fetch("outcome")
      assert_equal "success", summary.fetch("process_outcome")
      assert_equal "failure", summary.fetch("artifact_status")
      assert_equal false, summary.dig("completion", "operationally_complete")
      assert_equal "artifact_collection", summary.dig("cleanup", "errors", 0, "type")
    end
  end

  private

  def summary_api
    AgentRuntime::Execution::Summary
  end

  def recorded_attempt(store)
    # Independent protocol fixture: one model step with absolute token counts.
    # The intentionally forged normalized usage must never be an aggregation oracle.
    event = {"type" => "step_finish", "sessionID" => "ses-offline", "part" => {"id" => "prt-one", "messageID" => "msg-one", "type" => "step-finish", "sessionID" => "ses-offline", "reason" => "stop", "cost" => 0.25,
                                                                               "tokens" => {"input" => 11, "output" => 7, "reasoning" => 0, "cache" => {"read" => 3, "write" => 2}}}}
    evidence = {"schema_version" => "m12a-execution-v1", "attempt_id" => "offline-1", "session_id" => "ses-offline", "outcome" => "success",
                "events" => [{"sequence" => 1, "raw" => event}, {"sequence" => 2, "raw" => event}], "usage" => {"input_tokens" => 999_999}, "admission" => {"admitted" => true},
                "launch_observed" => true, "process" => {"status" => "success", "stdout" => [event, event].map { |raw| JSON.generate(raw) }.join("\n"), "stderr" => "", "exit_code" => 0}}
    log = store.put(type: "text", value: JSON.generate("execution" => evidence), run_id: "run", step_id: "work", attempt: 1)
    {"attempt" => 1, "status" => "success", "log" => log, "execution" => {"attempt_id" => "offline-1", "evidence" => log.fetch("id")}}
  end
end
