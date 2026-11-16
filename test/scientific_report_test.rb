require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/scientific_report"

class ScientificReportTest < Minitest::Test
  def test_simulator_report_preserves_failed_denominators_and_unknown_usage
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      cells = [
        {"id" => "a", "task_id" => "retrying", "solver_id" => "opencode", "model" => "route", "repetition" => 1,
         "status" => "success", "execution_status" => "success", "score" => 0.0, "usage" => nil},
        {"id" => "b", "task_id" => "retrying", "solver_id" => "opencode", "model" => "route", "repetition" => 2,
         "status" => "timeout", "execution_status" => "timeout", "score" => nil, "usage" => nil}
      ]
      store.save_report({"run_id" => "pilot", "manifest" => {"repetitions" => 2}, "cells" => cells})
      text = AgentRuntime::Benchmarks::ScientificReport.new(store: store).render(experiment_id: "pilot", evidence_kind: "simulated_relay")
      assert_includes text, "not genuine model-quality observations"
      assert_includes text, "| opencode | 2 | 1/2 | 1/2 | 0.0 | unknown | 2/2 |"
      assert_includes text, "timeout"
      assert_includes text, "not statistically generalizable superiority"
      arm = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: "pilot").fetch("arms").first
      assert_equal 2, arm.fetch("planned_cells")
      assert_equal 0, arm.fetch("conditional_denominator")
      assert_equal ["retrying"], arm.fetch("excluded_tasks")
    end
  end

  def test_missing_task_remains_in_planned_denominator
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      store.save_report({"run_id" => "missing", "manifest" => {"repetitions" => 1, "benchmark" => {"task_ids" => %w[present absent]}},
        "cells" => [{"id" => "one", "solver_id" => "opencode", "task_id" => "present", "repetition" => 1, "status" => "timeout"}]})
      arm = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: "missing").fetch("arms").first
      assert_equal 2, arm.fetch("total_tasks")
      assert_equal 2, arm.fetch("planned_cells")
      assert_includes arm.fetch("excluded_tasks"), "absent"
    end
  end
end
