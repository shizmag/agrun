require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../lib/agent_runtime/benchmarks/fixture_adapter"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require_relative "../lib/agent_runtime/benchmarks/registry"

class M12bPartialSubmissionTest < Minitest::Test
  %w[failure timeout cancelled].each do |status|
    define_method("test_strict_#{status}_recovers_only_persisted_partial_output") do
      in_tmp do |root|
        source = File.join(root, "source")
        FileUtils.mkdir_p(source)
        store = AgentRuntime::Store.new(File.join(root, "store"))
        adapter = Object.new
        adapter.define_singleton_method(:execute) do |request|
          repository = request.inputs.fetch("repository")
          File.write(File.join(repository, "partial.txt"), "actual partial")
          AgentRuntime::Result.new(status: status, outputs: {"repository" => repository}, error: {"classification" => status})
        end
        solver = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter, store: store)
        task = Struct.new(:repository, :instruction).new(source, "offline test")
        budget = {"timeout" => 3, "model_profile" => {"id" => "fixture", "provider" => "fixture", "model" => "fixture", "execution_kind" => "offline_fixture", "tool_policy" => {}}}
        result = solver.solve(task: task, model: "fixture", budget: budget, workspace: File.join(root, "solve"))
        assert_equal status, result.fetch("status")
        assert_equal "actual partial", File.read(File.join(result.fetch("repository"), "partial.txt"))
        report = store.report(result.fetch("execution").fetch("run_id"))
        assert_empty report.fetch("outputs")
        assert_empty report.fetch("steps").fetch("solve").fetch("outputs")
        partial = report.fetch("steps").fetch("solve").fetch("attempts").last.fetch("partial_outputs").fetch("repository")
        assert_equal partial, result.fetch("partial_repository_artifact")
        assert_equal store.value(partial), result.fetch("repository")
        runtime_repository = File.join(root, "solve", "runtime", "solve", "1", "inputs", "repository")
        File.write(File.join(runtime_repository, "partial.txt"), "later mutation")
        assert_equal "actual partial", File.read(File.join(result.fetch("repository"), "partial.txt"))
        assert_equal({"classification" => status}, result.fetch("error"))
      end
    end
  end

  def test_runner_preserves_runtime_partial_artifact_identity_and_lineage
    in_tmp do |root|
      store, runner, manifest = setup_runner(root)
      source = File.join(root, "partial")
      FileUtils.mkdir_p(source)
      input = store.put(type: "repository", value: source, run_id: "runtime", step_id: "input", attempt: 0)
      File.write(File.join(source, "partial.txt"), "partial")
      partial = store.put(type: "repository", value: source, run_id: "runtime", step_id: "solve", attempt: 1, inputs: [input.fetch("id")], metadata: {"partial" => true})
      solver = AgentRuntime::Benchmarks::FixtureSolvers.build("direct")
      solver.define_singleton_method(:solve) do |**_args|
        {"status" => "timeout", "repository" => store.value(partial), "partial_repository_artifact" => partial}
      end
      runner.instance_variable_set(:@solvers, {"direct" => solver})
      cell = runner.run(manifest: manifest).fetch("cells").first
      assert_equal partial, cell.fetch("partial_submission")
      assert_equal [input.fetch("id")], cell.fetch("partial_submission").fetch("inputs")
      assert_equal "runtime", cell.fetch("partial_submission").fetch("run_id")
      assert_equal "solve", cell.fetch("partial_submission").fetch("step_id")
      assert_equal 1, cell.fetch("partial_submission").fetch("attempt")
    end
  end

  def test_strict_failure_without_actual_output_has_no_partial_repository
    in_tmp do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      store = AgentRuntime::Store.new(File.join(root, "store"))
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |_request|
        AgentRuntime::Result.new(status: "failure", outputs: {}, error: {"classification" => "executor"})
      end
      solver = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter, store: store)
      task = Struct.new(:repository, :instruction).new(source, "offline test")
      budget = {"timeout" => 3, "model_profile" => {"id" => "fixture", "provider" => "fixture", "model" => "fixture", "execution_kind" => "offline_fixture", "tool_policy" => {}}}
      result = solver.solve(task: task, model: "fixture", budget: budget, workspace: File.join(root, "solve"))
      assert_equal "failure", result.fetch("status")
      assert_nil result["repository"]
    end
  end

  def test_failed_direct_solver_does_not_return_original_workspace_without_output
    in_tmp do |root|
      repository = File.join(root, "source")
      FileUtils.mkdir_p(repository)
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |_request|
        AgentRuntime::Result.new(status: "timeout", outputs: {}, error: {"classification" => "timeout"})
      end
      solver = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter)
      task = Struct.new(:repository, :instruction).new(repository, "offline test")
      result = solver.solve(task: task, model: "fixture", budget: {}, workspace: File.join(root, "solve"))
      assert_equal "timeout", result.fetch("status")
      assert_nil result["repository"]
    end
  end

  %w[failure timeout cancelled unknown].each do |status|
    define_method("test_#{status}_retains_partial_without_grading") do
      in_tmp do |root|
        store, runner, manifest = setup_runner(root)
        manifest["benchmark"]["task_ids"] = ["one"]
        manifest["repetitions"] = 1
        solver = AgentRuntime::Benchmarks::FixtureSolvers.build("direct")
        solver.define_singleton_method(:solve) do |task:, model:, budget:, workspace:|
          repository = File.join(workspace, "repository")
          File.write(File.join(repository, "partial.txt"), "unfinished")
          {"status" => status, "repository" => repository, "error" => {"classification" => status}}
        end
        runner.instance_variable_set(:@solvers, {"direct" => solver})
        report = runner.run(manifest: manifest)
        cell = report.fetch("cells").first
        assert_equal (%w[timeout cancelled].include?(status) ? status : "error"), cell.fetch("execution_status")
        assert_equal({"classification" => status}, cell.fetch("error"))
        assert_equal status, cell.fetch("solver_status")
        assert cell.fetch("partial_submission")
        refute cell.key?("submission")
        assert_empty cell.fetch("grading_attempts", [])
        assert_nil cell["score"]
        assert_equal cell["partial_submission"], store.report(report.fetch("run_id")).fetch("cells").first["partial_submission"]
      end
    end
  end

  def test_partial_capture_error_does_not_replace_solver_error
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      manifest["benchmark"]["task_ids"] = ["one"]
      manifest["repetitions"] = 1
      solver = AgentRuntime::Benchmarks::FixtureSolvers.build("direct")
      solver.define_singleton_method(:solve) do |**_args|
        {"status" => "timeout", "repository" => "/nonexistent-partial-repository", "error" => "original timeout"}
      end
      runner.instance_variable_set(:@solvers, {"direct" => solver})
      cell = runner.run(manifest: manifest).fetch("cells").first
      assert_equal "timeout", cell.fetch("execution_status")
      assert_equal "original timeout", cell.fetch("error")
      assert cell.fetch("partial_capture_error")
      refute cell.key?("partial_submission")
      assert_empty cell.fetch("grading_attempts", [])
    end
  end

  private

  def setup_runner(root)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    registry = AgentRuntime::Benchmarks::Registry.new
    registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
    runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry,
      solvers: {"direct" => AgentRuntime::Benchmarks::FixtureSolvers.build("direct")})
    manifest = {"schema_version" => 1, "experiment_id" => "partial-experiment", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["one"]},
                "solver_ids" => ["direct"], "models" => [{"id" => "fixture"}], "repetitions" => 1, "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
    [store, runner, manifest]
  end
end
