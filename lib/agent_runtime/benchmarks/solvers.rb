require "fileutils"
require "securerandom"
require "open3"
require_relative "../adapters/opencode_cli"

module AgentRuntime
  module Benchmarks
    module Solvers
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
        def initialize(live: false, adapter: nil)
          @live = live
          @adapter = adapter
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
        def initialize(program:, store:, live: false)
          @program, @store, @live = program, store, live
        end

        def configuration
          {"live" => @live, "program_digest" => Digest::SHA256.file(@program).hexdigest}
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
          end
          ir.fetch("steps").each do |step|
            step["timeout"] = [step.fetch("timeout"), budget.fetch("timeout", 120)].min
            next unless executors.fetch(step.fetch("executor"))["adapter"] == "opencode"
            step["config"] ||= {}
            step["config"]["live"] = @live
            step["config"]["model"] = model if model
          end
          report = Runtime.new(store: @store).run(ir, inputs: {"repository" => task.repository}, workspace: workspace)
          artifact = report.fetch("outputs", {})["repository"]
          observed_models = report.fetch("steps", {}).values.flat_map { |step| step.fetch("attempts", []).map { |attempt| attempt["model"] } }.compact.uniq
          {"status" => report.fetch("status"), "repository" => artifact && @store.value(artifact),
           "model" => ((observed_models.size == 1) ? observed_models.first : nil), "observed_models" => observed_models, "requested_model" => model, "runtime_run_id" => report["run_id"],
           "ir_digest" => report["ir_digest"], "usage" => nil, "cost" => nil}
        end
      end
    end
  end
end
