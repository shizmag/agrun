require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/budget"
require "digest"

class M12bAdversarialTest < Minitest::Test
  Budget = AgentRuntime::Execution::Budget

  def test_same_live_attempt_is_denied_concurrently_and_after_release_without_attempt_quota
    config = Budget::AdmissionConfig.new(wall_seconds: 60, max_concurrent_sessions: 2)
    coordinator = Budget::Coordinator.new(clock: -> { 100.0 })
    experiment = coordinator.open_scope(kind: "experiment", id: "pilot", config: config)
    run = coordinator.open_scope(kind: "run", id: "run", config: config, parent: experiment)
    scope = {"experiment_digest" => Digest::SHA256.hexdigest("pilot"), "task" => "retrying",
             "solver" => "single-agent", "provider" => "omniroute", "endpoint" => "https://example.invalid/v1",
             "route" => "cx/gpt-6-luna-low", "model" => "cx/gpt-6-luna-low", "mode" => "retrying"}
    grant = AgentRuntime::Execution::LiveAuthorization.new(scope: scope, expires_at: 200,
      financial_exposure: "not_hard_bounded", wall_clock: -> { 100.0 })
    profile = Budget::ModelProfile.new(id: "pilot", provider: scope.fetch("provider"),
      model: scope.fetch("model"), execution_kind: "real_provider")
    request = AgentRuntime::Request.new(run_id: "run", step_id: "step", attempt: 1,
      timeout: 30, cancellation: AgentRuntime::Cancellation.new)
    attempt_config = Budget::AdmissionConfig.new(wall_seconds: 60, max_attempts: 1, max_concurrent_sessions: 1)
    attempt = coordinator.open_scope(kind: "attempt", id: "step:1", config: attempt_config, parent: run)
    args = {scopes: [experiment, run, attempt], profile: profile, request: request,
            executable: "/fixture", executable_sha256: "a" * 64,
            authorization: grant, authorization_scope: scope}
    gate = Queue.new
    results = 2.times.map {
      Thread.new {
        gate.pop
        coordinator.admit(**args)
      }
    }
    2.times { gate << true }
    decisions = results.map(&:value)
    data = ->(decision) { decision.respond_to?(:decision) ? decision.decision.to_h : decision.to_h }
    assert_equal 1, decisions.count { |decision| data.call(decision).fetch("allowed") }
    assert_equal ["duplicate_attempt"], decisions.reject { |decision| data.call(decision).fetch("allowed") }.map { |decision| data.call(decision).fetch("reason") }
    # Dispatch stands in for a controlled fake process; denial must not call it.
    dispatches = decisions.count { |decision| data.call(decision).fetch("allowed") }
    coordinator.release(lease: decisions.find { |decision| data.call(decision).fetch("allowed") })
    after_release = coordinator.admit(**args)
    dispatches += 1 if data.call(after_release).fetch("allowed")
    assert_equal "duplicate_attempt", data.call(after_release).fetch("reason")
    assert_equal 1, dispatches
  end
end

require_relative "m12b_live_execution_test"

