require_relative "test_helper"
require_relative "support/m12d_relay_docker"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require_relative "../lib/agent_runtime/adapters/sandbox_open_code_cli"

class M12dInstalledTransportTest < Minitest::Test
  def test_real_opencode_exchange
    skip "explicit offline Docker opt-in required" unless ENV["AGRU_M12D_TRANSPORT_TEST"] == "1"
    relay = M12dRelayDocker.new.start
    helper = File.expand_path("support/m12c_mock_relay.cjs", __dir__)
    policy = AgentRuntime::Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.relay_volume,
      helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
    runner = AgentRuntime::Execution::SandboxRunner.new(
      image: "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1",
      limits: {"cpus" => 1, "memory_bytes" => 1073741824, "pids" => 128, "tmpfs_bytes" => 134217728}, network_policy: policy
    )
    launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
      executable_sha256: "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
      endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock",
      wire_model: "cx/gpt-6-luna-low", mock_only: false, transport_mode: "provider_relay")
    adapter = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: runner, launch: launch)
    in_tmp do |root|
      request = AgentRuntime::Request.new(run_id: "m12d-installed", step_id: "exchange", attempt: 1,
        inputs: {"prompt" => "Respond with AGRU_TRANSPORT_OK."}, config: {}, workspace: root, timeout: 60)
      result = adapter.execute(request)
      warn JSON.generate(result.to_h)
      warn relay.logs("relay")
      assert_equal "success", result.status
      assert_includes JSON.generate(result.to_h), "AGRU_TRANSPORT_OK"
      assert_includes relay.logs("relay"), '"simulator_authorized":true'
      network = runner.call(argv: ["/usr/local/bin/node", "-e", "const s=require('net').connect({host:'1.1.1.1',port:443});s.on('connect',()=>process.exit(9));s.on('error',()=>{console.log('DIRECT_NETWORK_DENIED');process.exit(0)});setTimeout(()=>process.exit(8),2000)"],
        workspace: root, timeout: 10, env: launch.environment)
      assert_equal "success", network.fetch("status")
      assert_includes network.fetch("stdout"), "DIRECT_NETWORK_DENIED"
      assert_equal "none", result.logs.dig("sandbox", "container_inspect", "HostConfig", "NetworkMode")
      assert_equal true, result.logs.dig("sandbox", "cleanup", "confirmed")
    end
    relay.close
    assert_raises(RuntimeError) { relay.command("inspect", "#{relay.instance_variable_get(:@prefix)}-relay") }
  ensure
    relay&.close
  end
end
