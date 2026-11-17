require "securerandom"
require "time"
require "fileutils"
require "open3"
require_relative "experiment_manifest"
require_relative "submission"
require_relative "fixture_adapter"
require_relative "fixture_solvers"
require_relative "repository_solver"
require_relative "solvers"
require_relative "adapters/nl2repo"
require_relative "../execution/summary"
require_relative "../execution/live_authorization"

module AgentRuntime
  module Benchmarks
    class ExperimentRunner
      def initialize(store:, root:, registry:, solvers:)
        @store, @root, @registry, @solvers = store, File.expand_path(root), registry, solvers
        @submissions = Submission.new(store: store)
      end

      def run(manifest:, cancellation: nil, live_authorization: nil, execution_id: nil)
        manifest = ExperimentManifest.new(manifest) unless manifest.is_a?(ExperimentManifest)
        definition_digest = manifest.digest
        definition_id = manifest.data.fetch("experiment_id")
        if execution_id
          manifest = ExperimentManifest.new(manifest.data.merge("experiment_id" => execution_id))
        end
        config = manifest.data
        adapter = @registry.fetch(config.fetch("benchmark").fetch("name"))
        if config["execution_mode"] == "live"
          validate_live!(manifest, adapter, live_authorization)
        else
          validate_offline!(config, adapter)
        end
        validate_identity!(config, adapter)
        existing = begin
          @store.report(config.fetch("experiment_id"))
        rescue AgentRuntime::Error => error
          raise unless error.message == "unknown run #{config.fetch("experiment_id")}"
          nil
        end
        raise ArgumentError, "experiment already exists" if existing
        report = {"run_id" => config.fetch("experiment_id"), "kind" => "experiment", "manifest" => config,
                  "definition_id" => definition_id, "definition_digest" => definition_digest,
                  "manifest_digest" => manifest.digest, "effective_parallelism" => 1,
                  "qualification" => qualification(adapter),
                  "provenance" => provenance(adapter),
                  "solver_configurations" => config.fetch("solver_ids").to_h { |id| [id, JSON.parse(JSON.generate(@solvers.fetch(id).configuration))] },
                  "cells" => JSON.parse(JSON.generate(ordered_cells(manifest)))}
        report.fetch("cells").each do |cell|
          cell["model"] ||= cell["model_id"]
          cell["execution_status"] = "not_started"
          cell["score"] = cell["verdict"] = cell["usage"] = cell["cost"] = nil
          cell["transitions"] = [{"status" => "not_started"}]
        end
        report.merge!(execution_metadata(manifest, report.fetch("cells")))
        @store.save_report(report)
        tracing = @store.tracing
        experiment_trace = tracing&.start("experiment", attributes: {"experiment_id" => report["run_id"], "manifest_digest" => report["manifest_digest"], "planned_cells" => report["cells"].map { |cell| cell["id"] }})
        report.fetch("cells").each do |cell|
          if cancellation&.cancelled?
            cell["status"] = cell["execution_status"] = "cancelled"
            cell["transitions"] << {"status" => "cancelled", "timestamp" => Time.now.utc.iso8601(6)}
            @store.save_report(report)
            next
          end
          if tracing
            attrs = {"experiment_id" => report["run_id"], "cell_id" => cell["id"], "architecture" => cell["solver_id"], "repetition" => cell["repetition"], "configured_model" => cell["model_id"]}
            cell_trace = tracing.start("cell", parent: experiment_trace, attributes: attrs)
            tracing.within(cell_trace, attrs) { execute_cell(report, cell, adapter) }
            tracing.finish(cell_trace, cell["execution_status"], {"submission" => cell["submission"], "partial_submission" => cell["partial_submission"], "grading_attempts" => cell["grading_attempts"], "score" => cell["score"], "verdict" => cell["verdict"], "error" => cell["error"]})
          else
            execute_cell(report, cell, adapter)
          end
        end
        tracing&.finish(experiment_trace, "completed", {"actual_cells" => report["cells"].map { |cell| cell["id"] }})
        @store.report(report.fetch("run_id"))
      end

      def regrade(experiment_id:, cell_id:, limits: nil)
        report = @store.report(experiment_id)
        cell = report.fetch("cells").find { |entry| entry.fetch("id") == cell_id }
        raise ArgumentError, "unknown experiment cell #{cell_id}" unless cell
        raise ArgumentError, "cell has no submission" unless cell["submission"]
        adapter = @registry.fetch(report.fetch("manifest").fetch("benchmark").fetch("name"))
        if report.dig("manifest", "execution_mode") == "live"
          raise ArgumentError, "live regrade requires audited-v2" unless adapter.instance_of?(Adapters::NL2Repo) && adapter.audited_scoring?
        else
          validate_offline!(report.fetch("manifest"), adapter)
        end
        validate_identity!(report.fetch("manifest"), adapter)
        task = Adapter.public_task(adapter.load_task(cell.fetch("task_id")))
        if (tracing = @store.tracing)
          cell_trace = tracing.trace.entities("kind" => "cell", "experiment_id" => experiment_id, "cell_id" => cell_id).last
          if cell_trace
            tracing.within(nil, cell_trace.fetch("attributes").merge("linked_cell_trace" => cell_trace.fetch("id"))) { grade(report, cell, adapter, task, limits || report.fetch("manifest").fetch("limits"), regrade: true) }
          else
            grade(report, cell, adapter, task, limits || report.fetch("manifest").fetch("limits"), regrade: true)
          end
        else
          grade(report, cell, adapter, task, limits || report.fetch("manifest").fetch("limits"), regrade: true)
        end
        @store.report(experiment_id)
      end

      private

      def ordered_cells(manifest)
        manifest.cells
      end

      def execution_metadata(manifest, cells)
        {}
      end

      def validate_live!(manifest, adapter, authorization)
        raise ArgumentError, "live authorization required" unless authorization.instance_of?(Execution::LiveAuthorization)
        config = manifest.data
        raise ArgumentError, "live pilot requires audited-v2" unless adapter.instance_of?(Adapters::NL2Repo) && adapter.audited_scoring?
        model = config.fetch("models").first
        profile = model.fetch("model_profile")
        solver_id = config.fetch("solver_ids").first
        solver = @solvers.fetch(solver_id)
        expected_class = {"single-agent" => Solvers::OpenCode, "fixed-workflow" => Solvers::FixedWorkflow, "dsl" => Solvers::ComparativeDSL}.fetch(solver_id)
        raise ArgumentError, "live pilot requires authorized OpenCode solver" unless solver.instance_of?(expected_class) && solver.respond_to?(:live_authorized?) && solver.live_authorized?(authorization)
        scope = {"experiment_digest" => manifest.digest, "task" => "retrying", "solver" => solver_id,
                 "provider" => profile.fetch("provider"), "model" => profile.fetch("model"),
                 "endpoint" => profile.fetch("tool_policy").fetch("endpoint"),
                 "route" => profile.fetch("tool_policy").fetch("route"), "mode" => "live"}
        authorization.preflight!(scope: scope)
      end

      def validate_offline!(config, adapter)
        raise ArgumentError, "only offline execution is supported" unless config["execution_mode"] == "offline"
        # Concrete built-ins, not self-asserted user metadata, authorize execution.
        if adapter.instance_of?(FixtureAdapter)
          raise ArgumentError, "offline experiments require built-in fixture solvers" unless config.fetch("solver_ids").all? { |id| FixtureSolvers::CATEGORIES.include?(id) && @solvers[id].instance_of?(FixtureSolvers::Solver) }
        elsif adapter.instance_of?(Adapters::NL2Repo)
          raise ArgumentError, "NL2Repo offline experiments require repository submission or registered pinned fixture execution" unless config.fetch("solver_ids").all? do |id|
            solver = @solvers[id]
            (id == "repository-submission" && solver.instance_of?(RepositorySolver)) ||
              (solver.instance_of?(Solvers::OpenCode) && solver.offline_fixture? &&
                config.fetch("models").all? { |model| model.dig("model_profile", "execution_kind") == "offline_fixture" })
          end
        else
          raise ArgumentError, "offline experiments require the built-in fixture adapter or NL2Repo adapter"
        end
        raise ArgumentError, "offline experiments require fixture model profiles" unless config.fetch("models").all? { |model| %w[fixture fixture-model].include?(model.fetch("id")) && (!model.key?("provider") || model["provider"] == "fixture") }
      end

      def qualification(adapter)
        adapter.instance_of?(Adapters::NL2Repo) ? "provisional official-benchmark integration" : "infrastructure-only demonstration"
      end

      def provenance(adapter)
        commit, status = Open3.capture2("git", "-C", File.expand_path("../../..", __dir__), "rev-parse", "HEAD", err: File::NULL)
        {"runtime_version" => AgentRuntime::VERSION, "runtime_commit" => status.success? ? commit.strip : nil,
         "ruby_version" => RUBY_VERSION, "ruby_platform" => RUBY_PLATFORM, "ir_schema_version" => 1,
         "adapter_identity" => JSON.parse(JSON.generate(adapter.identity))}
      end

      def validate_identity!(config, adapter)
        expected = config.fetch("benchmark")
        identity = adapter.identity
        raise ArgumentError, "benchmark revision mismatch" unless identity["name"] == expected["name"] && identity["revision"] == expected["revision"]
      end

      def transition(report, cell, status, execution_status: nil)
        cell["status"] = status
        cell["execution_status"] = execution_status if execution_status
        cell.fetch("transitions") << {"status" => status, "execution_status" => cell["execution_status"], "at" => Time.now.utc.iso8601(6)}
        @store.save_report(report)
      end

      def execute_cell(report, cell, adapter)
        task = Adapter.public_task(adapter.load_task(cell.fetch("task_id")))
        ready = ["available", true, "runnable"].include?(task["availability"]) || (task["availability"] == "verified" && task["instruction"].is_a?(String))
        unless ready
          cell["error"] = task["unavailable_reason"] || "task unavailable"
          transition(report, cell, "skipped", execution_status: "unavailable")
          return
        end
        attempt_id = SecureRandom.uuid
        cell["attempt_id"] = attempt_id
        workspace = File.join(@root, attempt_id)
        FileUtils.mkdir_p(File.dirname(workspace))
        transition(report, cell, "solving")
        adapter.prepare_solver_workspace(task: task, workspace: workspace)
        config = report.fetch("manifest")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          budget = JSON.parse(JSON.generate(config.fetch("limits")))
          budget["experiment_id"] = report.fetch("run_id")
          if config.fetch("execution_mode") == "live"
            budget["budget_policy"] = {"wall_seconds" => budget.fetch("timeout"), "max_attempts" => nil, "max_concurrent_sessions" => 1}
          end
          model_entry = config.fetch("models").find { |entry| entry.fetch("id") == cell.fetch("model_id") }
          budget["model_profile"] = model_entry.fetch("model_profile") if model_entry&.key?("model_profile")
          solver = @solvers.fetch(cell.fetch("solver_id"))
          solver.bind_store(@store) if solver.respond_to?(:bind_store)
          result = solver.solve(task: task, model: cell["model"], budget: budget, workspace: workspace)
        ensure
          cell["agent_duration"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
        cell["solver_status"] = result["status"]
        cell["usage"], cell["cost"] = result["usage"], result["cost"]
        cell["actual_model"] = result["model"]
        if result["execution"]
          cell["execution"] = Execution::Summary.from_run(store: @store, run_id: result.fetch("execution").fetch("run_id"))
          cell["usage"], cell["cost"] = cell["execution"].values_at("usage", "cost")
        end
        unless result["status"] == "success"
          cell["error"] = result["error"]
          if result["repository"]
            begin
              cell["partial_submission"] = if result["partial_repository_artifact"]
                artifact = @submissions.verify(result.fetch("partial_repository_artifact"))
                raise Error, "partial repository artifact path mismatch" unless @store.value(artifact) == result.fetch("repository")
                artifact
              else
                @submissions.capture(repository: result.fetch("repository"), run_id: report.fetch("run_id"), step_id: cell.fetch("id"), attempt: 1)
              end
            rescue => error
              cell["partial_capture_error"] = "#{error.class}: #{error.message}"
            end
          end
          status = %w[timeout cancelled].include?(result["status"]) ? result["status"] : "error"
          transition(report, cell, "completed", execution_status: status)
          return
        end
        cell["submission"] = @submissions.capture(repository: result.fetch("repository"), run_id: report.fetch("run_id"), step_id: cell.fetch("id"), attempt: 1)
        transition(report, cell, "submitted")
        grade(report, cell, adapter, task, config.fetch("limits"))
      rescue => error
        cell["score"] = cell["verdict"] = nil
        cell["error"] = "#{error.class}: #{error.message}"
        transition(report, cell, "completed", execution_status: "error")
      end

      def grade(report, cell, adapter, task, limits, regrade: false)
        evidence_keys = %w[protocol quality_basis trust_scope reason failure_category expected collected executed passed failed skipped total]
        active_keys = %w[score verdict error execution_status status grading_duration] + evidence_keys
        previous = active_keys.to_h { |key| [key, cell[key]] } if regrade
        original_attempt = cell.fetch("grading_attempts", []).find { |entry| entry["request"] }
        original_request = original_attempt&.fetch("request")
        unless regrade
          cell["score"] = cell["verdict"] = nil
          evidence_keys.each { |key| cell[key] = nil }
          cell["error"] = nil
        end
        attempt = {"attempt_id" => SecureRandom.uuid, "execution_status" => "not_started"}
        grading_trace = @store.tracing&.start("grading", attributes: {"grading_attempt_id" => attempt["attempt_id"], "regrade" => regrade, "submission" => cell["submission"]})
        (cell["grading_attempts"] ||= []) << attempt
        transition(report, cell, "grading")
        raise Error, "missing original grading request" if regrade && !original_request
        attempt["implementation_fingerprint"] = implementation_fingerprint(adapter)
        submission = @submissions.verify(cell.fetch("submission"))
        request = adapter.prepare_grading_request(task: task, submission: submission, limits: JSON.parse(JSON.generate(limits)))
        attempt["request"] = request
        if regrade && original_request
          bindings = %w[task_id benchmark specification_digest submission_id submission_digest procedure_digest environment_digest limits]
          changed = bindings.select { |key| original_request[key] != request[key] }
          raise Error, "regrade contract drift: #{changed.join(", ")}" unless changed.empty?
        end
        if regrade && original_attempt["implementation_fingerprint"] != attempt["implementation_fingerprint"]
          raise Error, "implementation fingerprint drift"
        end
        @store.save_report(report)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          raw = adapter.grade_submission(request)
        ensure
          attempt["duration"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          cell["grading_duration"] = cell.fetch("grading_attempts").sum { |entry| entry.fetch("duration", 0) }
        end
        attempt["raw"] = raw
        normalized = raw.dup
        normalized["evaluator_execution_status"] = raw["execution_status"] if raw.key?("execution_status")
        status = raw["execution_status"] || raw.fetch("status")
        # Successful evaluator execution is not an available evaluation verdict.
        status = raw["status"] if %w[unavailable error timeout cancelled].include?(raw["status"])
        status = "error" unless %w[success timeout cancelled unavailable error].include?(status)
        normalized["execution_status"] = status
        normalized["score"] = (status == "success") ? adapter.normalize_score(raw.fetch("score")) : nil
        score = normalized["score"]
        if status == "success" && !(score.is_a?(Numeric) && score.finite? && score.between?(0, 1))
          raise Error, "successful grading requires a finite score in [0,1]"
        end
        if status == "success" && (normalized.key?("passed") || normalized.key?("total"))
          passed, total = normalized.values_at("passed", "total")
          unless passed.is_a?(Integer) && total.is_a?(Integer) && total.positive? && passed.between?(0, total) && (passed.fdiv(total) - score).abs < 1e-12
            raise Error, "grading counts must have a positive consistent denominator"
          end
        end
        attempt["result"] = normalized
        attempt["execution_status"] = status
        repeated_unavailable = status == "unavailable" && previous && previous["execution_status"] == "unavailable"
        raise Error, "regrade failed: #{normalized["error"] || status}" if regrade && status != "success" && !repeated_unavailable
        (%w[verdict error] + evidence_keys).each { |key| cell[key] = normalized[key] }
        cell["score"] = (status == "success") ? score : nil
        cell["verdict"] = nil unless status == "success"
        transition(report, cell, "completed", execution_status: status)
        @store.tracing&.finish(grading_trace, status, {"request" => request, "result" => normalized, "implementation_fingerprint" => attempt["implementation_fingerprint"]})
      rescue => error
        @store.tracing&.finish(grading_trace, "failure", {"error" => error.message}) if grading_trace
        attempt["execution_status"] = "error" if attempt
        attempt["error"] = "#{error.class}: #{error.message}" if attempt
        cell["error"] = "#{error.class}: #{error.message}"
        if regrade && previous
          previous.each { |key, value| cell[key] = value }
          cell.fetch("transitions") << {"status" => "regrade_failed", "attempt_id" => attempt["attempt_id"], "at" => Time.now.utc.iso8601(6)}
          @store.save_report(report)
        else
          transition(report, cell, "completed", execution_status: "error")
        end
      end

      # Bounded fixture provenance only: file contents and Ruby method bindings,
      # not a complete transitive dependency or host-environment attestation.
      def implementation_fingerprint(adapter)
        methods = %i[grade_submission normalize_score].to_h do |name|
          method = adapter.method(name)
          location = method.source_location
          raise Error, "grading implementation has no inspectable source" unless location && File.file?(location.first)
          [name.to_s, {"owner" => method.owner.to_s, "source_file" => File.expand_path(location.first), "source_line" => location.last}]
        end
        adapter_files = adapter.class.ancestors.select { |ancestor| ancestor.is_a?(Class) && ancestor <= Adapter }.flat_map do |ancestor|
          (ancestor.instance_methods(false) + ancestor.private_instance_methods(false)).filter_map do |name|
            ancestor.instance_method(name).source_location&.first
          end
        end
        files = (methods.values.map { |binding| binding.fetch("source_file") } + adapter_files +
          [__FILE__, File.join(__dir__, "adapter.rb"), File.join(__dir__, "submission.rb"), File.expand_path("../store.rb", __dir__), File.expand_path("../ir.rb", __dir__)]).map { |path| File.expand_path(path) }.uniq.sort
        {"scope" => "Limited Ruby fixture source fingerprint; not full environment or transitive dependency proof.",
         "adapter_class" => adapter.class.name, "adapter_identity" => adapter.identity, "runtime_version" => AgentRuntime::VERSION, "ruby_version" => RUBY_VERSION,
         "methods" => methods, "files" => files.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }}
      end
    end
  end
end
