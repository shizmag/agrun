require_relative "nl2repo_test"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_audited_grader"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_audited_promotion"
require_relative "../../lib/agent_runtime/benchmarks/audited_results"

# Public normalization is deliberately not an authority boundary. These offline
# regression tests require neither downloaded assets nor a Docker daemon. Positive
# promotion tests belong here after the trusted collector/preflight API is frozen.
class NL2RepoAuditedPromotionTest < NL2RepoTest
  def test_normalization_preserves_only_finite_unit_interval_numeric_scores
    in_tmp do |root|
      adapter, = fixture(root)
      [0, 0.5, 1.0].each { |score| assert_equal score, adapter.normalize_score(score) }
      [-1, 2, Float::NAN, Float::INFINITY, "1.0", {"score" => 1.0}, nil].each do |score|
        assert_nil adapter.normalize_score(score)
      end
    end
  end

  def assert_unscored(evidence)
    in_tmp do |root|
      adapter, = fixture(root)
      assert_nil adapter.normalize_score(evidence)
    end
  end

  def test_structured_looking_stdout_cannot_promote_a_candidate
    assert_unscored("execution_status" => "success", "stdout" => JSON.generate(
      "authenticated" => true, "score" => 1.0, "verdict" => "pass",
      "result_authority" => "audited", "passed" => 100, "total" => 100
    ))
  end

  def test_self_asserted_collector_identity_cannot_promote_a_hash
    assert_unscored("execution_status" => "success", "authenticated" => true,
      "result_authority" => "audited", "collector_version" => "m1.1c",
      "score" => 1.0, "verdict" => "pass")
  end

  def test_missing_candidate_module_in_stdout_is_not_absence_proof
    assert_unscored("execution_status" => "failure",
      "stdout" => "ModuleNotFoundError: No module named 'retrying'\n",
      "score" => 0.0, "verdict" => "fail")
  end

  def test_candidate_supplied_absence_boolean_is_not_absence_proof
    assert_unscored("execution_status" => "success", "missing_candidate_module" => true,
      "required_module" => "retrying", "submission_digest" => "a" * 64,
      "score" => 0.0, "verdict" => "fail")
  end

  def test_missing_third_party_dependency_is_not_candidate_collection_zero
    assert_unscored("execution_status" => "failure",
      "stderr" => "ModuleNotFoundError: No module named 'pytest'\n",
      "score" => 0.0, "verdict" => "fail")
  end

  def test_ambiguous_collection_error_is_not_candidate_collection_zero
    assert_unscored("execution_status" => "failure", "collected" => 0,
      "collection_errors" => ["ImportError while importing test module"],
      "score" => 0.0, "verdict" => "fail")
  end

  def test_timeout_with_passing_output_stays_unscored
    assert_unscored("execution_status" => "timeout", "stdout" => "100 passed\n",
      "score" => 1.0, "verdict" => "pass")
  end

  def test_timeout_with_missing_module_claim_stays_unscored
    assert_unscored("execution_status" => "timeout", "missing_candidate_module" => true,
      "score" => 0.0, "verdict" => "fail")
  end

  def test_truncated_output_stays_unscored
    assert_unscored("execution_status" => "success", "stdout_truncated" => true,
      "stdout" => "100 passed\n", "score" => 1.0, "verdict" => "pass")
  end

  def test_successful_transport_without_results_stays_unscored
    assert_unscored("execution_status" => "success", "exit_code" => 0,
      "stdout" => "", "stderr" => "")
  end
end

