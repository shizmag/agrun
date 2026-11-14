require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks"
require_relative "../lib/agent_runtime/benchmarks/nl2repo_audited_grader"
require "time"

abort "explicit --allow-local-grading required; no assets are downloaded" unless ARGV == ["--allow-local-grading"]
root = File.expand_path(ENV.fetch("AGRU_BENCH_ROOT", ".agru/m11c-acceptance"))
FileUtils.mkdir_p(root)
store = AgentRuntime::Store.new(root)
grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: store)
adapter = AgentRuntime::Benchmarks::Adapters::NL2Repo.new(store: store, audited_grader: grader)
registry = AgentRuntime::Benchmarks::Registry.new
registry.register("nl2repo", adapter)
base = JSON.parse(File.read(File.expand_path("../experiments/nl2repo-official-smoke.json", __dir__)))
rows = []
Dir.mktmpdir("agru-m11c-controls-") do |work|
  controls = %w[reference empty incomplete].to_h do |name|
    path = File.join(work, name)
    FileUtils.mkdir_p(path)
    [name, path]
  end
  reference = File.expand_path("../.agru/nl2repo/reference/original-#{AgentRuntime::Benchmarks::NL2RepoAuditedGrader::REFERENCE_REVISION}/retrying.py", __dir__)
  raise "private reference digest mismatch" unless Digest::SHA256.file(reference).hexdigest == AgentRuntime::Benchmarks::NL2RepoAuditedGrader::REFERENCE_SHA256
  FileUtils.cp(reference, File.join(controls.fetch("reference"), "retrying.py"))
  File.write(File.join(controls.fetch("incomplete"), "retrying.py"), <<~PY)
    def retry(*args, **kwargs):
        return lambda function: function
  PY
  controls.each do |name, path|
    solver = AgentRuntime::Benchmarks::RepositorySolver.new(repository: path)
    runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "workspaces"), registry: registry,
      solvers: {"repository-submission" => solver})
    manifest = Marshal.load(Marshal.dump(base))
    manifest["experiment_id"] = "m11c-#{name}-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(4)}"
    experiment = runner.run(manifest: manifest)
    cell = experiment.fetch("cells").fetch(0)
    rows << {"control" => name, "experiment_id" => experiment.fetch("run_id"), "cell" => cell}
    reports = AgentRuntime::Benchmarks::Reports.new(store: store)
    export_dir = File.join(root, "exports", experiment.fetch("run_id"))
    FileUtils.mkdir_p(export_dir)
    %w[json csv markdown].each do |format|
      rendered = reports.render(experiment_id: experiment.fetch("run_id"), format: format)
      File.write(File.join(export_dir, "report.#{format}"), rendered)
      File.write(File.join(root, "#{name}.#{format}"), rendered)
    end
    if name == "incomplete"
      regraded = runner.regrade(experiment_id: experiment.fetch("run_id"), cell_id: cell.fetch("id"))
      repeat = regraded.fetch("cells").fetch(0)
      raise "regrade changed immutable submission" unless repeat["submission"] == cell["submission"]
      raise "regrade did not append attempt" unless repeat.fetch("grading_attempts").size == cell.fetch("grading_attempts").size + 1
      rows << {"control" => "independent_regrade", "experiment_id" => experiment.fetch("run_id"), "cell" => repeat}
    end
  end
end
File.write(File.join(root, "observations.json"), JSON.pretty_generate(rows) + "\n")
rows.each do |row|
  cell = row.fetch("cell")
  puts JSON.generate(row.except("cell").merge(cell.slice("status", "score", "passed", "total", "quality_basis", "expected", "executed", "protocol", "failure_reason")))
end
expected = {"reference" => 1.0, "empty" => 0.0, "incomplete" => 1.0 / 23, "independent_regrade" => 1.0 / 23}
rows.each do |row|
  cell = row.fetch("cell")
  raise "unvalidated #{row.fetch("control")}: #{cell.inspect}" unless cell["protocol"] == "nl2repo-audited-v2" && cell["score"] == expected.fetch(row.fetch("control"))
end
puts "M1.1c real persisted scoring controls PASS (#{root})"
