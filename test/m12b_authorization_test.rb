require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/budget"
require "digest"

# Conditional require lets the original implementation fail as assertions rather
# than aborting discovery with LoadError. Production must provide the new class.
authorization_file = File.expand_path("../lib/agent_runtime/execution/live_authorization.rb", __dir__)
require authorization_file if File.file?(authorization_file)

class M12bAuthorizationTest < Minitest::Test
  Budget = AgentRuntime::Execution::Budget

  def scope
    {"experiment_digest" => Digest::SHA256.hexdigest("frozen pilot fixture"),
     "task" => "task-1", "solver" => "solver-1", "provider" => "omniroute",
     "endpoint" => "https://omniroute.example.invalid/v1",
     "route" => "cx/gpt-6-luna-low", "model" => "cx/gpt-6-luna-low",
     "mode" => "retrying"}
  end

  def authorization(**options)
    assert AgentRuntime::Execution.const_defined?(:LiveAuthorization, false),
      "M1.2b requires scoped LiveAuthorization before any provider launch"
    AgentRuntime::Execution.const_get(:LiveAuthorization).new(
      scope: scope, expires_at: 200.0, financial_exposure: "not_hard_bounded",
      wall_clock: -> { 100.0 }, **options
    )
  end

  def policy(max_attempts: nil, wall_seconds: 10, sessions: 1)
    Budget::AdmissionConfig.new(wall_seconds: wall_seconds,
      max_attempts: max_attempts, max_concurrent_sessions: sessions)
  end

  def coordinator_scopes(coordinator, config)
    experiment = coordinator.open_scope(kind: "experiment", id: "pilot", config: config)
    run = coordinator.open_scope(kind: "run", id: "run-1", config: config, parent: experiment)
    [experiment, run]
  end

  def profile
    Budget::ModelProfile.new(id: "fixture", provider: "fixture",
      model: "deterministic", execution_kind: "offline_fixture")
  end

  def admit(coordinator, scopes, attempt)
    attempt_scope = coordinator.open_scope(kind: "attempt", id: "step:#{attempt}",
      config: policy(max_attempts: 1), parent: scopes.last)
    request = AgentRuntime::Request.new(run_id: "run-1", step_id: "step", attempt: attempt,
      timeout: 10, config: {}, inputs: {}, workspace: ".")
    executable = File.expand_path("fixtures/inert-opencode", __dir__)
    sha = "a" * 64
    grant = {"mode" => "offline_fixture", "executable" => executable,
             "sha256" => sha, "profile_digest" => Digest::SHA256.hexdigest(AgentRuntime::IR.dump(profile.to_h)),
             "experiment_id" => "pilot", "run_id" => "run-1"}
    coordinator.admit(scopes: scopes + [attempt_scope], profile: profile, request: request,
      executable: executable, executable_sha256: sha, authorization: ->(**) { grant })
  end

  def decision(outcome)
    outcome.respond_to?(:decision) ? outcome.decision.to_h : outcome.to_h
  end

  def test_scoped_evidence_is_a_deep_frozen_copy
    input = scope
    grant = authorization(scope: input)
    input["task"] = "changed"
    evidence = grant.preflight!(scope: scope)
    assert_equal scope, evidence.fetch("scope")
    assert_equal "not_hard_bounded", evidence.fetch("financial_exposure")
    assert_equal 200.0, evidence.fetch("expires_at")
    assert_equal evidence, grant.to_h
    assert_predicate evidence, :frozen?
    assert_predicate evidence.fetch("scope"), :frozen?
    assert_predicate evidence.fetch("scope").fetch("task"), :frozen?
  end

  def test_every_scope_field_is_compared_without_alias_or_endpoint_fallback
    grant = authorization
    scope.each_key do |field|
      changed = scope.merge(field => "different")
      assert_raises(ArgumentError, "must reject changed #{field}") { grant.preflight!(scope: changed) }
      assert_raises(ArgumentError, "must reject missing #{field}") { grant.preflight!(scope: scope.reject { |key, _| key == field }) }
    end
    assert_raises(ArgumentError) { grant.preflight!(scope: scope.merge("fallback" => "other")) }
  end

  def test_invalid_scope_is_not_an_authorization
    [scope.merge("experiment_digest" => "not-a-digest"),
      scope.merge("model" => ""), scope.transform_keys(&:to_sym),
      scope.merge("endpoint" => "https://secret@example.invalid/v1"),
      scope.merge("endpoint" => "https://example.invalid/v1?api_key=secret")].each do |invalid|
      assert_raises(ArgumentError) { authorization(scope: invalid) }
    end
  end

  def test_expiration_is_rechecked_at_each_launch_and_boundary_is_closed
    now = 199.0
    grant = authorization(wall_clock: -> { now })
    assert grant.preflight!(scope: scope)
    now = 200.0
    assert_raises(ArgumentError) { grant.preflight!(scope: scope) }
    now = 201.0
    assert_raises(ArgumentError) { grant.preflight!(scope: scope) }
  end

  def test_expiry_and_financial_exposure_must_be_explicit_and_valid
    [nil, Float::INFINITY, Float::NAN, "200"].each do |expiry|
      assert_raises(ArgumentError) { authorization(expires_at: expiry) }
    end
    [nil, true, "hard_bounded", ""].each do |exposure|
      assert_raises(ArgumentError) { authorization(financial_exposure: exposure) }
    end
  end

  def test_requested_hard_bounds_are_not_silently_downgraded_to_observations
    grant = authorization
    %w[tokens requests runs cost money].each do |kind|
      assert_raises(ArgumentError) { grant.preflight!(scope: scope, hard_limits: {kind => 1}) }
    end
    assert grant.preflight!(scope: scope, hard_limits: {})
  end

  def test_unbounded_attempt_policy_preserves_null_without_inventing_a_cap
    assert_nil policy.to_h.fetch("max_attempts")
    config = Budget::AdmissionConfig.new(wall_seconds: 10, max_concurrent_sessions: 1)
    assert_nil config.to_h.fetch("max_attempts")
    coordinator = Budget::Coordinator.new(clock: -> { 0.0 })
    scopes = coordinator_scopes(coordinator, config)
    25.times do |index|
      outcome = admit(coordinator, scopes, index + 1)
      assert decision(outcome).fetch("allowed"), decision(outcome).inspect
      coordinator.release(lease: outcome)
    end
  end

  def test_optional_attempt_cap_does_not_remove_finite_wall_or_concurrency
    [nil, 0, -1, Float::INFINITY, Float::NAN].each do |wall|
      assert_raises(ArgumentError) { policy(wall_seconds: wall) }
    end
    [nil, 0, -1, 1.5].each do |sessions|
      assert_raises(ArgumentError) { policy(sessions: sessions) }
    end
    [0, -1, 1.5].each do |attempts|
      assert_raises(ArgumentError) { policy(max_attempts: attempts) }
    end
    now = 0.0
    coordinator = Budget::Coordinator.new(clock: -> { now })
    scopes = coordinator_scopes(coordinator, policy)
    now = 10.0
    refute decision(admit(coordinator, scopes, 1)).fetch("allowed")
  end

  def test_atomic_local_concurrency_survives_unbounded_attempts
    coordinator = Budget::Coordinator.new(clock: -> { 0.0 })
    scopes = coordinator_scopes(coordinator, policy)
    ready = Queue.new
    go = Queue.new
    threads = 8.times.map do |index|
      Thread.new do
        ready << true
        go.pop
        admit(coordinator, scopes, index + 1)
      end
    end
    8.times { ready.pop }
    8.times { go << true }
    decisions = threads.map(&:value)
    admitted = decisions.select { |outcome| decision(outcome).fetch("allowed") }
    assert_equal 1, admitted.length
    coordinator.release(lease: admitted.fetch(0))
    assert decision(admit(coordinator, scopes, 9)).fetch("allowed")
  end

  def test_explicit_attempt_cap_still_enforced
    coordinator = Budget::Coordinator.new(clock: -> { 0.0 })
    scopes = coordinator_scopes(coordinator, policy(max_attempts: 1))
    first = admit(coordinator, scopes, 1)
    assert decision(first).fetch("allowed")
    coordinator.release(lease: first)
    refute decision(admit(coordinator, scopes, 2)).fetch("allowed")
  end

  def live_admit(authorization:, authorization_scope: scope)
    coordinator = Budget::Coordinator.new(clock: -> { 0.0 })
    scopes = coordinator_scopes(coordinator, policy(max_attempts: 2))
    scopes << coordinator.open_scope(kind: "attempt", id: "step:1",
      config: policy(max_attempts: 1), parent: scopes.last)
    request = AgentRuntime::Request.new(run_id: "run-1", step_id: "step", attempt: 1,
      timeout: 10, config: {}, inputs: {}, workspace: ".")
    live_profile = Budget::ModelProfile.new(id: "pilot", provider: "omniroute",
      model: "cx/gpt-6-luna-low", execution_kind: "real_provider")
    coordinator.admit(scopes: scopes, profile: live_profile, request: request,
      executable: File.expand_path("fixtures/inert-opencode", __dir__),
      executable_sha256: "a" * 64, authorization: authorization,
      authorization_scope: authorization_scope)
  end

  def test_real_provider_requires_concrete_scoped_authorization_not_a_callback
    grant = authorization
    assert decision(live_admit(authorization: grant)).fetch("allowed")
    [nil, grant.to_h, ->(**) { grant.to_h }].each do |forged|
      outcome = live_admit(authorization: forged)
      refute decision(outcome).fetch("allowed")
    end
  end

  def test_real_provider_scoped_grant_cannot_authorize_another_model
    grant = authorization
    outcome = live_admit(authorization: grant, authorization_scope: scope.merge("model" => "other"))
    refute decision(outcome).fetch("allowed")
  end
end