class NL2RepoAuditedPromotionPolicyTest < Minitest::Test
  class Transport
    def identity
      {"transport_sha256" => "1" * 64, "collector_sha256" => "2" * 64,
       "validator_sha256" => "4" * 64, "promotion_sha256" => "5" * 64,
       "image" => "example@sha256:#{"3" * 64}", "resource_policy" => {"network" => "none"}}
    end

    def issue(request, record)
      @issued ||= {}.compare_by_identity
      token = Object.new.freeze
      @issued[token] = [request, Marshal.load(Marshal.dump(record))]
      token
    end

    def consume_evidence(request:, evidence:)
      entry = @issued&.delete(evidence)
      entry[1] if entry && entry[0].equal?(request)
    end
  end

  def setup
    @transport = Transport.new
    @policy = AgentRuntime::Benchmarks::NL2RepoAuditedPromotion.new(transport: @transport)
    @binding = {"submission_digest" => "a" * 64, "procedure_digest" => "b" * 64,
                "specification_digest" => "c" * 64, "environment_digest" => "d" * 64}
    @ids = ["test_retrying.py::Test::test_one", "test_retrying.py::Test::test_two"]
    @request = {"task_id" => "retrying", "submission_digest" => "a" * 64,
                "audited_binding" => @binding, "expected_nodeids" => @ids}.freeze
  end

  def valid(outcomes = %w[passed passed])
    {"status" => "valid", "tests" => @ids.zip(outcomes).to_h, "executed" => @ids.length,
     "counts" => %w[passed failed error skipped xfailed xpassed].to_h { |name| [name, outcomes.count(name)] }}
  end

  def record
    {"protocol" => "nl2repo-audited-v2", "binding" => @binding, "expected_binding" => @binding,
     "expected_nodeids" => @ids, "candidate" => valid, "reference" => valid,
     "candidate_inventory" => {"submission_digest" => "a" * 64, "missing_required_module" => true, "checked_paths" => %w[retrying.py retrying]},
     "execution_status" => "success", "artifacts" => {"raw" => "artifact-1"}}
  end

  def collection(module_name = "retrying")
    {"status" => "collection_failure", "collected" => [], "collection_errors" => [{"nodeid" => "test_retrying.py",
                                                                                   "exception" => {"type" => "ModuleNotFoundError", "module" => module_name,
                                                                                                   "message" => "missing", "frames" => [{"path" => "/candidate/test_retrying.py", "lineno" => 7, "name" => "<module>"}]}}]}
  end

  def promote(value = record)
    @policy.call(request: @request, evidence: @transport.issue(@request, value))
  end

  def assert_unscored_policy(result)
    assert_nil result.fetch("score")
    assert_equal "untrusted", result.fetch("trust")
    refute_empty result.fetch("reason")
  end

  def test_complete_quality_scores_fixed_denominator_and_scoped_trust
    data = record
    data["candidate"] = valid(%w[passed failed])
    result = promote(data)
    assert_equal 0.5, result.fetch("score")
    assert_equal "success", result.fetch("status")
    assert_equal 1, result.fetch("passed")
    assert_equal 2, result.fetch("total")
    assert_equal "fail", result.fetch("verdict")
    assert_equal "validated_quality_result", result.fetch("quality_basis")
    assert_equal "audited", result.fetch("trust")
    assert_equal "benign_ordinary_submissions", result.fetch("trust_scope")
    assert_equal "nl2repo-audited-v2", result.fetch("protocol")
    assert_equal 2, result.fetch("expected")
    assert_equal 2, result.fetch("collected")
    assert_equal 2, result.fetch("executed")
    assert_equal 1, result.fetch("failed")
    assert_equal 0, result.fetch("skipped")
    refute result.key?("authenticated")
    assert_equal "pass", promote.fetch("verdict")
  end

  def test_real_structured_parser_result_promotes_without_stdout_authority
    doc = {"schema" => "agru.pytest-results.v1", "pytest_version" => "8.4.1", "binding" => @binding,
           "collected" => @ids, "collection_errors" => [], "exit_code" => 0, "finished" => true,
           "tests" => @ids.map { |id| {"nodeid" => id, "reports" => %w[setup call teardown].map { |phase| {"when" => phase, "outcome" => "passed"} }} }}
    parsed = AgentRuntime::Benchmarks::AuditedResults.parse(bytes: JSON.generate(doc),
      expected_nodeids: @ids, expected_binding: @binding,
      process: {"status" => "success", "exit_code" => 0, "stdout_truncated" => false, "stderr_truncated" => false})
    assert_equal "valid", parsed.fetch("status")
    data = record.merge("candidate" => parsed, "reference" => parsed)
    result = promote(data)
    assert_equal 1.0, result.fetch("score")
    assert_equal "validated_quality_result", result.fetch("quality_basis")
  end

  def test_absent_candidate_and_missing_dependency_have_distinct_policy
    data = record
    data["candidate"] = collection
    result = promote(data)
    assert_equal 0.0, result.fetch("score")
    assert_equal "candidate_collection_failure", result.fetch("quality_basis")
    assert_equal "fail", result.fetch("verdict")
    assert_equal 2, result.fetch("total")
    assert_equal 0, result.fetch("collected")
    assert_equal 0, result.fetch("executed")
    assert_equal 0, result.fetch("failed")
    data["candidate"] = collection("pytest")
    assert_unscored_policy promote(data)
  end

  def test_absence_zero_is_scoped_to_retrying_task_even_with_valid_receipt
    data = record.merge("candidate" => collection)
    assert_equal 0.0, promote(data).fetch("score")

    @request = @request.merge("task_id" => "another_task").freeze
    assert_unscored_policy promote(data)
  end

  def test_unscored_failure_taxonomy_preserves_protocol_without_quality_score
    cases = [
      [record.merge("reference" => valid(%w[passed failed])), "infrastructure"],
      [record.merge("candidate" => {"status" => "invalid", "reason" => "invalid report arrays"}), "protocol_violation"],
      [record.merge("candidate" => nil), "unavailable"],
      [record.merge("execution_status" => "error"), "unavailable"],
      [record.merge("execution_status" => "timeout"), "unavailable"]
    ]
    cases.each do |data, category|
      result = promote(data)
      assert_unscored_policy result
      assert_equal "nl2repo-audited-v2", result.fetch("protocol")
      assert_equal category, result.fetch("failure_category")
      assert_nil result.fetch("quality_basis")
    end
  end

  def test_ambiguous_present_module_and_missing_proof_are_unscored
    ["missing_required_module", "checked_paths", "submission_digest"].each do |key|
      data = record
      data["candidate"] = collection
      data["candidate_inventory"][key] = (key == "submission_digest") ? "wrong" : false
      assert_unscored_policy promote(data)
    end
    data = record
    data["candidate"] = collection
    data.delete("candidate_inventory")
    assert_unscored_policy promote(data)
  end

  def test_reference_failure_binding_mismatch_and_timeout_are_unscored
    data = record
    data["reference"] = valid(%w[failed passed])
    assert_unscored_policy promote(data)
    data = record
    data["binding"] = @binding.merge("submission_digest" => "wrong")
    assert_unscored_policy promote(data)
    data = record
    data["execution_status"] = "timeout"
    result = promote(data)
    assert_unscored_policy result
    assert_equal "timeout", result.fetch("execution_status")
  end

  def test_forged_replayed_and_different_request_evidence_is_unscored
    assert_unscored_policy @policy.call(request: @request, evidence: record)
    token = @transport.issue(@request, record)
    assert_equal 1.0, @policy.call(request: @request, evidence: token).fetch("score")
    assert_unscored_policy @policy.call(request: @request, evidence: token)
    token = @transport.issue(@request, record)
    assert_unscored_policy @policy.call(request: @request.dup.freeze, evidence: token)
  end

  def test_partial_collection_cannot_be_promoted_to_zero
    [nil, @ids, []].each do |collected|
      data = record
      data["candidate"] = collection
      data["candidate"]["collected"] = collected
      data["candidate"]["tests"] = {} if collected == []
      assert_unscored_policy promote(data)
    end
  end

  def test_wrong_inventory_and_inconsistent_counts_stay_unscored
    data = record
    data["expected_nodeids"] = [@ids.first]
    assert_unscored_policy promote(data)
    data = record
    data["candidate"]["counts"]["passed"] = 999
    assert_unscored_policy promote(data)
    data = record
    data["protocol"] = "official"
    assert_unscored_policy promote(data)
  end
