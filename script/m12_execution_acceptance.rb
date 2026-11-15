require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks"
require_relative "../lib/agent_runtime/execution/summary"
require "optparse"

options = {root: ".agru/m12-acceptance", inspect: false, report: "json"}
OptionParser.new do |parser|
  parser.banner = "Offline M1.2a persisted execution acceptance (no providers or Docker)"
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--inspect", "Reconstruct the last run without executing") { options[:inspect] = true }
  parser.on("--report FORMAT", %w[json csv markdown]) { |value| options[:report] = value }
end.parse!
root = File.expand_path(options.fetch(:root))
pointer = File.join(root, "last-experiment.json")
store = AgentRuntime::Store.new(root)
unless options[:inspect]
  registry = AgentRuntime::Benchmarks::Registry.new
  registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
  ids = AgentRuntime::Benchmarks::FixtureSolvers::CATEGORIES
  manifest = {"schema_version" => 1, "experiment_id" => "m12-#{SecureRandom.uuid}",
              "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => %w[zero half one]},
              "solver_ids" => ids, "models" => [{"id" => "fixture", "model_profile" => {"model" => "fixture/model"}}],
              "repetitions" => 1, "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
  runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "workspaces"), registry: registry,
    solvers: ids.to_h { |id| [id, AgentRuntime::Benchmarks::FixtureSolvers.build(id, store: store)] })
  result = runner.run(manifest: manifest)
  result.fetch("cells").each do |cell|
    execution = cell.fetch("execution")
    persisted = store.report(execution.fetch("run_id"))
    actual = persisted.fetch("steps").values.sum { |step| step.fetch("attempts").size }
    expected = (cell.fetch("solver_id") == "direct") ? 1 : 3
    raise "architecture invocation mismatch" unless actual == expected && execution.fetch("invocation_count") == actual
    raise "fixture evaluation incomplete" unless cell["status"] == "completed" && cell["execution_status"] == "success" && cell["score"].is_a?(Numeric)
  end
  cell = result.fetch("cells").first
  regraded = runner.regrade(experiment_id: result.fetch("run_id"), cell_id: cell.fetch("id"))
  current = regraded.fetch("cells").first
  raise "regrade changed execution or submission" unless current["execution"] == cell["execution"] && current["submission"] == cell["submission"]
  File.write(pointer, JSON.generate("experiment_id" => result.fetch("run_id")))
end
experiment_id = JSON.parse(File.read(pointer)).fetch("experiment_id")
reports = AgentRuntime::Benchmarks::Reports.new(store: AgentRuntime::Store.new(root))
%w[json csv markdown].each do |format|
  File.write(File.join(root, "acceptance.#{format}"), reports.render(experiment_id: experiment_id, format: format))
end
puts reports.render(experiment_id: experiment_id, format: options.fetch(:report))