class M12bAdapterConcurrencyTest < M12bLiveExecutionTest
  def test_duplicate_live_attempt_never_dispatches_twice_at_adapter_boundary
    with_request do |request, executable|
      request.config["model_profile"].merge!("provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "execution_kind" => "real_provider")
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(executable: executable,
        executable_sha256: Digest::SHA256.file(executable).hexdigest, credential: "offline-fake")
      scope = launch.scope.merge("experiment_digest" => "a" * 64, "task" => "task", "solver" => "solver", "mode" => "live")
      grant = AgentRuntime::Execution::LiveAuthorization.new(scope: scope, expires_at: Time.now.to_f + 60,
        financial_exposure: "not_hard_bounded")
      request.config["model_profile"]["tool_policy"] = {"endpoint" => scope.fetch("endpoint"), "route" => scope.fetch("route"), "model_fallback" => false}
      coordinator = AgentRuntime::Execution::Budget::Coordinator.new
      config = AgentRuntime::Execution::Budget::AdmissionConfig.new(wall_seconds: 10, max_concurrent_sessions: 2)
      experiment = coordinator.open_scope(kind: "experiment", id: "experiment", config: config)
      run = coordinator.open_scope(kind: "run", id: request.run_id, config: config, parent: experiment)
      attempt_config = AgentRuntime::Execution::Budget::AdmissionConfig.new(wall_seconds: 10, max_attempts: 1, max_concurrent_sessions: 1)
      attempt = coordinator.open_scope(kind: "attempt", id: "solve:1", config: attempt_config, parent: run)
      entered = Queue.new
      release = Queue.new
      runner = RecordingRunner.new {
        entered << true
        release.pop
      }
      options = {authorization: grant, authorization_scope: scope, launch_config: launch,
                 budget: coordinator, scopes: [experiment, run, attempt]}
      first = Thread.new { adapter(executable, runner, **options).execute(request) }
      Timeout.timeout(3) { entered.pop }
      second_thread = Thread.new { adapter(executable, runner, **options).execute(request) }
      second = Timeout.timeout(2) { second_thread.value }
      assert_equal "blocked", second.status
      assert_equal 1, runner.calls.length
      release << true
      assert_equal "success", first.value.status
      release << true
      third = adapter(executable, runner, **options).execute(request)
      assert_equal "blocked", third.status
      assert_equal 1, runner.calls.length
    ensure
      2.times { release << true } if defined?(release)
      first&.join
      second_thread&.join
    end
  end
end

class M12bAdapterConcurrencyTest
  class SpoofAuthorization
    def preflight!(**) = {"scope" => {}}
  end

  class PermissiveCoordinator < AgentRuntime::Execution::Budget::Coordinator
    def admit(**) = {"admitted" => true, "scope_ids" => []}
    def release(**) = nil
  end

  def test_spoof_authorization_cannot_dispatch_even_with_permissive_coordinator
    with_request do |request, executable|
      request.config["model_profile"].merge!("provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "execution_kind" => "real_provider")
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(executable: executable, executable_sha256: Digest::SHA256.file(executable).hexdigest, credential: "offline-fake")
      scope = launch.scope.merge("experiment_digest" => "a" * 64, "task" => "task", "solver" => "solver", "mode" => "live")
      request.config["model_profile"]["tool_policy"] = {"endpoint" => scope.fetch("endpoint"), "route" => scope.fetch("route"), "model_fallback" => false}
      runner = RecordingRunner.new
      result = adapter(executable, runner, authorization: SpoofAuthorization.new, authorization_scope: scope,
        launch_config: launch, budget: PermissiveCoordinator.new, scopes: [:fake]).execute(request)
      assert_equal "blocked", result.status
      assert_empty runner.calls
    end
  end
end

require_relative "m12b_reporting_test"
require_relative "benchmark/nl2repo_test"

class M12bAdditionalAdversarialTest < Minitest::Test
  def test_fixed_endpoint_and_route
    assert_equal "http://localhost:20128/v1", AgentRuntime::Execution::OpenCodeLaunch::ENDPOINT
    in_tmp do |dir|
      executable = File.join(dir, "fake")
      File.write(executable, "fake")
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(executable: executable, executable_sha256: Digest::SHA256.file(executable).hexdigest, credential: "offline")
      assert_equal "cx/gpt-6-luna-low", launch.scope.fetch("route")
    end
  end
end

class M12bReportingAdversarialTest < M12bReportingTest
  def test_root_cache_counts_are_preserved
    with_summary do |summary|
      assert_equal 3, summary.dig("usage", "tokens", "cache_read", "known_subtotal")
      assert_equal 2, summary.dig("usage", "tokens", "cache_write", "known_subtotal")
    end
  end
end

class M12bWorkspaceAdversarialTest < NL2RepoTest
  def test_hidden_procedure_is_not_in_workspace
    in_tmp do |root|
      adapter, = fixture(root)
      adapter.prepare(allow_download: true) # Fixture URL is a local git repository; no network.
      workspace = File.join(root, "solver")
      adapter.prepare_solver_workspace(task: adapter.load_task("calculator"), workspace: workspace)
      refute File.exist?(File.join(workspace, "hidden_test.rb"))
      refute_includes Dir.glob(File.join(workspace, "**", "*")), File.join(workspace, "hidden.py")
    end
  end
end