end

class NL2RepoAuditedAdapterDispatchTest < NL2RepoTest
  def test_loaded_grading_source_changes_fail_closed_with_restart_reason
    sources = [AgentRuntime::Benchmarks::NL2RepoAuditedGrader,
      AgentRuntime::Benchmarks::AuditedResults, AgentRuntime::Benchmarks::NL2RepoAuditedPromotion, Adapter]
    original_file = Digest::SHA256.method(:file)
    sources.each do |source|
      in_tmp do |root|
        store = AgentRuntime::Store.new(File.join(root, "store"))
        grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: store)
        path = source::SOURCE_PATH
        Digest::SHA256.define_singleton_method(:file) do |value, *args|
          (value == path) ? Struct.new(:hexdigest).new("0" * 64) : original_file.call(value, *args)
        end
        if source == Adapter
          adapter = Adapter.new(root: File.join(root, ".agru/nl2repo"), store: store, audited_grader: grader)
          error = assert_raises(AgentRuntime::Error) { adapter.grade_submission({}) }
        else
          error = assert_raises(AgentRuntime::Error) { grader.identity }
          evidence = grader.grade(submission: {}, binding: {}, expected_nodeids: [], request: {})
          result = AgentRuntime::Benchmarks::NL2RepoAuditedPromotion.new(transport: grader).call(request: {}, evidence: evidence)
          assert_nil result.fetch("score")
        end
        assert_includes error.message, "restart required"
      ensure
        Digest::SHA256.define_singleton_method(:file, original_file)
      end
    end
  end

  def test_validator_and_promotion_source_changes_rebind_grading_procedure
    in_tmp do |root|
      _, manifest, path = fixture(root)
      cases = AgentRuntime::Benchmarks::NL2RepoTestManifest.new
      manifest["revision"] = cases.identity.fetch("dataset_revision")
      File.write(path, JSON.generate(manifest))
      store = AgentRuntime::Store.new(File.join(root, "store"))
      candidate = File.join(root, "candidate")
      FileUtils.mkdir_p(candidate)
      submission = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: candidate)
      transport = NL2RepoAuditedPromotionPolicyTest::Transport.new
      source_identity = transport.identity
      transport.define_singleton_method(:identity) { source_identity.dup }
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"), store: store, audited_grader: transport)
      task = {"id" => "retrying", "specification_digest" => cases.identity.fetch("specification_sha256")}
      # This focused test isolates procedure binding; authentic task rejection is tested separately.
      adapter.define_singleton_method(:authentic_task!) { |value| value }
      original = adapter.prepare_grading_request(task: task, submission: submission, limits: {})
      %w[validator_sha256 promotion_sha256].each do |key|
        previous = source_identity.fetch(key)
        source_identity[key] = "9" * 64
        changed = adapter.prepare_grading_request(task: task, submission: submission, limits: {})
        refute_equal original.fetch("audited_binding").fetch("procedure_digest"), changed.fetch("audited_binding").fetch("procedure_digest")
        refute_equal original.fetch("request_digest"), changed.fetch("request_digest")
        source_identity[key] = previous
      end
    end
  end

  def test_copied_collector_must_match_request_digest_before_execution
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "store"))
      runner = Object.new
      runner.define_singleton_method(:call) { |**| raise "container must not launch" }
      grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: store, process_runner: runner)
      result = grader.send(:execute, repository: root, binding: {"collector_digest" => "0" * 64})
      assert_includes result.fetch("error"), "collector source changed since request"
    end
  end

  def test_audited_request_rejects_unpinned_specification_before_transport
    in_tmp do |root|
      _, manifest, path = fixture(root)
      manifest.fetch("tasks").first["id"] = "retrying"
      File.write(path, JSON.generate(manifest))
      store = AgentRuntime::Store.new(File.join(root, "store"))
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"),
        store: store, audited_grader: NL2RepoAuditedPromotionPolicyTest::Transport.new)
      adapter.prepare(allow_download: true)
      task = adapter.load_task("retrying")
      candidate = File.join(root, "candidate")
      FileUtils.mkdir_p(candidate)
      File.write(File.join(candidate, "retrying.py"), "# submitted bytes\n")
      submission = AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: candidate)
      error = assert_raises(ArgumentError) do
        adapter.prepare_grading_request(task: task, submission: submission, limits: {"timeout" => 10})
      end
      assert_equal "audited task specification or revision mismatch", error.message
    end
  end
end
