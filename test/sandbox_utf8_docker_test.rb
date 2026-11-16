require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

class SandboxUtf8DockerTest < Minitest::Test
  def test_complete_docker_capture_preserves_utf8_and_binary_evidence
    skip "explicit offline Docker opt-in required" unless ENV["AGRU_UTF8_DOCKER"] == "1"
    in_tmp do |workspace|
      runner = AgentRuntime::Execution::SandboxRunner.new(
        image: ENV.fetch("AGRU_UTF8_IMAGE", "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1"),
        limits: {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}
      )
      result = runner.call(argv: ["/bin/sh", "-c", "printf '\\342'; sleep 0.1; printf '\\202\\254'"], workspace: workspace, timeout: 30)
      assert_equal "success", result["status"], result.inspect
      assert_equal "€", result["stdout"]
      assert JSON.generate(result)
      result = runner.call(argv: ["/bin/sh", "-c", "printf '\\377\\342'"], workspace: workspace, timeout: 30)
      assert_equal "failure", result["status"], result.inspect
      assert_equal "invalid_utf8_output", result["error"]
      assert_equal [255, 226], result.fetch("binary_output_base64").fetch("stdout").unpack1("m0").bytes
      assert JSON.generate(result)
    end
  end
end
