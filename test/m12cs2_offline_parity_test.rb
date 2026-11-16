require_relative "test_helper"
require_relative "support/m12c_relay_docker"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require_relative "../lib/agent_runtime/adapters/sandbox_open_code_cli"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require_relative "../lib/agent_runtime/benchmarks/comparative_solvers"
require_relative "../lib/agent_runtime/benchmarks/adapters/nl2repo"
require_relative "../lib/agent_runtime/benchmarks/nl2repo_audited_grader"

# Installed-agent infrastructure parity only. Responses are deterministic fixtures,
# never model capability evidence. No reference implementation enters a workspace.
class M12cs2OfflineParityTest < Minitest::Test
  SPECIFICATION = "cd41306283b97f81d9cb8ec14985b47acf973dea92f492b53a4e1aaa796a4168".freeze

  def test_frozen_retrying_specification_through_complete_architectures
    skip "explicit S2 offline Docker opt-in required" unless ENV["AGRU_M12CS2_PARITY"] == "1"
    relay = M12cRelayDocker.new(script: "s2-parity")
    relay.start
    helper = File.expand_path("support/m12c_mock_relay.cjs", __dir__)
    policy = AgentRuntime::Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.relay_volume,
      helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
    runner = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_M12C_AGENT_IMAGE"),
      limits: {"cpus" => 1, "memory_bytes" => 1024 * 1024 * 1024, "pids" => 128, "tmpfs_bytes" => 128 * 1024 * 1024}, network_policy: policy)
    launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
      executable_sha256: "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
      endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: true)
    adapter = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: runner, launch: launch)
    execute = adapter.method(:execute)
    observations = []
    adapter.define_singleton_method(:execute) do |request|
      execute.call(request).tap do |result|
        observations << {"step_id" => request.step_id, "config" => request.config,
                         "status" => result.status, "logs" => result.logs}
      end
    end
    root = File.expand_path(ENV.fetch("AGRU_M12CS2_EVIDENCE_ROOT"))
    raise "evidence destination must be new" if File.exist?(root)
    FileUtils.mkdir_p(root)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    assets = File.expand_path(ENV.fetch("AGRU_M12CS2_ASSETS", ".agru/nl2repo"))
    grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: store, root: assets)
    benchmark = AgentRuntime::Benchmarks::Adapters::NL2Repo.new(store: store, root: assets, audited_grader: grader)
    task = benchmark.load_task("retrying")
    assert_equal SPECIFICATION, task.fetch("specification_digest")
    assert_equal SPECIFICATION, Digest::SHA256.hexdigest(task.fetch("instruction"))
    solvers = {
      "single-agent" => AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, store: store, adapter: adapter),
      "fixed-workflow" => AgentRuntime::Benchmarks::Solvers::FixedWorkflow.new(live: true, store: store, adapter: adapter),
      "dsl" => AgentRuntime::Benchmarks::Solvers::ComparativeDSL.new(live: true, store: store, adapter: adapter)
    }
    cells = []
    solvers.each do |name, solver|
      workspace = File.join(root, name)
      benchmark.prepare_solver_workspace(task: task, workspace: workspace)
      first = observations.length
      result = solver.solve(task: task, model: launch.model, budget: {"timeout" => 120}, workspace: workspace)
      cell = {"architecture" => name, "result" => result, "observations" => observations.drop(first)}
      cells << cell
      File.write(File.join(root, "evidence.json"), JSON.pretty_generate("fixture_only" => true, "specification_digest" => SPECIFICATION, "cells" => cells))
      assert_equal "success", result.fetch("status"), name
      roles = (name == "single-agent") ? ["single"] : %w[planner coder reviewer]
      assert_equal roles.length, cell.fetch("observations").length, name
      repository = result.fetch("repository")
      roles.each { |role| assert File.file?(File.join(repository, "s2-#{role}.txt")), "missing #{name}/#{role}" }
      boundary = AgentRuntime::Benchmarks::Submission.new(store: store)
      submission = boundary.capture(repository: repository, run_id: "s2-#{name}", preserve_modes: true)
      cell["submission"] = submission
      cell["grades"] = 2.times.map do
        request = benchmark.prepare_grading_request(task: task, submission: submission, limits: {"timeout" => 120})
        {"request" => request, "result" => benchmark.grade_submission(request)}
      end
      assert_equal [submission.fetch("digest")], cell.fetch("grades").map { |grade| grade.fetch("request").fetch("submission_digest") }.uniq
      cell.fetch("grades").each do |grade|
        actual = grade.fetch("result")
        assert_equal "success", actual.fetch("execution_status")
        assert_equal "nl2repo-audited-v2", actual.fetch("protocol")
        assert_equal "fail", actual.fetch("verdict")
        assert_equal 3, actual.fetch("passed")
        assert_equal 23, actual.fetch("executed")
      end
      assert_equal cell.fetch("grades").first.fetch("result").slice("score", "passed", "total", "verdict"),
        cell.fetch("grades").last.fetch("result").slice("score", "passed", "total", "verdict")
      assert_equal submission, AgentRuntime::Benchmarks::Submission.new(store: store).verify(submission)
      File.write(File.join(root, "evidence.json"), JSON.pretty_generate("fixture_only" => true, "specification_digest" => SPECIFICATION, "cells" => cells))
    end
    assert_equal 7, observations.length
  ensure
    if relay && root && File.directory?(root)
      %w[mock relay].each do |role|
        File.write(File.join(root, "#{role}.jsonl"), relay.logs(role))
      end
    end
    relay&.close
  end
end
