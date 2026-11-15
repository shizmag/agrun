require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/open_code_cli"
require "digest"
require "rbconfig"

class M12BudgetLaunchTest < Minitest::Test
  Budget = AgentRuntime::Execution::Budget

  def policy(sessions: 1)
    Budget::AdmissionConfig.new(wall_seconds: 10, max_attempts: 10,
      max_concurrent_sessions: sessions)
  end

  def with_fixture
    in_tmp do |root|
      executable = File.join(root, "inert-opencode")
      marker = File.join(root, "launches")
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        File.open(#{marker.inspect}, "a") { |file| file.puts Process.pid }
        puts JSON.generate({"type" => "step_finish", "sessionID" => "ses_fixture",
          "part" => {"id" => "part", "messageID" => "message", "sessionID" => "ses_fixture",
            "type" => "step-finish", "reason" => "stop", "cost" => 0,
            "tokens" => {"input" => 0, "output" => 0}}})
        $stdout.flush
        sleep 0.3
      RUBY
      File.chmod(0o755, executable)
      yield root, executable, marker
    end
  end

  def program(hard: false)
    limits = policy.to_h.dup
    limits["hard_limits"] = {"cost" => 1} if hard
    profile = {"id" => "offline", "provider" => "fixture", "model" => "deterministic",
               "execution_kind" => "offline_fixture", "tool_policy" => {}}
    config = {"prompt" => "inert fixture only", "model_profile" => profile, "budget_policy" => limits}
    step = {"id" => "agent", "executor" => "local", "needs" => [], "inputs" => {},
            "outputs" => {"text" => "text"}, "config" => {}, "timeout" => 3, "retries" => 0}
    {"schema_version" => 1, "name" => "budget-launch", "inputs" => {},
     "executors" => {"local" => {"adapter" => "local", "config" => config}},
     "steps" => [step],
     "outputs" => {"answer" => "agent.text"}}
  end

  def adapter(executable, coordinator, experiment, runner: AgentRuntime::Adapters::ProcessRunner.new, barrier: nil)
    scopes = lambda do |request, budget, limits|
      run = budget.open_scope(kind: "run", id: request.run_id, config: limits, parent: experiment)
      attempt = budget.open_scope(kind: "attempt", id: "#{request.step_id}:#{request.attempt}",
        config: Budget::AdmissionConfig.new(wall_seconds: 3, max_attempts: 1, max_concurrent_sessions: 1), parent: run)
      barrier&.call
      [experiment, run, attempt]
    end
    AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable,
      fixture_sha256: Digest::SHA256.file(executable).hexdigest,
      budget: coordinator, scopes: scopes, runner: runner)
  end

  def execute(root, adapter, name, hard: false, cancellation: nil)
    store = AgentRuntime::Store.new(File.join(root, name))
    report = AgentRuntime::Runtime.new(store: store, executors: {local: adapter})
      .run(program(hard: hard), cancellation: cancellation)
    reopened = AgentRuntime::Store.new(store.root)
    persisted = reopened.report(report.fetch("run_id"))
    attempt = persisted.fetch("steps").fetch("agent").fetch("attempts").first
    trace = attempt && attempt["log"] && JSON.parse(reopened.value(attempt.fetch("log"))).fetch("execution")
    [persisted, trace]
  end

  def test_shared_experiment_admits_one_actual_launch_and_persists_both_decisions
    with_fixture do |root, executable, marker|
      budget = Budget::Coordinator.new
      experiment = budget.open_scope(kind: "experiment", id: "shared", config: policy)
      ready = Queue.new
      start = Queue.new
      barrier = -> {
        ready << true
        start.pop
      }
      local = adapter(executable, budget, experiment, barrier: barrier)
      threads = 2.times.map { |index| Thread.new { execute(root, local, "store-#{index}") } }
      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)
      assert_equal 1, File.readlines(marker).size, "only admitted invocation may launch"
      assert_equal [false, true], results.map { |_, trace| trace.fetch("admission").fetch("allowed") }.sort_by(&:to_s)
      blocked = results.find { |_, trace| !trace.fetch("admission").fetch("allowed") }
      assert_equal "concurrency_exhausted", blocked.last.dig("admission", "reason")
      assert_equal "blocked", blocked.first.dig("steps", "agent", "status")
      allowed = results.find { |_, trace| trace.fetch("admission").fetch("allowed") }
      assert_equal "success", allowed.first.fetch("status")
    end
  end

  def test_unsupported_hard_money_never_launches
    with_fixture do |root, executable, marker|
      budget = Budget::Coordinator.new
      experiment = budget.open_scope(kind: "experiment", id: "shared", config: policy)
      report, trace = execute(root, adapter(executable, budget, experiment), "store", hard: true)
      refute File.exist?(marker)
      assert_equal "blocked", report.dig("steps", "agent", "status")
      assert_equal "invalid_configuration", trace.dig("admission", "reason")
      assert_includes report.dig("steps", "agent", "attempts", 0, "error", "message"), "unsupported_hard_limit"
    end
  end

  def test_cancelled_process_releases_capacity_for_next_run
    with_fixture do |root, executable, marker|
      budget = Budget::Coordinator.new
      experiment = budget.open_scope(kind: "experiment", id: "shared", config: policy)
      local = adapter(executable, budget, experiment)
      cancellation = AgentRuntime::Cancellation.new
      thread = Thread.new { execute(root, local, "cancelled", cancellation: cancellation) }
      Timeout.timeout(3) { Thread.pass until File.exist?(marker) }
      cancellation.cancel!
      first, trace = thread.value
      assert_equal "cancelled", first.dig("steps", "agent", "status")
      assert trace.dig("admission", "allowed")
      second, second_trace = execute(root, local, "next")
      assert second_trace.dig("admission", "allowed")
      assert_equal "success", second.fetch("status")
      assert_equal 2, File.readlines(marker).size
    end
  end

  def test_launch_failure_releases_capacity_for_next_run
    with_fixture do |root, executable, marker|
      budget = Budget::Coordinator.new
      experiment = budget.open_scope(kind: "experiment", id: "shared", config: policy)
      runner = Object.new
      runner.define_singleton_method(:call) { |**_args| raise Errno::ENOENT, "inert launch failure" }
      broken = adapter(executable, budget, experiment, runner: runner)
      first, first_trace = execute(root, broken, "failed")
      refute File.exist?(marker)
      assert_equal "failure", first.dig("steps", "agent", "status")
      second, trace = execute(root, adapter(executable, budget, experiment), "next")
      assert trace.dig("admission", "allowed")
      assert_equal "success", second.fetch("status")
      assert_equal 1, File.readlines(marker).size
      refute_nil first_trace, "launch failure must retain persisted pre-launch admission evidence"
      assert first_trace.dig("admission", "allowed")
    end
  end
end
