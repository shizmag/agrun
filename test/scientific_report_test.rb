require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/scientific_report"

class ScientificReportTest < Minitest::Test
  def test_saved_local_live_configuration_allows_failed_cells_without_fabricating_execution
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      report = {"run_id" => "local", "manifest" => {"repetitions" => 1, "execution_mode" => "live"},
                "transport" => "local-token-gateway", "live_provider" => true, "offline_injected_provider" => false,
                "solver_configurations" => {"opencode" => {"live" => true}},
                "cells" => [{"id" => "failed", "task_id" => "retrying", "solver_id" => "opencode", "execution_status" => "timeout"}]}
      store.save_report(report)
      text = AgentRuntime::Benchmarks::ScientificReport.new(store: store).render(experiment_id: "local", evidence_kind: "live_provider")
      assert_includes text, "timeout"
      assert_includes text, "not evidence that every cell reached a provider"
      assert_nil store.report("local").dig("provenance", "solver_execution")
      report["offline_injected_provider"] = true
      store.save_report(report)
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ScientificReport.new(store: store).render(experiment_id: "local", evidence_kind: "live_provider") }
    end
  end

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
      assert_raises(ArgumentError) do
        AgentRuntime::Benchmarks::ScientificReport.new(store: store).render(experiment_id: "pilot", evidence_kind: "live_provider")
      end
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

  def test_failure_does_not_escape_successful_protocol_denominator
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      base = {"solver_id" => "opencode", "task_id" => "retrying", "model" => "frozen"}
      store.save_report({"run_id" => "partial", "manifest" => {"repetitions" => 2}, "cells" => [
        base.merge("id" => "ok", "repetition" => 1, "protocol" => "audited", "quality_basis" => "tests", "execution_status" => "success", "evaluation_status" => "valid", "score" => 1),
        base.merge("id" => "failed", "repetition" => 2, "execution_status" => "timeout")
      ]})
      arms = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: "partial").fetch("arms")
      assert_equal 1, arms.size
      assert_equal 2, arms.first.fetch("observed_cells")
      assert_equal 0, arms.first.fetch("conditional_denominator")
      assert_nil arms.first.fetch("macro_score")
    end
  end
end
