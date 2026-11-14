require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/container_grader"
require_relative "../lib/agent_runtime/benchmarks/fixture_adapter"
require_relative "../lib/agent_runtime/benchmarks/repository_solver"
require_relative "../lib/agent_runtime/benchmarks/adapters/nl2repo"

class M11bAdversarialTest < Minitest::Test
  IMAGE = "example/grader@sha256:#{"a" * 64}"
  LIMITS = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "timeout_seconds" => 5, "tmpfs_bytes" => 1_048_576}.freeze

  class FakeRunner
    attr_reader :calls
    def initialize(raw)
      @raw = raw
      @calls = []
    end

    def call(**args)
      @calls << args
      return {"status" => "success", "exit_code" => 0} if args[:argv][1] == "rm"
      @raw
    end
  end

  def with_artifacts
    in_tmp do |dir|
      store = AgentRuntime::Store.new(File.join(dir, "store"))
      submissions = AgentRuntime::Benchmarks::Submission.new(store: store)
      artifacts = [0, 1].map do |score|
        repo = File.join(dir, "repo#{score}")
        FileUtils.mkdir_p(repo)
        File.write(File.join(repo, "answer.json"), JSON.generate("score" => score))
        submissions.capture(repository: repo)
      end
      yield store, artifacts
    end
  end

  def test_container_output_never_grants_score_or_authority
    with_artifacts do |store, artifacts|
      ['{"score":1}', '{"score":0}', "SUCCESS: all tests passed"].each do |output|
        raw = {"status" => "success", "stdout" => output, "stderr" => "", "exit_code" => 0, "duration" => 0.1, "stdout_truncated" => false, "stderr_truncated" => false}
        runner = FakeRunner.new(raw)
        plan = AgentRuntime::Benchmarks::ContainerGrader::Plan.new(image: IMAGE, command: "nl2repo")
        evidence = AgentRuntime::Benchmarks::ContainerGrader.new(store: store, process_runner: runner).grade(submission: artifacts.first, plan: plan, limits: LIMITS)
        assert_equal "untrusted", evidence["result_authority"]
        assert_nil evidence["score"]
        assert_equal "success", evidence["execution_status"]
        assert_equal %w[run rm], runner.calls.map { |call| call[:argv][1] }
      end
    end
  end

  def test_container_nonzero_and_timeout_are_not_quality_scores
    with_artifacts do |store, artifacts|
      [["success", 1, "error"], ["timeout", 0, "timeout"]].each do |status, exit_code, expected|
        raw = {"status" => status, "stdout" => '{"score":1}', "stderr" => "", "exit_code" => exit_code, "duration" => 0.1, "stdout_truncated" => false, "stderr_truncated" => false}
        runner = FakeRunner.new(raw)
        plan = AgentRuntime::Benchmarks::ContainerGrader::Plan.new(image: IMAGE, command: "nl2repo")
        result = AgentRuntime::Benchmarks::ContainerGrader.new(store: store, process_runner: runner).grade(submission: artifacts.first, plan: plan, limits: LIMITS)
        assert_equal expected, result["execution_status"]
        assert_nil result["score"]
        assert_equal "untrusted", result["result_authority"]
      end
    end
  end

  def test_fixture_request_rejects_task_submission_and_evidence_swaps
    with_artifacts do |store, artifacts|
      adapter = AgentRuntime::Benchmarks::FixtureAdapter.new(store: store)
      request = adapter.prepare_grading_request(task: adapter.load_task("one"), submission: artifacts.first, limits: {"seconds" => 1})
      result = adapter.grade_submission(request)
      assert_equal 0.0, result["score"]
      assert_equal artifacts.first["id"], result.fetch("evidence").fetch("submission_id")
      {"task_id" => "zero", "submission_id" => artifacts.last["id"], "submission_digest" => artifacts.last["digest"], "specification_digest" => "0" * 64, "request_digest" => "0" * 64}.each do |key, value|
        assert_raises(ArgumentError, key) { adapter.grade_submission(request.merge(key => value)) }
      end
      other = adapter.prepare_grading_request(task: adapter.load_task("one"), submission: artifacts.last, limits: {"seconds" => 1})
      assert_equal 1.0, adapter.grade_submission(other)["score"]
    end
  end
end

class M11bRepositorySolverAdversarialTest < Minitest::Test
  def test_rejects_symlink_repository_root
    in_tmp do |dir|
      source = File.join(dir, "private")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "hidden_test.py"), "secret")
      alias_path = File.join(dir, "alias")
      File.symlink(source, alias_path)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      assert_raises(ArgumentError, "repository root aliases must be rejected") do
        AgentRuntime::Benchmarks::RepositorySolver.new(repository: alias_path)
      end
    end
  end
end

class M11bDiagnosticCleanupTest < Minitest::Test
  class CleanupFailureRunner
    def call(**args)
      if args.fetch(:argv)[1] == "rm"
        {"status" => "failure", "exit_code" => 1, "stderr" => "daemon unavailable"}
      else
        {"status" => "timeout", "exit_code" => nil, "stdout" => "", "stderr" => ""}
      end
    end
  end

  def test_cleanup_failure_is_reported
    require_relative "../lib/agent_runtime/benchmarks/nl2repo_grader"
    result = AgentRuntime::Benchmarks::NL2RepoGrader.new(process_runner: CleanupFailureRunner.new).diagnose(script: "true", root: Dir.pwd, timeout: 1)
    refute_nil result["cleanup_error"], "cleanup failure must not be silently ignored"
  end
end

class M11bDiagnosticAuthorityTest < Minitest::Test
  class SpoofDiagnostic
    def diagnose_submission(**)
      {"score" => 1.0, "verdict" => "pass", "execution_status" => "success", "trust" => "official", "stdout" => '{"score":1.0}'}
    end
  end

  def test_spoofed_diagnostic_fields_do_not_become_protocol_score
    in_tmp do |dir|
      manifest = JSON.parse(File.read("benchmarks/nl2repo/manifest.json"))
      manifest["tasks"] = [manifest.fetch("tasks").find { |task| task.fetch("id") == "retrying" }]
      path = File.join(dir, "manifest.json")
      File.write(path, JSON.generate(manifest))
      store = AgentRuntime::Store.new(File.join(dir, "store"))
      adapter = AgentRuntime::Benchmarks::Adapters::NL2Repo.new(manifest_path: path, root: File.join(dir, ".agru/nl2repo"), store: store, diagnostics: true, diagnostic_runner: SpoofDiagnostic.new)
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      File.write(File.join(repo, "retrying.py"), "pass\n")
      submission = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: repo)
      request = adapter.prepare_grading_request(task: adapter.load_task("retrying"), submission: submission, limits: {"timeout" => 10})
      result = adapter.grade_submission(request)
      assert_equal 1.0, result.fetch("diagnostics").fetch("score")
      assert_nil result.fetch("score")
      assert_equal "unavailable", result.fetch("execution_status")
      assert_equal "untrusted", result.fetch("trust")
      assert_equal "untrusted", result.fetch("verdict")
    end
  end
end
