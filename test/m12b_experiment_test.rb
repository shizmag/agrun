require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"
require_relative "../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../lib/agent_runtime/benchmarks/registry"

class M12bExperimentTest < Minitest::Test
  def manifest
    {"schema_version" => 1, "experiment_id" => "m12b-live-test",
     "benchmark" => {"name" => "nl2repo", "revision" => "pinned", "task_ids" => ["retrying"]},
     "solver_ids" => ["single-agent"], "models" => [{"id" => "omniroute/cx/gpt-6-luna-low",
                                                     "model_profile" => {"provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "execution_kind" => "real_provider"}}],
     "repetitions" => 1, "limits" => {"timeout" => 600, "max_parallelism" => 1},
     "execution_mode" => "live", "subset_role" => "transport-validation"}
  end

  def test_frozen_live_manifest_is_configuration_not_launch_authority
    frozen = AgentRuntime::Benchmarks::ExperimentManifest.new(manifest)
    assert_equal "live", frozen.data.fetch("execution_mode")
    assert_equal 1, frozen.cells.length
    assert frozen.data.frozen?
    refute_equal frozen.digest, AgentRuntime::Benchmarks::ExperimentManifest.new(manifest.merge("experiment_id" => "another-authorized-run")).digest
    refute frozen.data.key?("authorization")
  end

  def test_live_manifest_rejects_implicit_models_and_multistrategy_expansion
    variants = [manifest.merge("solver_ids" => ["fixed-workflow"]),
      manifest.merge("solver_ids" => ["single-agent", "compositional-dsl"]),
      manifest.merge("benchmark" => manifest["benchmark"].merge("task_ids" => ["retrying", "another"])),
      manifest.merge("models" => [{"id" => "default"}])]
    variants.each { |value| assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(value) } }
  end

  def test_a_separate_manifest_may_represent_a_justified_repeat_without_global_run_quota
    value = AgentRuntime::Benchmarks::ExperimentManifest.new(manifest.merge("experiment_id" => "diagnostic-repeat"))
    assert_equal 1, value.cells.length
    refute value.data.fetch("limits").key?("max_attempts")
    refute value.data.fetch("limits").key?("max_tokens")
  end

  def test_live_runner_without_concrete_authorization_fails_before_solver_or_workspace
    in_tmp do |root|
      registry = AgentRuntime::Benchmarks::Registry.new
      store = AgentRuntime::Store.new(root)
      registry.register("nl2repo", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: root, registry: registry, solvers: {})
      error = assert_raises(ArgumentError) { runner.run(manifest: manifest) }
      assert_match(/live authorization required/, error.message)
      refute File.exist?(File.join(root, "experiments"))
    end
  end
end
