require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks"
require_relative "../lib/agent_runtime/benchmarks/live_cli"
require "rbconfig"
require "stringio"

# No endpoint is contacted: the pinned executable only writes an intentionally
# incomplete candidate and emits local events. Real audited grading is required.
root = File.expand_path("../.agru/m12b-mock", __dir__)
FileUtils.mkdir_p(root)
id = "m12b-mock-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(4)}"
work = File.join(root, id)
FileUtils.mkdir_p(work)
marker = File.join(work, "launches")
executable = File.join(work, "mock-opencode")
File.write(executable, <<~RUBY)
  #!#{RbConfig.ruby}
  require "json"
  raise "unexpected credential" unless ENV.fetch("OMNIROUTE_API_KEY") == "m12b-mock-only"
  File.open(#{marker.inspect}, "a") { |file| file.puts "launch" }
  File.write("retrying.py", <<~PYTHON)
    # Deliberately incomplete acceptance candidate; no reference copied.
    class RetryError(Exception):
        pass
    class Retrying:
        def __init__(self, *args, **kwargs):
            pass
    def retry(*args, **kwargs):
        def decorate(function):
            return function
        return decorate
  PYTHON
  puts JSON.generate({"type" => "step_start", "sessionID" => "ses_mock", "part" => {"id" => "start", "messageID" => "message", "sessionID" => "ses_mock", "type" => "step-start"}})
  puts JSON.generate({"type" => "step_finish", "sessionID" => "ses_mock", "part" => {"id" => "finish", "messageID" => "message", "sessionID" => "ses_mock", "type" => "step-finish", "reason" => "stop", "tokens" => {"input" => 1, "output" => 1}}})
RUBY
File.chmod(0o755, executable)
adapter = AgentRuntime::Benchmarks::Adapters::NL2Repo.new
manifest = {"schema_version" => 1, "experiment_id" => id,
            "benchmark" => adapter.identity.slice("name", "revision").merge("task_ids" => ["retrying"]),
            "solver_ids" => ["single-agent"], "models" => [{"id" => "omniroute", "model_profile" => {
              "id" => "mock-pilot", "provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "execution_kind" => "real_provider",
              "tool_policy" => {"endpoint" => AgentRuntime::Execution::OpenCodeLaunch::ENDPOINT, "route" => "cx/gpt-6-luna-low", "model_fallback" => false,
                                "executable" => executable, "executable_sha256" => Digest::SHA256.file(executable).hexdigest}
            }}],
            "repetitions" => 1, "limits" => {"timeout" => 120, "max_concurrent_sessions" => 1}, "execution_mode" => "live", "subset_role" => "mock-acceptance"}
frozen_manifest = AgentRuntime::Benchmarks::ExperimentManifest.new(manifest)
scope = {"experiment_digest" => frozen_manifest.digest, "task" => "retrying", "solver" => "single-agent", "provider" => "omniroute",
         "endpoint" => AgentRuntime::Execution::OpenCodeLaunch::ENDPOINT, "route" => "cx/gpt-6-luna-low", "model" => "cx/gpt-6-luna-low", "mode" => "live"}
manifest_path = File.join(work, "manifest.json")
authorization_path = File.join(work, "authorization.json")
File.write(manifest_path, JSON.pretty_generate(manifest))
File.write(authorization_path, JSON.pretty_generate({"scope" => scope, "expires_at" => Time.now.to_f + 600, "financial_exposure" => "not_hard_bounded"}))
previous = ENV["OMNIROUTE_API_KEY"]
begin
  ENV["OMNIROUTE_API_KEY"] = "m12b-mock-only"
  # Exercise the actual executable CLI/exit boundary as well as ProcessRunner.
  cli_process = AgentRuntime::Adapters::ProcessRunner.new.call(
    argv: [RbConfig.ruby, File.expand_path("../bin/agru", __dir__), "bench", "live", "run", manifest_path, "--authorization", authorization_path, "--root", root],
    cwd: File.expand_path("..", __dir__), timeout: 180
  )
  raise "mock executable CLI failed: #{cli_process.fetch("stderr")}" unless cli_process.fetch("status") == "success" && cli_process.fetch("exit_code") == 0
  result = AgentRuntime::Store.new(root).report(id)
  cell = result.fetch("cells").fetch(0)
  raise "mock solver did not succeed" unless cell.fetch("execution_status") == "success"
  raise "expected actual audited non-perfect score" unless cell["score"].is_a?(Numeric) && cell.fetch("score") < 1
  before = File.readlines(marker).length
  raise "mock must launch once" unless before == 1
  store = AgentRuntime::Store.new(root)
  cli = AgentRuntime::Benchmarks::CLI.new
  raise "report CLI failed" unless cli.run(["report", id, "--root", root]) == 0
  raise "regrade CLI failed" unless cli.run(["regrade", id, cell.fetch("id"), "--root", root, "--audited-scoring"]) == 0
  regraded = store.report(id)
  raise "regrade launched solver" unless File.readlines(marker).length == before
  raise "regrade not recorded" unless regraded.fetch("cells").fetch(0).fetch("grading_attempts").length == 2
  observation = {"experiment_id" => id, "provider_calls" => 0, "mock_launches" => before,
                 "score" => cell.fetch("score"), "grading_attempts" => regraded.fetch("cells").fetch(0).fetch("grading_attempts").length,
                 "kind" => "mock execution and actual audited grading; not model quality"}
  File.write(File.join(work, "observations.json"), JSON.pretty_generate(observation))
  puts JSON.pretty_generate(observation)
ensure
  previous ? ENV["OMNIROUTE_API_KEY"] = previous : ENV.delete("OMNIROUTE_API_KEY")
end
