require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"

class ResearchLiveManifestTest < Minitest::Test
  def manifest
    JSON.parse(File.read(File.expand_path("../experiments/research-live-operational.json", __dir__)))
  end

  def test_reviewed_nine_cells_and_existing_single_solver
    assert_equal 9, AgentRuntime::Benchmarks::ExperimentManifest.new(manifest).cells.length
    %w[single-agent fixed-workflow dsl].each do |solver|
      data = manifest
      data["solver_ids"] = [solver]
      assert_equal 3, AgentRuntime::Benchmarks::ExperimentManifest.new(data).cells.length
    end
    compute = JSON.parse(File.read(File.expand_path("../experiments/research-live-compute.json", __dir__)))
    assert_equal 9, AgentRuntime::Benchmarks::ExperimentManifest.new(compute).cells.length
  end

  def test_unreviewed_combinations_and_parallel_execution_rejected
    [["single-agent", "dsl"], %w[dsl fixed-workflow single-agent], ["other"]].each do |solvers|
      data = manifest
      data["solver_ids"] = solvers
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(data) }
    end
    %w[max_parallelism max_concurrent_sessions].each do |key|
      data = manifest
      data["limits"][key] = 2
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(data) }
    end
  end
end
