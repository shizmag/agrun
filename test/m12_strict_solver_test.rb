require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require_relative "../lib/agent_runtime/benchmarks/fixture_adapter"
require "rbconfig"

class M12StrictSolverTest < Minitest::Test
  def test_actual_authorized_cli_adapter_runs_through_direct_and_dsl_solvers
    in_tmp do |root|
      executable = File.join(root, "fixture-cli")
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        puts JSON.generate({"type"=>"step_finish","sessionID"=>"ses_solver","part"=>{"id"=>"part-one","messageID"=>"msg-one","sessionID"=>"ses_solver","type"=>"step-finish","reason"=>"stop","tokens"=>{"input"=>5,"output"=>2,"reasoning"=>0,"cache"=>{"read"=>0,"write"=>0}}}})
      RUBY
      File.chmod(0o755, executable)
      repository = File.join(root, "repository")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "answer.json"), JSON.generate("score" => 1))
      task = Struct.new(:repository, :instruction).new(repository, "offline fixture only")
      store = AgentRuntime::Store.new(File.join(root, "store"))
      profile = {"id" => "offline", "provider" => "fixture", "model" => "deterministic", "execution_kind" => "offline_fixture", "tool_policy" => {}}
      budget = {"timeout" => 3, "model_profile" => profile}
      program = File.join(root, "program.rb")
      File.write(program, <<~RUBY)
        program :strict_solver do
          input :repository, type: :repository
          executor :agent, via: :opencode
          step :solve, with: :agent, inputs: {repository: "repository"}, outputs: {repository: :repository}, config: {prompt: "offline fixture only"}
          emit :repository, from: "solve.repository"
        end
      RUBY
      %w[direct single-agent fixed-workflow dsl].each do |kind|
        roles = case kind
        when "direct" then %w[solve]
        when "single-agent" then %w[observe write review]
        else %w[plan write verify]
        end
        unless kind == "direct"
          steps = roles.each_with_index.map do |role, index|
            previous = index.zero? ? "repository" : "#{roles[index - 1]}.repository"
            needs = index.zero? ? [] : [roles[index - 1]]
            "step :#{role}, with: :agent, inputs: {repository: #{previous.inspect}}, outputs: {repository: :repository}, needs: #{needs.inspect}, config: {prompt: 'offline fixture only'}"
          end
          File.write(program, "program :strict_solver do\ninput :repository, type: :repository\nexecutor :agent, via: :opencode\n#{steps.join("\n")}\nemit :repository, from: #{"#{roles.last}.repository".inspect}\nend\n")
        end
        adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest)
        solver = if kind == "direct"
          AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter, store: store)
        else
          AgentRuntime::Benchmarks::Solvers::DSL.new(program: program, store: store, live: true, executors: {opencode: adapter})
        end
        policy = {"wall_seconds" => 10, "max_attempts" => roles.size, "max_concurrent_sessions" => 1}
        solver_task = task
        if kind == "direct"
          workspace_repository = File.join(root, kind, "repository")
          FileUtils.mkdir_p(workspace_repository)
          FileUtils.cp_r(File.join(repository, "."), workspace_repository)
          solver_task = AgentRuntime::Benchmarks::FixtureAdapter.new(store: store).load_task("one")
        end
        result = solver.solve(task: solver_task, model: "configured", budget: budget.merge("budget_policy" => policy), workspace: File.join(root, kind))
        assert_equal "success", result.fetch("status"), result.inspect
        assert_nil result["model"]
        summary = AgentRuntime::Execution::Summary.from_run(store: store, run_id: result.fetch("execution").fetch("run_id"))
        assert_equal roles.size, summary.fetch("invocation_count")
        assert_equal roles.sort, summary.fetch("steps").keys.sort
        assert_equal 5 * roles.size, summary.dig("usage", "tokens", "input", "known_subtotal")
        assert File.file?(File.join(result.fetch("repository"), "answer.json"))
        grader = AgentRuntime::Benchmarks::FixtureAdapter.new(store: store)
        submission = store.put(type: "repository", value: result.fetch("repository"), run_id: "grade-#{kind}", step_id: "submission", attempt: 1)
        grading_request = grader.prepare_grading_request(task: grader.load_task("one"), submission: submission, limits: {"timeout" => 3})
        verdict = grader.grade_submission(grading_request)
        assert_equal "success", verdict.fetch("status")
        assert_equal 1.0, verdict.fetch("score")
        assert_equal submission.fetch("digest"), verdict.fetch("evidence").fetch("submission_digest")
      end
    end
  end
end
