require_relative "test_helper"
require_relative "support/m12c_relay_docker"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require_relative "../lib/agent_runtime/adapters/sandbox_open_code_cli"

class M12cs3PluginCalibrationTest < Minitest::Test
  IMAGE = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1".freeze
  BINARY = "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0".freeze

  def test_same_installed_tool_trigger_with_enabled_and_explicitly_disabled_plugin
    skip "set AGRU_M12CS3_PLUGIN_CALIBRATION=1 (mock-only Docker)" unless ENV["AGRU_M12CS3_PLUGIN_CALIBRATION"] == "1"
    relay = M12cRelayDocker.new
    relay.start
    helper = File.expand_path("support/m12c_mock_relay.cjs", __dir__)
    policy = AgentRuntime::Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.relay_volume,
      helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
    runner = AgentRuntime::Execution::SandboxRunner.new(image: IMAGE,
      limits: {"cpus" => 1, "memory_bytes" => 1024 * 1024 * 1024, "pids" => 128, "tmpfs_bytes" => 128 * 1024 * 1024}, network_policy: policy)
    launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
      executable_sha256: BINARY, endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low",
      provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: true)
    in_tmp do |root|
      host_canary = File.join(root, "host-only-canary")
      File.write(host_canary, "synthetic-host-only-plugin-canary")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "host-canary-path.txt"), host_canary)
      FileUtils.cp_r(File.expand_path("support/m12c_plugin_sentinel", __dir__), File.join(workspace, "plugin"))
      File.write(File.join(workspace, "README.md"), "synthetic seed")
      ["generated", "project", "global", "disabled", "inherited-disabled", "malformed", "single-file", "production-project", "production-global", "production-generated"].each do |source|
        disabled = source.end_with?("disabled")
        config = {"plugins" => ["./plugin", *(disabled ? ["-agru.calibration.sentinel"] : [])]}
        File.write(File.join(workspace, "opencode.json"), JSON.generate(config))
        evidence = File.join(workspace, "plugin-evidence.jsonl")
        FileUtils.rm_f(evidence)
        FileUtils.rm_f(File.join(workspace, "sandbox-positive.txt"))
        env = launch.environment
        generated = JSON.parse(env.fetch("OPENCODE_CONFIG_CONTENT"))
        generated["plugins"] = ["/workspace/plugin", *(disabled ? ["-agru.calibration.sentinel"] : [])]
        if source == "project"
          generated.delete("plugins")
          env.delete("OPENCODE_DISABLE_PROJECT_CONFIG")
        elsif source == "global" || source == "inherited-disabled"
          generated.delete("plugins")
          File.write(File.join(workspace, "opencode.json"), "{}")
          FileUtils.mkdir_p(File.join(workspace, "global", "opencode"))
          File.write(File.join(workspace, "global", "opencode", "opencode.json"), JSON.generate({"plugins" => ["/workspace/plugin"]}))
          env["XDG_CONFIG_HOME"] = "/workspace/global"
          if disabled
            generated["plugins"] = ["-agru.calibration.sentinel"]
            File.write(File.join(workspace, "opencode.json"), JSON.generate({"plugins" => ["/workspace/plugin"]}))
            env.delete("OPENCODE_DISABLE_PROJECT_CONFIG")
          end
        elsif source == "single-file"
          File.write(File.join(workspace, "opencode.json"), "{}")
          generated["plugins"] = ["/workspace/plugin/index.js"]
        elsif source == "malformed"
          File.write(File.join(workspace, "plugin", "index.js"), "export default { broken syntax")
        end
        generated["policies"].reject! { |rule| rule["action"] == "plugin.use" }
        env["OPENCODE_CONFIG_CONTENT"] = JSON.generate(generated)
        if source.start_with?("production-")
          FileUtils.mkdir_p(File.join(workspace, "global", "opencode"))
          File.write(File.join(workspace, "global", "opencode", "opencode.json"), JSON.generate({"plugins" => ["/workspace/plugin"]}))
          File.write(File.join(workspace, "opencode.json"), JSON.generate({"plugins" => ["/workspace/plugin"]}))
          FileUtils.mkdir_p(File.join(workspace, ".opencode", "plugins"))
          FileUtils.cp_r(File.join(workspace, "plugin"), File.join(workspace, ".opencode", "plugins", "sentinel"))
          # Restore the exact production environment; the only generated attack
          # adds a known-working plugin while preserving the production deny.
          env = launch.environment
          if source == "production-generated"
            attack = JSON.parse(env.fetch("OPENCODE_CONFIG_CONTENT"))
            attack["plugins"] = ["/workspace/plugin"]
            env["OPENCODE_CONFIG_CONTENT"] = JSON.generate(attack)
          end
        end
        argv = launch.argv("Apply the requested synthetic edit and read README.md.")
        argv.insert(argv.index("--standalone"), "--print-logs") if source == "malformed"
        result = runner.call(argv: argv, workspace: workspace,
          timeout: 90, env: env)
        assert_equal "success", result["status"], result.inspect
        if source == "production-global"
          # Explicit launch env overrides the image's /tmp/config default.
          assert_equal "/tmp/agru-home/config", env.fetch("XDG_CONFIG_HOME")
          refute_equal "/workspace/global", env.fetch("XDG_CONFIG_HOME")
          assert_equal "1", env.fetch("OPENCODE_DISABLE_PROJECT_CONFIG")
          inspected = result.fetch("container_inspect")
          mounts = inspected.fetch("Mounts")
          assert_equal ["/helper.cjs", "/input", "/relay", "/supervisor.py"], mounts.map { |mount| mount.fetch("Destination") }.sort
          assert mounts.all? { |mount| mount["RW"] == false }, mounts.inspect
          refute mounts.any? { |mount| mount["Source"].to_s.include?(Dir.home) || mount["Destination"].to_s.start_with?("/tmp/agru-home", "/tmp/config", "/root", "/home") }, mounts.inspect
          assert_equal "none", inspected.fetch("HostConfig").fetch("NetworkMode")
        end
        assert_equal "synthetic-host-only-plugin-canary", File.read(host_canary)
        exported = result.fetch("export").fetch("path")
        evidence = File.join(exported, "plugin-evidence.jsonl")
        if source == "malformed"
          diagnostic = result.values_at("stdout", "stderr").join("\n")
          assert_match(/plugin|syntax|parse/i, diagnostic, "malformed module must produce a diagnostic, not be called disabled")
        end
        assert_equal "sandbox-positive\n", File.read(File.join(exported, "sandbox-positive.txt")), "mock edit must establish actual tool execution"
        if disabled || source == "single-file" || source == "malformed" || source.start_with?("production-")
          refute File.exist?(evidence), "#{source}: unexpected setup or hook evidence (invalid controls are not suppression proof)"
        else
          assert File.file?(evidence), "#{source}: missing enabled control makes suppression uninterpretable"
          rows = File.readlines(evidence).map { |line| JSON.parse(line) }
          assert rows.any? { |row| row["phase"] == "registered" }, rows.inspect
          assert rows.any? { |row| row["phase"] == "execute.before" }, rows.inspect
          assert rows.any? { |row| row["phase"] == "execute.before" && row["tool"] == "read" }, rows.inspect
          assert rows.any? { |row| row["phase"] == "host-canary" && row["denied"] }, rows.inspect
          assert rows.any? { |row| row["phase"] == "network" && row["denied"] }, rows.inspect
        end
        FileUtils.cp(File.expand_path("support/m12c_plugin_sentinel/index.js", __dir__), File.join(workspace, "plugin", "index.js"))
      ensure
        if exported && File.directory?(exported)
          FileUtils.remove_entry_secure(File.dirname(exported))
        end
      end
    end
  ensure
    relay&.close
  end
end
