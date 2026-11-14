require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/fixture_adapter"
require_relative "../../lib/agent_runtime/benchmarks/fixture_solvers"

class BenchmarkFixtureAdapterTest < Minitest::Test
  def test_every_request_binding_rejects_tampering_before_quality_is_returned
    in_tmp do |root|
      store, adapter = setup_adapter(root)
      artifact = submission(store, root)
      request = adapter.prepare_grading_request(task: adapter.load_task("one"), submission: artifact, limits: {"timeout" => 1})
      changes = {
        "task_id" => "half", "benchmark" => adapter.identity.merge("revision" => "forged"),
        "limits" => {"timeout" => 100}, "request_digest" => "f" * 64
      }
      %w[submission specification procedure environment].each do |kind|
        changes["#{kind}_id"] = "unknown-#{kind}"
        changes["#{kind}_digest"] = "0" * 64
      end
      assert_equal request.keys.sort, changes.keys.sort
      changes.each do |field, value|
        assert_raises(ArgumentError, "tampered #{field} must not return quality") do
          adapter.grade_submission(request.merge(field => value))
        end
      end
      request.keys.each do |field|
        assert_raises(ArgumentError, "missing #{field} must not return quality") do
          adapter.grade_submission(request.reject { |key, _| key == field })
        end
      end
    end
  end

  def test_forged_request_tokens_and_self_consistent_cross_request_substitutions_are_rejected
    in_tmp do |root|
      store, adapter = setup_adapter(root)
      first = adapter.prepare_grading_request(task: adapter.load_task("one"), submission: submission(store, root, score: 1), limits: {"timeout" => 1})
      second = adapter.prepare_grading_request(task: adapter.load_task("half"), submission: submission(store, root, score: 0.5), limits: {"timeout" => 2})
      forged = first.merge("limits" => {"timeout" => 99})
      forged["request_digest"] = AgentRuntime::IR.digest(forged.except("request_digest"))
      candidates = [forged, first.merge("request_digest" => "unknown"),
        first.merge("request_digest" => second.fetch("request_digest")),
        second.merge("request_digest" => first.fetch("request_digest"))]
      %w[submission specification procedure environment].each do |kind|
        candidates << first.merge("#{kind}_id" => second.fetch("#{kind}_id"), "#{kind}_digest" => second.fetch("#{kind}_digest"))
      end
      candidates << first.merge("task_id" => second.fetch("task_id"),
        "specification_id" => second.fetch("specification_id"), "specification_digest" => second.fetch("specification_digest"))
      candidates.each_with_index do |candidate, index|
        assert_raises(ArgumentError, "forged request #{index} must not return quality") { adapter.grade_submission(candidate) }
      end
      other_adapter = AgentRuntime::Benchmarks::FixtureAdapter.new(store: store)
      assert_raises(ArgumentError) { other_adapter.grade_submission(first) }
      assert_equal 1.0, adapter.grade_submission(first).fetch("score")
      assert_equal 0.5, adapter.grade_submission(second).fetch("score")
    end
  end

  def setup_adapter(root)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    [store, AgentRuntime::Benchmarks::FixtureAdapter.new(store: store)]
  end

  def submission(store, root, score: 1)
    repository = File.join(root, SecureRandom.hex(4))
    FileUtils.mkdir_p(repository)
    File.write(File.join(repository, "answer.json"), JSON.generate("score" => score))
    store.put(type: "repository", value: repository, run_id: "fixture", step_id: "solve", attempt: 1)
  end

  def test_fixture_tasks_are_public_and_unknown_ids_fail_closed
    in_tmp do |root|
      _, adapter = setup_adapter(root)
      refute_empty adapter.list_tasks
      adapter.list_tasks.each do |task|
        assert_empty task.keys - AgentRuntime::Benchmarks::Adapter::PUBLIC_TASK_FIELDS
        assert_equal task, adapter.load_task(task.fetch("id"))
      end
      assert_raises(KeyError) { adapter.load_task("not-a-task") }
    end
  end

  def test_requests_are_frozen_and_bind_actual_artifacts_and_contract
    in_tmp do |root|
      store, adapter = setup_adapter(root)
      artifact = submission(store, root)
      request = adapter.prepare_grading_request(task: adapter.list_tasks.first, submission: artifact, limits: {"timeout" => 1})
      assert_equal artifact["id"], request["submission_id"]
      assert_equal artifact["digest"], request["submission_digest"]
      %w[specification_digest procedure_digest environment_digest].each { |key| assert_match(/\A[0-9a-f]{64}\z/, request.fetch(key)) }
      assert request.frozen?
      assert request["limits"].frozen?
      report = adapter.grade_submission(request)
      assert_equal 1.0, report["score"]
      assert_equal "fixture", report["provenance"]
      assert_equal artifact["digest"], report.dig("evidence", "submission_digest")
      assert_raises(ArgumentError) { adapter.grade_submission(request.merge("submission_digest" => "0" * 64)) }
      assert_raises(ArgumentError) { adapter.grade_submission(request.merge("limits" => {"timeout" => 100})) }
    end
  end

  def test_zero_partial_and_full_scores_without_executing_generated_code
    in_tmp do |root|
      store, adapter = setup_adapter(root)
      [0, 0.5, 1].each do |score|
        artifact = submission(store, root, score: score)
        request = adapter.prepare_grading_request(task: adapter.list_tasks.first, submission: artifact, limits: {"timeout" => 1})
        assert_equal score.to_f, adapter.grade_submission(request)["score"]
      end
      [Float::NAN, Float::INFINITY, -1, 1.1, "1"].each do |score|
        assert_raises(ArgumentError) { adapter.normalize_score(score) }
      end
    end
  end

  def test_artifact_tampering_and_spoofed_task_are_rejected
    in_tmp do |root|
      store, adapter = setup_adapter(root)
      artifact = submission(store, root)
      task = adapter.list_tasks.first
      assert_raises(ArgumentError) { adapter.prepare_grading_request(task: task.merge("specification_digest" => "bad"), submission: artifact, limits: {}) }
      request = adapter.prepare_grading_request(task: task, submission: artifact, limits: {"timeout" => 1})
      File.chmod(0o644, File.join(artifact.fetch("path"), "answer.json"))
      File.write(File.join(artifact.fetch("path"), "answer.json"), "{}")
      assert_raises(AgentRuntime::Error) { adapter.grade_submission(request) }
    end
  end

  def test_fixture_grading_failure_is_distinct_and_submitted_code_is_never_executed
    in_tmp do |root|
      store, adapter = setup_adapter(root)
      repository = File.join(root, "unsafe")
      FileUtils.mkdir_p(repository)
      sentinel = File.join(root, "executed")
      File.write(File.join(repository, "answer.json"), JSON.generate("score" => 0.5))
      File.write(File.join(repository, "grader.rb"), "File.write(#{sentinel.inspect}, 'executed')")
      artifact = store.put(type: "repository", value: repository, run_id: "fixture", step_id: "solve", attempt: 1)
      request = adapter.prepare_grading_request(task: adapter.load_task("one"), submission: artifact, limits: {"timeout" => 1})
      assert_equal 0.5, adapter.grade_submission(request)["score"]
      refute File.exist?(sentinel)
      request = adapter.prepare_grading_request(task: adapter.load_task("failure"), submission: artifact, limits: {"timeout" => 1})
      result = adapter.grade_submission(request)
      assert_equal "failure", result["status"]
      assert_nil result["score"]
      refute File.exist?(sentinel)
    end
  end

  def test_four_solver_categories_share_contract_and_composition_has_runtime_evidence
    in_tmp do |root|
      _, adapter = setup_adapter(root)
      %w[direct single-agent fixed-workflow compositional-dsl].each do |id|
        workspace = File.join(root, id)
        adapter.prepare_solver_workspace(task: adapter.list_tasks.first, workspace: workspace)
        solver = AgentRuntime::Benchmarks::FixtureSolvers.build(id)
        result = solver.solve(task: adapter.list_tasks.first, model: {"id" => "fake"}, budget: {"timeout" => 10}, workspace: workspace)
        assert_equal "success", result["status"]
        assert File.directory?(result["repository"])
        assert_nil result["usage"]
        assert_nil result["cost"]
        assert result["runtime_run_id"] if id == "compositional-dsl"
      end
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::FixtureSolvers.build("live") }
    end
  end
end
