require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../script/m12cs3_environment_freeze"

class M12cs3EnvironmentFreezeTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("freeze-")
    git("init", "-q")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    File.write(File.join(@root, "runtime"), "runtime-v1")
    git("add", ".")
    git("commit", "-qm", "fixture")
    @spec = {"image" => "sha256:#{"a" * 64}", "requested_model" => "cx/gpt-6-luna-low"}
    M12cs3EnvironmentFreeze::BINDINGS.each { |key| @spec[key] = "runtime" }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @root, *args)
    raise out unless status.success?
    out.strip
  end

  def test_candidate_round_trip_is_not_acceptance
    manifest = M12cs3EnvironmentFreeze.create(@root, @spec)
    assert_equal "candidate", manifest.fetch("status")
    assert M12cs3EnvironmentFreeze.validate(@root, manifest)
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.validate(@root, manifest.merge("status" => "accepted")) }
  end

  def test_dirty_runtime_and_new_commit_invalidate_freeze
    manifest = M12cs3EnvironmentFreeze.create(@root, @spec)
    File.write(File.join(@root, "runtime"), "runtime-v2")
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.validate(@root, manifest) }
    git("add", ".")
    git("commit", "-qm", "changed")
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.validate(@root, manifest) }
  end

  def test_candidate_creation_rejects_dirty_tracked_and_untracked_files
    File.write(File.join(@root, "runtime"), "dirty")
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.create(@root, @spec) }
    File.write(File.join(@root, "runtime"), "runtime-v1")
    File.write(File.join(@root, "untracked"), "execution input")
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.create(@root, @spec) }
  end

  def test_standalone_cli_creates_from_clean_fixture
    input = File.join(File.dirname(@root), "#{File.basename(@root)}-spec.json")
    File.write(input, JSON.generate(@spec))
    script = File.expand_path("../script/m12cs3_environment_freeze.rb", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, "create", @root, input)
    assert status.success?, stderr
    assert_equal "candidate", JSON.parse(stdout).fetch("status")
  ensure
    File.unlink(input) if input && File.exist?(input)
  end

  def test_digest_and_fixture_mislabel_are_rejected
    manifest = M12cs3EnvironmentFreeze.create(@root, @spec)
    manifest["requested_model"] = "other"
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.validate(@root, manifest) }
    @spec["evidence_kind"] = "live"
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.create(@root, @spec) }
  end

  def test_missing_binding_and_external_symlink_are_rejected
    assert_raises(KeyError) { M12cs3EnvironmentFreeze.create(@root, @spec.except("scientific_protocol")) }
    File.symlink("/etc/hosts", File.join(@root, "escape"))
    git("add", ".")
    git("commit", "-qm", "symlink")
    @spec["scientific_protocol"] = "escape"
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.create(@root, @spec) }
  end

  def test_release_requires_current_environment_gates_and_independent_review
    candidate = M12cs3EnvironmentFreeze.create(@root, @spec)
    evidence = {"candidate_sha256" => candidate.fetch("sha256"), "runtime_commit" => candidate.fetch("runtime_commit"), "evidence_kind" => "installed_mock", "capability_claim" => false,
                "gates" => M12cs3EnvironmentFreeze::GATES.to_h { |gate| [gate, true] }, "artifacts" => {"parity" => "a" * 64}}
    review = {"verdict" => "pass", "independent" => true, "reviewer" => "review-session", "producer" => "acceptance-session", "evidence_sha256" => M12cs3EnvironmentFreeze.digest(evidence)}
    release = M12cs3EnvironmentFreeze.release(@root, candidate, evidence, review)
    assert M12cs3EnvironmentFreeze.validate_release(@root, candidate, evidence, review, release)
    bad = evidence.merge("capability_claim" => true)
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.release(@root, candidate, bad, review) }
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.release(@root, candidate, evidence, review.merge("independent" => false)) }
    M12cs3EnvironmentFreeze::GATES.each do |gate|
      bad = evidence.merge("gates" => evidence.fetch("gates").merge(gate => false))
      assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.release(@root, candidate, bad, review) }
    end
    File.write(File.join(@root, "runtime"), "stale environment")
    assert_raises(ArgumentError) { M12cs3EnvironmentFreeze.validate_release(@root, candidate, evidence, review, release) }
  end
end
