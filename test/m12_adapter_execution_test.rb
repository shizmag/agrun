require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/open_code_cli"
require "digest"

class M12AdapterExecutionTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/m12_fake_opencode.rb", __dir__)

  def profile
    {"id" => "offline", "provider" => "fixture", "model" => "deterministic",
     "execution_kind" => "offline_fixture", "tool_policy" => {}}
  end

  def test_duplicate_native_observations_survive_persistence_without_provider_charge
    in_tmp do |root|
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: FIXTURE,
        fixture_sha256: Digest::SHA256.file(FIXTURE).hexdigest)
      store = AgentRuntime::Store.new(File.join(root, "store"))
      ir = program("duplicate")
      report = AgentRuntime::Runtime.new(store: store, executors: {local: adapter}).run(ir)
      assert_equal "success", report["status"]
      reopened = AgentRuntime::Store.new(store.root)
      attempt = reopened.report(report["run_id"]).dig("steps", "agent", "attempts", 0)
      trace = JSON.parse(reopened.value(attempt.fetch("log"))).fetch("execution")
      assert_equal "success", trace["outcome"]
      assert_equal false, trace.dig("completion", "accounting_complete")
      assert_nil trace.dig("completion", "session_reported_complete")
      assert_nil attempt["cost"]
      assert_equal 2, trace.fetch("requests").size, "duplicate observations retained as evidence"
      assert_equal 1, trace.fetch("usage").fetch("coverage").fetch("accepted_requests")
      assert_equal 10, trace.fetch("usage").fetch("tokens").fetch("input").fetch("known_subtotal")
      refute attempt.fetch("execution").key?("process")
      assert trace.fetch("admission").fetch("allowed")
    end
  end

  def test_partial_patch_is_preserved_as_evidence_on_failure
    in_tmp do |root|
      executable = File.join(root, "failed-fixture")
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write("partial.txt", "partial change")
        puts '{"type":"error","message":"synthetic failure"}'
        exit 1
      RUBY
      File.chmod(0o755, executable)
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable,
        fixture_sha256: Digest::SHA256.file(executable).hexdigest)
      request = AgentRuntime::Request.new(run_id: "failed", step_id: "agent", attempt: 1,
        inputs: {}, workspace: root, timeout: 3, cancellation: AgentRuntime::Cancellation.new,
        config: {"prompt" => "offline", "model_profile" => profile,
                 "budget_policy" => {"wall_seconds" => 3, "max_attempts" => 1, "max_concurrent_sessions" => 1}})
      result = adapter.execute(request)
      assert_equal "failure", result.status
      assert_includes result.outputs.fetch("patch"), "partial change"
    end
  end

  def test_timeout_after_finish_never_becomes_success
    in_tmp do |root|
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: FIXTURE,
        fixture_sha256: Digest::SHA256.file(FIXTURE).hexdigest)
      request = AgentRuntime::Request.new(run_id: "timeout", step_id: "agent", attempt: 1,
        inputs: {}, workspace: root, timeout: 0.7, cancellation: AgentRuntime::Cancellation.new,
        config: program("hang")["executors"]["local"]["config"])
      result = adapter.execute(request)
      assert_equal "timeout", result.status
      assert_equal "timeout", result.logs.dig("execution", "outcome")
      refute result.logs.dig("execution", "completion", "operationally_complete")
      refute_empty result.logs.dig("execution", "events")
    end
  end

  def program(scenario)
    {"schema_version" => 1, "name" => "offline-agent", "inputs" => {},
     "executors" => {"local" => {"adapter" => "local", "config" => {
       "prompt" => "synthetic only", "model_profile" => profile,
       "env" => {"M12_SCENARIO" => scenario},
       "budget_policy" => {"wall_seconds" => 3, "max_attempts" => 2, "max_concurrent_sessions" => 1}
     }}},
     "steps" => [{"id" => "agent", "executor" => "local", "inputs" => {},
                  "outputs" => {"patch" => "patch"}, "needs" => [], "config" => {}, "timeout" => 3, "retries" => 0}],
     "outputs" => {"patch" => "agent.patch"}}
  end
end
