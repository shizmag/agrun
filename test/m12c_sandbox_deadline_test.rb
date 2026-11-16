require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_deadline"

class M12cSandboxDeadlineTest < Minitest::Test
  def setup
    @now = 100.0
    @cancelled = false
    @token = Object.new
    test = self
    @token.define_singleton_method(:cancelled?) { test.instance_variable_get(:@cancelled) }
  end

  def test_all_phases_consume_one_budget
    deadline = build(timeout: 7)
    %w[prepare start run quiesce export verify].each_with_index do |phase, index|
      @now = 100.0 + index
      assert_in_delta 7.0 - index, deadline.remaining!(phase: phase)
    end
    @now = 107.0
    error = assert_raises(AgentRuntime::Execution::SandboxDeadline::Exceeded) { deadline.check!(phase: "verify") }
    assert_equal "timeout", error.status
    assert_equal "verify", error.phase
  end

  def test_per_operation_cap_never_renews_budget
    deadline = build(timeout: 20)
    assert_equal 3.0, deadline.remaining!(phase: "start", cap: 3)
    @now = 119.5
    assert_equal 0.5, deadline.remaining!(phase: "export", cap: 10)
  end

  def test_cancellation_prevents_next_phase_even_before_expiry
    deadline = build
    @cancelled = true
    error = assert_raises(AgentRuntime::Execution::SandboxDeadline::Exceeded) { deadline.remaining!(phase: "prepare") }
    assert_equal "cancelled", error.status
    assert_equal "prepare", error.phase
  end

  def test_cancellation_wins_when_deadline_also_expired
    deadline = build
    @cancelled = true
    @now = 200.0
    error = assert_raises(AgentRuntime::Execution::SandboxDeadline::Exceeded) { deadline.check!(phase: "export") }
    assert_equal "cancelled", error.status
  end

  def test_emergency_cleanup_has_one_explicit_bounded_budget_and_ignores_request_cancellation
    deadline = build
    @now = 200.0
    @cancelled = true
    cleanup = deadline.emergency_cleanup(timeout: 2)
    assert_equal 2.0, cleanup.remaining!(phase: "kill")
    @now = 201.5
    assert_equal 0.5, cleanup.remaining!(phase: "remove")
    assert_same cleanup, deadline.emergency_cleanup(timeout: 2)
    @now = 202.0
    assert_raises(AgentRuntime::Execution::SandboxDeadline::Exceeded) { cleanup.check!(phase: "verify removal") }
    assert_raises(AgentRuntime::Execution::SandboxDeadline::Exceeded) { deadline.check!(phase: "export") }
  end

  def test_invalid_limits_are_rejected
    [0, -1, Float::INFINITY, Float::NAN].each do |value|
      assert_raises(ArgumentError) { build(timeout: value) }
      assert_raises(ArgumentError) { build.remaining!(phase: "run", cap: value) }
      assert_raises(ArgumentError) { build.emergency_cleanup(timeout: value) }
    end
  end

  private

  def build(timeout: 10)
    AgentRuntime::Execution::SandboxDeadline.new(timeout: timeout, cancellation: @token, clock: -> { @now })
  end
end
