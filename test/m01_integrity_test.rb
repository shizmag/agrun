require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks"

class M01IntegrityTest < Minitest::Test
  # M0.1 additive boundaries and initial-result classifications are recorded in
  # docs/m0.1-c-plan.md; these tests never authorize a weaker verifier contract.
  GOOD = <<~RUBY
    module Clamp
      def self.call(value, minimum, maximum)
        raise ArgumentError if minimum > maximum
        [[value, minimum].max, maximum].min
      end
    end
  RUBY
  BAD = <<~RUBY
    module Clamp
      def self.call(value, minimum, maximum)
        maximum
      end
    end
  RUBY

  def fixture
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "store"))
      task = AgentRuntime::Benchmarks::Fixture.demo(root: File.join(root, "fixture"))
      repository = File.join(root, "submission")
      FileUtils.cp_r(task.repository, repository)
      File.write(File.join(repository, "lib/clamp.rb"), GOOD)
      evaluator = AgentRuntime::Evaluation::Evaluator.new(store: store)
      yield store, task, repository, evaluator, root
    end
  end

  def generation(store, repository, run_id = "run")
    store.put(type: "repository", value: repository, run_id: run_id,
      step_id: "producer", attempt: 1)
  end

  def verify(evaluator, report, task, repository, **options)
    evaluator.verify!(report: report, task: task, repository: repository,
      run_id: "run", **options)
  end

  def mutate_artifact(artifact)
    path = artifact.fetch("path")
    if artifact["type"] == "repository"
      path = File.join(path, "lib/clamp.rb")
    end
    File.chmod(0o644, path)
    File.binwrite(path, "corrupt")
  end

  # C-01/C-02/C-05: hand-written submissions, actual external procedure.
  def test_correct_bad_correct_are_independent_evaluations
    fixture do |store, task, repository, evaluator|
      baseline = File.binread(File.join(task.repository, "lib/clamp.rb"))
      reports = [GOOD, BAD, GOOD].each_with_index.map do |source, index|
        File.write(File.join(repository, "lib/clamp.rb"), source)
        evaluator.evaluate(task: task, repository: repository, run_id: "run-#{index}")
      end
      assert_equal %w[pass fail pass], reports.map { |r| r.fetch("verdict") }
      assert_equal ["completed"] * 3, reports.map { |r| r.fetch("execution_status") }
      assert_equal 3, reports.map { |r| r.fetch("evaluation_id") }.uniq.size
      assert_equal baseline, File.binread(File.join(task.repository, "lib/clamp.rb"))
      reports.zip([GOOD, BAD, GOOD]).each do |report, expected|
        path = store.value(report.fetch("generation"))
        assert_equal expected, File.read(File.join(path, "lib/clamp.rb"))
      end
    end
  end

  # C-04: CAS deduplication must not collapse generation/event identity.
  def test_same_run_good_bad_good_does_not_cache_verdict_by_run
    fixture do |_, task, repository, evaluator|
      reports = [GOOD, BAD, GOOD].map do |source|
        File.write(File.join(repository, "lib/clamp.rb"), source)
        evaluator.evaluate(task: task, repository: repository, run_id: "same-run")
      end
      assert_equal %w[pass fail pass], reports.map { |report| report.fetch("verdict") }
      assert_equal ["completed"] * 3, reports.map { |report| report.fetch("execution_status") }
    end
  end

  def test_equal_bytes_have_distinct_generation_and_evaluation_identity
    fixture do |store, task, repository, evaluator|
      first = generation(store, repository)
      second = generation(store, repository)
      assert_equal first.fetch("digest"), second.fetch("digest")
      refute_equal first.fetch("id"), second.fetch("id")
      reports = [first, second].map do |artifact|
        evaluator.evaluate(task: task, repository: repository, run_id: "run", generation: artifact)
      end
      reports.zip([first, second]).each do |report, artifact|
        assert_equal "submitted", report.fetch("identity_mode")
        assert_equal artifact, report.fetch("generation")
        assert_equal report, verify(evaluator, report, task, repository, generation: artifact)
      end
      refute_equal reports[0].fetch("evaluation_id"), reports[1].fetch("evaluation_id")
      assert_raises(AgentRuntime::Error) { verify(evaluator, reports[0], task, repository, generation: second) }
      assert_raises(AgentRuntime::Error) { verify(evaluator, reports[0], task, repository) }
    end
  end

  def test_standalone_identity_round_trip_and_report_payload
    fixture do |store, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      assert_equal "standalone", report.fetch("identity_mode")
      assert_equal "repository", report.fetch("generation").fetch("type")
      assert_equal "run", report.fetch("generation").fetch("run_id")
      refute_empty report.fetch("evaluation_id")
      payload = report.except("report_artifact")
      assert_equal payload, store.value(report.fetch("report_artifact"))
      assert_equal report, verify(evaluator, report, task, repository)
    end
  end

  def test_submitted_generation_rejects_wrong_run_type_and_bytes
    fixture do |store, task, repository, evaluator|
      wrong_run = generation(store, repository, "other")
      wrong_type = store.put(type: "text", value: GOOD, run_id: "run", step_id: "producer", attempt: 1)
      stale = generation(store, repository)
      File.write(File.join(repository, "lib/clamp.rb"), BAD)
      [wrong_run, wrong_type, stale].each do |artifact|
        assert_raises(AgentRuntime::Error) do
          evaluator.evaluate(task: task, repository: repository, run_id: "run", generation: artifact)
        end
      end
    end
  end

  # C-08/C-09: historical snapshots survive workspace edits, not current reuse.
  def test_changed_submission_invalidates_current_verification_not_snapshot
    fixture do |store, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      File.write(File.join(repository, "lib/clamp.rb"), BAD)
      snapshot = store.value(report.fetch("generation"))
      assert_equal GOOD, File.read(File.join(snapshot, "lib/clamp.rb"))
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
    end
  end

  def test_specification_revision_and_instruction_changes_reject_old_evidence
    fixture do |_, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      variants = [[:instruction, "Different requirement"], [:dataset_revision, "other"],
        [:base_commit, "0" * 40], [:spec, task.spec.merge("extra" => true)]]
      variants.each do |field, value|
        changed = task.dup
        changed[field] = value
        assert_raises(AgentRuntime::Error, field.to_s) { verify(evaluator, report, changed, repository) }
      end
    end
  end

  def test_public_test_bytes_are_bound_not_only_the_path
    fixture do |_, task, repository, evaluator, root|
      public_test = File.join(root, "public_test.rb")
      File.write(public_test, "# public contract A\n")
      task.public_tests = [public_test]
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      File.write(public_test, "# public contract B\n")
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
    end
  end

  def test_procedure_bytes_are_bound_independently
    fixture do |store, task, repository, evaluator, root|
      procedure = File.join(root, "procedure.rb")
      FileUtils.cp(task.hidden_test, procedure)
      task.hidden_test = procedure
      expected = Digest::SHA256.hexdigest(File.binread(procedure))
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      assert_equal expected, report.fetch("bindings").fetch("procedure")
      assert_equal File.binread(procedure), store.value(report.fetch("artifacts").fetch("procedure"))
      File.open(procedure, "a") { |f| f.puts "# changed" }
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
    end
  end

  def test_timeout_and_evaluator_version_are_bound
    fixture do |store, task, repository, _, _|
      evaluator = AgentRuntime::Evaluation::Evaluator.new(store: store, evaluator_version: "fixture-v1")
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run", timeout: 30)
      assert_equal report, verify(evaluator, report, task, repository, timeout: 30.0)
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository, timeout: 31) }
      changed = AgentRuntime::Evaluation::Evaluator.new(store: store, evaluator_version: "fixture-v2")
      assert_raises(AgentRuntime::Error) { verify(changed, report, task, repository) }
    end
  end

  def test_inherited_environment_change_rejects_old_evidence
    key = "AGRU_M01_INTEGRITY_FIXTURE"
    previous = ENV[key]
    ENV[key] = "first-nonsecret-value"
    fixture do |store, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      environment = store.value(report.fetch("artifacts").fetch("environment"))
      refute_includes JSON.generate(environment), "first-nonsecret-value"
      ENV[key] = "second-nonsecret-value"
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
    end
  ensure
    ENV[key] = previous
  end

  def test_canonical_metadata_cannot_be_forged_even_with_equal_content
    fixture do |store, _, repository|
      artifact = generation(store, repository)
      assert_equal artifact, store.artifact(artifact.fetch("id"))
      %w[id digest type path run_id step_id attempt inputs metadata].each do |field|
        altered = Marshal.load(Marshal.dump(artifact))
        altered.delete(field)
        assert_raises(AgentRuntime::Error, field) { store.value(altered) }
      end
      altered = artifact.merge("run_id" => "other")
      assert_raises(AgentRuntime::Error) { store.value(altered) }
      assert_raises(AgentRuntime::Error) { store.artifact("nonexistent") }
    end
  end

  def test_corrupt_and_missing_evidence_objects_fail_closed
    %w[artifact specification procedure environment].each do |kind|
      fixture do |store, task, repository, evaluator|
        report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
        artifact = report.fetch("artifacts").fetch(kind)
        mutate_artifact(artifact)
        assert_raises(AgentRuntime::Error, kind) { store.value(artifact) }
        assert_raises(AgentRuntime::Error, kind) { verify(evaluator, report, task, repository) }
      end
    end
  end

  def test_missing_object_is_not_repaired_on_read
    fixture do |store, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      path = report.fetch("artifacts").fetch("procedure").fetch("path")
      File.unlink(path)
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
      refute File.exist?(path)
      assert_raises(AgentRuntime::Error) { store.value(report.fetch("artifacts").fetch("procedure")) }
    end
  end

  def test_missing_repository_manifest_rejects_even_with_intact_tree
    fixture do |store, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      artifact = report.fetch("generation")
      manifest = File.join(store.root, "objects", artifact.fetch("digest"))
      File.unlink(manifest)
      assert Dir.exist?(artifact.fetch("path"))
      assert_raises(AgentRuntime::Error) { store.value(artifact) }
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
      refute File.exist?(manifest)
    end
  end

  def test_report_tampering_and_wrong_run_replay_are_rejected
    fixture do |_, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      changes = [{"verdict" => "fail"}, {"evaluation_id" => "forged"},
        {"bindings" => {}}, {"artifacts" => {}}, {"identity_mode" => "submitted"}]
      changes.each do |change|
        assert_raises(AgentRuntime::Error) { verify(evaluator, report.merge(change), task, repository) }
      end
      assert_raises(AgentRuntime::Error) do
        evaluator.verify!(report: report, task: task, repository: repository, run_id: "other")
      end
    end
  end

  def test_cross_run_canonical_input_lineage_is_allowed_but_corruption_is_not
    fixture do |store, _, repository|
      parent = generation(store, repository, "parent-run")
      child = store.put(type: "repository", value: repository, run_id: "run",
        step_id: "producer", attempt: 1, inputs: [parent])
      assert_equal child.fetch("path"), store.value(child)
      # Parent and child can deduplicate; a separate text parent isolates lineage.
      text = store.put(type: "text", value: "parent evidence", run_id: "parent-run", step_id: "source", attempt: 1)
      descendant = store.put(type: "repository", value: repository, run_id: "run",
        step_id: "producer", attempt: 2, inputs: [text])
      mutate_artifact(text)
      assert_raises(AgentRuntime::Error) { store.value(descendant) }
    end
  end

  INVALID_PROTOCOL = {
    "empty" => {"stdout" => ""},
    "ordinary_text" => {"stdout" => "ordinary text\n"},
    "invalid_json" => {"stdout" => "AGRU_VERDICT={\n"},
    "null" => {"stdout" => "AGRU_VERDICT=null\n"},
    "number" => {"stdout" => "AGRU_VERDICT=1\n"},
    "array" => {"stdout" => "AGRU_VERDICT=[]\n"},
    "string" => {"stdout" => "AGRU_VERDICT=\"pass\"\n"},
    "missing_verdict" => {"stdout" => "AGRU_VERDICT={}\n"},
    "unknown_verdict" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"unknown\"}\n"},
    "duplicate_same" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"pass\"}\nAGRU_VERDICT={\"verdict\":\"pass\"}\n"},
    "duplicate_opposite" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"fail\"}\nAGRU_VERDICT={\"verdict\":\"pass\"}\n"},
    "truncated" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"pass\"}\n", "stdout_truncated" => true},
    "stderr_truncated" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"pass\"}\n", "stderr_truncated" => true},
    "stderr_only" => {"stdout" => "", "stderr" => "AGRU_VERDICT={\"verdict\":\"pass\"}\n"},
    "mismatched_exit" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"pass\"}\n", "status" => "failure", "exit_code" => 1},
    "crash_with_pass" => {"stdout" => "AGRU_VERDICT={\"verdict\":\"pass\"}\n", "status" => "failure", "exit_code" => 2}
  }.freeze

  INVALID_PROTOCOL.each do |name, overrides|
    define_method("test_protocol_rejects_#{name}") do
      execution = {"status" => "success", "exit_code" => 0, "stderr" => ""}.merge(overrides)
      fixture do |store, task, repository|
        process = Object.new
        process.define_singleton_method(:call) { |**_| execution }
        evaluator = AgentRuntime::Evaluation::Evaluator.new(store: store, process_runner: process)
        report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
        assert_equal "error", report.fetch("execution_status"), execution.inspect
        assert_equal "not_evaluated", report.fetch("verdict"), execution.inspect
      end
    end
  end

  def test_report_object_corruption_is_not_ignored
    fixture do |_, task, repository, evaluator|
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      mutate_artifact(report.fetch("report_artifact"))
      assert_raises(AgentRuntime::Error) { verify(evaluator, report, task, repository) }
    end
  end

  def test_forged_matching_digest_and_bytes_do_not_replace_canonical_identity
    fixture do |store, _, repository|
      artifact = generation(store, repository)
      forged = artifact.merge("type" => "text")
      path = File.join(File.dirname(repository), "forged-object")
      File.binwrite(path, "replacement bytes")
      forged["path"] = path
      forged["digest"] = Digest::SHA256.hexdigest(File.binread(path))
      assert_raises(AgentRuntime::Error) { store.value(forged) }
    end
  end

  def test_runner_supplies_current_submitted_generation
    fixture do |store, task, repository, _, root|
      solver = Object.new
      solver.define_singleton_method(:solve) { |**_| {"status" => "success", "repository" => repository} }
      captured = nil
      evaluator = Object.new
      evaluator.define_singleton_method(:evaluate) do |**arguments|
        captured = arguments
        {"execution_status" => "completed", "verdict" => "pass"}
      end
      runner = AgentRuntime::Benchmarks::Runner.new(store: store, root: File.join(root, "runs"), evaluator: evaluator)
      report = runner.run(task: task, solver: solver)
      artifact = captured.fetch(:generation)
      assert_equal report.fetch("run_id"), artifact.fetch("run_id")
      assert_equal "repository", artifact.fetch("type")
      assert_equal artifact, store.artifact(artifact.fetch("id"))
      assert_equal GOOD, File.read(File.join(store.value(artifact), "lib/clamp.rb"))
    end
  end

  def test_real_grader_crash_and_timeout_are_not_correctness_failures
    fixture do |_, task, repository, evaluator, root|
      procedure = File.join(root, "grader.rb")
      task.hidden_test = procedure
      File.write(procedure, "raise 'fixture grader crash'\n")
      crashed = evaluator.evaluate(task: task, repository: repository, run_id: "crash")
      assert_equal "error", crashed.fetch("execution_status")
      assert_equal "not_evaluated", crashed.fetch("verdict")
      File.write(procedure, "sleep 60\n")
      timed_out = evaluator.evaluate(task: task, repository: repository, run_id: "deadline", timeout: 0.1)
      assert_equal "timeout", timed_out.fetch("execution_status")
      assert_equal "not_evaluated", timed_out.fetch("verdict")
    end
  end

  def test_runner_preserves_successful_solution_when_evaluator_raises
    fixture do |store, task, repository, _, root|
      solver = Object.new
      solver.define_singleton_method(:solve) { |**_| {"status" => "success", "repository" => repository} }
      evaluator = Object.new
      evaluator.define_singleton_method(:evaluate) { |**_| raise "fixture infrastructure exception" }
      runner = AgentRuntime::Benchmarks::Runner.new(store: store, root: File.join(root, "runs"), evaluator: evaluator)
      report = runner.run(task: task, solver: solver)
      assert_equal "success", report.fetch("solution").fetch("status")
      assert_equal "error", report.fetch("evaluation").fetch("execution_status")
      assert_equal "not_evaluated", report.fetch("evaluation").fetch("verdict")
      assert_includes report.fetch("error"), "RuntimeError"
      assert_equal report, store.report(report.fetch("run_id"))
    end
  end

  def test_owned_evidence_has_unique_evaluation_identity_and_submitted_lineage
    fixture do |store, task, repository, evaluator|
      producer = generation(store, repository)
      before = Marshal.load(Marshal.dump(producer))
      report = evaluator.evaluate(task: task, repository: repository, run_id: "run", generation: producer)
      assert_equal before, store.artifact(producer.fetch("id"))
      evidence = report.fetch("artifacts").values + [report.fetch("report_artifact")]
      evidence.each { |a| assert_equal({"evaluation_id" => report.fetch("evaluation_id")}, a.fetch("metadata")) }
      assert_equal [producer], report.fetch("artifacts").fetch("artifact").fetch("inputs")
      assert_equal report, verify(evaluator, report, task, repository, generation: producer)
    end
  end

  def test_missing_and_malformed_canonical_metadata_fail_closed
    [nil, "{", "[]"].each do |payload|
      fixture do |store, _, repository|
        artifact = generation(store, repository)
        db = SQLite3::Database.new(File.join(store.root, "metadata.sqlite3"))
        if payload
          db.execute("UPDATE artifacts SET data=? WHERE id=?", [payload, artifact.fetch("id")])
        else
          db.execute("DELETE FROM artifacts WHERE id=?", [artifact.fetch("id")])
        end
        assert_raises(AgentRuntime::Error) { store.artifact(artifact.fetch("id")) }
        assert_raises(AgentRuntime::Error) { store.value(artifact) }
        db.close
      end
    end
  end

  def test_provenance_cycles_and_missing_input_ids_reject
    fixture do |store, _, repository|
      artifact = generation(store, repository)
      db = SQLite3::Database.new(File.join(store.root, "metadata.sqlite3"))
      [artifact.fetch("id"), "nonexistent"].each do |input|
        altered = artifact.merge("inputs" => [input])
        db.execute("UPDATE artifacts SET data=? WHERE id=?", [JSON.generate(altered), artifact.fetch("id")])
        assert_raises(AgentRuntime::Error) { store.value(altered) }
      end
      db.close
    end
  end

  def test_nonfinite_timeout_and_missing_public_test_fail_closed
    fixture do |_, task, repository, evaluator, root|
      [Float::NAN, Float::INFINITY, -Float::INFINITY, 0, -1].each do |timeout|
        assert_raises(AgentRuntime::Error) do
          evaluator.evaluate(task: task, repository: repository, run_id: "run", timeout: timeout)
        end
      end
      task.public_tests = [File.join(root, "missing-test.rb")]
      assert_raises(AgentRuntime::Error) { evaluator.evaluate(task: task, repository: repository, run_id: "run") }
    end
  end

  def test_timeout_and_cancellation_precede_pass_marker_and_truncation
    %w[timeout cancelled].each do |status|
      fixture do |store, task, repository|
        process = Object.new
        process.define_singleton_method(:call) do |**_|
          {"status" => status, "exit_code" => 0, "stdout" => "AGRU_VERDICT={\"verdict\":\"pass\"}\n",
           "stdout_truncated" => true, "stderr_truncated" => true}
        end
        evaluator = AgentRuntime::Evaluation::Evaluator.new(store: store, process_runner: process)
        report = evaluator.evaluate(task: task, repository: repository, run_id: "run")
        assert_equal status, report.fetch("execution_status")
        assert_equal "not_evaluated", report.fetch("verdict")
      end
    end
  end

  def test_same_run_evidence_swap_is_rejected_even_for_equal_bytes
    fixture do |_, task, repository, evaluator|
      first = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      second = evaluator.evaluate(task: task, repository: repository, run_id: "run")
      first.fetch("artifacts").each_key do |key|
        altered = Marshal.load(Marshal.dump(first))
        altered.fetch("artifacts")[key] = second.fetch("artifacts").fetch(key)
        assert_raises(AgentRuntime::Error, key) { verify(evaluator, altered, task, repository) }
      end
      assert_raises(AgentRuntime::Error) do
        verify(evaluator, first.merge("report_artifact" => second.fetch("report_artifact")), task, repository)
      end
    end
  end
end
