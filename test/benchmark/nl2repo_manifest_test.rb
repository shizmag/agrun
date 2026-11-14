require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_test_manifest"

class NL2RepoManifestTest < Minitest::Test
  Manifest = AgentRuntime::Benchmarks::NL2RepoTestManifest
  MANIFEST_PATH = File.expand_path("../../benchmarks/nl2repo/retrying-test-manifest.json", __dir__)
  EXPECTED_IDENTITIES = {
    "TestStopConditions" => %w[test_legacy_explicit_stop_type test_never_stop test_stop_after_attempt test_stop_after_delay test_stop_func],
    "TestWaitConditions" => %w[test_exponential test_exponential_with_max_wait test_exponential_with_max_wait_and_multiplier test_fixed_sleep test_incrementing_sleep test_legacy_explicit_wait_type test_no_sleep test_random_sleep test_random_sleep_without_min test_wait_func],
    "TestDecoratorWrapper" => %w[test_defaults test_retry_if_exception_of_type test_with_stop_on_exception test_with_stop_on_return_value test_with_wait test_wrapped_exception],
    "TestBeforeAfterAttempts" => %w[test_after_attempts test_before_attempts]
  }.flat_map { |klass, methods| methods.map { |method| "test_retrying.py::#{klass}::#{method}" } }.freeze

  def manifest_data
    JSON.parse(File.read(MANIFEST_PATH))
  end

  def test_manifest_binds_official_sources_and_actual_reference_collection
    manifest = manifest_data
    assert_equal 1, manifest.fetch("schema_version")
    assert_equal "retrying", manifest.fetch("task_id")
    assert_equal "781a1da1ee41fb8edb0bed22f586d69111610edf", manifest.fetch("dataset_revision")
    assert_equal "sha256:1302235420db9d34955c42273ebaf23df8bbee31ceeaf3c336347f54b64146fe", manifest.fetch("image_digest")
    assert_equal "cd41306283b97f81d9cb8ec14985b47acf973dea92f492b53a4e1aaa796a4168", manifest.fetch("specification_sha256")
    assert_equal "6d6286fc485273ba8b434afbf3f754f3f69321281bd94fd1f08b88a9171e056f", manifest.fetch("test_source_sha256")
    assert_equal "test_retrying.py", manifest.fetch("test_path")
    assert_equal "d8f1cc7e269fe908cae965fb9338d3625c56c9e56a35435dcb6f78ee74a53e0a", manifest.fetch("reference").fetch("module_sha256")
    assert_equal 0, manifest.fetch("reference_collection").fetch("exit_code")
    assert_equal 23, manifest.fetch("reference_collection").fetch("collected")
    assert_equal 23, manifest.fetch("reference_validation").fetch("call_passed")
    assert_equal [], manifest.fetch("reference_validation").fetch("nonpassed_reports")
  end

  def test_all_reference_identities_are_exact_unique_and_not_inferred_from_metadata
    tests = manifest_data.fetch("tests")
    identities = tests.map { |entry| entry.fetch("nodeid") }
    assert_equal EXPECTED_IDENTITIES, identities
    assert_equal 23, identities.uniq.length
    assert tests.all? { |entry| entry.key?("parameter_id") && entry["parameter_id"].nil? }
  end

  def test_api_exposes_frozen_expected_nodeids_and_source_bound_identity
    manifest = Manifest.new
    assert_equal EXPECTED_IDENTITIES, manifest.expected_nodeids
    assert_equal EXPECTED_IDENTITIES, manifest.nodeids
    assert_equal "nl2repo-audited-v2", manifest.identity.fetch("protocol_id")
    assert_equal Digest::SHA256.file(MANIFEST_PATH).hexdigest, manifest.digest
    assert manifest.expected_nodeids.frozen?
    assert manifest.expected_nodeids.all?(&:frozen?)
    identity = manifest.identity
    assert_equal Digest::SHA256.file(MANIFEST_PATH).hexdigest, identity.fetch("manifest_sha256")
    assert_equal manifest_data.fetch("test_source_sha256"), identity.fetch("test_source_sha256")
    assert identity.frozen?
    assert identity.values.all?(&:frozen?)
  end

  def test_collection_validation_accepts_exact_set_in_any_order
    manifest = Manifest.new
    assert_equal true, manifest.validate_collection!(nodeids: EXPECTED_IDENTITIES.reverse,
      test_source_sha256: manifest_data.fetch("test_source_sha256"))
    assert_equal true, manifest.validate_collection!(nodeids: EXPECTED_IDENTITIES,
      test_source_sha256: manifest_data.fetch("test_source_sha256"),
      parameter_ids: EXPECTED_IDENTITIES.to_h { |nodeid| [nodeid, nil] })
  end

  def test_collection_validation_rejects_missing_extra_duplicate_wrong_root_and_parameter_aliases
    manifest = Manifest.new
    invalid = [nil, "23 passed", [], EXPECTED_IDENTITIES[0...-1],
      EXPECTED_IDENTITIES + [EXPECTED_IDENTITIES.first],
      EXPECTED_IDENTITIES + ["test_retrying.py::extra"],
      EXPECTED_IDENTITIES.map { |nodeid| "/tmp/private/#{nodeid}" },
      EXPECTED_IDENTITIES.map { |nodeid| "private/#{nodeid}" },
      EXPECTED_IDENTITIES.map { |nodeid| "#{nodeid}[parameter]" }]
    invalid.each do |nodeids|
      assert_raises(ArgumentError) do
        manifest.validate_collection!(nodeids: nodeids, test_source_sha256: manifest_data.fetch("test_source_sha256"))
      end
    end
  end

  def test_collection_validation_rejects_source_mismatch_and_parameter_mapping_mismatch
    manifest = Manifest.new
    [nil, "0" * 64].each do |digest|
      assert_raises(ArgumentError) do
        manifest.validate_collection!(nodeids: EXPECTED_IDENTITIES, test_source_sha256: digest)
      end
    end
    [{}, EXPECTED_IDENTITIES.to_h { |nodeid| [nodeid, "invented"] }, []].each do |mapping|
      assert_raises(ArgumentError) do
        manifest.validate_collection!(nodeids: EXPECTED_IDENTITIES,
          test_source_sha256: manifest_data.fetch("test_source_sha256"), parameter_ids: mapping)
      end
    end
  end

  def test_manifest_validation_rejects_changed_pins_unknown_fields_and_untrusted_collections
    mutations = [
      ->(data) { data["schema_version"] = 2 },
      ->(data) { data["task_id"] = "other" },
      ->(data) { data["dataset_revision"] = "0" * 40 },
      ->(data) { data["image_digest"] = "sha256:" + "0" * 64 },
      ->(data) { data["specification_sha256"] = "0" * 64 },
      ->(data) { data["test_source_sha256"] = "0" * 64 },
      ->(data) { data["reference"]["module_sha256"] = "0" * 64 },
      ->(data) { data["reference_collection"]["exit_code"] = 2 },
      ->(data) { data["reference_collection"]["collected"] = 22 },
      ->(data) { data["reference_validation"]["call_passed"] = 22 },
      ->(data) { data["tests"].pop },
      ->(data) { data["tests"][0] = data["tests"][1] },
      ->(data) { data["tests"][0]["parameter_id"] = "invented" },
      ->(data) { data["pytest_args"] = ["-k", "test_defaults"] },
      ->(data) { data["selection"] = {"exclude" => [EXPECTED_IDENTITIES.first]} },
      ->(data) { data["unexpected"] = true }
    ]
    in_tmp do |dir|
      path = File.join(dir, "manifest.json")
      mutations.each do |mutate|
        data = manifest_data
        mutate.call(data)
        File.write(path, JSON.generate(data))
        assert_raises(ArgumentError) { Manifest.new(path: path) }
      end
      ["not json", "[]", "null"].each do |bytes|
        File.write(path, bytes)
        assert_raises(ArgumentError) { Manifest.new(path: path) }
      end
    end
  end

  def test_protocol_registry_appends_scoped_v2_without_promoting_historical_records
    registry = JSON.parse(File.read(File.expand_path("../../benchmarks/nl2repo/protocols.json", __dir__)))
    legacy, v1, v2 = registry.fetch("protocols")
    assert_equal "nl2repo-legacy-781a1da1ee41fb8edb0bed22f586d69111610edf", legacy.fetch("id")
    assert_equal "nl2repo-audited-v1", v1.fetch("id")
    assert_equal false, legacy.fetch("authoritative_score_available")
    assert_equal false, v1.fetch("authoritative_score_available")
    assert_equal "nl2repo-audited-v2", v2.fetch("id")
    assert_equal ["retrying"], v2.fetch("task_ids")
    assert_equal "benign_ordinary_submissions", v2.fetch("trust_scope")
    assert_equal Manifest.new.digest, v2.fetch("manifest_sha256")
    assert_equal 23, v2.fetch("expected_cases")
    assert_equal false, v2.fetch("authoritative_score_available")
  end
end
