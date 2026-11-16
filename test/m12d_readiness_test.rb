require_relative "test_helper"
require_relative "../script/m12d_readiness"

class M12dReadinessTest < Minitest::Test
  def plan
    JSON.parse(File.read(File.expand_path("../experiments/m12d-authorization-plan.json", __dir__)))
  end

  def test_checked_in_plan_is_not_authorized
    refute plan.fetch("authorized")
    assert_equal "BLOCKED", plan.fetch("status")
    assert_includes M12dReadiness.blockers(plan), "reviewed_live_transport"
    assert_includes M12dReadiness.blockers(plan), "independent_mock_parity"
  end

  def test_missing_gates_cannot_pass_vacuously
    value = plan
    value.delete("required_gates")
    assert_includes M12dReadiness.blockers(value), "operator_scope_authorization"
  end

  def test_unknown_usage_and_identity_are_not_zero_or_attestation
    assert_nil plan.fetch("provider").fetch("pricing")
    assert_nil plan.fetch("provider").fetch("served_model_attestation")
    assert_nil plan.fetch("resources_per_cell").fetch("hard_token_cap")
  end

  def test_balanced_serial_schedule
    schedule = plan.fetch("schedule")
    assert_equal 9, schedule.fetch("order").flatten.length
    assert_equal 1, schedule.fetch("max_parallel_cells")
    schedule.fetch("order").transpose.each do |position|
      assert_equal %w[dsl fixed-workflow single-agent], position.sort
    end
  end
end
