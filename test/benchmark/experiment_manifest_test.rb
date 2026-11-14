require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/experiment_manifest"

class BenchmarkExperimentManifestTest < Minitest::Test
  def data
    {"schema_version" => 1, "experiment_id" => "offline-contract",
     "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["zero", "half", "one"]},
     "solver_ids" => ["direct", "single-agent", "fixed-workflow", "compositional-dsl"],
     "models" => [{"id" => "fake", "provider" => "fixture"}], "repetitions" => 2,
     "limits" => {"timeout" => 10, "max_steps" => 4}, "execution_mode" => "offline", "subset_role" => "development"}
  end

  def manifest(value = data)
    AgentRuntime::Benchmarks::ExperimentManifest.new(value)
  end

  def test_manifest_detaches_and_deeply_freezes_normalized_json
    source = data
    value = manifest(source)
    source["benchmark"]["task_ids"] << "later"
    assert_equal 3, value.data.dig("benchmark", "task_ids").length
    assert value.data.frozen?
    assert value.data["benchmark"].frozen?
    assert value.data.dig("benchmark", "task_ids").all?(&:frozen?)
    assert_raises(FrozenError) { value.data["solver_ids"] << "later" }
    assert_equal value.digest, manifest(data.to_a.reverse.to_h).digest
    refute_equal value.digest, manifest(data.merge("experiment_id" => "another")).digest
  end

  def test_cells_are_complete_deterministic_coordinates_bound_to_manifest
    value = manifest
    cells = value.cells
    assert_equal 24, cells.length
    assert_equal cells, manifest.cells
    assert_equal 24, cells.map { |cell| cell.fetch("id") }.uniq.length
    assert_equal ["not_started"], cells.map { |cell| cell.fetch("status") }.uniq
    assert_equal [1, 2], cells.map { |cell| cell.fetch("repetition") }.uniq
    assert_equal ["zero", "half", "one"], cells.map { |cell| cell.fetch("task_id") }.uniq
    assert cells.none? { |cell| cell.key?("attempt_id") }
    refute_equal cells.first["id"], manifest(data.merge("experiment_id" => "other")).cells.first["id"]
  end

  def test_duplicate_and_empty_dimensions_are_rejected
    [[], ["direct", "direct"]].each do |ids|
      assert_raises(ArgumentError) { manifest(data.merge("solver_ids" => ids)) }
    end
    assert_raises(ArgumentError) { manifest(data.merge("models" => [{"id" => "fake"}, {"id" => "fake"}])) }
    assert_raises(ArgumentError) { manifest(data.merge("benchmark" => data["benchmark"].merge("task_ids" => ["one", "one"]))) }
    assert_raises(ArgumentError) { manifest(data.merge("repetitions" => 0)) }
    assert_raises(ArgumentError) { manifest(data.merge("repetitions" => 1.5)) }
  end

  def test_live_nonfinite_nonpositive_and_unknown_configuration_fail_closed
    assert_raises(ArgumentError) { manifest(data.merge("execution_mode" => "live")) }
    assert_raises(ArgumentError) { manifest(data.merge("secret" => true)) }
    [0, -1, Float::INFINITY, Float::NAN, "10", true].each do |limit|
      assert_raises(ArgumentError) { manifest(data.merge("limits" => {"timeout" => limit})) }
    end
    assert_raises(ArgumentError) { manifest(data.merge("benchmark" => data["benchmark"].merge("revision" => ""))) }
  end
end
