require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"

class M12cManifestTest < Minitest::Test
  def test_each_comparative_architecture_has_an_individually_authorizable_manifest
    %w[single-agent fixed-workflow dsl].each do |solver|
      data = JSON.parse(File.read(File.expand_path("../experiments/retrying-live-pilot-02.json", __dir__)))
      data["solver_ids"] = [solver]
      assert_equal [solver], AgentRuntime::Benchmarks::ExperimentManifest.new(data).data.fetch("solver_ids")
    end
  end

  def test_unknown_live_architectures_remain_rejected
    data = JSON.parse(File.read(File.expand_path("../experiments/retrying-live-pilot-02.json", __dir__)))
    data["solver_ids"] = ["unreviewed"]
    assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(data) }
  end
end
