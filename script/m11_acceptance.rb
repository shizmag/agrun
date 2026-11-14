require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks"
require "time"

root = File.expand_path(ENV.fetch("AGRU_BENCH_ROOT", ".agru/m11-acceptance"))
store = AgentRuntime::Store.new(root)
registry = AgentRuntime::Benchmarks::Registry.new
adapter = AgentRuntime::Benchmarks::FixtureAdapter.new(store: store)
registry.register("fixture", adapter)
manifest = JSON.parse(File.read(File.expand_path("../experiments/fixture-infrastructure-smoke.json", __dir__)))
manifest["experiment_id"] = "m11-acceptance-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(4)}"
runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "workspaces"), registry: registry,
  solvers: AgentRuntime::Benchmarks::FixtureSolvers::CATEGORIES.to_h { |id| [id, AgentRuntime::Benchmarks::FixtureSolvers.build(id)] })
experiment = runner.run(manifest: manifest)
raise "incomplete fixture matrix" unless experiment.fetch("cells").size == 16 && experiment.fetch("cells").all? { |cell| cell["status"] == "completed" }
cell = experiment.fetch("cells").first
regraded = runner.regrade(experiment_id: experiment.fetch("run_id"), cell_id: cell.fetch("id"))
raise "regrade changed submission" unless regraded.fetch("cells").first["submission"] == cell["submission"]
reports = AgentRuntime::Benchmarks::Reports.new(store: store)
%w[json csv markdown].each do |format|
  File.write(File.join(root, "acceptance.#{format}"), reports.render(experiment_id: experiment.fetch("run_id"), format: format))
end
evidence = {"run_id" => "#{experiment.fetch("run_id")}-acceptance", "kind" => "m11_acceptance",
            "qualification" => "infrastructure-only demonstration", "experiment_id" => experiment.fetch("run_id"),
            "manifest_digest" => experiment.fetch("manifest_digest"), "fixture_cells" => 16,
            "regrade_submission_preserved" => true, "report_formats" => %w[json csv markdown],
            "official_protocol_status" => "blocked", "official_score" => nil,
            "acceptance_scope" => "persisted fixture matrix, immutable submission, independent regrade and report exports; not all official acceptance scenarios",
            "official_acceptance" => %w[BENCH-05 BENCH-06 BENCH-07].to_h { |id| [id, {"status" => "blocked", "reason" => "native official controls unavailable; fixture outcomes are not substitutes"}] },
            "official_blockers" => ["official task images not installed", "immutable official image digests unverified", "native score collector untrusted", "positive/negative official controls unexecuted"]}
store.save_report(evidence)
puts JSON.pretty_generate(evidence.merge("store" => root))
