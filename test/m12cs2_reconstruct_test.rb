require_relative "test_helper"
require "open3"

class M12cs2ReconstructTest < Minitest::Test
  SCRIPT = File.expand_path("../script/m12cs2_reconstruct.rb", __dir__)

  def fixture(root)
    File.write(File.join(root, "evidence"), "offline evidence")
    artifact = {"path" => "evidence", "sha256" => Digest::SHA256.hexdigest("offline evidence")}
    {"schema_version" => 1, "status" => "accepted",
     "identity" => {"runtime_commit" => "a" * 40, "configured_image" => "sha256:#{"b" * 64}", "supervisor_sha256" => "c" * 64, "mode_catalog_sha256" => "d" * 64},
     "cases" => (1..20).map { |id| {"id" => id, "status" => "pass", "artifacts" => [artifact.dup]} },
     "parity" => %w[single fixed dsl].map { |arm| {"arm" => arm, "invoked_count" => ((arm == "single") ? 1 : 3), "artifact" => artifact.dup, "grade" => artifact.dup, "regrade" => artifact.dup} }}
  end

  def reconstruct(root, report)
    path = File.join(root, "report.json")
    File.write(path, JSON.generate(report))
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, path)
    assert_empty stderr
    [JSON.parse(stdout), status]
  end

  def test_complete_report_integrity_passes_without_claiming_truth_or_freeze
    in_tmp do |root|
      output, status = reconstruct(root, fixture(root))
      assert status.success?, output.inspect
      assert_equal "pass", output["outcome"]
      assert_match(/not independent proof/, output.fetch("scope"))
    end
  end

  def test_incomplete_duplicate_tampered_identity_and_architecture_reports_fail
    mutations = [
      ->(r) { r["cases"].pop },
      ->(r) { r["cases"][19]["id"] = 1 },
      ->(r) { r["cases"][0]["artifacts"][0]["sha256"] = "0" * 64 },
      ->(r) { r["identity"].delete("supervisor_sha256") },
      ->(r) { r["identity"]["runtime_commit"] = "short" },
      ->(r) { r["parity"][1]["invoked_count"] = 1 },
      ->(r) { r["parity"][0].delete("regrade") },
      ->(r) { r["status"] = "partial" },
      ->(r) { r["cases"][0]["artifacts"] = [] }
    ]
    mutations.each do |mutation|
      in_tmp do |root|
        report = fixture(root)
        mutation.call(report)
        output, status = reconstruct(root, report)
        refute status.success?, output.inspect
        assert_equal "fail", output["outcome"]
      end
    end
  end

  def test_symlink_escape_fails
    in_tmp do |outer|
      root = File.join(outer, "report")
      Dir.mkdir(root)
      report = fixture(root)
      File.write(File.join(outer, "outside"), "offline evidence")
      File.unlink(File.join(root, "evidence"))
      File.symlink(File.join(outer, "outside"), File.join(root, "evidence"))
      output, status = reconstruct(root, report)
      refute status.success?
      assert_match(/escapes/, output.fetch("errors").join)
    end
  end
end
