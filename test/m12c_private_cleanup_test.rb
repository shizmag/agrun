require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

class M12cPrivateCleanupTest < Minitest::Test
  def test_real_docker_rejects_agent_privileged_mode
    skip "explicit Docker export opt-in required" unless ENV["AGRU_S2_EXPORT_DOCKER"] == "1"
    image = ENV.fetch("AGRU_S2_EXPORT_IMAGE", "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1")
    limits = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}
    Dir.mktmpdir do |workspace|
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: image, limits: limits)
      script = "touch privileged; chmod 4755 privileged; test $(stat -c %a privileged) = 4755"
      result = boundary.call(argv: ["/bin/sh", "-c", script], workspace: workspace, timeout: 20)
      refute_equal "success", result["status"], result.inspect
      assert_match(/mode|privileged/i, result.fetch("error"), result.inspect)
      refute result.key?("export"), result.inspect
      assert_equal true, result.dig("cleanup", "confirmed"), result.inspect
    end
  end

  def test_real_docker_cleans_private_staging_with_read_only_directories
    skip "explicit Docker export opt-in required" unless ENV["AGRU_S2_EXPORT_DOCKER"] == "1"
    image = ENV.fetch("AGRU_S2_EXPORT_IMAGE", "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1")
    limits = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}
    Dir.mktmpdir do |workspace|
      nested = File.join(workspace, "readonly")
      Dir.mkdir(nested)
      File.write(File.join(nested, "file"), "private-data")
      File.chmod(0o555, nested)
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: image, limits: limits)
      result = boundary.call(argv: ["/bin/true"], workspace: workspace, timeout: 20)
      assert_equal "success", result["status"], result.inspect
      assert_equal true, result.dig("cleanup", "confirmed"), result.inspect
      assert_equal true, result.dig("cleanup", "private_confirmed"), result.inspect
      input_mount = result.fetch("container_inspect").fetch("Mounts").find { |mount| mount["Destination"] == "/input" }
      refute_nil input_mount
      refute File.exist?(input_mount.fetch("Source")), "private staging remains on host"
      exported = result.fetch("export").fetch("path")
      assert_equal 0o555, File.stat(File.join(exported, "readonly")).mode & 0o777
      assert_equal "private-data", File.read(File.join(exported, "readonly", "file"))
    ensure
      File.chmod(0o700, nested) if nested && File.exist?(nested)
      if exported && File.directory?(exported)
        File.chmod(0o700, File.join(exported, "readonly")) if File.directory?(File.join(exported, "readonly"))
        FileUtils.remove_entry(File.dirname(exported))
      end
    end
  end
end
