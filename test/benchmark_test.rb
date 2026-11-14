require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks"
require_relative "../lib/agent_runtime/cli"
require "stringio"

class BenchmarkTest < Minitest::Test
  def test_manifest_loading_and_reproducible_fixture_revision
    in_tmp do |root|
      a = AgentRuntime::Benchmarks::Fixture.demo(root: File.join(root, "a"))
      b = AgentRuntime::Benchmarks::Fixture.demo(root: File.join(root, "b"))
      assert_equal a.base_commit, b.base_commit
      assert_equal "local-demo", a.dataset
      assert_equal [], a.public_tests
      File.write(File.join(root, "bad.json"), "{}")
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::Manifest.load(File.join(root, "bad.json")) }
    end
  end

  def test_matrix_retains_every_repetition_and_expected_failures
    in_tmp do |root|
      _, task, runner = setup_fixture(root)
      results = runner.matrix(tasks: [task], solvers: {"good" => AgentRuntime::Benchmarks::Solvers::Fake.new, "bad" => AgentRuntime::Benchmarks::Solvers::Fake.new(good: false)}, repetitions: 2)
      assert_equal 4, results.size
      assert_equal 4, results.map { |r| r["run_id"] }.uniq.size
      assert_equal [1, 2], results.select { |r| r["solver_id"] == "bad" }.map { |r| r["repetition"] }
      assert_equal %w[pass pass fail fail], results.map { |r| r.dig("evaluation", "verdict") }
    end
  end

  def setup_fixture(root)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    task = AgentRuntime::Benchmarks::Fixture.demo(root: File.join(root, "fixture"))
    runner = AgentRuntime::Benchmarks::Runner.new(store: store, root: File.join(root, "runs"))
    [store, task, runner]
  end

  def test_good_and_bad_solver_separate_execution_from_verdict
    in_tmp do |root|
      store, task, runner = setup_fixture(root)
      good = runner.run(task: task, solver: AgentRuntime::Benchmarks::Solvers::Fake.new)
      bad = runner.run(task: task, solver: AgentRuntime::Benchmarks::Solvers::Fake.new(good: false))
      assert_equal "success", good["status"]
      assert_equal "success", bad["status"]
      assert_equal "completed", bad.dig("evaluation", "execution_status")
      assert_equal "pass", good.dig("evaluation", "verdict")
      assert_equal "fail", bad.dig("evaluation", "verdict")
      assert_equal task.base_commit, AgentRuntime::Benchmarks::Fixture.git(task.repository, "rev-parse", "HEAD").strip
      assert_empty AgentRuntime::Benchmarks::Fixture.git(task.repository, "diff")
      refute_empty good.dig("solution", "patch")
      assert_equal good, store.report(good["run_id"])
      assert_equal 1, good["repetition"]
      assert good["started_at"]
      assert good["ended_at"]
      assert_equal AgentRuntime::IR.digest(good["configuration"]), good["configuration_digest"]
      refute_equal good["configuration_digest"], bad["configuration_digest"]
      directory = File.join(root, "runs", good["run_id"])
      assert_equal good, JSON.parse(File.read(File.join(directory, "result.json")))
      assert_includes File.read(File.join(directory, "result.csv")), '"pass"'
      assert_equal %w[artifact environment procedure specification], good.dig("evaluation", "bindings").keys.sort
      artifact = good.dig("evaluation", "report_artifact")
      assert_equal "pass", store.value(artifact)["verdict"]
      refute_equal good.dig("evaluation", "bindings", "artifact"), bad.dig("evaluation", "bindings", "artifact")
    end
  end

  def test_hidden_material_is_not_given_to_solver
    in_tmp do |root|
      _, task, runner = setup_fixture(root)
      observed = false
      solver = Object.new
      solver.define_singleton_method(:solve) do |task:, model:, budget:, workspace:|
        raise "hidden procedure leaked" unless task.hidden_test.nil?
        raise "hidden file leaked" if Dir.glob(File.join(task.repository, "**/*")).any? { |p| p.include?("hidden_test") }
        observed = true
        AgentRuntime::Benchmarks::Solvers::Fake.new.solve(task: task, model: model, budget: budget, workspace: workspace)
      end
      assert_equal "pass", runner.run(task: task, solver: solver).dig("evaluation", "verdict")
      assert observed
    end
  end

  def test_opencode_is_blocked_before_adapter_is_called_offline
    adapter = Object.new
    adapter.define_singleton_method(:execute) { |_| raise "must not call live adapter" }
    result = AgentRuntime::Benchmarks::Solvers::OpenCode.new(adapter: adapter).solve(task: nil,
      model: nil, budget: {}, workspace: nil)
    assert_equal "blocked", result["status"]
  end

  def test_dsl_solver_evaluates_real_modified_repository
    in_tmp do |root|
      store, task, runner = setup_fixture(root)
      solver = AgentRuntime::Benchmarks::Solvers::DSL.new(store: store,
        program: File.expand_path("../programs/demo.rb", __dir__))
      report = runner.run(task: task, solver: solver)
      assert_equal "pass", report.dig("evaluation", "verdict"), report.inspect
      assert report.dig("solution", "runtime_run_id")
      assert report["ir_digest"]
    end
  end

  def test_timeout_is_not_a_correctness_failure
    in_tmp do |root|
      store, task, = setup_fixture(root)
      process = Object.new
      process.define_singleton_method(:call) { |**_| {"status" => "timeout", "exit_code" => nil} }
      evaluator = AgentRuntime::Evaluation::Evaluator.new(store: store, process_runner: process)
      result = evaluator.evaluate(task: task, repository: task.repository, run_id: "timeout")
      assert_equal "timeout", result["execution_status"]
      assert_equal "not_evaluated", result["verdict"]
    end
  end

  def test_cli_offline_end_to_end_and_report
    in_tmp do |root|
      output, = capture_io do
        assert_equal 0, AgentRuntime::CLI.start(["benchmark", "--suite", "demo", "--offline", "--root", root])
      end
      report = JSON.parse(output)
      assert_equal "pass", report.dig("evaluation", "verdict")
      output, = capture_io do
        assert_equal 0, AgentRuntime::CLI.start(["report", report.fetch("run_id"), "--root", root])
      end
      assert_equal report, JSON.parse(output)
      capture_io do
        assert_equal 0, AgentRuntime::CLI.start(["run", "--offline", "--root", root])
        assert_equal 0, AgentRuntime::CLI.start(["validate"])
        assert_equal 0, AgentRuntime::CLI.start(["graph"])
        assert_equal 0, AgentRuntime::CLI.start(["doctor"])
      end
    end
  end

  def test_grader_exception_is_not_an_incorrect_solution
    in_tmp do |root|
      store, task, = setup_fixture(root)
      task.hidden_test = File.join(root, "broken_grader.rb")
      File.write(task.hidden_test, 'raise "grader unavailable"')
      result = AgentRuntime::Evaluation::Evaluator.new(store: store).evaluate(task: task,
        repository: task.repository, run_id: "broken-grader")
      assert_equal "error", result["execution_status"]
      assert_equal "not_evaluated", result["verdict"]
    end
  end

  def test_specification_procedure_and_environment_are_exactly_bound
    in_tmp do |root|
      store, task, = setup_fixture(root)
      evaluator = AgentRuntime::Evaluation::Evaluator.new(store: store)
      first = evaluator.evaluate(task: task, repository: task.repository, run_id: "first")
      task.spec = task.spec.merge("additional_requirement" => "provenance probe")
      procedure = File.join(root, "changed_procedure.rb")
      File.write(procedure, File.read(task.hidden_test) + "\n# changed procedure bytes\n")
      task.hidden_test = procedure
      prior = ENV["AGRU_BINDING_PROBE"]
      begin
        ENV["AGRU_BINDING_PROBE"] = "changed"
        second = evaluator.evaluate(task: task, repository: task.repository, run_id: "second")
      ensure
        prior.nil? ? ENV.delete("AGRU_BINDING_PROBE") : ENV["AGRU_BINDING_PROBE"] = prior
      end
      assert_equal first.dig("bindings", "artifact"), second.dig("bindings", "artifact")
      %w[specification procedure environment].each do |key|
        refute_equal first.dig("bindings", key), second.dig("bindings", key)
      end
    end
  end

  def test_dsl_live_config_cannot_override_offline_caller
    in_tmp do |root|
      store, task, runner = setup_fixture(root)
      program = File.join(root, "live.rb")
      File.write(program, <<~RUBY)
        program :live do
          input :repository, type: :repository
          executor :agent, via: :opencode, config: {"live" => true, "prompt" => "Do not execute"}
          step :solve, with: :agent, inputs: {repository: :repository}, outputs: {repository: :repository}, config: {"live" => true}
          emit :repository, from: "solve.repository"
        end
      RUBY
      solver = AgentRuntime::Benchmarks::Solvers::DSL.new(program: program, store: store)
      report = runner.run(task: task, solver: solver)
      assert_equal "blocked", report["status"]
      assert_equal "not_evaluated", report.dig("evaluation", "verdict")
      capture_io { assert_equal 1, AgentRuntime::CLI.start(["run", program, "--offline", "--root", root]) }
    end
  end
end
