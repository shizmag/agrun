require "bundler/setup"
require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks/simulated_comparison"
require_relative "../lib/agent_runtime/tracing/diagnostics"
require_relative "../lib/agent_runtime/benchmarks/portable_regrade"

root = File.expand_path(ARGV.fetch(0, ".agru/m2-tracing-acceptance-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}"))
assets = File.expand_path(ARGV.fetch(1, ".agru/nl2repo"))
raise "acceptance root already exists" if File.exist?(root)
FileUtils.mkdir_p(root, mode: 0o700)
trace_root = File.join(root, "traces")
result = AgentRuntime::Benchmarks::SimulatedComparison.new.run(root: root, assets: assets,
  destination: File.join(root, "frozen"), experiment_id: "m2-offline-nine-cell",
  trace_root: trace_root, raw_content: true)
trace = AgentRuntime::Tracing::Store.new(trace_root, raw_content: true)
verification = trace.verify
entities = trace.entities
counts = entities.group_by { |entity| entity.fetch("kind") }.transform_values(&:length)
raise "expected nine traced cells" unless counts["cell"] == 9
raise "expected 21 observed tools" unless counts["tool"] == 21
raise "expected tools in every cell" unless entities.select { |entity| entity["kind"] == "tool" }.map { |entity| entity.dig("attributes", "cell_id") }.uniq.length == 9
raise "expected request observations" unless counts.fetch("llm_request", 0) == 42
raise "expected original and repeated grading" unless counts["grading"] == 18
portable_grade = AgentRuntime::Benchmarks::PortableRegrade.new.run(bundle: File.join(root, "frozen"), root: File.join(root, "portable-regrade-store"), assets: assets)
raise "portable regrade mismatch" unless portable_grade["verified"]
trace.export(File.join(root, "portable-trace"), include_raw: true)
restored = AgentRuntime::Tracing::Store.import(File.join(root, "portable-trace"), File.join(root, "restored-trace"))
restored_verification = restored.verify
restored.close
File.write(File.join(root, "trace-verification.json"), JSON.pretty_generate({"original" => verification, "restored" => restored_verification, "counts" => counts, "portable_regrade_verified" => portable_grade["verified"], "freeze" => result}), perm: 0o600)
trace.close
puts JSON.pretty_generate({"root" => root, "trace_database" => File.join(trace_root, "trace.sqlite3"), "verification" => verification, "restored" => restored_verification, "counts" => counts, "portable_regrade_verified" => portable_grade["verified"]})
exit((verification["complete"] && restored_verification["complete"]) ? 0 : 1)
