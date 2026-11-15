require_relative "test_helper"
require "rbconfig"
require_relative "../lib/agent_runtime/execution/sandbox_archive_transport"

class M12cArchiveTransportTest < Minitest::Test
  def transport(code, max_bytes: 3_000_000, timeout: 3, cancellation: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "archive")
      deadline = AgentRuntime::Execution::SandboxDeadline.new(timeout: timeout, cancellation: cancellation)
      result = AgentRuntime::Execution::SandboxArchiveTransport.new.call(
        argv: [RbConfig.ruby, "-e", code], cwd: dir, path: path,
        deadline: deadline, max_bytes: max_bytes
      )
      yield result, File.binread(path)
    end
  end

  def test_binary_archive_larger_than_process_runner_cap
    transport('STDOUT.binmode; STDOUT.write("\\xFF\\x00".b * 700_000)') do |result, data|
      assert_equal "success", result.fetch("status")
      assert_equal "\xFF\x00".b * 700_000, data
      assert result.dig("cleanup", "reaped")
    end
  end

  def test_overflow_never_writes_more_than_limit
    transport('STDOUT.write("x" * 100_000)', max_bytes: 100) do |result, data|
      assert_equal "failure", result.fetch("status")
      assert_equal "archive byte limit exceeded", result.fetch("error")
      assert_operator data.bytesize, :<=, 100
      assert result.dig("cleanup", "reaped")
    end
  end

  def test_timeout_kills_term_ignoring_process_and_reaps
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    transport('trap("TERM", "IGNORE"); sleep 10', timeout: 0.1) do |result, _|
      assert_equal "timeout", result.fetch("status")
      assert result.dig("cleanup", "reaped")
      assert_empty result.dig("cleanup", "errors")
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_cancelled_deadline_does_not_launch
    token = AgentRuntime::Cancellation.new
    token.cancel!
    transport('abort "should not run"', cancellation: token) do |result, data|
      assert_equal "cancelled", result.fetch("status")
      assert_empty data
    end
  end

  def test_stderr_is_capped_but_drained
    transport('STDERR.write("z" * 200_000); STDOUT.write("ok")') do |result, data|
      assert_equal "success", result.fetch("status")
      assert_equal "ok", data
      assert_equal 16_384, result.fetch("stderr").bytesize
      assert result.fetch("stderr_truncated")
    end
  end

  def test_cancellation_while_streaming
    token = AgentRuntime::Cancellation.new
    worker = Thread.new {
      sleep 0.1
      token.cancel!
    }
    transport('trap("TERM", "IGNORE"); loop { STDOUT.write("x" * 100); STDOUT.flush; sleep 0.01 }', cancellation: token) do |result, _|
      assert_equal "cancelled", result.fetch("status")
      assert result.dig("cleanup", "reaped")
    end
  ensure
    worker&.join
  end

  def test_already_consumed_shared_deadline_is_not_reset
    Dir.mktmpdir do |dir|
      now = 1.0
      deadline = AgentRuntime::Execution::SandboxDeadline.new(timeout: 1, clock: -> { now })
      now = 2.0
      result = AgentRuntime::Execution::SandboxArchiveTransport.new.call(
        argv: [RbConfig.ruby, "-e", 'abort "should not run"'], cwd: dir,
        path: File.join(dir, "archive"), deadline: deadline, max_bytes: 100
      )
      assert_equal "timeout", result.fetch("status")
      assert_equal 0, result.fetch("bytes")
    end
  end
end
