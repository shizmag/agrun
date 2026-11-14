# Explicit opt-in offline verification; intentionally not part of default tests.
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks/nl2repo_audited_grader"
require_relative "../lib/agent_runtime/benchmarks/audited_results"

abort "usage: mise exec -- ruby script/m11c_collector_checks.rb --allow-local-grading" unless ARGV == ["--allow-local-grading"]

root = File.expand_path("..", __dir__)
reference = File.join(root, ".agru/nl2repo/reference/original-#{AgentRuntime::Benchmarks::NL2RepoAuditedGrader::REFERENCE_REVISION}/retrying.py")
manifest = JSON.parse(File.read(File.join(root, "benchmarks/nl2repo/retrying-test-manifest.json")))
expected = manifest.fetch("tests").map { |test| test.fetch("nodeid") }

Dir.mktmpdir("agru-sentinel-") do |scratch|
  candidate = File.join(scratch, "candidate")
  FileUtils.mkdir_p(candidate)
  FileUtils.cp(reference, File.join(candidate, "retrying.py"))
  # These must not influence the trusted collection, nor get imported as hooks.
  File.write(File.join(candidate, "test_retrying.py"), "raise RuntimeError('candidate test was collected')\n")
  File.write(File.join(candidate, "test_injected.py"), "def test_injected(): assert False\n")
  File.write(File.join(candidate, "conftest.py"), "raise RuntimeError('candidate conftest was imported')\n")
  File.write(File.join(candidate, "pytest.ini"), "[pytest]\naddopts = --collect-only\npython_files = test_injected.py\n")
  File.write(File.join(candidate, "setup.py"), "raise RuntimeError('candidate preparation was executed')\n")
  store = AgentRuntime::Store.new(File.join(scratch, "store"))
  submission = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: candidate)
  grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: store)
  binding = {"submission_digest" => submission.fetch("digest"),
             "collector_digest" => Digest::SHA256.file(AgentRuntime::Benchmarks::NL2RepoAuditedGrader::HELPER).hexdigest,
             "procedure_digest" => Digest::SHA256.file(AgentRuntime::Benchmarks::NL2RepoAuditedGrader::HELPER).hexdigest,
             "sentinel" => "candidate-tests-config-hooks-and-preparation"}
  raw = grader.execute(repository: candidate, binding: binding)
  abort JSON.pretty_generate(raw) unless raw.key?("report_bytes")
  parsed = AgentRuntime::Benchmarks::AuditedResults.parse(bytes: raw.fetch("report_bytes"),
    expected_nodeids: expected, expected_binding: binding, process: raw.fetch("process"))
  unless parsed["status"] == "valid" && parsed.fetch("counts")["passed"] == 23
    abort JSON.pretty_generate({"raw" => raw, "parsed" => parsed})
  end
  puts JSON.pretty_generate({"check" => "candidate-tests-config-hooks-and-preparation", "result" => parsed,
                             "process_exit_code" => raw.fetch("process").fetch("exit_code"), "network" => "none"})
end
