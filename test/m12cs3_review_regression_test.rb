require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/sandbox_open_code_cli"
require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"

class M12cs3ReviewRegressionTest < Minitest::Test
  def test_success_without_export_digest_is_blocked
    Dir.mktmpdir do |repository|
      launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode", executable_sha256: "a" * 64,
        endpoint: "http://127.0.0.1:18080/v1", model: "mock/fixture", provider: "mock", wire_model: "fixture", mock_only: true)
      runner = Object.new
      runner.define_singleton_method(:call) { |**| {"status" => "success", "container_inspect" => {}, "cleanup" => {"confirmed" => true}, "export" => {"path" => repository}, "stdout" => "", "stderr" => "", "exit_code" => 0} }
      adapter = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: runner, launch: launch)
      request = AgentRuntime::Request.new(inputs: {"repository" => repository}, config: {"prompt" => "fixture"}, workspace: repository, timeout: 1)
      result = adapter.execute(request)
      assert_equal "blocked", result.status
      assert_empty result.outputs
    end
  end

  def test_live_manifest_rejects_fixture_model_profile
    data = {"schema_version" => 1, "experiment_id" => "pilot", "benchmark" => {"name" => "nl2repo", "revision" => "pinned", "task_ids" => ["retrying"]},
            "solver_ids" => ["single-agent"], "models" => [{"id" => "pilot", "model_profile" => {"id" => "pilot", "provider" => "fixture", "model" => "fixture", "execution_kind" => "offline_fixture", "tool_policy" => {}}}],
            "repetitions" => 1, "limits" => {"timeout" => 10, "max_concurrent_sessions" => 1}, "execution_mode" => "live", "subset_role" => "smoke"}
    error = assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(data) }
    assert_match(/live pilot requires one explicit real-provider model/, error.message)
  end
end
