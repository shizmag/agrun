require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/submission"
require_relative "../lib/agent_runtime/benchmarks/container_grader"

class BenchmarkIsolationTest < Minitest::Test
  IMAGE = "example/grader@sha256:#{"a" * 64}"
  LIMITS = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "timeout_seconds" => 5, "tmpfs_bytes" => 1_048_576}.freeze

  class RecordingRunner
    attr_reader :calls
    attr_accessor :response, :hook

    def initialize
      @calls = []
      @response = {"status" => "success", "stdout" => '{"score":1}', "stderr" => "", "exit_code" => 0, "duration" => 0.1, "stdout_truncated" => false, "stderr_truncated" => false}
    end

    def call(**args)
      @calls << args
      hook&.call(args)
      return response.dup if args[:argv][1] == "run"
      {"status" => "success", "stdout" => "", "stderr" => "", "exit_code" => 0}
    end
  end

  def with_submission
    in_tmp do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      File.write(File.join(repo, "solution.py"), "print('solution')\n")
      store = AgentRuntime::Store.new(File.join(dir, "store"))
      submissions = AgentRuntime::Benchmarks::Submission.new(store: store)
      yield submissions.capture(repository: repo), store, submissions, repo
    end
  end

  def grade(store, artifact, runner, **options)
    AgentRuntime::Benchmarks::ContainerGrader.new(store: store, process_runner: runner).grade(
      submission: artifact, plan: AgentRuntime::Benchmarks::ContainerGrader::Plan.new(image: IMAGE, command: "nl2repo"), limits: LIMITS, **options
    )
  end

  def test_plan_rejects_tags_commands_and_host_mounts
    plan = AgentRuntime::Benchmarks::ContainerGrader::Plan
    ["ubuntu:latest", "ubuntu", "ubuntu@sha256:abc", "--privileged@sha256:#{"a" * 64}"].each do |image|
      assert_raises(ArgumentError) { plan.new(image: image, command: "nl2repo") }
    end
    assert_raises(ArgumentError) { plan.new(image: IMAGE, command: "sh") }
    assert_raises(ArgumentError) { plan.new(image: IMAGE, command: "nl2repo", mounts: ["/"]) }
  end

  def test_fresh_hardened_container_and_untrusted_json
    with_submission do |artifact, store, _, repo|
      runner = RecordingRunner.new
      first = grade(store, artifact, runner)
      second = grade(store, artifact, runner)
      runs = runner.calls.select { |call| call[:argv][1] == "run" }
      argv = runs.first[:argv]
      %w[--read-only --cap-drop=ALL --security-opt=no-new-privileges --network=none --user=65534:65534 --pull=never].each { |flag| assert_includes argv, flag }
      %w[--cpus=1 --memory=134217728 --memory-swap=134217728 --pids-limit=32].each { |flag| assert_includes argv, flag }
      assert argv.any? { |arg| arg.start_with?("/tmp:rw,noexec,nosuid,nodev,size=1048576") }
      refute argv.any? { |arg| arg.include?(repo) || arg.include?("docker.sock") }
      assert_includes argv, IMAGE
      assert_equal "/opt/agru/bin/grade-nl2repo", argv[-3]
      assert_equal [IMAGE, "/submission"], argv.last(2)
      refute_equal first.fetch("container_name"), second.fetch("container_name")
      assert_equal "success", first.fetch("execution_status")
      assert_equal "untrusted", first.fetch("result_authority")
      refute first.key?("score")
      refute first.key?("verdict")
      assert_equal '{"score":1}', first.fetch("stdout")
      assert_equal 2, runner.calls.count { |call| call[:argv][1, 2] == ["rm", "--force"] }
      assert_equal 5, runs.first[:timeout]
    end
  end

  def test_timeout_cancellation_and_daemon_failure_cleanup_without_fallback
    %w[timeout cancelled failure].each do |status|
      with_submission do |artifact, store|
        runner = RecordingRunner.new
        runner.response["status"] = status
        runner.response["exit_code"] = nil
        evidence = grade(store, artifact, runner)
        assert_equal((status == "failure") ? "error" : status, evidence.fetch("execution_status"))
        assert_equal %w[run rm], runner.calls.map { |call| call[:argv][1] }
      end
    end
    with_submission do |artifact, store|
      runner = RecordingRunner.new
      runner.hook = ->(args) { raise IOError, "daemon unavailable" if args[:argv][1] == "run" }
      evidence = grade(store, artifact, runner)
      assert_equal "error", evidence.fetch("execution_status")
      assert_includes evidence.fetch("error"), "daemon unavailable"
      assert_equal %w[run rm], runner.calls.map { |call| call[:argv][1] }
    end
  end

  def test_invalid_limits_do_not_launch
    with_submission do |artifact, store|
      [0, -1, Float::INFINITY, Float::NAN, "1", true, nil].each do |value|
        LIMITS.each_key do |key|
          runner = RecordingRunner.new
          grader = AgentRuntime::Benchmarks::ContainerGrader.new(store: store, process_runner: runner)
          assert_raises(ArgumentError) { grader.grade(submission: artifact, plan: AgentRuntime::Benchmarks::ContainerGrader::Plan.new(image: IMAGE, command: "nl2repo"), limits: LIMITS.merge(key => value)) }
          assert_empty runner.calls
        end
      end
    end
  end

  def test_real_process_runner_bounds_hanging_run_and_preserves_cleanup_after_cancellation
    require "rbconfig"
    %w[timeout cancelled].each do |expected|
      with_submission do |artifact, store|
        calls = []
        process_runner = AgentRuntime::Adapters::ProcessRunner.new
        runner = Object.new
        runner.define_singleton_method(:call) do |**args|
          calls << args
          # Run a real hanging child in place of Docker, preserving all boundary
          # timeout/cancellation arguments. Cleanup is a real successful child.
          code = (args[:argv][1] == "run") ? "sleep 30" : "exit 0"
          process_runner.call(**args.merge(argv: [RbConfig.ruby, "-e", code]))
        end
        cancellation = AgentRuntime::Cancellation.new
        canceller = if expected == "cancelled"
          Thread.new do
            sleep 0.1
            cancellation.cancel!
          end
        end
        grader = AgentRuntime::Benchmarks::ContainerGrader.new(store: store, process_runner: runner)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        evidence = grader.grade(submission: artifact,
          plan: AgentRuntime::Benchmarks::ContainerGrader::Plan.new(image: IMAGE, command: "nl2repo"),
          limits: LIMITS.merge("timeout_seconds" => (expected == "timeout") ? 0.1 : 5), cancellation: cancellation)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        canceller&.join
        assert_equal expected, evidence.fetch("execution_status")
        assert_operator elapsed, :<, 4
        assert_equal %w[run rm], calls.map { |call| call[:argv][1] }
        assert_same cancellation, calls.first.fetch(:cancellation)
        assert_equal 10, calls.last.fetch(:timeout)
        refute calls.last.key?(:cancellation)
        refute evidence.key?("cleanup_error")
      ensure
        canceller&.join
      end
    end
  end

  def test_capture_rejects_symlinks_and_special_files
    with_submission do |_, _, submissions, repo|
      File.symlink("solution.py", File.join(repo, "link"))
      assert_raises(AgentRuntime::Error) { submissions.capture(repository: repo) }
      File.unlink(File.join(repo, "link"))
      File.mkfifo(File.join(repo, "pipe"))
      assert_raises(AgentRuntime::Error) { submissions.capture(repository: repo) }
    end
  end

  def test_store_identity_and_traversal_are_revalidated
    with_submission do |artifact, _, submissions|
      assert_raises(AgentRuntime::Error) { submissions.verify(artifact.merge("digest" => "0" * 64)) }
      assert_raises(AgentRuntime::Error) { submissions.verify(artifact.merge("path" => "/")) }
      object = artifact.fetch("path").delete_suffix(".tree")
      File.chmod(0o644, object)
      File.write(object, JSON.generate("../escape" => "owned"))
      assert_raises(AgentRuntime::Error) { submissions.verify(artifact) }
    end
  end

  def test_changed_store_never_reaches_docker
    with_submission do |artifact, store|
      path = File.join(artifact.fetch("path"), "solution.py")
      File.chmod(0o644, path)
      File.write(path, "different content")
      runner = RecordingRunner.new
      evidence = grade(store, artifact, runner)
      assert_equal "error", evidence.fetch("execution_status")
      assert_empty runner.calls
    end
  end

  def test_materialization_rejects_existing_destination_and_symlink_roots
    with_submission do |artifact, _, submissions, repo|
      assert_raises(AgentRuntime::Error) { submissions.materialize(artifact, destination: repo) }
      link = "#{repo}-alias"
      File.symlink(repo, link)
      assert_raises(AgentRuntime::Error) { submissions.capture(repository: link) }
      assert_raises(AgentRuntime::Error) { submissions.materialize(artifact, destination: link) }
    end
  end

  def test_source_and_private_snapshot_mutation_fail_closed
    [:source, :snapshot].each do |target|
      with_submission do |artifact, store|
        runner = RecordingRunner.new
        mounted_path = nil
        runner.hook = lambda do |args|
          next unless args[:argv][1] == "run"
          mount = args[:argv].find { |arg| arg.start_with?("type=bind,src=") }
          mounted_path = mount.split(",")[1].delete_prefix("src=")
          refute_equal artifact.fetch("path"), mounted_path
          path = File.join((target == :source) ? artifact.fetch("path") : mounted_path, "solution.py")
          File.chmod(0o644, path)
          File.write(path, "tampered")
        end
        evidence = grade(store, artifact, runner)
        assert_equal "error", evidence.fetch("execution_status")
        refute File.exist?(mounted_path)
        assert_equal "untrusted", evidence.fetch("result_authority")
      end
    end
  end

  def test_nonzero_truncated_and_cleanup_failure_never_establish_success
    with_submission do |artifact, store|
      [{"exit_code" => 7}, {"stdout_truncated" => true}, {"stderr_truncated" => true}].each do |change|
        runner = RecordingRunner.new
        runner.response.merge!(change)
        assert_equal "error", grade(store, artifact, runner).fetch("execution_status")
      end
      runner = RecordingRunner.new
      runner.hook = ->(args) { raise IOError, "cleanup failed" if args[:argv][1] == "rm" }
      evidence = grade(store, artifact, runner)
      assert_equal "error", evidence.fetch("execution_status")
      assert_includes evidence.fetch("cleanup_error"), "cleanup failed"
    end
  end
end
