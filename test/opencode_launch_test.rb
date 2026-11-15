require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/opencode_launch"

class OpenCodeLaunchTest < Minitest::Test
  def test_isolated_secret_free_launch_and_cleanup
    in_tmp do |workspace|
      executable = File.join(workspace, "opencode")
      File.write(executable, "fixture executable")
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(executable: executable,
        executable_sha256: Digest::SHA256.file(executable).hexdigest,
        credential: "not-persisted-secret")
      root = nil
      assert_equal "cx/gpt-6-luna-low", launch.scope.fetch("model")
      assert_equal "omniroute/cx/gpt-6-luna-low", launch.model_profile
      launch.with_environment(workspace: workspace) do |env|
        root = env.fetch("HOME")
        refute root.start_with?(workspace + "/")
        assert_equal "not-persisted-secret", env.fetch("OMNIROUTE_API_KEY")
        config_text = File.read(env.fetch("OPENCODE_CONFIG"))
        refute_includes config_text, "not-persisted-secret"
        config = JSON.parse(config_text)
        assert_equal "omniroute/cx/gpt-6-luna-low", config.fetch("model")
        assert_equal config.fetch("model"), config.fetch("smallModel")
        assert_equal [], config.fetch("plugins")
        assert_includes config.fetch("policies"), {"action" => "provider.use", "resource" => "*", "effect" => "deny"}
        assert_includes config.fetch("policies"), {"action" => "tool.use", "resource" => "edit:/*", "effect" => "deny"}
        assert_equal "1", env.fetch("OPENCODE_DISABLE_PROJECT_CONFIG")
        assert_equal "http", config.dig("providers", "omniroute", "settings", "transport")
        refute config.dig("providers", "omniroute", "models", "cx/gpt-6-luna-low").key?("limit")
        assert_equal "{env:OMNIROUTE_API_KEY}", config.dig("providers", "omniroute", "settings", "apiKey")
        assert launch.argv.include?("--standalone")
        refute_includes launch.inspect, "not-persisted-secret"
        refute_includes JSON.generate(launch.to_h), "not-persisted-secret"
      end
      refute File.exist?(root)
    end
  end

  def test_rejects_changed_executable_before_environment
    in_tmp do |workspace|
      executable = File.join(workspace, "opencode")
      File.write(executable, "original")
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(executable: executable,
        executable_sha256: Digest::SHA256.file(executable).hexdigest, credential: "test")
      File.write(executable, "changed")
      assert_raises(ArgumentError) { launch.with_environment(workspace: workspace) { flunk } }
    end
  end
end
