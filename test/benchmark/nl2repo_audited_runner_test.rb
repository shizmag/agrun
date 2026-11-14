require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../../lib/agent_runtime/benchmarks/reports"
require_relative "../../lib/agent_runtime/benchmarks/registry"

# Scripted results exercise the generic runner boundary, not protocol acceptance.
class NL2RepoAuditedRunnerTest < Minitest::Test
  def test_raw_audited_evidence_survives_store_reload_and_json_rendering
    in_tmp do |root|
      store, runner, manifest = setup_runner(root, [audited_result])
      runner.run(manifest: manifest)
      cell = store.report(manifest.fetch("experiment_id")).fetch("cells").first
      assert_equal audited_result, cell.fetch("grading_attempts").first.fetch("raw")
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      rendered = JSON.parse(reports.render(experiment_id: manifest.fetch("experiment_id")))
      assert_equal audited_result, rendered.fetch("cells").first.fetch("grading_attempts").first.fetch("raw")
      assert_equal 1, rendered.fetch("summary").fetch("arms").first.fetch("pooled_counts").fetch("coverage")
    end
  end

  def test_protocol_basis_and_counts_are_visible_in_all_report_formats
    in_tmp do |root|
      store, runner, manifest = setup_runner(root, [audited_result])
      cell = runner.run(manifest: manifest).fetch("cells").first
      %w[protocol quality_basis expected collected executed passed failed skipped total].each do |key|
        assert_equal audited_result.fetch(key), cell[key]
      end
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      csv = reports.render(experiment_id: manifest.fetch("experiment_id"), format: "csv").lines.map do |line|
        line.scan(/"((?:[^"]|"")*)"(?:,|\r?\n|\z)/).flatten.map { |value| value.gsub('""', '"') }
      end
      row = csv.first.zip(csv.fetch(1)).to_h
      %w[protocol quality_basis expected collected executed passed failed skipped total].each do |key|
        assert_equal audited_result.fetch(key).to_s, row.fetch(key)
      end
      assert_equal audited_result, JSON.parse(row.fetch("grading_attempts")).first.fetch("raw")
      markdown = reports.render(experiment_id: manifest.fetch("experiment_id"), format: "markdown")
      %w[protocol quality_basis expected collected executed passed failed skipped total].each { |key| assert_includes markdown, " | #{key} | " }
      assert_includes markdown, "nl2repo-audited-v2"
      assert_includes markdown, "validated_quality_result"
      assert_includes markdown, "raw-evidence-marker"
    end
  end

  def test_failed_regrade_preserves_active_audited_result_and_retains_attempt
    in_tmp do |root|
      failed = {"execution_status" => "error", "score" => nil, "verdict" => nil,
                "error" => "invalid audited envelope", "protocol" => "rejected-protocol"}
      store, runner, manifest, requests = setup_runner(root, [audited_result, failed])
      original = runner.run(manifest: manifest).fetch("cells").first
      # Seed promotion fields so rollback coverage is useful before promotion lands.
      report = store.report(manifest.fetch("experiment_id"))
      report.fetch("cells").first.merge!(audited_result.slice("protocol", "quality_basis", "expected", "collected", "executed", "failed", "skipped"))
      store.save_report(report)
      original.merge!(audited_result.slice("protocol", "quality_basis", "expected", "collected", "executed", "failed", "skipped"))
      current = runner.regrade(experiment_id: manifest.fetch("experiment_id"), cell_id: original.fetch("id")).fetch("cells").first
      %w[score verdict passed total protocol quality_basis trust_scope reason failure_category expected collected executed failed skipped error execution_status status grading_duration submission attempt_id].each do |key|
        if original[key].nil?
          assert_nil current[key], "active #{key} changed after failed regrade"
        else
          assert_equal original[key], current[key], "active #{key} changed after failed regrade"
        end
      end
      assert_equal 2, current.fetch("grading_attempts").size
      assert_equal failed, current.fetch("grading_attempts").last.fetch("raw")
      assert_equal "regrade_failed", current.fetch("transitions").last.fetch("status")
      assert_equal 2, requests.size
      %w[task_id benchmark specification_digest submission_id submission_digest procedure_digest environment_digest limits].each do |key|
        assert_equal requests.first.fetch(key), requests.last.fetch(key), "regrade request changed #{key}"
      end
    end
  end

  def test_measured_zero_has_counts_but_missing_counts_remain_unknown
    in_tmp do |root|
      measured = audited_result.merge("score" => 0.0, "passed" => 0, "failed" => 2, "verdict" => "fail")
      store, runner, manifest = setup_runner(root, [measured])
      cell = runner.run(manifest: manifest).fetch("cells").first
      assert_equal "success", cell.fetch("execution_status")
      assert_equal "fail", cell.fetch("verdict")
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      counts = reports.summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms").first.fetch("pooled_counts")
      assert_equal({"passed" => 0, "total" => 2, "coverage" => 1}, counts)
      evidence = reports.summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms").first.fetch("count_evidence")
      assert_equal({"total" => 0, "known_cells" => 1}, evidence.fetch("passed"))
      report = store.report(manifest.fetch("experiment_id"))
      %w[expected collected executed passed failed skipped total].each { |key| report.fetch("cells").first[key] = nil }
      store.save_report(report)
      counts = reports.summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms").first.fetch("pooled_counts")
      assert_equal({"passed" => nil, "total" => nil, "coverage" => 0}, counts)
      evidence = reports.summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms").first.fetch("count_evidence")
      evidence.each_value { |value| assert_equal({"total" => nil, "known_cells" => 0}, value) }
    end
  end

  def test_aggregate_arms_do_not_blend_protocols_or_quality_bases
    in_tmp do |root|
      store, runner, manifest = setup_runner(root, [audited_result])
      original = runner.run(manifest: manifest).fetch("cells").first
      report = store.report(manifest.fetch("experiment_id"))
      identities = [["v1", "legacy"], ["v2", "audited"], ["v2", "other"]]
      report["cells"] = identities.each_with_index.map do |(protocol, basis), index|
        original.merge("id" => "partition-#{index}", "protocol" => protocol, "quality_basis" => basis)
      end
      store.save_report(report)
      arms = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms")
      assert_equal 3, arms.size
      assert_equal identities.sort, arms.map { |arm| arm.values_at("protocol", "quality_basis") }.sort
      arms.each do |arm|
        assert_equal 1, arm.fetch("valid_cells")
        assert_equal 1, arm.fetch("conditional_denominator")
        assert_equal({"passed" => 1, "total" => 2, "coverage" => 1}, arm.fetch("pooled_counts"))
      end
    end
  end

  def test_split_repetitions_cannot_jointly_establish_protocol_complete_task
    in_tmp do |root|
      store, runner, manifest = setup_runner(root, [audited_result])
      original = runner.run(manifest: manifest).fetch("cells").first
      report = store.report(manifest.fetch("experiment_id"))
      report.fetch("manifest")["repetitions"] = 2
      report["cells"] = ["legacy-v1", "nl2repo-audited-v2"].each_with_index.map do |protocol, index|
        original.merge("id" => "split-#{index}", "repetition" => index + 1, "protocol" => protocol, "quality_basis" => "validated_quality_result")
      end
      store.save_report(report)
      arms = AgentRuntime::Benchmarks::Reports.new(store: store).summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms")
      assert_equal 2, arms.size
      arms.each do |arm|
        assert_nil arm.fetch("macro_score")
        assert_equal 0, arm.fetch("conditional_denominator")
        assert_empty arm.fetch("included_tasks")
        assert_equal ["half"], arm.fetch("excluded_tasks")
      end
    end
  end

  def test_changed_submission_cannot_reach_grader_on_regrade
    in_tmp do |root|
      store, runner, manifest, requests = setup_runner(root, [audited_result, audited_result])
      original = runner.run(manifest: manifest).fetch("cells").first
      repository = File.join(root, "replacement")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "answer.json"), '{"score":1}')
      replacement = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: repository)
      report = store.report(manifest.fetch("experiment_id"))
      report.fetch("cells").first["submission"] = replacement
      store.save_report(report)
      current = runner.regrade(experiment_id: manifest.fetch("experiment_id"), cell_id: original.fetch("id")).fetch("cells").first
      assert_equal 1, requests.size
      assert_equal original.fetch("score"), current.fetch("score")
      assert_includes current.fetch("grading_attempts").last.fetch("error"), "regrade contract drift: submission_id, submission_digest"
      assert_equal "regrade_failed", current.fetch("transitions").last.fetch("status")
    end
  end

  def test_successful_regrade_clears_missing_identity_and_count_evidence
    in_tmp do |root|
      legacy = audited_result.except("protocol", "quality_basis", "expected", "collected", "executed", "failed", "skipped")
      store, runner, manifest = setup_runner(root, [audited_result, legacy])
      original = runner.run(manifest: manifest).fetch("cells").first
      current = runner.regrade(experiment_id: manifest.fetch("experiment_id"), cell_id: original.fetch("id")).fetch("cells").first
      %w[protocol quality_basis expected collected executed failed skipped].each { |key| assert_nil current[key] }
      assert_equal "nl2repo-audited-v2", current.fetch("grading_attempts").first.fetch("raw").fetch("protocol")
      assert_equal "success", current.fetch("execution_status")
      assert_equal 2, store.report(manifest.fetch("experiment_id")).fetch("cells").first.fetch("grading_attempts").size
    end
  end

  def test_scoped_audited_summary_preserves_status_basis_reason_and_missingness
    in_tmp do |root|
      store, runner, manifest = setup_runner(root, [audited_result])
      original = runner.run(manifest: manifest).fetch("cells").first
      report = store.report(manifest.fetch("experiment_id"))
      report["qualification"] = "provisional official-benchmark integration"
      report["cells"] = [original.merge("trust_scope" => "benign_ordinary_submissions"),
        original.merge("id" => "zero", "score" => 0.0, "quality_basis" => "candidate_collection_failure"),
        original.merge("id" => "infra", "score" => nil, "execution_status" => "error", "quality_basis" => nil, "reason" => "evaluation did not complete", "failure_category" => "infrastructure"),
        original.merge("id" => "violation", "score" => nil, "execution_status" => "success", "quality_basis" => nil, "reason" => "audited binding mismatch", "failure_category" => "protocol_violation")]
      store.save_report(report)
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      summary = reports.summary(experiment_id: manifest.fetch("experiment_id"))
      assert_equal({"success" => 3, "error" => 1}, summary.fetch("evidence_coverage").fetch("by_execution_status"))
      assert_equal({"validated_quality_result" => 1, "candidate_collection_failure" => 1}, summary.fetch("evidence_coverage").fetch("by_quality_basis"))
      assert_equal({"evaluation did not complete" => 1, "audited binding mismatch" => 1}, summary.fetch("evidence_coverage").fetch("by_reason"))
      assert_equal({"infrastructure" => 1, "protocol_violation" => 1}, summary.fetch("evidence_coverage").fetch("by_failure_category"))
      assert_equal 2, summary.fetch("evidence_coverage").fetch("valid_score_cells")
      assert_equal 2, summary.fetch("evidence_coverage").fetch("missing_score_cells")
      assert_includes summary.fetch("interpretation"), "controlled ordinary submissions"
      assert_includes summary.fetch("interpretation"), "not authenticated against malicious Python"
      markdown = reports.render(experiment_id: manifest.fetch("experiment_id"), format: "markdown")
      assert_includes markdown, "Evidence coverage"
      assert_includes markdown, "benign_ordinary_submissions"
      assert_includes reports.render(experiment_id: manifest.fetch("experiment_id"), format: "csv"), "audited binding mismatch"
    end
  end

  def test_unavailable_failure_category_is_promoted_and_restored_after_failed_regrade
    in_tmp do |root|
      unavailable = {"execution_status" => "unavailable", "score" => nil, "protocol" => "nl2repo-audited-v2",
                     "reason" => "missing local image", "failure_category" => "unavailable"}
      failed = {"execution_status" => "error", "error" => "infrastructure failure", "failure_category" => "infrastructure"}
      store, runner, manifest = setup_runner(root, [unavailable, failed])
      original = runner.run(manifest: manifest).fetch("cells").first
      assert_equal "unavailable", original.fetch("failure_category")
      current = runner.regrade(experiment_id: manifest.fetch("experiment_id"), cell_id: original.fetch("id")).fetch("cells").first
      assert_equal "unavailable", current.fetch("failure_category")
      assert_equal "infrastructure", current.fetch("grading_attempts").last.fetch("raw").fetch("failure_category")
      reports = AgentRuntime::Benchmarks::Reports.new(store: store)
      coverage = reports.summary(experiment_id: manifest.fetch("experiment_id")).fetch("arms").first.fetch("evidence_coverage")
      assert_equal({"unavailable" => 1}, coverage.fetch("by_failure_category"))
      assert_equal 0, coverage.fetch("valid_score_cells")
      assert_includes reports.render(experiment_id: manifest.fetch("experiment_id"), format: "csv"), '"failure_category"'
      assert_includes reports.render(experiment_id: manifest.fetch("experiment_id"), format: "markdown"), " | failure_category | "
    end
  end

  private

  def audited_result
    {"execution_status" => "success", "score" => 0.5, "verdict" => "fail",
     "protocol" => "nl2repo-audited-v2", "quality_basis" => "validated_quality_result",
     "trust_scope" => "benign_ordinary_submissions",
     "expected" => 3, "collected" => 3, "executed" => 2, "passed" => 1, "failed" => 1,
     "skipped" => 1, "total" => 2, "evidence" => {"marker" => "raw-evidence-marker"}}
  end

  def setup_runner(root, results)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    adapter = AgentRuntime::Benchmarks::FixtureAdapter.new(store: store)
    requests = []
    adapter.define_singleton_method(:grade_submission) do |request|
      requests << JSON.parse(JSON.generate(request))
      results.shift || raise("unexpected grader invocation")
    end
    registry = AgentRuntime::Benchmarks::Registry.new
    registry.register("fixture", adapter)
    runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry,
      solvers: {"direct" => AgentRuntime::Benchmarks::FixtureSolvers.build("direct")})
    manifest = {"schema_version" => 1, "experiment_id" => "audited-runner-contract", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["half"]},
                "solver_ids" => ["direct"], "models" => [{"id" => "fixture"}], "repetitions" => 1, "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
    [store, runner, manifest, requests]
  end
end
