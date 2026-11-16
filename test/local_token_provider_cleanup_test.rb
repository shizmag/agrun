require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/local_token_provider"

class LocalTokenProviderCleanupTest < Minitest::Test
  def test_uncooperative_process_is_killed_and_reaped
    provider = AgentRuntime::Execution::LocalTokenProvider.new(root: Dir.pwd, ledger: {}, credential: "offline", audit_path: "unused")
    stdin, stdout, stderr, wait = Open3.popen3(RbConfig.ruby, "-e", 'trap("TERM") {}; STDOUT.puts("ready"); STDOUT.flush; loop { sleep 1 }')
    assert_equal "ready\n", stdout.gets
    provider.instance_variable_set(:@stdin, stdin)
    provider.instance_variable_set(:@stdout, stdout)
    provider.instance_variable_set(:@stderr, stderr)
    provider.instance_variable_set(:@wait, wait)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    provider.close
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15
    assert wait.value.signaled?
    assert_equal Signal.list.fetch("KILL"), wait.value.termsig
    assert_raises(Errno::ESRCH) { Process.kill(0, wait.pid) }
  ensure
    provider&.close
  end
end
