require_relative "test_helper"
require "socket"
require_relative "support/m12c_relay_docker"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require_relative "../lib/agent_runtime/execution/sandbox_open_code_launch"

class M12cInstalledNegativeTest < Minitest::Test
  def test_installed_client_does_not_follow_injected_redirect_to_host
    skip "set AGRU_M12C_INSTALLED_NEGATIVE=1" unless ENV["AGRU_M12C_INSTALLED_NEGATIVE"] == "1"
    listener = TCPServer.new("0.0.0.0", 0)
    port = listener.addr[1]
    hits = Queue.new
    serving = Thread.new do
      loop do
        connection = listener.accept
        hits << true
        connection.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        connection.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    relay = M12cRelayDocker.new(script: "redirect-negative")
    relay.start
    positive = relay.command("run", "--rm", "--pull=never", "--network=bridge", relay.image,
      "node", "-e", "require('http').get('http://host.docker.internal:#{port}/control',r=>{console.log(r.statusCode);r.resume()})")
    assert_includes positive, "200"
    assert_equal 1, hits.size
    in_tmp do |workspace|
      helper = File.expand_path("support/m12c_mock_relay.cjs", __dir__)
      policy = AgentRuntime::Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.relay_volume,
        helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
      runner = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_M12C_AGENT_IMAGE"),
        limits: {"cpus" => 1, "memory_bytes" => 1073741824, "pids" => 128, "tmpfs_bytes" => 134217728}, network_policy: policy)
      launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
        executable_sha256: "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
        endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: true)
      result = runner.call(argv: launch.argv("AGRU_REDIRECT_PORT=#{port} exercise redirect denial"), env: launch.environment, workspace: workspace, timeout: 45)
      assert_includes relay.logs("mock"), '"injected_redirect":true'
      assert_includes relay.logs("relay"), '"reason":"redirect"'
      assert_equal 1, hits.size, "installed client/relay must not reach injected external host location"
      assert_equal true, result.fetch("cleanup").fetch("confirmed")
    ensure
      FileUtils.remove_entry(result["export_directory"]) if result && result["export_directory"] && File.directory?(result["export_directory"])
    end
  ensure
    relay&.close
    listener&.close
    serving&.join(2)
    serving&.kill
  end

  def test_installed_native_child_cannot_read_unsubmitted_host_canary
    skip "set AGRU_M12C_INSTALLED_NEGATIVE=1" unless ENV["AGRU_M12C_INSTALLED_NEGATIVE"] == "1"
    in_tmp do |root|
      marker = "synthetic-host-#{SecureRandom.hex(24)}"
      hidden = File.join(root, "host-canary")
      File.write(hidden, marker)
      assert_equal marker, File.read(hidden)
      workspace = File.join(root, "workspace")
      Dir.mkdir(workspace)
      File.write(File.join(workspace, "README.md"), "VISIBLE_NATIVE_POSITIVE_12C")
      # Submitted config is hostile input; clean global config must win. These
      # sentinels are synthetic and never attempt a host operation.
      File.write(File.join(workspace, "sentinel.cjs"), "require('fs').writeFileSync('/workspace/AUX_STARTED','synthetic-aux-started')")
      File.write(File.join(workspace, "plugin.mjs"), "import fs from 'node:fs'; fs.writeFileSync('/workspace/PLUGIN_STARTED','synthetic'); export default {id:'synthetic-control',setup:async()=>{}};")
      File.write(File.join(workspace, "mcp.cjs"), "require('fs').writeFileSync('/workspace/MCP_STARTED','synthetic-mcp-started');process.exit(0)")
      File.write(File.join(workspace, "lsp.cjs"), "require('fs').writeFileSync('/workspace/LSP_STARTED','synthetic-lsp-started');process.exit(0)")
      control = M12cRelayDocker.new
      control.command("run", "--rm", "--pull=never", "--network=none", "-v", "#{workspace}:/workspace", control.image,
        "node", "/workspace/sentinel.cjs")
      assert_equal "synthetic-aux-started", File.read(File.join(workspace, "AUX_STARTED"))
      File.unlink(File.join(workspace, "AUX_STARTED"))
      File.write(File.join(workspace, "opencode.json"), JSON.generate({
        "plugins" => ["file:///workspace/plugin.mjs"],
        "mcp" => {"servers" => {"sentinel" => {"type" => "local", "command" => ["node", "/workspace/mcp.cjs"]}}},
        "lsp" => {"sentinel" => {"command" => ["node", "/workspace/lsp.cjs"], "extensions" => [".md"]}}
      }))
      relay = M12cRelayDocker.new(script: "native-host-negative")
      relay.start
      helper = File.expand_path("support/m12c_mock_relay.cjs", __dir__)
      policy = AgentRuntime::Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.relay_volume,
        helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
      runner = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_M12C_AGENT_IMAGE"),
        limits: {"cpus" => 1, "memory_bytes" => 1073741824, "pids" => 128, "tmpfs_bytes" => 134217728}, network_policy: policy)
      launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
        executable_sha256: "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
        endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: true)
      environment = launch.environment
      if ENV["AGRU_M12C_AUX_ENABLED_CONTROL"] == "1"
        environment.delete("OPENCODE_DISABLE_PROJECT_CONFIG")
        configuration = JSON.parse(environment.fetch("OPENCODE_CONFIG_CONTENT"))
        configuration.delete("policies")
        configuration.delete("plugins")
        configuration.delete("mcp")
        configuration.delete("lsp")
        environment["OPENCODE_CONFIG_CONTENT"] = JSON.generate(configuration)
      end
      result = runner.call(argv: launch.argv("AGRU_HOST_PATH=#{hidden} run the fixed native child boundary test"), env: environment, workspace: workspace, timeout: 90)
      logs = relay.logs("mock")
      assert_equal 0, result["exit_code"], result.inspect
      assert_includes logs, '"negative_child":true'
      assert_includes logs, "VISIBLE_NATIVE_POSITIVE_12C"
      assert_match(/not found|not exist|denied|ENOENT/i, logs)
      assert_includes logs, '"negative_child_completed":true'
      assert_includes result.fetch("stdout"), "background_wait"
      refute_includes logs + result.fetch("stdout") + result.fetch("stderr"), marker
      assert_equal "success", result.fetch("status"), result.inspect
      auxiliary_started = File.exist?(File.join(result.fetch("export_directory"), "PLUGIN_STARTED"))
      if ENV["AGRU_M12C_AUX_ENABLED_CONTROL"] == "1"
        warn "AUX_CALIBRATION MCP=#{File.exist?(File.join(result.fetch("export_directory"), "MCP_STARTED"))} LSP=#{File.exist?(File.join(result.fetch("export_directory"), "LSP_STARTED"))} PLUGIN=#{auxiliary_started}"
        assert File.exist?(File.join(result.fetch("export_directory"), "MCP_STARTED")), "enabled MCP startup must execute sentinel"
      else
        refute auxiliary_started
        refute File.exist?(File.join(result.fetch("export_directory"), "MCP_STARTED"))
        refute File.exist?(File.join(result.fetch("export_directory"), "LSP_STARTED"))
      end
    ensure
      relay&.close
      FileUtils.remove_entry(result["export_directory"]) if result && result["export_directory"] && File.directory?(result["export_directory"])
    end
  end
end
