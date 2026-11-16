require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks/local_comparison"

# Reporting only: never constructs a solver/provider or modifies execution metadata.
root = File.expand_path(ARGV.fetch(0))
id = ARGV.fetch(1)
directory = File.join(root, "local-token-comparison", id)
store = AgentRuntime::Store.new(File.join(root, "store"))
verification = AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(File.join(directory, "frozen"))
raise "expected saved live evidence" unless verification["evidence_kind"] == "live_provider"
markdown = AgentRuntime::Benchmarks::ScientificReport.new(store: store).render(experiment_id: id, evidence_kind: "live_provider")
File.write(File.join(directory, "report.md"), markdown)
puts JSON.pretty_generate({"verification" => verification, "report_path" => File.join(directory, "report.md"),
                          "execution_statuses" => store.report(id).fetch("cells").map { |cell| cell.fetch("execution_status") }})
