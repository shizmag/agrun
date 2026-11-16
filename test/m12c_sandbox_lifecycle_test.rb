require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

class M12cSandboxLifecycleTest < Minitest::Test
  class Interceptor
    def initialize(&hook)
      @hook = hook
      @runner = AgentRuntime::Adapters::ProcessRunner.new
    end

    def call(**args)
      @hook.call(args)
      raw = @runner.call(**args)
      @after&.call(args, raw)
      raw
    end

    def after(&hook)
      @after = hook
      self
    end
  end

  def setup
    skip "explicit Docker lifecycle opt-in required" unless ENV["AGRU_S2_EXPORT_DOCKER"] == "1"
  end

  def run_boundary(runner:, timeout: 5, cancellation: nil, argv: ["/bin/true"])
    Dir.mktmpdir do |workspace|
      boundary = AgentRuntime::Execution::SandboxRunner.new(
        image: ENV.fetch("AGRU_S2_EXPORT_IMAGE", "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1"),
        limits: {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}, process_runner: runner
      )
      result = boundary.call(argv: argv, workspace: workspace, timeout: timeout, cancellation: cancellation,
        env: {"HOME" => "/tmp/home", "XDG_CONFIG_HOME" => "/tmp/config", "XDG_DATA_HOME" => "/tmp/data", "XDG_CACHE_HOME" => "/tmp/cache"})
      refute result.key?("export"), result.inspect
      refute result.key?("export_directory"), result.inspect
      assert result.dig("cleanup", "confirmed"), result.inspect
      yield result
    end
  end

  def test_cancel_during_quiescence_never_exports
    token = AgentRuntime::Cancellation.new
    runner = Interceptor.new { |args| token.cancel! if args[:argv][1] == "logs" }
    run_boundary(runner: runner, cancellation: token, argv: ["/bin/sleep", "10"]) do |result|
      assert_equal "cancelled", result["status"], result.inspect
    end
  end

  def test_expired_deadline_before_export_never_accepts_partial
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    runner = Interceptor.new do |args|
      if args[:argv].include?("/control/status.json")
        sleep args[:timeout] + 0.05
      end
    end
    run_boundary(runner: runner, timeout: 2) do |result|
      assert_equal "timeout", result["status"], result.inspect
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 12.5
  end

  def test_container_disappearance_never_accepts_partial
    removed = false
    runner = Interceptor.new do |args|
      if args[:argv][1] == "logs"
        system("docker", "rm", "--force", args[:argv].last, out: File::NULL, err: File::NULL)
        removed = true
      end
    end
    # Docker rm of an already absent named container succeeds on this engine;
    # regardless of cleanup reporting, disappearance must not yield an export.
    run_boundary(runner: runner) { |result| assert_equal "failure", result["status"], result.inspect }
    assert removed, "test did not reach quiescence"
  end

  def test_untrusted_effective_environment_is_rejected_before_start
    ["LD_PRELOAD=/evil.so", "PYTHONPATH=/workspace", "HOME=/evil"].each do |entry|
      started = false
      runner = Interceptor.new { |args| started = true if args[:argv][1] == "start" }.after do |args, raw|
        if args[:argv][1] == "inspect"
          data = JSON.parse(raw.fetch("stdout"))
          data.first.fetch("Config").fetch("Env") << entry
          raw["stdout"] = JSON.generate(data)
        end
      end
      run_boundary(runner: runner) { |result| assert_equal "failure", result["status"], result.inspect }
      refute started, "untrusted effective environment reached container start"
    end
  end

  def test_caller_loader_environment_is_rejected_before_docker
    called = false
    boundary = AgentRuntime::Execution::SandboxRunner.new(
      image: "sha256:#{"a" * 64}", limits: {"cpus" => 1, "memory_bytes" => 1024, "pids" => 8, "tmpfs_bytes" => 1024},
      process_runner: Interceptor.new { called = true }
    )
    %w[LD_PRELOAD PYTHONPATH].each do |key|
      assert_raises(ArgumentError) { boundary.call(argv: ["/bin/true"], workspace: ".", timeout: 1, env: {key => "/evil"}) }
    end
    refute called
  end

  def test_timeout_during_real_docker_archive_stream_never_accepts_partial
    require_relative "../lib/agent_runtime/execution/sandbox_archive_transport"
    transport = AgentRuntime::Execution::SandboxArchiveTransport.new
    archive_result = nil
    wrapper = Object.new
    wrapper.define_singleton_method(:call) do |**args|
      if args[:argv].last == "/control/archive.tar"
        # Read actual supervisor archive bytes, flush them through Docker exec,
        # then hold the stream open beyond the existing request deadline.
        argv = args[:argv].take(5) + ["/usr/bin/python3", "-I", "-S", "-c",
          'import sys,time; f=open("/control/archive.tar","rb"); sys.stdout.buffer.write(f.read(512)); sys.stdout.buffer.flush(); time.sleep(30)']
        archive_result = transport.call(**args.merge(argv: argv))
      else
        transport.call(**args)
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AgentRuntime::Execution::SandboxArchiveTransport.stub(:new, -> { wrapper }) do
      run_boundary(runner: Interceptor.new { |_args| }, timeout: 3) do |result|
        assert_equal "timeout", result["status"], result["error"]
        assert_match(/export archive/, result["error"])
      end
    end
    refute_nil archive_result, "archive transport was not reached"
    assert_operator archive_result.fetch("bytes"), :>, 0
    assert_equal "timeout", archive_result.fetch("status")
    assert archive_result.dig("cleanup", "reaped")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 13.5
  end
end
