require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/simulated_comparison"
require_relative "../lib/agent_runtime/benchmarks/comparative_cli"

class SimulatedComparisonTest < Minitest::Test
  def test_plan_is_nine_cells_without_execution
    manifest = AgentRuntime::Benchmarks::ExperimentManifest.new(AgentRuntime::Benchmarks::SimulatedComparison.plan)
    assert_equal 9, manifest.cells.size
    assert_equal "offline", manifest.data.fetch("execution_mode")
    assert_equal ["retrying"], manifest.data.fetch("benchmark").fetch("task_ids")
    assert_match(/\Asha256:[a-f0-9]{64}\z/, AgentRuntime::Benchmarks::SimulatedComparison::IMAGE)
  end

  def test_cli_requires_explicit_simulation_opt_in
    _, error = capture_io do
      assert_equal 1, AgentRuntime::Benchmarks::ComparativeCLI.new.run(["run", "example", "destination"])
    end
    assert_includes error, "--allow-simulated-execution required"
  end

  def test_schedule_is_position_balanced_and_frozen_before_execution
    klass = AgentRuntime::Benchmarks::SimulatedComparison.const_get(:Runner, false)
    runner = klass.new(mock_solvers: {}, store: nil, root: ".agru/test", registry: {})
    manifest = AgentRuntime::Benchmarks::ExperimentManifest.new(AgentRuntime::Benchmarks::SimulatedComparison.plan)
    cells = runner.send(:ordered_cells, manifest)
    positions = cells.each_slice(3).to_a.transpose
    positions.each { |position| assert_equal %w[dsl fixed-workflow single-agent], position.map { |cell| cell.fetch("solver_id") }.sort }
    metadata = runner.send(:execution_metadata, manifest, cells)
    assert_equal cells.map { |cell| cell.fetch("id") }, metadata.fetch("schedule").fetch("cell_order")
  end
end
