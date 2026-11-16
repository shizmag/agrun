require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/resource_report"

class ResourceReportTest < Minitest::Test
  def test_nested_usage_and_partial_architecture_subtotals
    cells = [{"id" => "one", "solver_id" => "dsl", "model" => "route", "agent_duration" => 2.5,
              "usage" => {"coverage" => {"stream_complete" => false, "accepted_requests" => 2},
                          "tokens" => {"input" => {"total" => nil, "known_subtotal" => 12}, "output" => {"total" => 0, "known_subtotal" => 0}}},
              "execution" => {"counts" => {"tool_event_observations" => 3}}},
      {"id" => "failed", "solver_id" => "dsl", "model" => "route"}]
    report = AgentRuntime::Benchmarks::ResourceReport.new
    data = report.summary(cells: cells, evidence_kind: "simulated_relay")
    assert data["synthetic"]
    metrics = data["architectures"].first.fetch("metrics")
    assert_nil metrics.dig("input", "total")
    assert_equal 12, metrics.dig("input", "known_subtotal")
    assert_equal 1, metrics.dig("input", "known")
    assert_equal 2, metrics.dig("input", "expected")
    assert_equal 0, metrics.dig("output", "known_subtotal")
    assert_nil metrics.dig("retries", "known_subtotal")
    assert_nil metrics.dig("provider_errors", "total")
    assert_nil metrics.dig("tool_events", "total")
    assert_equal 3, metrics.dig("tool_events", "known_subtotal")
    text = report.render(cells: cells, evidence_kind: "simulated_relay")
    assert_includes text, "12 subtotal (1/2 known)"
    assert_includes text, "synthetic: true"
    assert_includes text, "unknown"
  end

  def test_complete_totals_do_not_mix_routes_and_root_steps_are_not_provider_requests
    cells = %w[a b].map do |route|
      {"solver_id" => "single", "model" => route, "usage" => {"tokens" => {"input" => {"total" => 10}},
                                                              "coverage" => {"stream_complete" => true, "identity_kind" => "root_step_observation", "accepted_requests" => 1, "conflicting_requests" => 0, "unidentified_observations" => 0}}}
    end
    data = AgentRuntime::Benchmarks::ResourceReport.new.summary(cells: cells, evidence_kind: "live_provider")
    refute data["synthetic"]
    assert_equal 2, data["architectures"].size
    assert_equal 10, data["architectures"].first.dig("metrics", "input", "total")
    assert_nil data["cells"].first.dig("metrics", "requests", "total")
  end
end
