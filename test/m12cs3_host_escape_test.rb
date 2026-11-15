require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

class M12cs3HostEscapeTest < Minitest::Test
  IMAGE = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1".freeze
  LIMITS = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}.freeze

  def test_auxiliary_process_cannot_write_host_canary
    skip "explicit Docker opt-in required" unless ENV["AGRU_S2_EXPORT_DOCKER"] == "1"
    Dir.mktmpdir("agru-host-canary-") do |host|
      Dir.mktmpdir("agru-host-workspace-") do |workspace|
        canary = File.join(host, "escaped")
        # The child forks and exits after attempting an absolute host write; no shell quoting is needed.
        code = "import os; p=os.fork(); " \
          "exec('if p == 0:\\n try:\\n  open(#{canary.inspect}, \\\"w\\\").write(\\\"escape\\\")\\n except OSError:\\n  pass\\n os._exit(0)\\nelse:\\n os.waitpid(p, 0)')"
        runner = AgentRuntime::Execution::SandboxRunner.new(image: IMAGE, limits: LIMITS)
        result = runner.call(argv: ["/usr/bin/python3", "-c", code], workspace: workspace, timeout: 20)
        assert_equal "success", result.fetch("status"), result.inspect
        assert_equal 0, result.fetch("exit_code"), result.inspect
        refute File.exist?(canary), "auxiliary process wrote the host canary"
      ensure
        export = result&.dig("export", "path")
        FileUtils.remove_entry(File.dirname(export)) if export && File.directory?(File.dirname(export))
      end
    end
  end
end
