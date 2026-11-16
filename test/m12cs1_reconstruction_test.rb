require_relative "test_helper"
require "open3"
require "json"
require "digest"

class M12cs1ReconstructionTest < Minitest::Test
  SCRIPT = File.expand_path("../script/m12cs1_reconstruct.rb", __dir__)
  MANIFEST = File.expand_path("../sandbox/m12cs1-categories.json", __dir__)

  def fixture(dir)
    File.write(File.join(dir, "evidence.txt"), "offline fixture only")
    digest = Digest::SHA256.file(File.join(dir, "evidence.txt")).hexdigest
    {"schema_version" => 1, "categories" => JSON.parse(File.read(MANIFEST)).fetch("categories").map { |id|
      {"id" => id, "status" => "pass", "artifacts" => [{"path" => "evidence.txt", "sha256" => digest}]}
    }}
  end

  def reconstruct(dir, report)
    path = File.join(dir, "report.json")
    File.write(path, JSON.generate(report))
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, path)
    assert_empty err
    [JSON.parse(out), status]
  end

  def test_complete_verified_fixture_passes
    in_tmp do |dir|
      result, status = reconstruct(dir, fixture(dir))
      assert status.success?
      assert_equal "pass", result.fetch("outcome")
      assert_equal 24, result.fetch("category_count")
    end
  end

  def test_missing_duplicate_and_extra_categories_fail
    in_tmp do |dir|
      [:missing, :duplicate, :extra].each do |kind|
        report = fixture(dir)
        rows = report.fetch("categories")
        rows.pop if kind == :missing
        rows << rows.first.dup if kind == :duplicate
        rows.first["id"] = "unregistered" if kind == :extra
        result, status = reconstruct(dir, report)
        refute status.success?
        assert_equal "fail", result.fetch("outcome")
      end
    end
  end

  def test_nonpass_and_unverified_artifacts_fail
    in_tmp do |dir|
      %w[pending fail skipped unknown].each do |value|
        report = fixture(dir)
        report["categories"][0]["status"] = value
        result, status = reconstruct(dir, report)
        refute status.success?
        assert_equal "fail", result["outcome"]
      end
      [[], [{"path" => "missing", "sha256" => "0" * 64}],
        [{"path" => "evidence.txt", "sha256" => "0" * 64}],
        [{"path" => "../escape", "sha256" => "0" * 64}]].each do |artifacts|
        report = fixture(dir)
        report["categories"][0]["artifacts"] = artifacts
        result, status = reconstruct(dir, report)
        refute status.success?
        assert_equal "fail", result["outcome"]
      end
    end
  end

  def test_malformed_json_fails_closed
    in_tmp do |dir|
      path = File.join(dir, "bad.json")
      File.write(path, "{")
      out, _, status = Open3.capture3(RbConfig.ruby, SCRIPT, path)
      refute status.success?
      assert_equal "fail", JSON.parse(out).fetch("outcome")
    end
  end
end
