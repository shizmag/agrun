require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/open_code_cli"
require "rbconfig"
require "digest"

class M12AdapterGuardTest < Minitest::Test
  def request(root)
    AgentRuntime::Request.new(run_id: "offline", step_id: "guard", attempt: 1,
      inputs: {}, config: {"prompt" => "do not call providers", "live" => true},
      workspace: root, timeout: 1, cancellation: AgentRuntime::Cancellation.new)
  end

  def test_live_flag_does_not_authorize_an_unregistered_executable
    in_tmp do |root|
      marker = File.join(root, "launched")
      path = File.join(root, "untrusted")
      File.write(path, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'forbidden')\n")
      File.chmod(0o755, path)
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: path, live: true).execute(request(root))
      assert_equal "blocked", result.status
      refute File.exist?(marker), "unregistered executable must not reach spawn"
      assert result.logs.dig("execution", "admission"), "denial must be inspectable"
    end
  end

  def test_changed_fixture_identity_cannot_launch
    in_tmp do |root|
      marker = File.join(root, "launched")
      path = File.join(root, "fixture")
      File.write(path, "#!#{RbConfig.ruby}\nputs '{}'\n")
      File.chmod(0o755, path)
      digest = Digest::SHA256.file(path).hexdigest
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: path,
        live: true, fixture_sha256: digest)
      File.write(path, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'forbidden')\n")
      result = adapter.execute(request(root))
      assert_equal "blocked", result.status
      refute File.exist?(marker)
      assert result.logs.dig("execution", "admission")
    end
  end

  def test_unchanged_explicitly_authorized_fixture_launches
    in_tmp do |root|
      marker = File.join(root, "launched")
      path = File.join(root, "fixture")
      File.write(path, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'authorized')\nputs '{\"type\":\"step_finish\",\"part\":{}}'\n")
      File.chmod(0o755, path)
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: path,
        live: true, fixture_sha256: Digest::SHA256.file(path).hexdigest)
      result = adapter.execute(request(root))
      assert_equal "success", result.status
      assert_equal "authorized", File.read(marker)
    end
  end

  def test_symlink_fixture_is_rejected_even_with_matching_bytes
    in_tmp do |root|
      marker = File.join(root, "launched")
      target = File.join(root, "target")
      File.write(target, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'forbidden')\n")
      File.chmod(0o755, target)
      link = File.join(root, "fixture-link")
      File.symlink(target, link)
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: link, live: true,
        fixture_sha256: Digest::SHA256.file(target).hexdigest)
      assert_equal "blocked", adapter.execute(request(root)).status
      refute File.exist?(marker)
    end
  end
end
