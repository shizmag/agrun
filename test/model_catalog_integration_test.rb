require_relative "test_helper"
require "open3"

class ModelCatalogIntegrationTest < Minitest::Test
  def test_manifest_rejects_endpoint_and_unsupported_parameter_delivery
    require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"
    source = JSON.parse(File.read(File.expand_path("../experiments/fixture-infrastructure-smoke.json", __dir__)))
    source["models"][0].merge!("catalog_route" => "r", "model_profile" => {"provider" => "p", "model" => "wire", "tool_policy" => {"endpoint" => "wrong"}, "inference_parameters" => {"effort" => "low"}})
    data = {"revision" => "v1", "models" => {"base" => {}}, "variants" => {"v" => {"model" => "base", "parameters" => {"effort" => "low"}}}, "routes" => {"r" => {"provider" => "p", "endpoint" => "right", "wire_id" => "wire", "variant" => "v"}}, "pricing" => {}}
    catalog = AgentRuntime::Execution::ModelCatalog.new(data)
    assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(source, catalog: catalog) }
    source["models"][0]["model_profile"]["tool_policy"]["endpoint"] = "right"
    assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ExperimentManifest.new(source, catalog: catalog) }
    data["routes"]["r"]["parameter_delivery"] = "wire_id"
    resolved = AgentRuntime::Benchmarks::ExperimentManifest.new(source, catalog: AgentRuntime::Execution::ModelCatalog.new(data))
    assert_equal "wire", resolved.data["models"][0]["model_resolution"]["route"]["wire_id"]
  end

  def cli(*args)
    Open3.capture3(RbConfig.ruby, File.expand_path("../bin/agru", __dir__), "bench", *args)
  end

  def test_catalog_snapshot_survives_all_offline_strategy_cells_and_report_reload
    Dir.mktmpdir("catalog-integration") do |dir|
      manifest = JSON.parse(File.read(File.expand_path("../experiments/fixture-infrastructure-smoke.json", __dir__)))
      manifest["solver_ids"] = %w[single-agent fixed-workflow compositional-dsl]
      manifest["models"][0].merge!("catalog_route" => "operator", "model_profile" => {"provider" => "fixture", "model" => "operator-low", "tool_policy" => {"endpoint" => "local"}, "inference_parameters" => {"reasoning_effort" => "low"}})
      catalog = {"revision" => "test-v1", "models" => {"base" => {}},
                 "variants" => {"low" => {"model" => "base", "parameters" => {"reasoning_effort" => "low"}}},
                 "routes" => {"operator" => {"variant" => "low", "provider" => "fixture", "endpoint" => "local", "wire_id" => "operator-low", "parameter_delivery" => "wire_id"}}, "pricing" => {}}
      manifest_path = File.join(dir, "manifest.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(manifest_path, JSON.generate(manifest))
      File.write(catalog_path, JSON.generate(catalog))
      out, err, status = cli("plan", manifest_path, "--model-catalog", catalog_path)
      assert status.success?, err
      plan = JSON.parse(out)
      snapshot = plan.fetch("manifest").fetch("models").first.fetch("model_resolution")
      assert_equal "operator-low", snapshot.fetch("route").fetch("wire_id")
      assert_equal %w[compositional-dsl fixed-workflow single-agent], plan.fetch("cells").map { |cell| cell.fetch("solver_id") }.uniq.sort
      root = File.join(dir, ".agru")
      out, err, status = cli("run", manifest_path, "--root", root, "--model-catalog", catalog_path)
      assert status.success?, err
      assert_equal snapshot, JSON.parse(out).fetch("manifest").fetch("models").first.fetch("model_resolution")
      File.write(catalog_path, "{}")
      out, err, status = cli("report", manifest.fetch("experiment_id"), "--root", root)
      assert status.success?, err
      report = JSON.parse(out)
      assert_equal snapshot, report.fetch("manifest").fetch("models").first.fetch("model_resolution")
      assert report.fetch("arms").all? { |arm| arm.fetch("model_resolution") == snapshot }
    end
  end

  def test_catalog_is_opt_in_and_legacy_plan_has_no_synthetic_resolution
    out, err, status = cli("plan", "experiments/fixture-infrastructure-smoke.json")
    assert status.success?, err
    refute JSON.parse(out).fetch("manifest").fetch("models").first.key?("model_resolution")
  end
end
