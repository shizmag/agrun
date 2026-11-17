module AgentRuntime
  module Benchmarks
    module Solvers
      class FixedWorkflow < DSL
        def self.program
          roles = %w[planner coder reviewer]
          {"schema_version" => 1, "name" => "fixed-workflow", "inputs" => {"repository" => "repository"},
           "executors" => {"agent" => {"adapter" => "opencode", "config" => {}}},
           "steps" => roles.each_with_index.map { |role, index|
             {"id" => role, "executor" => "agent", "needs" => index.zero? ? [] : [roles[index - 1]],
              "inputs" => {"repository" => index.zero? ? "repository" : "#{roles[index - 1]}.repository"},
              "outputs" => {"repository" => "repository"}, "config" => {"role" => role},
              "retries" => 0, "timeout" => 120}
           }, "outputs" => {"repository" => "reviewer.repository"}}
        end

        def initialize(store:, adapter:, live: false)
          super(program: __FILE__, store: store, live: live, executors: {"opencode" => adapter})
        end

        def compiled_program = self.class.program

        def configuration
          super.merge("strategy" => self.class.program.fetch("name"))
        end

        def solve(task:, model:, budget:, workspace:)
          return {"status" => "blocked", "error" => "DSL requires explicit --live"} unless @live
          raise Error, "workflow requires shared Store" unless @store
          run_id = SecureRandom.uuid
          adapter = RoleAdapter.new(@executors.fetch("opencode"), Solvers.task_instruction(task), budget.fetch("timeout", 120))
          artifact = @store.put(type: "repository", value: Solvers.task_repository(task, workspace), run_id: run_id, step_id: "input", attempt: 0)
          report = {"run_id" => run_id, "status" => "running", "started_at" => Time.now.utc.iso8601(6), "steps" => {}, "outputs" => {}}
          @store.save_report(report)
          tracing = @store.tracing
          architecture_trace = tracing&.start("architecture", attributes: {"run_id" => run_id, "architecture" => "fixed-workflow", "planned_steps" => %w[planner coder reviewer]})
          %w[planner coder reviewer].each do |role|
            directory = File.join(workspace, "workflow", role)
            repository = File.join(directory, "repository")
            Store.materialize(Store.manifest(@store.value(artifact)), repository)
            config = {"live" => true, "role" => role, "model" => model, "budget" => budget,
                      "budget_policy" => Solvers.budget_policy(budget), "preserve_partial_outputs" => true}
            config["model_profile"] = budget.fetch("model_profile") if budget.key?("model_profile")
            config["experiment_id"] = budget.fetch("experiment_id") if budget.key?("experiment_id")
            request = Request.new(run_id: run_id, step_id: role, attempt: 1, inputs: {"repository" => repository}, config: config,
              workspace: directory, timeout: budget.fetch("timeout", 120), cancellation: Cancellation.new)
            @store.save_attempt(run_id, role, 1, {"attempt" => 1, "status" => "running", "request" => {"config" => config, "inputs" => {"repository" => artifact}}})
            stage_trace = tracing&.start("stage", parent: architecture_trace, attributes: {"run_id" => run_id, "stage" => role, "input_contract" => {"repository" => "preceding.repository"}, "output_contract" => {"repository" => "repository"}})
            attempt_trace = tracing&.start("attempt", parent: stage_trace, attributes: {"run_id" => run_id, "stage" => role, "attempt" => 1})
            tracing&.handoff(parent: attempt_trace, inputs: {"repository" => artifact}, contract: {"repository" => "repository"}, direction: "input")
            tracing&.checkpoint(parent: attempt_trace, repository: repository, run_id: run_id, stage: role, attempt: 1, boundary: "before")
            request.config["trace_attempt_id"] = attempt_trace if attempt_trace
            begin
              result = Timeout.timeout(adapter.remaining + 1) { adapter.execute(request) }
            rescue Timeout::Error
              result = Result.new(status: "timeout", outputs: {"repository" => repository}, error: {"message" => "workflow deadline exhausted"})
            rescue => error
              result = Result.new(status: "failure", outputs: {"repository" => repository}, error: {"message" => error.message})
            end
            data = {"attempt" => 1, "status" => result.status, "error" => result.error, "duration" => result.duration,
                    "usage" => result.usage, "cost" => result.cost, "session_id" => result.session_id, "model" => result.model}
            if result.logs
              data["log"] = @store.put(type: "text", value: JSON.generate(result.logs), run_id: run_id, step_id: role, attempt: 1)
              data["execution"] = result.logs["execution"].except("events", "requests", "raw", "stdout", "stderr", "process", "frozen_config") if result.logs.is_a?(Hash) && result.logs["execution"].is_a?(Hash)
            end
            artifact = @store.put(type: "repository", value: result.outputs&.fetch("repository", nil) || repository, run_id: run_id, step_id: role, attempt: 1, inputs: [artifact.fetch("id")], metadata: {"partial" => result.status != "success"})
            outputs = {"repository" => artifact}
            if tracing
              tracing.execution(parent: attempt_trace, logs: result.logs, error: result.error)
              tracing.handoff(parent: attempt_trace, inputs: outputs, contract: {"repository" => "repository"}, direction: "output", validation: result.error)
              tracing.checkpoint(parent: attempt_trace, repository: @store.value(artifact), run_id: run_id, stage: role, attempt: 1, boundary: "after")
              tracing.finish(attempt_trace, result.status, data.slice("usage", "duration", "error"))
              tracing.finish(stage_trace, result.status)
            end
            data["partial_outputs"] = outputs unless result.status == "success"
            @store.save_attempt(run_id, role, 1, data)
            report["steps"][role] = {"status" => result.status, "attempts" => [data], "outputs" => (result.status == "success") ? outputs : {}}
            report["status"] = result.status
            @store.save_report(report)
            break unless result.status == "success"
          end
          report["outputs"] = {"repository" => artifact} if report["status"] == "success"
          report["finished_at"] = Time.now.utc.iso8601(6)
          tracing&.finish(architecture_trace, report["status"], {"actual_steps" => report["steps"].keys})
          @store.save_report(report)
          summary = Execution::Summary.from_run(store: @store, run_id: run_id)
          {"status" => report["status"], "repository" => @store.value(artifact), "partial_repository_artifact" => (artifact unless report["status"] == "success"),
           "error" => report.fetch("steps").values.flat_map { |step| step.fetch("attempts", []) }.rfind { |attempt| attempt["error"] }&.fetch("error"),
           "requested_model" => model, "model" => nil, "execution" => {"schema_version" => 1, "run_id" => run_id,
                                                                       "summary_digest" => summary["digest"], "status" => summary["status"], "execution_count" => summary["execution_count"], "requested_model" => model, "served_model" => nil}}
        end

        def solve_graph(task:, model:, budget:, workspace:)
          original = @executors
          @executors = {"opencode" => RoleAdapter.new(original.fetch("opencode"), Solvers.task_instruction(task), budget.fetch("timeout", 120))}
          DSL.instance_method(:solve).bind_call(self, task: task, model: model, budget: budget, workspace: workspace)
        ensure
          @executors = original if original
        end
      end

      class ComparativeDSL < FixedWorkflow
        def solve(**arguments) = solve_graph(**arguments)

        def compiled_program
          ir = super
          ir["steps"].each { |step| step["timeout"] = @workflow_timeout }
          ir
        end

        def solve_graph(task:, model:, budget:, workspace:)
          @workflow_timeout = budget.fetch("timeout", 120)
          super
        end

        def self.program
          AgentRuntime.compile(File.expand_path("../../../programs/comparative.rb", __dir__))
        end
      end

      class RoleAdapter
        def remaining = [@deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max

        def timeout_cleanup_grace = 1.0

        def initialize(adapter, instruction, timeout)
          @adapter, @instruction = adapter, instruction
          @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(timeout)
        end

        def execute(request, &block)
          remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return Result.new(status: "timeout", outputs: {}, error: "workflow deadline exhausted") unless remaining.positive?
          request.timeout = [request.timeout, remaining].min
          role = request.config.fetch("role")
          if %w[inventory validate].include?(role)
            repository = request.inputs.fetch("repository")
            manifest = Store.manifest(repository)
            evidence = {"kind" => role, "manifest" => manifest, "quality_verdict" => "not_evaluated",
                        "purpose" => "Repository structure and integrity validation, not benchmark grading"}
            outputs = {(role == "inventory") ? "inventory" : "validation" => JSON.generate(evidence)}
            outputs["repository"] = repository if role == "validate"
            return Result.new(status: "success", outputs: outputs,
              duration: 0.0, logs: {"validation" => evidence})
          end
          directions = {
            "planner" => "Plan the change. Do not implement it. Write a plan in your response and in WORKFLOW_PLAN.md.",
            "coder" => "Implement the task using the supplied plan or WORKFLOW_PLAN.md. Run relevant tests.",
            "reviewer" => "Independently verify the implementation against the task. Run relevant tests and inspect the diff. Do not modify the implementation. Report failures honestly."
          }
          handoffs = request.inputs.except("repository")
          request.config = request.config.merge("prompt" => [@instruction, directions.fetch(role), JSON.generate(handoffs)].join("\n\n"))
          reviewed_repository = request.inputs.fetch("repository")
          before_review = Store.manifest(reviewed_repository) if role == "reviewer"
          result = @adapter.execute(request, &block)
          result.outputs ||= {}
          result.outputs["plan"] = result.outputs.fetch("text", "") if role == "planner"
          result.outputs["implementation"] = result.outputs.fetch("text", "") if role == "coder"
          if role == "reviewer" && before_review != Store.manifest(reviewed_repository)
            result.status = "failure"
            result.error = {"type" => "reviewer_mutation", "message" => "independent reviewer modified the submitted repository"}
          end
          result
        end
      end
    end
  end
end
