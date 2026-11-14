require_relative "adapter"

module AgentRuntime
  module Benchmarks
    module FixtureSolvers
      CATEGORIES = %w[direct single-agent fixed-workflow compositional-dsl].freeze

      def self.build(id)
        raise ArgumentError, "unknown fixture solver #{id}" unless CATEGORIES.include?(id)
        Solver.new(id)
      end

      class Solver
        def initialize(category)
          @category = category
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
          if @category == "compositional-dsl"
            runtime_run_id = compose(workspace, steps)
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
          result
        end

        private

        def compose(workspace, steps)
          program = File.join(workspace, "fixture_program.rb")
          declarations = steps.each_with_index.map do |step, index|
            previous = (index == 0) ? "seed" : "#{steps[index - 1]}.value"
            needs = (index == 0) ? [] : [steps[index - 1]]
            "step :#{step}, with: :fixture, inputs: {value: #{previous.inspect}}, outputs: {value: :text}, needs: #{needs.inspect}, config: {values: {value: #{step.inspect}}}\n"
          end.join
          File.write(program, "program :fixture_composition do\ninput :seed, type: :text\nexecutor :fixture, via: :fake\n#{declarations}emit :result, from: #{"#{steps.last}.value".inspect}\nend\n")
          store = Store.new(File.join(workspace, "runtime_store"))
          report = Runtime.new(store: store).run(AgentRuntime.compile(program), inputs: {"seed" => "fixture"}, workspace: File.join(workspace, "runtime"))
          raise Error, "fixture composition failed" unless report["status"] == "success"
          report.fetch("run_id")
        end
      end
    end
  end
end
