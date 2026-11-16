require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/local_comparison"

class LocalComparisonTest < Minitest::Test
  def test_exact_model_nine_cell_manifest_and_schedule
    comparison = AgentRuntime::Benchmarks::LocalComparison
    manifest = comparison.manifest
    assert_equal 9, manifest.cells.size
    assert_equal "live", manifest.data.fetch("execution_mode")
    assert_equal "cx/gpt-6-luna-low", manifest.data.fetch("models").first.fetch("model_profile").fetch("model")
    schedule = AgentRuntime::Benchmarks::AuthorizedComparison.schedule(manifest)
    assert_equal 9, schedule.map { |cell| cell.fetch("id") }.uniq.size
    assert_equal %w[single-agent fixed-workflow dsl], schedule.first(3).map { |cell| cell.fetch("solver_id") }
  end

  def test_no_live_execution_without_explicit_opt_in
    comparison = AgentRuntime::Benchmarks::LocalComparison.new(root: ".agru", assets: ".agru/nl2repo")
    assert_raises(ArgumentError) { comparison.run(authorization_path: "absent", credential_file: "absent") }
  end

  def test_temporary_ledger_requires_injected_provider
    assert_raises(ArgumentError) do
      AgentRuntime::Benchmarks::LocalComparison.new(root: ".agru", assets: ".agru/nl2repo", test_ledger_path: "temporary")
    end
  end
end
