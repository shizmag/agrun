require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

class SandboxBoundaryTest < Minitest::Test
  IMAGE = "alpine@sha256:#{"a" * 64}".freeze
  LIMITS = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}.freeze

  def runner(process_runner: nil, **options)
    AgentRuntime::Execution::SandboxRunner.new(image: IMAGE, limits: LIMITS,
      process_runner: process_runner, **options)
  end

  def test_arbitrary_network_policy_is_rejected
    assert_raises(ArgumentError) { runner(network_policy: "bridge") }
  end

  def test_unpinned_image_is_rejected
    assert_raises(ArgumentError) do
      AgentRuntime::Execution::SandboxRunner.new(image: "alpine:latest", limits: LIMITS)
    end
  end

  def test_input_symlink_and_hardlink_fail_before_docker
    in_tmp do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      canary = File.join(root, "canary")
      File.write(canary, "synthetic-secret")
      calls = []
      fake = Object.new
      fake.define_singleton_method(:call) { |**args|
        calls << args
        raise "must not run"
      }
      File.symlink(canary, File.join(source, "escape"))
      result = runner(process_runner: fake).call(argv: ["/bin/cat", "escape"], workspace: source, timeout: 1)
      assert_equal "failure", result["status"]
      assert_empty calls
      File.unlink(File.join(source, "escape"))
      File.link(canary, File.join(source, "escape"))
      result = runner(process_runner: fake).call(argv: ["/bin/cat", "escape"], workspace: source, timeout: 1)
      assert_equal "failure", result["status"]
      assert_empty calls
      assert_equal "synthetic-secret", File.read(canary)
    end
  end

  def test_create_failure_attempts_cleanup_and_never_falls_back
    in_tmp do |source|
      calls = []
      fake = Object.new
      fake.define_singleton_method(:call) do |**args|
        calls << args
        {"status" => "failure", "exit_code" => 1, "stdout" => "", "stderr" => "unavailable"}
      end
      result = runner(process_runner: fake).call(argv: ["/bin/true"], workspace: source, timeout: 1)
      assert_equal "failure", result["status"]
      assert_equal %w[create rm], calls.map { |call| call[:argv][1] }
      assert_equal false, result["cleanup"]["confirmed"]
      assert result["cleanup"]["error"]
      refute result.key?("export")
    end
  end

  def test_real_container_host_canary_denial_and_export
    skip "set AGRU_SANDBOX_TEST_IMAGE to an installed digest-pinned clean image" unless ENV["AGRU_SANDBOX_TEST_IMAGE"]
    in_tmp do |root|
      workspace = File.join(root, "workspace")
      Dir.mkdir(workspace)
      canary = File.join(root, "canary")
      marker = SecureRandom.hex(24)
      File.write(canary, marker)
      assert_equal marker, File.read(canary) # Positive host calibration.
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_SANDBOX_TEST_IMAGE"), limits: LIMITS)
      script = 'test ! -r "$1" && test ! -r ../canary && test ! -S /var/run/docker.sock && printf built > result.txt'
      result = boundary.call(argv: ["/bin/sh", "-c", script, "control", canary], workspace: workspace, timeout: 20)
      assert_equal "blocked", result["status"], result.inspect
      assert result["cleanup"]["confirmed"]
      assert_equal "none", result.dig("container_inspect", "HostConfig", "NetworkMode")
      assert_match(/writer_quiescence_unsupported/, result["error"])
      refute result.key?("export")
      refute_includes result["stdout"], marker
      refute File.exist?(File.join(workspace, "result.txt"))
    ensure
      if result && result["export"]
        exported = File.dirname(result["export"]["path"])
        FileUtils.chmod_R("u+w", exported)
        FileUtils.remove_entry(exported)
      end
    end
  end

  def real_boundary
    skip "set AGRU_SANDBOX_TEST_IMAGE for actual Docker controls" unless ENV["AGRU_SANDBOX_TEST_IMAGE"]
    AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_SANDBOX_TEST_IMAGE"), limits: LIMITS)
  end

  def release_export(result)
    return unless result["export"]
    root = File.dirname(result["export"]["path"])
    FileUtils.chmod_R("u+w", root)
    FileUtils.remove_entry(root)
  end

  def test_real_malicious_export_types_are_rejected
    boundary = real_boundary
    ["ln -s /etc/passwd escape", "echo data > original; ln original hardlink", "mkfifo pipe"].each do |script|
      in_tmp do |workspace|
        result = boundary.call(argv: ["/bin/sh", "-c", script], workspace: workspace, timeout: 10)
        assert_equal "failure", result["status"], result.inspect
        assert result["cleanup"]["confirmed"], result.inspect
        assert_match(/unsafe workspace\/export entry/, result["error"])
        refute result.key?("export")
      end
    end
  end

  def test_real_timeout_removes_container_and_descendants
    boundary = real_boundary
    in_tmp do |workspace|
      result = boundary.call(argv: ["/bin/sh", "-c", "sleep 60 & wait"], workspace: workspace, timeout: 0.2)
      assert_equal "timeout", result["status"], result.inspect
      assert result["cleanup"]["confirmed"]
      refute result.key?("export")
      raw = AgentRuntime::Adapters::ProcessRunner.new.call(argv: ["docker", "inspect", result["container_name"]], cwd: workspace, timeout: 10)
      refute_equal 0, raw["exit_code"]
    end
  end

  def test_real_cancellation_removes_container
    boundary = real_boundary
    cancellation = Object.new
    started = nil
    cancellation.define_singleton_method(:cancelled?) do
      started ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 0.2
    end
    in_tmp do |workspace|
      result = boundary.call(argv: ["/bin/sh", "-c", "sleep 60 & wait"], workspace: workspace, timeout: 20, cancellation: cancellation)
      assert_equal "cancelled", result["status"], result.inspect
      assert result["cleanup"]["confirmed"]
      refute result.key?("export")
    end
  end

  def test_real_synthetic_private_layout_and_host_environment_are_absent
    boundary = real_boundary
    require "socket"
    in_tmp do |root|
      workspace = File.join(root, "workspace")
      Dir.mkdir(workspace)
      marker = SecureRandom.hex(24)
      paths = %w[home/.config/credentials sibling/repo hidden/procedure reference/answer].map do |relative|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, marker)
        assert_equal marker, File.read(path)
        path
      end
      socket_path = File.join(root, "synthetic.sock")
      socket = UNIXServer.new(socket_path)
      client = UNIXSocket.new(socket_path)
      peer = socket.accept
      peer.write(marker)
      assert_equal marker, client.read(marker.bytesize)
      peer.close
      client.close
      previous = ENV["AGRU_SYNTHETIC_HOST_SECRET"]
      ENV["AGRU_SYNTHETIC_HOST_SECRET"] = marker
      script = 'test -z "$AGRU_SYNTHETIC_HOST_SECRET" || exit 31; for p do test ! -e "$p" || exit 32; done; test ! -S /var/run/docker.sock; test ! -S /run/host-services/ssh-auth.sock'
      result = boundary.call(argv: ["/bin/sh", "-c", script, "control", *paths, socket_path], workspace: workspace, timeout: 10)
      assert_equal "blocked", result["status"], result.inspect
      refute_includes result["stdout"], marker
      assert result["cleanup"]["confirmed"]
    ensure
      ENV["AGRU_SYNTHETIC_HOST_SECRET"] = previous
      socket&.close
      release_export(result) if result
    end
  end

  def test_real_python_canary_open_denied
    skip "set AGRU_SANDBOX_PYTHON_IMAGE for Python boundary control" unless ENV["AGRU_SANDBOX_PYTHON_IMAGE"]
    boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_SANDBOX_PYTHON_IMAGE"), limits: LIMITS)
    in_tmp do |root|
      workspace = File.join(root, "workspace")
      Dir.mkdir(workspace)
      canary = File.join(root, "canary")
      marker = SecureRandom.hex(24)
      File.write(canary, marker)
      assert_equal marker, File.read(canary)
      code = "import pathlib,sys\nassert pathlib.Path('/workspace').is_dir()\nfor p in sys.argv[1:]:\n try:\n  pathlib.Path(p).read_bytes()\n except (FileNotFoundError,PermissionError):\n  continue\n raise SystemExit('host canary readable')\npathlib.Path('python-result').write_text('ok')"
      reviewed_env = {"HOME" => "/tmp/agru-home", "XDG_CONFIG_HOME" => "/tmp/agru-home/config", "XDG_DATA_HOME" => "/tmp/agru-home/data", "XDG_CACHE_HOME" => "/tmp/agru-home/cache", "XDG_STATE_HOME" => "/tmp/agru-home/state"}
      result = boundary.call(argv: ["/bin/sh", "-c", 'exec python3 -c "$1" "$2" "$3"', "control", code, canary, "../canary"], workspace: workspace, timeout: 10, env: reviewed_env)
      assert_equal "blocked", result["status"], result.inspect
      refute result.key?("export")
    ensure
      release_export(result) if result
    end
  end

  def test_inspect_failure_never_starts_execution
    in_tmp do |workspace|
      calls = []
      fake = Object.new
      fake.define_singleton_method(:call) do |**args|
        calls << args[:argv]
        {"status" => "success", "exit_code" => 0, "stdout" => (args[:argv][1] == "inspect") ? "[]" : "", "stderr" => ""}
      end
      result = runner(process_runner: fake).call(argv: ["/bin/true"], workspace: workspace, timeout: 1)
      assert_equal "failure", result["status"]
      assert_equal %w[create inspect rm], calls.map { |args| args[1] }
      assert result["cleanup"]["confirmed"]
    end
  end

  def test_real_unknown_image_fails_closed
    real_boundary
    boundary = AgentRuntime::Execution::SandboxRunner.new(image: "sha256:#{"f" * 64}", limits: LIMITS)
    in_tmp do |workspace|
      result = boundary.call(argv: ["/bin/true"], workspace: workspace, timeout: 1)
      assert_equal "failure", result["status"]
      refute result.key?("export")
      assert result["cleanup"]["attempted"]
    end
  end

  def test_descriptor_copy_limits_and_cancellation_fail_before_docker
    in_tmp do |workspace|
      File.write(File.join(workspace, "large"), "x" * 128)
      fake = Object.new
      fake.define_singleton_method(:call) { |**| raise "docker must not execute" }
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: IMAGE, limits: LIMITS.merge("workspace_bytes" => 16), process_runner: fake)
      result = boundary.call(argv: ["/bin/true"], workspace: workspace, timeout: 1)
      assert_equal "failure", result["status"]
      assert_match(/workspace byte limit exceeded/, result["error"])
      cancellation = Object.new
      cancellation.define_singleton_method(:cancelled?) { true }
      result = runner(process_runner: fake).call(argv: ["/bin/true"], workspace: workspace, timeout: 1, cancellation: cancellation)
      assert_match(/workspace copy cancelled/, result["error"])
    end
  end

  def test_real_workspace_tmpfs_quota
    real_boundary
    boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_SANDBOX_TEST_IMAGE"), limits: LIMITS.merge("workspace_bytes" => 1_048_576))
    in_tmp do |workspace|
      result = boundary.call(argv: ["/bin/sh", "-c", "dd if=/dev/zero of=overflow bs=1048576 count=3"], workspace: workspace, timeout: 10)
      assert_equal "failure", result["status"], result.inspect
      assert_includes result["stderr"], "No space left on device"
      assert result["cleanup"]["confirmed"]
      refute result.key?("export")
    end
  end

  def test_copy_does_not_change_parent_cwd_under_concurrency
    in_tmp do |workspace|
      30.times { |index| FileUtils.mkdir_p(File.join(workspace, "d#{index}", "nested")) }
      original = Dir.pwd
      observed = []
      running = true
      observer = Thread.new do
        while running
          observed << Dir.pwd
          sleep 0.001
        end
      end
      destination = File.join(File.dirname(workspace), "copy-#{SecureRandom.hex(8)}")
      runner.send(:copy_tree!, workspace, destination, timeout: 5, cancellation: nil)
      running = false
      observer.join
      assert_equal [original], observed.uniq
    ensure
      running = false
      observer&.join
      FileUtils.remove_entry(destination) if destination && File.exist?(destination)
    end
  end

  def test_directory_replacement_race_never_copies_external_canary
    in_tmp do |root|
      source = File.join(root, "source")
      external = File.join(root, "external")
      FileUtils.mkdir_p(File.join(source, "switch"))
      Dir.mkdir(external)
      marker = SecureRandom.hex(32)
      File.write(File.join(external, "secret"), marker)
      assert_equal marker, File.read(File.join(external, "secret"))
      running = true
      attacker = Thread.new do
        while running
          begin
            File.rename(File.join(source, "switch"), File.join(source, "held"))
            File.symlink(external, File.join(source, "switch"))
            Thread.pass
            File.unlink(File.join(source, "switch"))
            File.rename(File.join(source, "held"), File.join(source, "switch"))
          rescue SystemCallError
            Thread.pass
          end
        end
      end
      20.times do |index|
        destination = File.join(root, "copy#{index}")
        begin
          runner.send(:copy_tree!, source, destination, timeout: 2, cancellation: nil)
        rescue AgentRuntime::Execution::SandboxRunner::BoundaryError, SystemCallError
          # Rejection is valid; following the replacement symlink is not.
        end
        refute Dir.glob(File.join(destination, "**", "*"), File::FNM_DOTMATCH).any? { |path| File.file?(path) && File.read(path).include?(marker) }
      end
    ensure
      running = false
      attacker&.join
    end
  end
end
