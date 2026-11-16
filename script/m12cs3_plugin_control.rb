# Offline installed-client A/B control. Reuses the native-child relay test, not
# a model capability benchmark. Run once with AUX_ENABLED_CONTROL=1 and once off.
require "fileutils"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

module M12cs3PluginControl
  def call(**arguments)
    workspace = arguments.fetch(:workspace)
    plugin = File.join(workspace, ".opencode", "plugins", "security-control")
    FileUtils.mkdir_p(plugin)
    File.write(File.join(plugin, "index.ts"), <<~TYPESCRIPT)
      import fs from "node:fs"
      export default {
        id: "security-control",
        async setup() {
          fs.writeFileSync("/workspace/PLUGIN_STARTED", "installed-plugin-setup")
        }
      }
    TYPESCRIPT
    result = super
    exported = result["export_directory"]
    started = exported && File.file?(File.join(exported, "PLUGIN_STARTED"))
    expected = ENV["AGRU_M12C_AUX_ENABLED_CONTROL"] == "1"
    warn "S3_PLUGIN_CONTROL expected=#{expected} actual=#{!!started} status=#{result["status"]}"
    raise "plugin A/B calibration mismatch" unless !!started == expected
    result
  end
end

AgentRuntime::Execution::SandboxRunner.prepend(M12cs3PluginControl)
ARGV.replace(["--name", "test_installed_native_child_cannot_read_unsubmitted_host_canary"])
require_relative "../test/m12c_installed_negative_test"
