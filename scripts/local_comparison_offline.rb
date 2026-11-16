require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks/local_comparison"
require_relative "../lib/agent_runtime/benchmarks/portable_regrade"

# Internal integration harness. Its transport is synthetic and cannot call HTTP.
root = File.expand_path(ARGV.fetch(0))
assets = File.expand_path(ARGV.fetch(1))
FileUtils.mkdir_p(root)
comparison = AgentRuntime::Benchmarks::LocalComparison
authorization = File.join(root, "authorization.json")
File.write(authorization, JSON.generate("bindings" => comparison.bindings(assets: assets), "expires_at" => Time.now.to_f + 3600))
credential = File.join(root, "offline-credential")
File.write(credential, "offline-only", perm: 0o600)
factory = ->(ledger, directory) {
  AgentRuntime::Execution::LocalTokenProvider.new(root: comparison::ROOT, ledger: ledger,
    credential: "offline-only", audit_path: File.join(directory, "gateway-audit.jsonl"), offline: true)
}
report = comparison.new(root: root, assets: assets, provider_factory: factory,
  test_ledger_path: File.join(root, "offline.tokens.jsonl"))
  .run(authorization_path: authorization, credential_file: credential, allow_live: true)
report["portable_regrade"] = AgentRuntime::Benchmarks::PortableRegrade.new.run(bundle: report.fetch("bundle").fetch("path"),
  root: File.join(root, "portable-#{report.fetch("execution_id")}"), assets: assets)
raise "offline nine-cell execution incomplete" unless report.fetch("report").fetch("cells").size == 9 &&
  report.fetch("report").fetch("cells").all? { |cell| cell["submission"] && cell.fetch("grading_attempts", []).size >= 2 }
raise "offline ledger did not settle" unless report.fetch("token_ledger").fetch("known_usage_tokens").positive?
puts JSON.pretty_generate(report)
