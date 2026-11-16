require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../lib/agent_runtime/benchmarks/reports"
require_relative "../lib/agent_runtime/benchmarks/registry"

class ExperimentRunnerTest < Minitest::Test
  def test_execution_identity_does_not_change_definition_identity
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      first = runner.run(manifest: manifest, execution_id: "execution-one")
      second = runner.run(manifest: manifest, execution_id: "execution-two")
      assert_equal "execution-one", first.fetch("run_id")
      assert_equal "execution-two", second.fetch("run_id")
      assert_equal first.fetch("definition_digest"), second.fetch("definition_digest")
      assert_equal "fixture-experiment", first.fetch("definition_id")
      refute_equal first.fetch("cells").first.fetch("id"), second.fetch("cells").first.fetch("id")
    end
  end

  def test_fixture_matrix_and_regrade_use_persisted_submission
    in_tmp do |root|
      store, runner, manifest = setup_runner(root)
      result = runner.run(manifest: manifest)
      assert_equal 6, result.fetch("cells").size
      assert_equal [0.5, 0.5, 1.0, 1.0, nil, nil], result.fetch("cells").map { |row| row["score"] }
      assert_equal 6, result.fetch("cells").map { |row| row["attempt_id"] }.uniq.size
      assert_equal 1, result.fetch("effective_parallelism")
      assert_equal RUBY_VERSION, result.fetch("provenance").fetch("ruby_version")
      assert_equal "fixture", result.fetch("provenance").fetch("adapter_identity").fetch("name")
      assert_equal 1, result.fetch("provenance").fetch("ir_schema_version")
      cell = result.fetch("cells").first
      assert_equal "not_started", cell.fetch("transitions").first.fetch("status")
      assert_nil cell.fetch("usage")
      regraded = runner.regrade(experiment_id: "fixture-experiment", cell_id: cell.fetch("id"))
      current = regraded.fetch("cells").first
      assert_equal 2, current.fetch("grading_attempts").size
      assert_equal cell["submission"], current["submission"]
      assert_equal cell["attempt_id"], current["attempt_id"]
      assert_equal 2, current.fetch("grading_attempts").map { |attempt| attempt.fetch("attempt_id") }.uniq.size
      assert_equal result.fetch("manifest_digest"), store.report("fixture-experiment").fetch("manifest_digest")
    end
  end

  def test_cancellation_retains_all_initial_cells
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      cancellation = Object.new
      def cancellation.cancelled? = true
      result = runner.run(manifest: manifest, cancellation: cancellation)
      assert_equal 6, result.fetch("cells").size
      assert result.fetch("cells").all? { |cell| cell["execution_status"] == "not_started" }
    end
  end

  def test_initial_matrix_is_durable_before_first_solver_and_duplicate_run_rejected
    in_tmp do |root|
      store, runner, manifest = setup_runner(root)
      solver = runner.instance_variable_get(:@solvers).fetch("direct")
      original = solver.method(:solve)
      observed = nil
      solver.define_singleton_method(:solve) do |**arguments|
        observed ||= store.report("fixture-experiment")
        original.call(**arguments)
      end
      runner.run(manifest: manifest)
      assert_equal 6, observed.fetch("cells").size
      assert observed.fetch("cells").all? { |cell| cell["execution_status"] == "not_started" }
      assert observed.fetch("cells").drop(1).all? { |cell| cell["status"] == "not_started" }
      assert_raises(ArgumentError) { runner.run(manifest: manifest) }
    end
  end

  def test_offline_gate_rejects_custom_solver
    in_tmp do |root|
      store, _, manifest = setup_runner(root)
      registry = AgentRuntime::Benchmarks::Registry.new
      registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: root, registry: registry, solvers: {"direct" => Object.new})
      assert_raises(ArgumentError) { runner.run(manifest: manifest) }
    end
  end

  def test_regrade_contract_drift_keeps_active_success_and_records_failed_attempt
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      result = runner.run(manifest: manifest)
      original = result.fetch("cells").first
      adapter = runner.instance_variable_get(:@registry).fetch("fixture")
      prepare = adapter.method(:prepare_grading_request)
      adapter.define_singleton_method(:prepare_grading_request) do |**arguments|
        prepare.call(**arguments).merge("procedure_digest" => "changed")
      end
      regraded = runner.regrade(experiment_id: result.fetch("run_id"), cell_id: original.fetch("id"))
      current = regraded.fetch("cells").first
      assert_equal original["score"], current["score"]
      assert_equal "success", current["execution_status"]
      assert_equal "error", current.fetch("grading_attempts").last.fetch("execution_status")
      assert_includes current.fetch("grading_attempts").last.fetch("error"), "contract drift"
    end
  end

  def test_live_mode_is_rejected_before_solver_work
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      manifest["execution_mode"] = "live"
      solver = runner.instance_variable_get(:@solvers).fetch("direct")
      solver.define_singleton_method(:solve) { |**| flunk "solver must not run" }
      assert_raises(ArgumentError) { runner.run(manifest: manifest) }
    end
  end

  def test_failed_regrade_preserves_prior_active_evaluation
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      adapter = runner.instance_variable_get(:@registry).fetch("fixture")
      grade = adapter.method(:grade_submission)
      fail_grading = false
      adapter.define_singleton_method(:grade_submission) do |request|
        fail_grading ? {"status" => "failure", "error" => "infrastructure down"} : grade.call(request)
      end
      result = runner.run(manifest: manifest)
      original = result.fetch("cells").first
      fail_grading = true
      current = runner.regrade(experiment_id: result.fetch("run_id"), cell_id: original.fetch("id")).fetch("cells").first
      assert_equal original["score"], current["score"]
      assert_equal original["verdict"], current["verdict"]
      assert_equal "success", current["execution_status"]
      assert_equal "error", current.fetch("grading_attempts").last.fetch("execution_status")
      assert_equal "infrastructure down", current.fetch("grading_attempts").last.fetch("raw").fetch("error")
    end
  end

  def test_regrade_rejects_specification_environment_and_limit_drift_before_grading
    %w[specification_digest environment_digest limits].each do |binding|
      in_tmp do |root|
        _, runner, manifest = setup_runner(root)
        result = runner.run(manifest: manifest)
        original = result.fetch("cells").first
        adapter = runner.instance_variable_get(:@registry).fetch("fixture")
        prepare = adapter.method(:prepare_grading_request)
        adapter.define_singleton_method(:prepare_grading_request) do |**arguments|
          prepare.call(**arguments).merge(binding => "changed")
        end
        graded = false
        adapter.define_singleton_method(:grade_submission) { |_| graded = true }
        current = runner.regrade(experiment_id: result.fetch("run_id"), cell_id: original.fetch("id")).fetch("cells").first
        refute graded, binding
        assert_equal original["score"], current["score"]
        assert_includes current.fetch("grading_attempts").last.fetch("error"), binding
      end
    end
  end

  def test_regrade_requires_original_request_and_preserves_score
    in_tmp do |root|
      store, runner, manifest = setup_runner(root)
      report = runner.run(manifest: manifest)
      cell = report.fetch("cells").first
      cell.fetch("grading_attempts").each { |attempt| attempt.delete("request") }
      store.save_report(report)
      current = runner.regrade(experiment_id: report.fetch("run_id"), cell_id: cell.fetch("id")).fetch("cells").first
      assert_equal cell["score"], current["score"]
      assert_includes current.fetch("grading_attempts").last.fetch("error"), "missing original grading request"
    end
  end

  def test_regrade_rejects_changed_evaluator_method_binding
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      report = runner.run(manifest: manifest)
      cell = report.fetch("cells").first
      assert cell.fetch("grading_attempts").first.fetch("implementation_fingerprint").fetch("files").any?
      adapter = runner.instance_variable_get(:@registry).fetch("fixture")
      original = adapter.method(:normalize_score)
      adapter.define_singleton_method(:normalize_score) { |raw| original.call(raw) }
      current = runner.regrade(experiment_id: report.fetch("run_id"), cell_id: cell.fetch("id")).fetch("cells").first
      assert_equal cell["score"], current["score"]
      assert_includes current.fetch("grading_attempts").last.fetch("error"), "implementation fingerprint drift"
    end
  end

  def test_regrade_rejects_changed_adapter_subclass
    in_tmp do |root|
      store, runner, manifest = setup_runner(root)
      report = runner.run(manifest: manifest)
      cell = report.fetch("cells").first
      changed_class = Class.new(AgentRuntime::Benchmarks::FixtureAdapter) do
        def grade_submission(request)
          super
        end
      end
      registry = AgentRuntime::Benchmarks::Registry.new
      registry.register("fixture", changed_class.new(store: store))
      runner.instance_variable_set(:@registry, registry)
      assert_raises(ArgumentError) { runner.regrade(experiment_id: report.fetch("run_id"), cell_id: cell.fetch("id")) }
      current = store.report(report.fetch("run_id")).fetch("cells").first
      assert_equal cell["score"], current["score"]
      assert_equal cell.fetch("grading_attempts"), current.fetch("grading_attempts")
    end
  end

  def test_explicit_fixture_model_alias_is_supported_but_live_provider_is_rejected
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      manifest["models"] = [{"id" => "fixture-model", "provider" => "fixture"}]
      result = runner.run(manifest: manifest)
      assert_equal "fixture-model", result.fetch("cells").first.fetch("model")
      manifest["experiment_id"] = "live-provider"
      manifest["models"].first["provider"] = "live"
      assert_raises(ArgumentError) { runner.run(manifest: manifest) }
    end
  end

  def test_unavailable_is_explicit_and_other_cells_continue
    in_tmp do |root|
      _, runner, manifest = setup_runner(root)
      manifest["benchmark"]["task_ids"] = %w[unavailable half]
      result = runner.run(manifest: manifest)
      assert_equal %w[unavailable unavailable success success], result.fetch("cells").map { |row| row["execution_status"] }
      assert result.fetch("cells").first(2).all? { |row| row["status"] == "skipped" && !row["error"].nil? && row["score"].nil? }
    end
  end

  def test_pairing_requires_matching_task_and_repetition
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      rows = [cell("a", 1, 1), cell("a", 2, 0), cell("b", 1, 1)]
      other = [cell("a", 1, 0), cell("a", 2, nil, "error"), cell("c", 1, 1)]
      other.each { |row| row["solver_id"] = "single-agent" }
      store.save_report({"run_id" => "paired", "manifest" => {"repetitions" => 2}, "cells" => rows + other})
      paired = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: "paired").fetch("paired").first
      assert_equal [["a", 1]], paired.fetch("included_coordinates")
      assert_equal 3, paired.fetch("excluded_coordinates").size
      assert_nil paired.fetch("scientific_delta")
      assert_equal 1.0, paired.fetch("fixture_diagnostic_delta")
    end
  end

  def test_reports_use_complete_task_repetitions_not_valid_cell_pool
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      cells = [cell("a", 1, 1), cell("a", 2, 0), cell("b", 1, 1), cell("b", 2, nil, "error")]
      store.save_report({"run_id" => "experiment", "kind" => "experiment", "manifest" => {"repetitions" => 2}, "cells" => cells})
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      arm = reports.summary(experiment_id: "experiment").fetch("arms").first
      assert_equal 0.5, arm.fetch("macro_score")
      assert_equal ["a"], arm.fetch("included_tasks")
      assert_equal ["b"], arm.fetch("excluded_tasks")
      assert_equal 3, arm.fetch("valid_cells")
      assert_equal 1, arm.fetch("invalid_cells")
      assert_nil arm.fetch("cost_total")
      parsed = JSON.parse(reports.render(experiment_id: "experiment", format: "json"))
      assert_equal cells, parsed.fetch("cells")
      assert_includes reports.render(experiment_id: "experiment", format: "csv"), "execution_status"
      assert_includes reports.render(experiment_id: "experiment", format: "markdown"), "not scientific"
    end
  end

  def test_empty_denominator_is_null_and_unstarted_cells_remain_visible
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      store.save_report({"run_id" => "empty", "manifest" => {"repetitions" => 1}, "cells" => [cell("a", 1, nil, "not_started")]})
      arm = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: "empty").fetch("arms").first
      assert_nil arm.fetch("macro_score")
      assert_equal 1, arm.fetch("status_counts").fetch("not_started")
      summary = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: "empty")
      assert_equal 1, summary.fetch("execution_counts").fetch("planned")
      assert_equal 1, summary.fetch("execution_counts").fetch("missing")
      assert_equal 0, summary.fetch("evaluation_completion").fetch("completed")
      assert_nil summary.fetch("timings").fetch("agent").fetch("p95")
      assert_includes summary.fetch("limitations"), "Tool usage is unavailable unless explicitly recorded."
    end
  end

  def test_summary_retains_identity_task_results_timing_coverage_and_artifact_references
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      rows = [cell("a", 1, 1), cell("a", 2, 0)]
      rows.first.merge!("agent_duration" => 2.0, "grading_duration" => 1.0, "submission" => {"id" => "artifact"}, "attempt_id" => "attempt")
      store.save_report({"run_id" => "metrics", "manifest" => {"repetitions" => 2}, "manifest_digest" => "digest", "provenance" => {"runtime_commit" => "commit"}, "cells" => rows})
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      summary = reports.summary(experiment_id: "metrics")
      assert_equal "digest", summary.fetch("manifest_digest")
      assert_equal "commit", summary.fetch("provenance").fetch("runtime_commit")
      assert_equal rows, summary.fetch("per_task_results").fetch("a")
      assert_equal 2.0, summary.fetch("timings").fetch("agent").fetch("total")
      assert_equal 1, summary.fetch("timings").fetch("agent").fetch("known_cells")
      assert_equal 2, summary.fetch("evaluation_completion").fetch("completed")
      csv = reports.render(experiment_id: "metrics", format: "csv")
      assert_includes csv, "submission"
      assert_includes csv, "attempt_id"
      assert_includes csv, "artifact"
    end
  end

  private

  def setup_runner(root)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    registry = AgentRuntime::Benchmarks::Registry.new
    registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
    runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry,
      solvers: {"direct" => AgentRuntime::Benchmarks::FixtureSolvers.build("direct")})
    manifest = {"schema_version" => 1, "experiment_id" => "fixture-experiment", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => %w[half one failure]},
                "solver_ids" => ["direct"], "models" => [{"id" => "fixture"}], "repetitions" => 2, "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
    [store, runner, manifest]
  end

  def cell(task, repetition, score, status = "success")
    {"id" => "#{task}-#{repetition}", "task_id" => task, "solver_id" => "direct", "model" => "fixture", "repetition" => repetition,
     "execution_status" => status, "score" => score, "usage" => nil, "cost" => nil}
  end
end
