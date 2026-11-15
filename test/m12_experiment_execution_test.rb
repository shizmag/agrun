require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../lib/agent_runtime/benchmarks/registry"
require_relative "../lib/agent_runtime/benchmarks/reports"
require_relative "../lib/agent_runtime/benchmarks/solvers"

class M12ExperimentExecutionTest < Minitest::Test
  def test_direct_strict_solver_does_not_claim_configured_model_as_observed
    in_tmp do |root|
      repository = File.join(root, "source")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "answer.txt"), "fixture")
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |request|
        AgentRuntime::Result.new(status: "success", outputs: {"repository" => request.inputs.fetch("repository")}, model: nil)
      end
      task = Struct.new(:repository, :instruction).new(repository, "offline fixture")
      solver = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter, store: AgentRuntime::Store.new(File.join(root, "store")))
      result = solver.solve(task: task, model: "configured-alias", budget: {"timeout" => 2, "model_profile" => {"model" => "fixture/model"}}, workspace: File.join(root, "workspace"))
      assert_equal "success", result.fetch("status")
      assert_nil result.fetch("model")
      assert_equal "configured-alias", result.fetch("requested_model")
    end
  end

  def test_four_architectures_persist_actual_runtime_attempts_in_shared_store
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "store"))
      registry = AgentRuntime::Benchmarks::Registry.new
      registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
      ids = AgentRuntime::Benchmarks::FixtureSolvers::CATEGORIES
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry,
        solvers: ids.to_h { |id| [id, AgentRuntime::Benchmarks::FixtureSolvers.build(id, store: store)] })
      manifest = {"schema_version" => 1, "experiment_id" => "parity", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["one"]},
                  "solver_ids" => ids, "models" => [{"id" => "fixture", "model_profile" => {"model" => "fixture/model"}}], "repetitions" => 1,
                  "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
      report = runner.run(manifest: manifest)
      counts = report.fetch("cells").map do |cell|
        execution = cell.fetch("execution")
        persisted = store.report(execution.fetch("run_id"))
        actual = persisted.fetch("steps").values.sum { |step| step.fetch("attempts").size }
        expected_roles = case cell.fetch("solver_id")
        when "direct" then %w[write]
        when "single-agent" then %w[observe review write]
        else %w[plan verify write]
        end
        assert_equal expected_roles, persisted.fetch("steps").keys.sort
        persisted.fetch("steps").each_value do |step|
          step.fetch("attempts").each do |attempt|
            trace = JSON.parse(store.value(store.artifact(attempt.fetch("log").fetch("id")))).fetch("execution")
            assert_equal 10, JSON.parse(trace.fetch("process").fetch("stdout")).dig("part", "tokens", "input")
          end
        end
        assert_equal actual, execution.fetch("invocation_count")
        assert_equal "success", cell.fetch("execution_status")
        actual
      end
      assert_equal [1, 3, 3, 3], counts
      assert_equal 1, report.fetch("cells").map { |cell| cell.fetch("submission").fetch("digest") }.uniq.size
      report.fetch("cells").each do |cell|
        cell["usage"] = {"forged_usage" => 999999}
        cell["cost"] = 999999
      end
      store.save_report(report)
      reports = AgentRuntime::Benchmarks::Reports.new(store: AgentRuntime::Store.new(store.root))
      json = JSON.parse(reports.render(experiment_id: "parity", format: "json"))
      assert_equal counts, json.fetch("cells").map { |cell| cell.fetch("execution").fetch("invocation_count") }
      json.fetch("cells").each do |cell|
        assert_nil cell["cost"]
        assert_equal cell.dig("execution", "usage"), cell["usage"]
      end
      %w[json csv markdown].each do |format|
        output = reports.render(experiment_id: "parity", format: format)
        refute_includes output, "forged_usage"
        refute_includes output, "999999"
      end
      assert_includes reports.render(experiment_id: "parity", format: "csv").lines.first, "execution"
      assert_includes reports.render(experiment_id: "parity", format: "markdown"), "## Execution evidence"
      json.fetch("cells").each do |cell|
        text = JSON.generate(cell.fetch("execution"))
        %w[events requests process stdout stderr frozen_config].each { |key| refute_includes text, "\"#{key}\":" }
      end
    end
  end

  def test_explicit_profile_reaches_solver_without_mutating_legacy_model_id
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "store"))
      registry = AgentRuntime::Benchmarks::Registry.new
      registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
      calls = []
      solver = AgentRuntime::Benchmarks::FixtureSolvers.build("direct")
      solver.define_singleton_method(:configuration) { {"architecture" => "direct", "fixture" => true} }
      solver.define_singleton_method(:solve) do |task:, model:, budget:, workspace:|
        calls << {"model" => model, "budget" => JSON.parse(JSON.generate(budget))}
        {"status" => "blocked", "error" => "recording only"}
      end
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry, solvers: {"direct" => solver})
      profile = {"model" => "fixture/model"}
      manifest = {"schema_version" => 1, "experiment_id" => "execution-contract", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["one"]},
                  "solver_ids" => ["direct"], "models" => [{"id" => "fixture", "model_profile" => profile}], "repetitions" => 1,
                  "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
      result = runner.run(manifest: manifest)
      assert_equal 1, calls.size
      assert_equal "fixture", calls.first.fetch("model")
      assert_equal profile, calls.first.fetch("budget").fetch("model_profile")
      assert_equal 10, calls.first.fetch("budget").fetch("timeout")
      assert_nil result.fetch("cells").first["score"]
      assert_nil result.fetch("cells").first["verdict"]
    end
  end
end
