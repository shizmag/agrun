require_relative "../test_helper"
require "open3"

event_stream_path = File.expand_path("../../lib/agent_runtime/execution/event_stream.rb", __dir__)
require event_stream_path if File.exist?(event_stream_path)

class EventStreamTest < Minitest::Test
  SIMULATOR = File.expand_path("../fixtures/m12_fake_opencode.rb", __dir__)

  def parse(scenario = "success", **options)
    stdout, stderr, status = Open3.capture3({"M12_SCENARIO" => scenario}, RbConfig.ruby, SIMULATOR, "run", "--format", "json", "--standalone", "--", "synthetic prompt")
    AgentRuntime::Execution::EventStream.parse(stdout: stdout, stderr: stderr, exit_code: status.exitstatus, **options)
  end

  def test_success_is_operational_not_native_session_or_accounting_completion
    record = parse
    assert_equal "m12a-execution-v1", record.fetch("schema_version")
    assert_equal "success", record.fetch("outcome")
    assert_equal "ses_synthetic", record.fetch("session_id")
    assert_equal "root_steps", record.fetch("accounting_scope")
    assert_equal true, record.fetch("completion").fetch("operationally_complete")
    assert_nil record.fetch("completion").fetch("session_reported_complete")
    assert_equal false, record.fetch("completion").fetch("accounting_complete")
    assert_nil record.fetch("protocol_error")
  end

  def test_canonical_usage_observation_does_not_invent_provider_identity_or_charge
    record = parse
    request = record.fetch("requests").fetch(0)
    assert_equal JSON.generate(["ses_synthetic", "msg_one"]), request.fetch("request_id")
    assert_nil request.fetch("provider")
    assert_nil request.fetch("model")
    assert_nil request.fetch("reported_cost")
    assert_equal "root_step_observation", request.fetch("identity_kind")
    assert_equal "invocation_local", request.fetch("identity_scope")
    assert_equal({"input" => 10, "output" => 3, "reasoning" => 2, "cache_read" => 4, "cache_write" => 1}, request.fetch("tokens"))
    assert_equal "disjoint", request.fetch("input_cache_relation")
    assert_equal "disjoint", request.fetch("output_reasoning_relation")
    assert_equal 0.125, record.fetch("native_cost_observations").fetch(0).fetch("value")
  end

  def test_preserves_duplicate_and_conflicting_observations_for_usage_normalizer
    assert_equal 2, parse("multiple").fetch("requests").length
    assert_equal 2, parse("duplicate").fetch("requests").length
    conflicting = parse("conflict")
    assert_equal 2, conflicting.fetch("requests").length
    assert_equal [0.125, 0.25], conflicting.fetch("native_cost_observations").map { |value| value.fetch("value") }
    # Cost is opaque and not canonical provider-charge evidence, so cost alone
    # cannot manufacture a canonical provider-usage conflict.
    assert_equal conflicting.fetch("requests")[0], conflicting.fetch("requests")[1]
  end

  def test_error_and_nonzero_override_valid_finish
    %w[error nonzero].each do |scenario|
      record = parse(scenario)
      assert_equal "failure", record.fetch("outcome"), scenario
      refute record.fetch("completion").fetch("operationally_complete"), scenario
    end
  end

  def test_timeout_and_cancellation_override_valid_finish
    %w[timeout cancelled].each do |status|
      record = parse(process_status: status)
      assert_equal status, record.fetch("outcome")
      refute record.fetch("completion").fetch("operationally_complete")
    end
  end

  def test_empty_and_text_only_never_complete
    %w[empty text_only].each do |scenario|
      record = parse(scenario)
      assert_equal "unknown", record.fetch("outcome"), scenario
      refute record.fetch("completion").fetch("operationally_complete")
    end
  end

  def test_malformed_nonobject_and_partial_are_protocol_errors
    %w[malformed nonobject partial foreign].each do |scenario|
      record = parse(scenario)
      assert_equal "unknown", record.fetch("outcome"), scenario
      refute_nil record.fetch("protocol_error"), scenario
      refute record.fetch("completion").fetch("operationally_complete"), scenario
    end
  end

  def test_truncated_stdout_cannot_establish_success
    record = parse(stdout_truncated: true)
    assert_equal "unknown", record.fetch("outcome")
    refute_nil record.fetch("protocol_error")
  end

  def test_truncated_stderr_does_not_invalidate_complete_stdout
    assert_equal "success", parse(stderr_truncated: true).fetch("outcome")
  end

  def test_tool_error_is_evidence_not_terminal_execution_failure
    record = parse("tools")
    assert_equal "success", record.fetch("outcome")
    tool = record.fetch("tool_calls").fetch(0)
    assert_equal "call_one", tool.fetch("id")
    assert_equal "prt_tool", tool.fetch("partID")
    assert_equal "error", tool.fetch("state").fetch("status")
  end

  def test_retry_background_and_unknown_extensions_preserve_event_order
    record = parse("retry_background")
    assert_equal %w[step_start retry background_wait step_finish], record.fetch("events").map { |event| event.fetch("type") }
    assert_equal "success", record.fetch("outcome")
    extended = parse("unknown")
    assert_equal "future_extension", extended.fetch("events").last.fetch("type")
    assert_equal "success", extended.fetch("outcome")
  end

  def test_raw_evidence_is_sensitive_but_not_copied_into_accounting_or_identity
    record = parse("sensitive", identity: {"requested_model" => "provider/model"})
    secret = "synthetic-secret-not-a-real-key"
    assert_includes JSON.generate(record.fetch("events")), secret
    %w[requests identity native_cost_observations completion protocol_error].each do |key|
      refute_includes JSON.generate(record.fetch(key)), secret, key
    end
    assert_equal({"requested_model" => "provider/model"}, record.fetch("identity"))
    assert_nil record.fetch("requests").fetch(0).fetch("model")
  end

  def test_valid_final_record_without_newline_is_accepted
    stdout = JSON.generate({"type" => "step_finish", "sessionID" => "ses_one", "timestamp" => 1,
                            "part" => {"type" => "step-finish", "id" => "prt_one", "sessionID" => "ses_one", "messageID" => "msg_one", "reason" => "stop"}})
    record = AgentRuntime::Execution::EventStream.parse(stdout: stdout)
    assert_equal "success", record.fetch("outcome")
    assert_nil record.fetch("requests").fetch(0).fetch("tokens").fetch("input")
  end

  def test_nonobject_null_scalar_and_missing_identity_fail_closed
    ["null", "17", '"text"', '{"type":"step_finish","part":{}}'].each do |stdout|
      record = AgentRuntime::Execution::EventStream.parse(stdout: stdout)
      assert_equal "unknown", record.fetch("outcome"), stdout
      refute_nil record.fetch("protocol_error"), stdout
    end
  end

  def test_blank_lines_are_ignored_but_malformed_middle_line_is_not
    stdout, = Open3.capture3({"M12_SCENARIO" => "success"}, RbConfig.ruby, SIMULATOR)
    assert_equal "success", AgentRuntime::Execution::EventStream.parse(stdout: "\n#{stdout}\n").fetch("outcome")
    corrupted = stdout.lines.insert(1, "{broken\n").join
    record = AgentRuntime::Execution::EventStream.parse(stdout: corrupted)
    assert_equal "unknown", record.fetch("outcome")
    refute_nil record.fetch("protocol_error")
  end

  def test_duplicate_usage_token_conflicts_are_preserved_not_resolved_by_parser
    stdout, = Open3.capture3({"M12_SCENARIO" => "duplicate"}, RbConfig.ruby, SIMULATOR)
    events = stdout.lines.map { |line| JSON.parse(line) }
    events.last.fetch("part").fetch("tokens")["input"] = 999
    record = AgentRuntime::Execution::EventStream.parse(stdout: events.map { |event| JSON.generate(event) }.join("\n"))
    requests = record.fetch("requests")
    assert_equal [10, 999], requests.map { |request| request.fetch("tokens").fetch("input") }
    assert_equal requests.first.fetch("request_id"), requests.last.fetch("request_id")
  end

  def test_requested_session_identity_must_match_observed_session
    record = parse(identity: {"requested_session_id" => "ses_other"})
    assert_equal "unknown", record.fetch("outcome")
    refute_nil record.fetch("protocol_error")
  end

  def test_protocol_error_has_stable_safe_shape
    record = AgentRuntime::Execution::EventStream.parse(stdout: "synthetic-secret-not-a-real-key\n")
    assert_equal({"type" => "protocol", "code" => "invalid_json", "message" => "Protocol record is not valid JSON", "line" => 1}, record.fetch("protocol_error"))
  end

  def test_invocation_scope_is_retained_without_claiming_observed_model
    record = parse(identity: {"invocation_id" => "run_step_attempt_2", "requested_model" => "provider/model"})
    assert_equal "run_step_attempt_2", record.fetch("requests").first.fetch("identity_scope")
    assert_nil record.fetch("requests").first.fetch("model")
  end

  def test_setup_error_without_session_is_failure_not_success
    stdout = JSON.generate({"type" => "error", "sessionID" => "", "error" => {"type" => "unknown", "message" => "setup failed"}})
    record = AgentRuntime::Execution::EventStream.parse(stdout: stdout)
    assert_equal "failure", record.fetch("outcome")
    assert_nil record.fetch("session_id")
  end

  def test_simulator_help_and_version_are_offline_and_deterministic
    version, stderr, status = Open3.capture3(RbConfig.ruby, SIMULATOR, "--version")
    assert status.success?
    assert_equal "opencode v2.3.0\n", version
    assert_empty stderr
    help, _, status = Open3.capture3(RbConfig.ruby, SIMULATOR, "run", "--help")
    assert status.success?
    assert_includes help, "--standalone"
  end
end
