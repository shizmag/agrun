require "fileutils"
require "securerandom"
require "open3"
require_relative "../adapters/opencode_cli"
require_relative "../execution/summary"

module AgentRuntime
  module Benchmarks
    module Solvers
      def self.budget_policy(budget)
        budget.fetch("budget_policy") do
          {"wall_seconds" => budget.fetch("timeout", 120), "max_attempts" => 1, "max_concurrent_sessions" => 1}
        end
      end
      GOOD_IMPLEMENTATION = <<~RUBY.freeze
        module Clamp
          def self.call(value, minimum, maximum)
            raise ArgumentError, "inverted bounds" if minimum > maximum
            [[value, minimum].max, maximum].min
          end
        end
      RUBY

      # Contract-test solvers, not performance baselines or model substitutes.
      class Fake
        def initialize(good: true)
          @good = good
        end

        def configuration
          {"good" => @good}
        end

        def solve(task:, model:, budget:, workspace:)
          repository = File.join(workspace, "repository")
          FileUtils.mkdir_p(repository)
          FileUtils.cp_r(File.join(task.repository, "."), repository)
          File.write(File.join(repository, "lib/clamp.rb"), GOOD_IMPLEMENTATION) if @good
          patch, = Open3.capture2("git", "-C", repository, "diff", "--", ".")
          {"status" => "success", "repository" => repository, "patch" => patch,
           "model" => "fake", "requested_model" => model, "usage" => nil, "cost" => nil}
        end
      end

      class OpenCode
        def offline_fixture?
          @adapter.instance_of?(AgentRuntime::Adapters::OpenCodeCLI) && @adapter.respond_to?(:offline_fixture?) && @adapter.offline_fixture?
        end

        def initialize(live: false, adapter: nil, store: nil)
          @live = live
          @adapter = adapter
          @store = store
        end

        def bind_store(store)
          raise Error, "OpenCode execution Store mismatch" if @store && @store.root != store.root
          @store = store
        end

        def configuration
          {"live" => @live, "adapter" => @adapter ? @adapter.class.name : Adapters::OpenCodeCLI.name}
        end

        def solve(task:, model:, budget:, workspace:)
          return {"status" => "blocked", "error" => "OpenCode requires explicit --live"} unless @live

          repository = File.join(workspace, "repository")
          FileUtils.mkdir_p(repository)
          FileUtils.cp_r(File.join(task.repository, "."), repository)
          adapter = @adapter || Adapters::OpenCodeCLI.new
          if budget.key?("model_profile")
            raise Error, "strict OpenCode solver requires shared Store" unless @store
            config = {"live" => true, "model_profile" => budget.fetch("model_profile"), "prompt" => task.instruction, "budget" => budget, "budget_policy" => Solvers.budget_policy(budget)}
            ir = {"schema_version" => 1, "name" => "direct-opencode", "inputs" => {"repository" => "repository"},
                  "executors" => {"opencode" => {"adapter" => "opencode", "config" => config}},
                  "steps" => [{"id" => "solve", "executor" => "opencode", "inputs" => {"repository" => "repository"}, "outputs" => {"repository" => "repository"},
                               "needs" => [], "config" => {}, "timeout" => budget.fetch("timeout", 120), "retries" => 0}], "outputs" => {"repository" => "solve.repository"}}
            report = Runtime.new(store: @store, executors: {opencode: adapter}).run(ir, inputs: {"repository" => repository}, workspace: File.join(workspace, "runtime"))
            output = report.fetch("outputs")["repository"]
            summary = Execution::Summary.from_run(store: @store, run_id: report.fetch("run_id"))
            return {"status" => report.fetch("status"), "repository" => output && @store.value(output),
                    "requested_model" => model, "model" => nil,
                    "execution" => {"schema_version" => 1, "run_id" => report.fetch("run_id")}, "usage" => summary["usage"], "cost" => summary["cost"]}
          end
          request = Request.new(run_id: SecureRandom.uuid, step_id: "solve", attempt: 1,
            inputs: {"repository" => repository}, config: {"live" => true, "model" => model,
                                                           "prompt" => task.instruction, "budget" => budget}, workspace: repository,
            timeout: budget.fetch("timeout", 120), cancellation: nil)
          result = adapter.execute(request)
          outputs = result.outputs || {}
          {"status" => result.status, "repository" => outputs["repository"] || repository,
           "patch" => outputs["patch"], "usage" => result.usage, "cost" => result.cost,
           "model" => result.model, "requested_model" => model, "error" => result.error}
        end
      end

      class DSL
        def offline_fixture?
          !@executors.empty? && @executors.values.all? do |adapter|
            adapter.instance_of?(AgentRuntime::Adapters::OpenCodeCLI) && adapter.respond_to?(:offline_fixture?) && adapter.offline_fixture?
          end
        end

        def initialize(program:, store:, live: false, executors: {})
          @program, @store, @live = program, store, live
          @executors = executors.dup.freeze
        end

        def configuration
          config = {"live" => @live, "program_digest" => Digest::SHA256.file(@program).hexdigest}
          config["executors"] = @executors.to_h { |name, adapter| [name.to_s, adapter.class.name] } unless @executors.empty?
          config
        end

        def bind_store(store)
          raise Error, "DSL execution Store mismatch" unless @store.root == store.root
        end

        def solve(task:, model:, budget:, workspace:)
          ir = AgentRuntime.compile(@program)
          # Runtime adapters enforce live gating too. Never silently enable live
          # calls merely because the benchmark selected a DSL program.
          executors = ir.fetch("executors", {})
          entries = executors.is_a?(Hash) ? executors.values : executors
          entries.each do |entry|
            next unless entry["adapter"].to_s == "opencode"
            unless @live
              return {"status" => "blocked", "error" => "OpenCode DSL executors require explicit --live"}
            end
            entry["config"] ||= {}
            entry["config"]["live"] = @live
            entry["config"]["model"] = model if model
            entry["config"]["model_profile"] = budget["model_profile"] if budget.key?("model_profile")
            entry["config"]["budget_policy"] = Solvers.budget_policy(budget) if budget.key?("model_profile")
          end
          ir.fetch("steps").each do |step|
            step["timeout"] = [step.fetch("timeout"), budget.fetch("timeout", 120)].min
            next unless executors.fetch(step.fetch("executor"))["adapter"] == "opencode"
            step["config"] ||= {}
            step["config"]["live"] = @live
            step["config"]["model"] = model if model
            step["config"]["model_profile"] = budget["model_profile"] if budget.key?("model_profile")
          end
          report = Runtime.new(store: @store, executors: @executors).run(ir, inputs: {"repository" => task.repository}, workspace: workspace)
          artifact = report.fetch("outputs", {})["repository"]
          observed_models = report.fetch("steps", {}).values.flat_map { |step| step.fetch("attempts", []).map { |attempt| attempt["model"] } }.compact.uniq
          result = {"status" => report.fetch("status"), "repository" => artifact && @store.value(artifact),
                    "model" => ((observed_models.size == 1) ? observed_models.first : nil), "observed_models" => observed_models, "requested_model" => model, "runtime_run_id" => report["run_id"],
                    "ir_digest" => report["ir_digest"], "usage" => nil, "cost" => nil}
          if budget.key?("model_profile")
            summary = Execution::Summary.from_run(store: @store, run_id: report.fetch("run_id"))
            result["execution"] = {"schema_version" => 1, "run_id" => report.fetch("run_id")}
            result["usage"], result["cost"] = summary.values_at("usage", "cost")
          end
          result
        end
      end
    end
  end
end
