require_relative "test_helper"
require "socket"
require "timeout"
require "rbconfig"
require_relative "../lib/agent_runtime/adapters/process_runner"

class M12aProcessRunnerLifecycleTest < Minitest::Test
  # Both processes keep a socket open until death. EOF proves termination without
  # confusing a dead, not-yet-reaped grandchild with a live process via kill(0).
  FIXTURE = <<~RUBY
    require "socket"
    trap("TERM", "IGNORE")
    child = fork do
      socket = UNIXSocket.new(ARGV.fetch(0))
      socket.puts Process.pid
      sleep
    end
    socket = UNIXSocket.new(ARGV.fetch(0))
    socket.puts Process.pid
    exit! if ARGV[1] == "exit_leader"
    sleep
  RUBY

  def test_timeout_terminates_descendants_and_reaps_direct_child
    with_descendants(:timeout) { |result| assert_equal "timeout", result.fetch("status") }
  end

  def test_cancellation_terminates_descendants_and_reaps_direct_child
    with_descendants(:cancel) { |result| assert_equal "cancelled", result.fetch("status") }
  end

  def test_cancellation_delivers_term_before_kill
    Dir.mktmpdir do |dir|
      ready = File.join(dir, "ready")
      marker = File.join(dir, "term")
      child = File.join(dir, "child.rb")
      File.write(child, <<~RUBY)
        trap("TERM") { File.write(#{marker.inspect}, "term"); exit }
        File.write(#{ready.inspect}, "ready")
        sleep 5
      RUBY
      token = AgentRuntime::Cancellation.new
      worker = Thread.new { AgentRuntime::Adapters::ProcessRunner.new.call(argv: [RbConfig.ruby, child], cwd: dir, timeout: 3, cancellation: token) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until File.exist?(ready) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      assert File.exist?(ready), "child never started"
      token.cancel!
      assert_equal "cancelled", worker.value.fetch("status")
      assert File.exist?(marker), "child never received TERM before forced KILL"
    ensure
      token&.cancel!
      worker&.join
    end
  end

  def test_outer_timeout_cleans_descendants_before_propagating
    with_descendants(:outer) { |error| assert_instance_of Timeout::Error, error }
  end

  def test_outer_timeout_cleans_descendant_after_direct_child_was_reaped
    with_descendants(:outer_reaped) { |error| assert_instance_of Timeout::Error, error }
  end

  def test_pre_cancel_does_not_spawn
    in_tmp do |dir|
      token = AgentRuntime::Cancellation.new
      token.cancel!
      marker = File.join(dir, "spawned")
      result = runner.call(argv: [RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'spawned')", marker], cwd: dir, timeout: 1, cancellation: token)
      assert_equal "cancelled", result.fetch("status")
      refute_path_exists marker
      assert_nil result.fetch("exit_code")
    end
  end

  def test_cleanup_retains_failed_kill_observation_without_replacing_exception
    in_tmp do |dir|
      calls = 0
      token = Object.new
      token.define_singleton_method(:cancelled?) do
        calls += 1
        raise Timeout::Error, "injected supervision interruption" if calls > 1
        false
      end
      instance = runner
      signal = instance.method(:signal_group)
      instance.define_singleton_method(:signal_group) do |name, pid|
        signal.call(name, pid)
        raise Errno::EPERM, "injected observation after real cleanup"
      end
      error = assert_raises(Timeout::Error) do
        instance.call(argv: [RbConfig.ruby, "-e", "sleep"], cwd: dir, timeout: 10, cancellation: token)
      end
      assert_equal "injected supervision interruption", error.message
      cleanup = error.instance_variable_get(:@process_cleanup)
      assert_equal true, cleanup.fetch("reaped")
      assert_equal "kill", cleanup.fetch("errors").first.fetch("operation")
      assert_equal "Errno::EPERM", cleanup.fetch("errors").first.fetch("class")
    end
  end

  def test_concurrent_overflow_is_bounded_and_independently_flagged
    in_tmp do |dir|
      script = "threads = [Thread.new { STDOUT.write('a' * 1_048_577) }, Thread.new { STDERR.write('b' * 1_048_577) }]; threads.each(&:join)"
      result = Timeout.timeout(10) { runner.call(argv: [RbConfig.ruby, "-e", script], cwd: dir, timeout: 5) }
      assert_equal "success", result.fetch("status")
      assert_equal true, result.fetch("stdout_truncated")
      assert_equal true, result.fetch("stderr_truncated")
      assert_equal true, result.fetch("truncated")
      %w[stdout stderr].zip(%w[a b]).each do |stream, byte|
        assert_equal 1_048_576, result.fetch(stream).bytesize
        assert result.fetch(stream) == byte * 1_048_576, "#{stream} must retain exactly its bounded prefix"
      end
    end
  end

  def test_exact_capture_limit_does_not_mark_truncation
    in_tmp do |dir|
      result = Timeout.timeout(10) { runner.call(argv: [RbConfig.ruby, "-e", "STDOUT.write('a' * 1_048_576)"], cwd: dir, timeout: 5) }
      assert_equal false, result.fetch("stdout_truncated")
      assert_equal false, result.fetch("stderr_truncated")
      assert_equal 1_048_576, result.fetch("stdout").bytesize
    end
  end

  def test_invalid_utf8_fails_with_lossless_json_evidence
    in_tmp do |dir|
      result = runner.call(argv: [RbConfig.ruby, "-e", "STDOUT.binmode.write([255, 97].pack('C*')); STDERR.binmode.write([254].pack('C*'))"], cwd: dir, timeout: 5)
      assert_equal "failure", result.fetch("status")
      assert_equal "invalid_utf8_output", result.fetch("encoding_error")
      assert_equal "", result.fetch("stdout")
      assert_equal [255, 97], result.fetch("binary_output_base64").fetch("stdout").unpack1("m0").bytes
      assert_equal [254], result.fetch("binary_output_base64").fetch("stderr").unpack1("m0").bytes
      assert_equal result, JSON.parse(JSON.generate(result))
    end
  end

  private

  def runner
    AgentRuntime::Adapters::ProcessRunner.new
  end

  def with_descendants(mode)
    in_tmp do |dir|
      server = UNIXServer.new(File.join(dir, "ready.sock"))
      connections = []
      pids = []
      token = AgentRuntime::Cancellation.new
      # Deadline is gated on BOTH readiness handshakes, not Ruby startup time.
      expired = false
      clock = Process.method(:clock_gettime)
      controlled_clock = ->(kind, *args) { clock.call(kind, *args) + (expired ? 100 : 0) }
      worker = nil
      Process.stub(:clock_gettime, controlled_clock) do
        worker = Thread.new do
          Thread.current.report_on_exception = false
          if [:outer, :outer_reaped].include?(mode)
            Timeout.timeout(3) do
              runner.call(argv: [RbConfig.ruby, "-e", FIXTURE, server.path, (mode == :outer_reaped) ? "exit_leader" : "keep_leader"], cwd: dir, timeout: 30, cancellation: token)
            end
          else
            runner.call(argv: [RbConfig.ruby, "-e", FIXTURE, server.path], cwd: dir, timeout: 30, cancellation: token)
          end
        rescue Timeout::Error => error
          error
        end
        Timeout.timeout(10) do
          2.times do
            connection = server.accept
            connections << connection
            pids << Integer(connection.gets)
          end
        end
        assert worker.alive?, "supervision must still be active after both readiness handshakes"
        token.cancel! if mode == :cancel
        expired = true if mode == :timeout
        result = Timeout.timeout(10) { worker.value }
        yield result
        unless result.is_a?(Exception)
          cleanup = result.fetch("cleanup")
          assert_equal true, cleanup.fetch("reaped")
          assert_empty cleanup.fetch("errors")
        end
        connections.each do |connection|
          assert IO.select([connection], nil, nil, 0.5), "fixture process survived runner completion (#{mode})"
          assert_nil connection.read(1), "fixture socket must close on process death"
        end
        # One fixture PID is the direct child; neither may be waitable here.
        pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
      end
    ensure
      # Never let fallback cleanup satisfy the assertions above.
      pids&.each do |pid|
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      token&.cancel!
      worker&.join(2)
      pids&.each do |pid|
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end
      connections&.each(&:close)
      server&.close
    end
  end
end
