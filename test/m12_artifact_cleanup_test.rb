require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/open_code_cli"
require "digest"

class M12ArtifactCleanupTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/m12_fake_opencode.rb", __dir__)

  class RemoveWorkspaceRunner
    def call(**options)
      result = AgentRuntime::Adapters::ProcessRunner.new.call(**options)
      # The test owns this empty temporary workspace. Rename rather than delete
      # it: real GitPatch's post-execution collection can no longer enter cwd.
      File.rename(options.fetch(:cwd), "#{options.fetch(:cwd)}-moved")
      result
    end
  end

  def test_artifact_collection_failure_retains_execution_and_releases_budget
    in_tmp do |root|
      workspace = File.join(root, "workspace")
      Dir.mkdir(workspace)
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: FIXTURE,
        fixture_sha256: Digest::SHA256.file(FIXTURE).hexdigest, runner: RemoveWorkspaceRunner.new)
      config = {"prompt" => "synthetic", "env" => {"M12_SCENARIO" => "success"},
                "model_profile" => {"id" => "offline", "provider" => "fixture", "model" => "deterministic", "execution_kind" => "offline_fixture", "tool_policy" => {}},
                "budget_policy" => {"wall_seconds" => 10, "max_attempts" => 2, "max_concurrent_sessions" => 1}}
      request = AgentRuntime::Request.new(run_id: "artifact-run", step_id: "agent", attempt: 1,
        inputs: {}, config: config, workspace: workspace, timeout: 3, cancellation: AgentRuntime::Cancellation.new)
      result = adapter.execute(request)
      assert_equal "failure", result.status
      assert_equal "artifact_collection", result.error.fetch("type")
      assert_equal false, result.retry_safe
      assert_equal({}, result.outputs)
      trace = result.logs.fetch("execution")
      assert trace.fetch("admission").fetch("allowed")
      assert_equal "failure", trace.fetch("outcome")
      refute trace.fetch("completion").fetch("operationally_complete")
      assert_equal 1, trace.fetch("requests").size
      assert_equal 10, trace.dig("usage", "tokens", "input", "known_subtotal")
      assert_equal "success", trace.fetch("process").fetch("status")
      refute_empty trace.fetch("cleanup").fetch("errors")
      # A second invocation in the same run must not be blocked by a leaked
      # concurrency lease, even though artifact collection failed previously.
      Dir.mkdir(workspace)
      request.attempt = 2
      second = adapter.execute(request)
      refute_equal "blocked", second.status
      assert second.logs.fetch("execution").fetch("admission").fetch("allowed")
    end
  end
end
