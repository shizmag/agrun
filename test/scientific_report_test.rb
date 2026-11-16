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
    end
  end
end
