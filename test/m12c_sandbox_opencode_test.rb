require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/sandbox_open_code_cli"
require_relative "../lib/agent_runtime/adapters/open_code_cli"

class M12cSandboxOpenCodeTest < Minitest::Test
  class Boundary
    attr_reader :calls

    def initialize(status: "success", evidence: true)
      @status, @evidence, @calls = status, evidence, []
    end

    def call(**options)
      @calls << options
      {"status" => @status, "stdout" => "", "stderr" => "", "exit_code" => 0,
       "container_inspect" => @evidence ? {"Image" => "fixture"} : nil,
       "cleanup" => {"confirmed" => @evidence},
       "export" => {"path" => options.fetch(:workspace), "digest" => "a" * 64}}
    end
  end

  def launch
    AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
      executable_sha256: "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
      endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: true)
  end

  def test_explicit_config_preserves_shell_and_disables_extensions
    config = JSON.parse(launch.environment.fetch("OPENCODE_CONFIG_CONTENT"))
    assert_equal [], config.fetch("plugins")
    assert_equal({}, config.fetch("mcp"))
    assert_equal false, config.fetch("lsp")
    assert_includes config.fetch("policies"), {"action" => "tool.use", "resource" => "bash", "effect" => "allow"}
    refute_includes launch.environment.to_s, "OMNIROUTE_API_KEY"
  end

  def test_requires_mock_opt_in_and_rejects_unsupported_extension_configuration
    assert_raises(ArgumentError) do
      AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/opt/opencode", executable_sha256: "a" * 64,
        endpoint: "https://provider.example/v1", model: "mock/model", provider: "mock", wire_model: "model", mock_only: false)
    end
    assert_raises(ArgumentError) { launch.with_extensions(plugins: ["unreviewed"]) }
  end

  def test_boundary_receives_explicit_launch_without_host_fallback
    in_tmp do |workspace|
      boundary = Boundary.new
      adapter = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: boundary, launch: launch)
      request = AgentRuntime::Request.new(inputs: {"repository" => workspace}, workspace: workspace,
        config: {"prompt" => "write candidate"}, timeout: 10)
      assert_equal "success", adapter.execute(request).status
      assert_equal workspace, boundary.calls.first.fetch(:workspace)
      assert_equal "/bin/sh", boundary.calls.first.fetch(:argv).first
      assert_includes boundary.calls.first.fetch(:argv), "/usr/local/bin/opencode"
      assert_equal "write candidate", boundary.calls.first.fetch(:argv).last
      bad = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: Boundary.new(evidence: false), launch: launch)
      assert_equal "blocked", bad.execute(request).status
      failed = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: Boundary.new(status: "timeout"), launch: launch)
      partial = failed.execute(request)
      assert_equal "timeout", partial.status
      assert_equal workspace, partial.logs.dig("partial_export", "path")
      assert_equal false, partial.logs.dig("execution", "completion", "accounting_complete")
      refute_nil partial.usage
    end
  end

  def test_blocked_sandbox_never_falls_back_to_host_execution
    in_tmp do |workspace|
      boundary = Boundary.new(status: "blocked")
      adapter = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: boundary, launch: launch)
      request = AgentRuntime::Request.new(inputs: {"repository" => workspace}, workspace: workspace,
        config: {"prompt" => "write candidate"}, timeout: 10)
      host_calls = 0
      host_adapter = Object.new
      host_adapter.define_singleton_method(:execute) do |_|
        host_calls += 1
        nil
      end
      AgentRuntime::Adapters::OpenCodeCLI.stub(:new, ->(*) { host_adapter }) do
        result = adapter.execute(request)
        assert_equal 0, host_calls, "blocked sandbox must not invoke host execution"
        assert_equal "blocked", result.status
        assert_empty result.outputs
      end
      assert_equal 0, host_calls
      assert_equal 1, boundary.calls.length
    end
  end
end
