require_relative "nl2repo_test"
require_relative "../../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../../lib/agent_runtime/benchmarks/registry"
require_relative "../../lib/agent_runtime/benchmarks/repository_solver"

class NL2RepoRunnerIntegrationTest < NL2RepoTest
  def setup_integration(root, imported: true)
    _, data, path = fixture(root)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"), store: store)
    adapter.prepare(allow_download: true) if imported
    registry = AgentRuntime::Benchmarks::Registry.new
    registry.register("nl2repo", adapter)
    solver = AgentRuntime::Benchmarks::RepositorySolver.new
    runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry,
      solvers: {"repository-submission" => solver})
    manifest = {"schema_version" => 1, "experiment_id" => "nl2repo-integration", "benchmark" => {
                                                                                   "name" => "nl2repo", "revision" => data.fetch("revision"), "task_ids" => ["calculator"]
                                                                                 },
                "solver_ids" => ["repository-submission"], "models" => [{"id" => "fixture"}], "repetitions" => 1,
                "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "infrastructure-only"}
    [store, runner, manifest, solver]
  end

  def test_authorized_repository_submission_and_independent_unavailable_regrade
    in_tmp do |root|
      store, runner, manifest, solver = setup_integration(root)
      result = runner.run(manifest: manifest)
      cell = result.fetch("cells").first
      assert_equal "unavailable", cell.fetch("execution_status")
      assert_equal "success", cell.fetch("solver_status")
      assert_nil cell.fetch("score")
      assert_nil cell.fetch("verdict")
      assert_equal "provisional official-benchmark integration", result.fetch("qualification")
      assert_equal "repository", store.artifact(cell.fetch("submission").fetch("id")).fetch("type")
      workspace = File.join(root, "runs", cell.fetch("attempt_id"))
      assert_equal "Build a calculator.\n", File.read(File.join(workspace, "INSTRUCTION.md"))
      refute File.exist?(File.join(workspace, "hidden.py"))
      refute File.exist?(File.join(workspace, "repository/answer.json"))
      File.write(File.join(workspace, "repository/README.md"), "mutated")
      solver.define_singleton_method(:solve) { |**| raise "solver must not run during regrade" }
      regraded = runner.regrade(experiment_id: result.fetch("run_id"), cell_id: cell.fetch("id")).fetch("cells").first
      assert_equal cell.fetch("submission"), regraded.fetch("submission")
      assert_equal cell.fetch("attempt_id"), regraded.fetch("attempt_id")
      assert_equal 2, regraded.fetch("grading_attempts").size
      assert_nil regraded.fetch("score")
      assert_equal "unavailable", regraded.fetch("grading_attempts").last.fetch("execution_status")
    end
  end

  def test_missing_task_never_invokes_solver
    in_tmp do |root|
      _, runner, manifest, solver = setup_integration(root, imported: false)
      solver.define_singleton_method(:solve) { |**| raise "solver must not run" }
      cell = runner.run(manifest: manifest).fetch("cells").first
      assert_equal "unavailable", cell.fetch("execution_status")
      refute cell.key?("submission")
    end
  end

  def test_explicit_repository_is_frozen_before_solving_and_bound_to_configuration
    in_tmp do |root|
      store, runner, manifest, = setup_integration(root)
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "app.rb"), "puts :real_submission\n")
      solver = AgentRuntime::Benchmarks::RepositorySolver.new(repository: source)
      digest = Digest::SHA256.hexdigest(AgentRuntime::IR.dump(AgentRuntime::Store.manifest(source)))
      runner.instance_variable_get(:@solvers)["repository-submission"] = solver
      File.write(File.join(source, "app.rb"), "mutated source")
      result = runner.run(manifest: manifest)
      artifact = result.fetch("cells").first.fetch("submission")
      assert_equal digest, artifact.fetch("digest")
      assert_equal digest, result.fetch("solver_configurations").fetch("repository-submission").fetch("source_digest")
      assert_equal "puts :real_submission\n", File.read(File.join(store.artifact(artifact.fetch("id")).fetch("path"), "app.rb"))
    end
  end

  def test_explicit_repository_rejects_symlinks_and_hardlinks
    in_tmp do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      target = File.join(root, "private")
      File.write(target, "secret")
      File.symlink(target, File.join(source, "alias"))
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::RepositorySolver.new(repository: source) }
      File.unlink(File.join(source, "alias"))
      File.link(target, File.join(source, "alias"))
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::RepositorySolver.new(repository: source) }
    end
  end

  def test_fixture_score_solver_cannot_be_used_for_nl2repo
    in_tmp do |root|
      _, runner, manifest, = setup_integration(root)
      manifest["solver_ids"] = ["direct"]
      runner.instance_variable_get(:@solvers)["direct"] = AgentRuntime::Benchmarks::FixtureSolvers.build("direct")
      assert_raises(ArgumentError) { runner.run(manifest: manifest) }
    end
  end

  def test_excluded_task_never_receives_repository_submission
    in_tmp do |root|
      _, _, path = fixture(root)
      data = JSON.parse(File.read(path))
      data.fetch("tasks").first["authorized"] = false
      File.write(path, JSON.generate(data))
      store = AgentRuntime::Store.new(File.join(root, "store"))
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"), store: store)
      task = adapter.load_task("calculator")
      assert_nil task.fetch("instruction")
      assert_equal "excluded", task.fetch("availability")
      assert_raises(ArgumentError) { adapter.prepare_solver_workspace(task: task, workspace: File.join(root, "solver")) }
      refute File.exist?(File.join(root, "solver"))
    end
  end

  def test_untrusted_diagnostics_remain_raw_evidence_not_scores
    in_tmp do |root|
      store, runner, manifest, = setup_integration(root)
      adapter = runner.instance_variable_get(:@registry).fetch("nl2repo")
      grade = adapter.method(:grade_submission)
      adapter.define_singleton_method(:grade_submission) do |request|
        grade.call(request).merge("diagnostics" => {"authority" => "untrusted", "observed_score" => 1.0, "collector_stdout_digest" => "d" * 64})
      end
      result = runner.run(manifest: manifest)
      cell = result.fetch("cells").first
      assert_equal "unavailable", cell.fetch("execution_status")
      assert_nil cell.fetch("score")
      assert_nil cell.fetch("verdict")
      persisted = store.report(result.fetch("run_id")).fetch("cells").first
      raw = persisted.fetch("grading_attempts").first.fetch("raw")
      assert_equal "untrusted", raw.fetch("diagnostics").fetch("authority")
      assert_equal 1.0, raw.fetch("diagnostics").fetch("observed_score")
      assert_equal "d" * 64, raw.fetch("diagnostics").fetch("collector_stdout_digest")
    end
  end

  def test_native_diagnostic_bridge_uses_private_verified_store_snapshot
    in_tmp do |root|
      _, data, path = fixture(root)
      data.fetch("tasks").first["id"] = "retrying"
      File.write(path, JSON.generate(data))
      store = AgentRuntime::Store.new(File.join(root, "store"))
      helper = Object.new
      observed = []
      helper.define_singleton_method(:diagnose_submission) do |task:, repository:, limits:|
        observed << repository
        raise "wrong task" unless task == "retrying"
        raise "wrong bytes" unless File.read(File.join(repository, "retrying.py")) == "controlled bytes"
        {"authority" => "untrusted", "observed_passed" => 1, "observed_total" => 23}
      end
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"), store: store, diagnostics: true, diagnostic_runner: helper)
      adapter.prepare(allow_download: true)
      repository = File.join(root, "submitted")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "retrying.py"), "controlled bytes")
      artifact = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: repository)
      request = adapter.prepare_grading_request(task: adapter.load_task("retrying"), submission: artifact, limits: {"timeout" => 10})
      File.write(File.join(repository, "retrying.py"), "mutated mutable repository")
      result = adapter.grade_submission(request)
      assert_equal "unavailable", result.fetch("execution_status")
      assert_nil result.fetch("score")
      assert_equal "untrusted", result.fetch("diagnostics").fetch("authority")
      assert_equal artifact.fetch("digest"), result.fetch("diagnostic_submission_digest")
      assert_equal 1, observed.size
      refute File.exist?(observed.first)
      refute_equal artifact.fetch("path"), observed.first
    end
  end
end
