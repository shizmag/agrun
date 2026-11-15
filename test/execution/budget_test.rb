require_relative "../test_helper"
require "digest"

class ExecutionBudgetTest < Minitest::Test
  def setup
    # Deliberately loaded here: Gate 3/4 must expose the absent implementation
    # as baseline errors rather than silently skip these acceptance contracts.
    require_relative "../../lib/agent_runtime/execution/budget"
    @api = AgentRuntime::Execution::Budget
    @now = 100.0
    @events = []
    @profile = @api::ModelProfile.new(id: "fixture", provider: "fixture",
      model: "deterministic", execution_kind: "offline_fixture", tool_policy: {})
    @executable = File.expand_path("../fixtures/not-a-provider", __dir__)
    @identity = "a" * 64
    @grant = {"mode" => "offline_fixture", "executable" => @executable,
              "sha256" => @identity, "profile_digest" => profile_digest,
              "experiment_id" => "exp", "run_id" => "run"}
    @coordinator = coordinator
  end

  def profile_digest(profile = @profile)
    Digest::SHA256.hexdigest(AgentRuntime::IR.dump(profile.to_h))
  end

  def coordinator
    @api::Coordinator.new(clock: -> { @now })
  end

  def config(wall: 30, attempts: 10, sessions: 2, **extra)
    @api::AdmissionConfig.new(wall_seconds: wall, max_attempts: attempts,
      max_concurrent_sessions: sessions, **extra)
  end

  def chain(coordinator: @coordinator, run: "run", experiment: nil, pool: nil,
    run_config: config, attempt: 1)
    experiment ||= coordinator.open_scope(kind: "experiment", id: "exp",
      config: config, parent: pool)
    run_scope = coordinator.open_scope(kind: "run", id: run,
      config: run_config, parent: experiment)
    attempt_scope = coordinator.open_scope(kind: "attempt", id: "step:#{attempt}",
      config: config(attempts: 1, sessions: 1), parent: run_scope)
    [pool, experiment, run_scope, attempt_scope].compact
  end

  def request(run: "run", attempt: 1, timeout: 20)
    AgentRuntime::Request.new(run_id: run, step_id: "step", attempt: attempt,
      inputs: {}, config: {}, workspace: ".", timeout: timeout,
      cancellation: AgentRuntime::Cancellation.new)
  end

  def admit(scopes, req = request, profile: @profile, coordinator: @coordinator, &sink)
    sink ||= ->(event) { @events << [event.to_h, req] }
    coordinator.admit(scopes: scopes, profile: profile, request: req,
      executable: @executable, executable_sha256: @identity,
      authorization: ->(**_identity) { @grant }, &sink)
  end

  def decision(outcome)
    outcome.respond_to?(:decision) ? outcome.decision.to_h : outcome.to_h
  end

  def retry_chain(scopes, number)
    scopes[0...-1] + [@coordinator.open_scope(kind: "attempt", id: "step:#{number}",
      config: config(attempts: 1, sessions: 1), parent: scopes[-2])]
  end

  def test_profile_normalizes_copies_and_deeply_freezes_values
    policy = {"allowed" => ["read"]}
    profile = @api::ModelProfile.new(id: "fixture", provider: "fixture",
      model: "deterministic", execution_kind: "offline_fixture", tool_policy: policy)
    before = profile_digest(profile)
    policy["allowed"] << "write"
    assert profile.frozen?
    assert_equal ["read"], profile.to_h.fetch("tool_policy").fetch("allowed")
    assert_equal before, profile_digest(profile)
    assert_equal JSON.parse(JSON.generate(profile.to_h)), profile.to_h
  end

  def test_required_limits_reject_invalid_numbers
    [0, -1, Float::NAN, Float::INFINITY, "1", true, nil].each do |bad|
      assert_raises(ArgumentError) { config(wall: bad) }
    end
    [0, -1, 1.5, "1", true, nil].each do |bad|
      assert_raises(ArgumentError) { config(attempts: bad) } unless bad.nil?
      assert_raises(ArgumentError) { config(sessions: bad) }
    end
    assert_nil config(attempts: nil).to_h.fetch("max_attempts")
    assert_raises(ArgumentError) { @api::AdmissionConfig.new(wall_seconds: 1) }
  end

  def test_unsupported_hard_limits_fail_instead_of_becoming_advisory
    %w[cost tokens model tools].each do |name|
      error = assert_raises(ArgumentError) { config(hard_limits: {name => 1}) }
      assert_includes error.message, "unsupported_hard_limit"
    end
    assert_empty @events
  end

  def test_admission_callback_receives_json_decision_before_caller_can_execute
    scopes = chain
    req = request
    lease = admit(scopes, req)
    data = decision(lease)
    assert_equal true, data.fetch("allowed")
    assert_equal "admitted", data.fetch("reason")
    assert_equal 1, data.fetch("schema_version")
    assert_equal profile_digest, data.fetch("profile_digest")
    assert_equal 20, lease.timeout
    assert_equal [[data, req]], @events
    assert_equal data, JSON.parse(JSON.generate(data))
    data.fetch("scopes").each do |scope|
      assert_equal 0, scope.fetch("attempts_before")
      assert_equal 1, scope.fetch("attempts_after")
      assert_equal 1, scope.fetch("active_after")
    end
  ensure
    @coordinator&.release(lease: lease) if lease
  end

  def test_default_authorization_denies_without_consuming_capacity
    @grant = nil
    data = decision(admit(chain))
    assert_equal false, data.fetch("allowed")
    assert_equal "authorization_required", data.fetch("reason")
    assert_equal 1, @events.size
    data.fetch("scopes").each do |scope|
      assert_equal scope.fetch("attempts_before"), scope.fetch("attempts_after")
      assert_equal scope.fetch("active_before"), scope.fetch("active_after")
    end
  end

  def test_real_provider_is_denied_even_with_matching_host_grant_and_live_config
    profile = @api::ModelProfile.new(id: "live", provider: "provider",
      model: "model", execution_kind: "real_provider", tool_policy: {})
    @grant = @grant.merge("mode" => "live", "profile_digest" => profile_digest(profile))
    req = request
    req.config["live"] = true
    data = decision(admit(chain, req, profile: profile))
    assert_equal false, data.fetch("allowed")
    assert_equal "real_provider_disabled", data.fetch("reason")
  end

  def test_offline_grant_requires_all_host_identity_bindings
    scopes = chain
    original = @grant
    {"executable" => "/wrong", "sha256" => "b" * 64,
     "profile_digest" => "c" * 64, "experiment_id" => "wrong",
     "run_id" => "wrong", "mode" => "live"}.each do |key, value|
      @grant = original.merge(key => value)
      assert_equal "authorization_mismatch", decision(admit(scopes)).fetch("reason"), key
    end
  end

  def test_idle_scope_deadline_denies_at_exact_boundary
    scopes = chain(run_config: config(wall: 3))
    @now += 3
    data = decision(admit(scopes))
    assert_equal "wall_exhausted", data.fetch("reason")
    assert_equal({"kind" => "run", "id" => "run"}, data.fetch("denied_scope"))
    assert_nil data.fetch("effective_timeout_seconds")
  end

  def test_setup_elapsed_reduces_timeout_and_expiry_prevents_spawn
    scopes = chain(run_config: config(wall: 5))
    @now += 1
    lease = admit(scopes)
    assert_equal 4, lease.timeout
    @now += 2
    assert_equal 2, @coordinator.remaining_timeout(lease: lease)
    @now += 2
    assert_nil @coordinator.remaining_timeout(lease: lease)
  ensure
    @coordinator&.release(lease: lease) if lease
  end

  def test_release_is_idempotent_and_never_refunds_attempts
    scopes = chain(run_config: config(attempts: 1))
    lease = admit(scopes)
    2.times { @coordinator.release(lease: lease) }
    data = decision(admit(retry_chain(scopes, 2), request(attempt: 2)))
    assert_equal "attempts_exhausted", data.fetch("reason")
    run = data.fetch("scopes").find { |scope| scope.fetch("kind") == "run" }
    assert_equal 1, run.fetch("attempts_after")
    assert_equal 0, run.fetch("active_after")
  end

  def test_duplicate_attempt_denies_after_release
    scopes = chain
    lease = admit(scopes)
    @coordinator.release(lease: lease)
    assert_equal "duplicate_attempt", decision(admit(scopes)).fetch("reason")
  end

  def test_concurrent_admissions_are_atomic_and_terminal_without_queue
    scopes = chain(run_config: config(sessions: 1))
    second = retry_chain(scopes, 2)
    ready = Queue.new
    start = Queue.new
    threads = [scopes, second].each_with_index.map do |candidate, index|
      Thread.new do
        ready << true
        start.pop
        admit(candidate, request(attempt: index + 1))
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    outcomes = threads.map(&:value)
    assert_equal 1, outcomes.count { |outcome| decision(outcome).fetch("allowed") }
    denied = outcomes.find { |outcome| !decision(outcome).fetch("allowed") }
    assert_equal "concurrency_exhausted", decision(denied).fetch("reason")
    decision(denied).fetch("scopes").each do |scope|
      assert_equal scope.fetch("attempts_before"), scope.fetch("attempts_after")
      assert_equal scope.fetch("active_before"), scope.fetch("active_after")
    end
  ensure
    outcomes&.each do |outcome|
      @coordinator.release(lease: outcome) if decision(outcome).fetch("allowed")
    end
  end

  def test_shared_experiment_caps_distinct_runs
    experiment = @coordinator.open_scope(kind: "experiment", id: "exp",
      config: config(attempts: 1))
    first = chain(experiment: experiment)
    second = chain(experiment: experiment, run: "other")
    lease = admit(first)
    @coordinator.release(lease: lease)
    @grant = @grant.merge("run_id" => "other")
    data = decision(admit(second, request(run: "other")))
    assert_equal "attempts_exhausted", data.fetch("reason")
    assert_equal({"kind" => "experiment", "id" => "exp"}, data.fetch("denied_scope"))
  end

  def test_foreign_and_incomplete_scope_chains_reject_before_callback
    scopes = chain
    assert_raises(ArgumentError) { admit(scopes.drop(1)) }
    assert_raises(ArgumentError) { admit(scopes, coordinator: coordinator) }
    assert_empty @events
  end

  def test_shared_pool_caps_distinct_experiments
    pool = @coordinator.open_scope(kind: "pool", id: "pool", config: config(attempts: 1))
    first = chain(pool: pool)
    experiment = @coordinator.open_scope(kind: "experiment", id: "exp-other",
      config: config, parent: pool)
    second = chain(pool: pool, experiment: experiment, run: "other")
    lease = admit(first)
    @coordinator.release(lease: lease)
    @grant = @grant.merge("experiment_id" => "exp-other", "run_id" => "other")
    data = decision(admit(second, request(run: "other")))
    assert_equal "attempts_exhausted", data.fetch("reason")
    assert_equal({"kind" => "pool", "id" => "pool"}, data.fetch("denied_scope"))
  end

  def test_request_timeout_also_decreases_during_setup
    lease = admit(chain, request(timeout: 2))
    @now += 1
    assert_equal 1, @coordinator.remaining_timeout(lease: lease)
    @now += 1
    assert_nil @coordinator.remaining_timeout(lease: lease)
  ensure
    @coordinator&.release(lease: lease) if lease
  end

  def test_callback_failure_releases_capacity_but_consumes_admitted_attempt
    scopes = chain(run_config: config(attempts: 2, sessions: 1))
    error = assert_raises(IOError) do
      admit(scopes) { |_event| raise IOError, "evidence unavailable" }
    end
    assert_equal "evidence unavailable", error.message
    lease = admit(retry_chain(scopes, 2), request(attempt: 2))
    assert decision(lease).fetch("allowed")
    run = decision(lease).fetch("scopes").find { |scope| scope.fetch("kind") == "run" }
    assert_equal 1, run.fetch("attempts_before")
    assert_equal 0, run.fetch("active_before")
  ensure
    @coordinator&.release(lease: lease) if lease
  end
end
