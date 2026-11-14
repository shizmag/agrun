require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/container_grader"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_grader"

# These are isolation prerequisites, not executed official-task acceptance tests.
# Initial missing-capability red was recorded before diagnostic implementation.
# The task-specific diagnostic transport does not grant official authority.
class NL2RepoGraderTest < Minitest::Test
  IMAGE = "example/nl2repo@sha256:#{"a" * 64}"
  LIMITS = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "timeout_seconds" => 5, "tmpfs_bytes" => 1_048_576}.freeze

  class Runner
    attr_reader :calls

    def initialize(status: "success", output: "", truncated: false)
      @calls = []
      @status = status
      @output = output
      @truncated = truncated
    end

    def call(**args)
      @calls << args
      cleanup = args.fetch(:argv)[1] == "rm"
      {"status" => cleanup ? "success" : @status,
       "stdout" => cleanup ? "" : @output, "stderr" => "",
       "exit_code" => (cleanup || @status == "success") ? 0 : nil,
       "stdout_truncated" => !cleanup && @truncated, "stderr_truncated" => false}
    end
  end

  def with_execution(runner)
    in_tmp do |root|
      repository = File.join(root, "candidate")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "solution.py"), "raise RuntimeError('incorrect candidate')\n")
      store = AgentRuntime::Store.new(File.join(root, "store"))
      submission = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: repository)
      plan = AgentRuntime::Benchmarks::ContainerGrader::Plan.new(image: IMAGE, command: "nl2repo")
      evidence = AgentRuntime::Benchmarks::ContainerGrader.new(store: store, process_runner: runner).grade(
        submission: submission, plan: plan, limits: LIMITS
      )
      yield evidence, submission
    end
  end

  def test_task_specific_diagnostic_is_scoreless_bounded_and_always_cleans_up
    runner = Runner.new(output: '{"score":1,"trusted":true}')
    result = AgentRuntime::Benchmarks::NL2RepoGrader.new(process_runner: runner).diagnose(script: "true", root: Dir.pwd)
    assert_nil result.fetch("official_score")
    assert_equal "untrusted_diagnostic", result.fetch("result_authority")
    assert_equal %w[run rm], runner.calls.map { |call| call.fetch(:argv)[1] }
    %w[--pull=never --platform=linux/amd64 --network=none --read-only --memory=512m --pids-limit=64 --cap-drop=ALL].each do |flag|
      assert_includes runner.calls.first.fetch(:argv), flag
    end
    refute runner.calls.first.fetch(:argv).include?("--mount")
    assert_raises(ArgumentError) { AgentRuntime::Benchmarks::NL2RepoGrader.new(process_runner: runner).diagnose(script: "true", root: Dir.pwd, timeout: 301) }
  end

  def test_forged_native_summary_and_structured_report_are_not_authority
    output = "211 passed in 0.01s\n" + JSON.generate({"score" => 1, "passed" => 211, "trusted" => true})
    with_execution(Runner.new(output: output)) do |evidence, submission|
      assert_equal "success", evidence.fetch("execution_status")
      assert_equal "untrusted", evidence.fetch("result_authority")
      assert_equal submission.fetch("digest"), evidence.fetch("submission_digest")
      refute evidence.key?("score")
      refute evidence.key?("verdict")
    end
  end

  def test_diagnostic_cleanup_runs_when_transport_raises
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |**args|
      calls << args
      raise IOError, "transport interrupted" if args.fetch(:argv)[1] == "run"
      {"status" => "success"}
    end
    grader = AgentRuntime::Benchmarks::NL2RepoGrader.new(process_runner: runner)
    assert_raises(IOError) { grader.diagnose(script: "true", root: Dir.pwd) }
    assert_equal %w[run rm], calls.map { |call| call.fetch(:argv)[1] }
  end

  def test_timeout_never_becomes_a_zero_or_full_quality_score
    runner = Runner.new(status: "timeout", output: "211 passed")
    with_execution(runner) do |evidence, _|
      assert_equal "timeout", evidence.fetch("execution_status")
      assert_equal "untrusted", evidence.fetch("result_authority")
      refute evidence.key?("score")
      assert_equal %w[run rm], runner.calls.map { |call| call.fetch(:argv)[1] }
    end
  end

  def test_truncated_success_report_is_an_execution_error
    with_execution(Runner.new(output: '{"score":1}', truncated: true)) do |evidence, _|
      assert_equal "error", evidence.fetch("execution_status")
      refute evidence.key?("score")
    end
  end

  def test_task_image_cannot_pull_or_receive_solver_selected_host_assets
    runner = Runner.new
    with_execution(runner) do |_evidence, _|
      argv = runner.calls.first.fetch(:argv)
      assert_includes argv, "--pull=never"
      assert_includes argv, "--network=none"
      assert_includes argv, "--read-only"
      assert_includes argv, "--user=65534:65534"
      mounts = argv.each_cons(2).filter_map { |flag, value| value if flag == "--mount" }
      assert_equal 1, mounts.length
      assert_includes mounts.first, "dst=/submission,readonly"
      refute_includes mounts.first, ".agru/nl2repo"
      assert_equal [IMAGE, "/submission"], argv.last(2)
    end
  end
end
