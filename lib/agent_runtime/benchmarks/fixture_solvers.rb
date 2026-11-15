require_relative "adapter"

module AgentRuntime
  module Benchmarks
    module FixtureSolvers
      CATEGORIES = %w[direct single-agent fixed-workflow compositional-dsl].freeze

      def self.build(id, store: nil)
        raise ArgumentError, "unknown fixture solver #{id}" unless CATEGORIES.include?(id)
        Solver.new(id, store: store)
      end

      class Solver
        def initialize(category, store: nil)
          @category = category
          @store = store
        end

        def bind_store(store)
          raise Error, "fixture execution Store mismatch" if @store && @store.root != store.root
          @store = store
        end

        def configuration
          {"category" => @category, "provenance" => "fixture", "live" => false}
        end

        def solve(task:, model:, budget:, workspace:)
          Adapter.public_task(task)
          repository = File.join(File.expand_path(workspace), "repository")
          FileUtils.mkdir_p(repository)
          score = {"zero" => 0, "half" => 0.5}.fetch(task.fetch("id"), 1)
          steps = case @category
          when "direct" then ["write"]
          when "single-agent" then %w[observe write review]
          else %w[plan write verify]
          end
          runtime_run_id = nil
          if budget.key?("model_profile") || @category == "compositional-dsl"
            raise Error, "strict fixture requires shared Store" if budget.key?("model_profile") && !@store
            runtime_run_id = compose(workspace, steps, shared: budget.key?("model_profile"))
          else
            steps.each do |step|
              request = Request.new(config: {"values" => {"value" => step}}, inputs: {}, workspace: workspace, timeout: budget.fetch("timeout", 10))
              result = AgentRuntime::Adapters::Fake.new.execute(request)
              raise Error, "fixture step failed" unless result.status == "success"
            end
          end
          File.write(File.join(repository, "answer.json"), JSON.generate("score" => score))
          result = {"status" => "success", "repository" => repository, "model" => model,
                    "usage" => nil, "cost" => nil, "steps" => steps, "provenance" => "fixture"}
          result["runtime_run_id"] = runtime_run_id if runtime_run_id
          result["execution"] = {"schema_version" => 1, "run_id" => runtime_run_id} if budget.key?("model_profile")
          result
        end

        private

        def compose(workspace, steps, shared: false)
          program = File.join(workspace, "fixture_program.rb")
          declarations = steps.each_with_index.map do |step, index|
            previous = (index == 0) ? "seed" : "#{steps[index - 1]}.value"
            needs = (index == 0) ? [] : [steps[index - 1]]
            "step :#{step}, with: :fixture, inputs: {value: #{previous.inspect}}, outputs: {value: :text}, needs: #{needs.inspect}, config: {values: {value: #{step.inspect}}}\n"
          end.join
          File.write(program, "program :fixture_composition do\ninput :seed, type: :text\nexecutor :fixture, via: :fake\n#{declarations}emit :result, from: #{"#{steps.last}.value".inspect}\nend\n")
          store = shared ? @store : Store.new(File.join(workspace, "runtime_store"))
          executors = {}
          if shared
            adapter = AgentRuntime::Adapters::Fake.new
            adapter.define_singleton_method(:execute) do |request|
              result = super(request)
              event = {"type" => "step_finish", "sessionID" => request.run_id, "part" => {"id" => "part-#{request.step_id}", "messageID" => request.step_id, "sessionID" => request.run_id, "type" => "step-finish", "reason" => "stop",
                                                                                          "tokens" => {"input" => 10, "output" => 3, "reasoning" => 2, "cache" => {"read" => 4, "write" => 1}}}}
              result.logs = {"execution" => {"schema_version" => "m12a-execution-v1", "attempt_id" => "#{request.step_id}:#{request.attempt}",
                                             "launch_observed" => true, "admission" => {"allowed" => true}, "process" => {"status" => "success", "stdout" => JSON.generate(event), "stderr" => "", "exit_code" => 0}}}
              result
            end
            executors[:fake] = adapter
          end
          report = Runtime.new(store: store, executors: executors).run(AgentRuntime.compile(program), inputs: {"seed" => "fixture"}, workspace: File.join(workspace, "runtime"))
          raise Error, "fixture composition failed" unless report["status"] == "success"
          report.fetch("run_id")
        end
      end
    end
  end
end
