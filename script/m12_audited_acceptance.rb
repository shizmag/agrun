require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks"
require_relative "../lib/agent_runtime/benchmarks/nl2repo_audited_grader"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require "rbconfig"

abort "explicit --allow-local-grading required; no assets are downloaded" unless ARGV == ["--allow-local-grading"]
root = File.expand_path(ENV.fetch("AGRU_BENCH_ROOT", ".agru/m12a-audited-agent"))
FileUtils.mkdir_p(root)
store = AgentRuntime::Store.new(root)
grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: store)
registry = AgentRuntime::Benchmarks::Registry.new
registry.register("nl2repo", AgentRuntime::Benchmarks::Adapters::NL2Repo.new(store: store, audited_grader: grader))
reference = File.expand_path("../.agru/nl2repo/reference/original-#{AgentRuntime::Benchmarks::NL2RepoAuditedGrader::REFERENCE_REVISION}/retrying.py", __dir__)
raise "pinned reference digest mismatch" unless Digest::SHA256.file(reference).hexdigest == AgentRuntime::Benchmarks::NL2RepoAuditedGrader::REFERENCE_SHA256

# An authorized deterministic executable exercises the agent execution boundary;
# this is not a model-quality result. Only public implementation bytes enter the
# solver repository. The existing grader alone handles its private procedure.
Dir.mktmpdir("agru-m12a-agent-") do |work|
  executable = File.join(work, "local-agent")
  File.write(executable, <<~RUBY)
    #!#{RbConfig.ruby}
    require "json"
    require "fileutils"
    require "digest"
    reference = #{reference.inspect}
    raise "reference changed" unless Digest::SHA256.file(reference).hexdigest == #{AgentRuntime::Benchmarks::NL2RepoAuditedGrader::REFERENCE_SHA256.inspect}
    FileUtils.cp(reference, File.join(Dir.pwd, "retrying.py"))
    puts JSON.generate({"type" => "step_start", "sessionID" => "ses_audited_fixture", "part" => {"id" => "start-one", "messageID" => "msg-one", "sessionID" => "ses_audited_fixture", "type" => "step-start"}})
    puts JSON.generate({"type" => "step_finish", "sessionID" => "ses_audited_fixture", "part" => {"id" => "finish-one", "messageID" => "msg-one", "sessionID" => "ses_audited_fixture", "type" => "step-finish", "reason" => "stop", "tokens" => {"input" => 10, "output" => 3, "reasoning" => 0, "cache" => {"read" => 0, "write" => 0}}}})
  RUBY
  File.chmod(0o755, executable)
  adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable,
    fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true)
  solver = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter, store: store)
  runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store,
    root: File.join(root, "workspaces"), registry: registry, solvers: {"offline-agent" => solver})
  manifest = JSON.parse(File.read(File.expand_path("../experiments/nl2repo-official-smoke.json", __dir__)))
  manifest["experiment_id"] = "m12a-audited-agent-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(4)}"
  manifest["solver_ids"] = ["offline-agent"]
  manifest["models"] = [{"id" => "fixture", "provider" => "fixture",
                         "model_profile" => {"id" => "audited-offline", "provider" => "fixture", "model" => "deterministic",
                                             "execution_kind" => "offline_fixture", "tool_policy" => {}}}]
  # Solvers derive the canonical wall-time / one-attempt / one-session policy
  # from this manifest's limits and freeze it in the execution trace.
  experiment = runner.run(manifest: manifest)
  # Write observed reports before assertions so failures remain inspectable.
  reports = AgentRuntime::Benchmarks::Reports.new(store: store)
  export_dir = File.join(root, "exports", experiment.fetch("run_id"))
  FileUtils.mkdir_p(export_dir)
  %w[json csv markdown].each do |format|
    File.write(File.join(export_dir, "report.#{format}"), reports.render(experiment_id: experiment.fetch("run_id"), format: format))
  end
  File.write(File.join(root, "observations.json"), JSON.pretty_generate(experiment) + "\n")
  persisted = AgentRuntime::Store.new(root)
  observed = persisted.report(experiment.fetch("run_id")).fetch("cells").fetch(0)
  execution = observed.fetch("execution")
  reconstructed = AgentRuntime::Execution::Summary.from_run(store: persisted, run_id: execution.fetch("run_id"))
  raise "execution summary mismatch after reload" unless reconstructed == execution
  raise "fixture did not launch exactly once" unless reconstructed.fetch("invocation_count") == 1
  usage = reconstructed.fetch("usage")
  raise "input usage not reconstructed" unless usage.dig("tokens", "input", "known_subtotal") == 10
  raise "output usage not reconstructed" unless usage.dig("tokens", "output", "known_subtotal") == 3
  raise "incomplete stream must not claim token totals" unless usage.dig("tokens", "input", "total").nil? && usage.dig("tokens", "output", "total").nil?
  raise "usage projection mismatch" unless observed.fetch("usage") == usage
  raise "solver failed" unless observed.fetch("execution_status") == "success"
  raise "audited grader did not pass official tests" unless (observed.fetch("score") - 1.0).abs < 0.000001 && observed.fetch("passed") == 23 && observed.fetch("total") == 23
  puts JSON.generate({"experiment_id" => experiment.fetch("run_id"), "kind" => "authorized deterministic agent; not model quality", "execution" => reconstructed}.merge(observed.slice("status", "execution_status", "score", "passed", "total", "quality_basis", "protocol")))
end
