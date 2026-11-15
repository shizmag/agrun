require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/open_code_cli"
require "digest"

class M12ScenarioAcceptanceTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/m12_fake_opencode.rb", __dir__)

  def persisted(scenario, env: {}, timeout: 3)
    in_tmp do |root|
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: FIXTURE,
        fixture_sha256: Digest::SHA256.file(FIXTURE).hexdigest)
      config = {"prompt" => "synthetic only",
                "model_profile" => {"id" => "offline", "provider" => "fixture", "model" => "deterministic", "execution_kind" => "offline_fixture", "tool_policy" => {}},
                "env" => {"M12_SCENARIO" => scenario}.merge(env),
                "budget_policy" => {"wall_seconds" => 3, "max_attempts" => 2, "max_concurrent_sessions" => 1}}
      ir = {"schema_version" => 1, "name" => "scenario-acceptance", "inputs" => {},
            "executors" => {"local" => {"adapter" => "local", "config" => config}},
            "steps" => [{"id" => "agent", "executor" => "local", "inputs" => {}, "outputs" => {"patch" => "patch"}, "needs" => [], "config" => {}, "timeout" => timeout, "retries" => 0}],
            "outputs" => {"patch" => "agent.patch"}}
      store = AgentRuntime::Store.new(File.join(root, "store"))
      report = AgentRuntime::Runtime.new(store: store, executors: {local: adapter}).run(ir)
      reopened = AgentRuntime::Store.new(store.root)
      attempt = reopened.report(report.fetch("run_id")).dig("steps", "agent", "attempts", 0)
      logs = JSON.parse(reopened.value(attempt.fetch("log")))
      yield report, attempt, logs.fetch("execution"), reopened
    end
  end

  def test_ex01_success_preserves_operational_not_provider_completion
    persisted("success") do |report, attempt, trace, _|
      assert_equal "success", report.fetch("status")
      assert_equal "success", trace.fetch("outcome")
      assert_nil trace.dig("completion", "session_reported_complete")
      assert_equal false, trace.dig("completion", "accounting_complete")
      assert_nil attempt["cost"]
    end
  end

  def test_ex02_missing_completion_and_ex03_malformed_never_succeed
    %w[empty text_only malformed nonobject partial].each do |scenario|
      persisted(scenario) do |report, _, trace, _|
        refute_equal "success", report.fetch("status"), scenario
        refute trace.dig("completion", "operationally_complete"), scenario
      end
    end
  end

  def test_ex04_unknown_extension_is_preserved_not_authoritative
    persisted("aggregate_conflict") do |report, _, trace, _|
      assert_equal "success", report.fetch("status")
      assert_includes trace.fetch("events").map { |event| event.fetch("type") }, "synthetic_aggregate"
      assert_equal 10, trace.dig("usage", "tokens", "input", "known_subtotal")
      assert_equal false, trace.dig("completion", "accounting_complete")
    end
  end

  def test_ex05_duplicate_and_ex06_conflicting_usage_observations
    persisted("duplicate") do |_, _, trace, _|
      assert_equal 2, trace.fetch("requests").size
      assert_equal 1, trace.dig("usage", "coverage", "accepted_requests")
    end
    persisted("usage_conflict") do |_, _, trace, _|
      assert_equal 2, trace.fetch("requests").size
      assert_equal 0, trace.dig("usage", "coverage", "accepted_requests")
    end
  end

  def test_ex07_missing_usage_is_unknown_not_free
    persisted("missing_usage") do |_, attempt, trace, _|
      assert_equal "success", trace.fetch("outcome")
      assert_nil attempt["cost"]
      assert_nil trace.dig("usage", "tokens", "input", "total")
      assert_nil trace.dig("usage", "tokens", "input", "known_subtotal")
    end
  end

  def test_ex19_truncated_capture_never_establishes_completion
    persisted("truncated") do |report, _, trace, _|
      refute_equal "success", report.fetch("status")
      refute trace.dig("completion", "operationally_complete")
    end
  end

  def test_ex20_model_extension_cannot_claim_observed_identity
    persisted("model_mismatch") do |_, _, trace, _|
      # Audited native CLI has no observed model record. An unknown extension
      # must not become authoritative provider identity or pricing evidence.
      assert_nil trace.fetch("requests").first.fetch("model")
      assert_nil trace.fetch("requests").first.fetch("provider")
      assert_includes trace.fetch("events").map { |event| event.fetch("type") }, "synthetic_model"
    end
  end

  def test_ex22_credentials_are_absent_from_persisted_logs_and_attempt
    persisted("sensitive", env: {"OPENAI_API_KEY" => "synthetic-config-secret"}) do |_, attempt, trace, _|
      evidence = JSON.generate({"attempt" => attempt, "trace" => trace})
      refute_includes evidence, "synthetic-config-secret"
      refute_includes evidence, "synthetic-secret-not-a-real-key"
      assert_includes evidence, "[REDACTED]"
    end
  end

  def test_ex23_partial_artifact_does_not_turn_failure_into_success
    persisted("artifact_failure") do |report, _, trace, _|
      refute_equal "success", report.fetch("status")
      assert_equal "failure", trace.fetch("outcome")
      refute trace.dig("completion", "operationally_complete")
      artifact = File.join(trace.fetch("identity").fetch("workspace"), "synthetic_partial_artifact.txt")
      assert File.file?(artifact), "the failing solver really produced a partial artifact"
    end
  end

  def test_ex23_successful_artifact_preserves_success_without_implying_verdict
    persisted("artifact_success") do |report, _, trace, _|
      assert_equal "success", report.fetch("status")
      artifact = File.join(trace.fetch("identity").fetch("workspace"), "synthetic_partial_artifact.txt")
      assert_equal "offline artifact\n", File.read(artifact)
    end
  end
end
