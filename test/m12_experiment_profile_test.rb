require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"

class M12ExperimentProfileTest < Minitest::Test
  def test_explicit_profile_is_deep_frozen_and_changes_cell_identity
    source = manifest
    first = AgentRuntime::Benchmarks::ExperimentManifest.new(source)
    source.fetch("models").first.fetch("model_profile")["model"] = "fixture/changed"
    assert_equal "fixture/model", first.data.fetch("models").first.fetch("model_profile").fetch("model")
    assert first.data.fetch("models").first.fetch("model_profile").frozen?
    second = AgentRuntime::Benchmarks::ExperimentManifest.new(source)
    refute_equal first.digest, second.digest
    refute_equal first.cells.first.fetch("id"), second.cells.first.fetch("id")
  end

  def test_profile_must_be_an_object
    source = manifest
    source.fetch("models").first["model_profile"] = "fixture/model"
    assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(source) }
  end

  def test_legacy_manifest_remains_accepted_without_profile
    source = manifest
    source.fetch("models").first.delete("model_profile")
    parsed = AgentRuntime::Benchmarks::ExperimentManifest.new(source)
    refute parsed.data.fetch("models").first.key?("model_profile")
  end

  private

  def manifest
    {"schema_version" => 1, "experiment_id" => "profile-contract", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["one"]},
     "solver_ids" => ["direct"], "models" => [{"id" => "fixture", "model_profile" => {"model" => "fixture/model"}}],
     "repetitions" => 1, "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
  end
end
