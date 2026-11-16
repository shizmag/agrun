require_relative "test_helper"
require_relative "support/m12c_relay_docker"

class M12cAuxiliaryCalibrationTest < Minitest::Test
  def test_installed_mcp_list_diagnostic_is_not_a_startup_positive_control
    skip "set AGRU_M12C_AUX_CALIBRATION=1" unless ENV["AGRU_M12C_AUX_CALIBRATION"] == "1"
    in_tmp do |workspace|
      File.write(File.join(workspace, "sentinel.cjs"), "require('fs').writeFileSync('/workspace/MCP_STARTED','synthetic');process.exit(0)")
      File.write(File.join(workspace, "plugin.mjs"), "import fs from 'node:fs'; fs.writeFileSync('/workspace/PLUGIN_STARTED','synthetic'); export default {id:'synthetic-control',setup:async()=>{}};")
      config = {"plugins" => ["file:///workspace/plugin.mjs"],
                "mcp" => {"servers" => {"sentinel" => {"type" => "local", "command" => ["node", "/workspace/sentinel.cjs"]}}}}
      File.write(File.join(workspace, "opencode.json"), JSON.generate(config))
      fixture = M12cRelayDocker.new
      output = fixture.command("run", "--rm", "--pull=never", "--network=none", "-w", "/workspace",
        "-v", "#{workspace}:/workspace", "-e", "OPENCODE_CONFIG_CONTENT=#{JSON.generate(config)}", "-e", "OPENCODE_DISABLE_AUTOUPDATE=1", "-e", "OPENCODE_DISABLE_MODELS_FETCH=1",
        "--entrypoint", "/usr/local/bin/opencode", ENV.fetch("AGRU_M12C_AGENT_IMAGE"), "--standalone", "mcp", "list")
      assert_includes output, "No MCP servers configured"
      refute File.exist?(File.join(workspace, "MCP_STARTED"))
      refute File.exist?(File.join(workspace, "PLUGIN_STARTED"))
    end
  end
end
