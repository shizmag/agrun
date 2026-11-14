require_relative "../test_helper"

class NL2RepoProtocolCatalogTest < Minitest::Test
  def test_protocol_definitions_do_not_claim_unobserved_authority
    catalog = JSON.parse(File.read(File.expand_path("../../benchmarks/nl2repo/protocols.json", __dir__)))
    revision = "781a1da1ee41fb8edb0bed22f586d69111610edf"
    assert_equal revision, catalog.fetch("dataset_revision")
    legacy, audited = catalog.fetch("protocols")
    assert_equal "nl2repo-legacy-#{revision}", legacy.fetch("id")
    assert_equal "parsed-passed-count", legacy.fetch("raw_score_unit")
    assert_equal "nl2repo-audited-v1", audited.fetch("id")
    refute_equal legacy.fetch("id"), audited.fetch("id")
    [legacy, audited, catalog.fetch("diagnostics")].each do |definition|
      assert_equal false, definition.fetch("authoritative_score_available")
    end
  end

  def test_selected_control_manifest_does_not_invent_reference_outcomes
    control = JSON.parse(File.read(File.expand_path("../../benchmarks/nl2repo/selected-task-controls.json", __dir__)))
    assert_equal "retrying", control.fetch("task_id")
    assert_equal 23, control.fetch("official_metadata").fetch("declared_test_case_count")
    image = control.fetch("image")
    assert_equal "sha256:1302235420db9d34955c42273ebaf23df8bbee31ceeaf3c336347f54b64146fe", image.fetch("digest")
    assert image.fetch("immutable_reference").end_with?("@#{image.fetch("digest")}")
    assert_equal "linux/amd64", image.fetch("registry_platform")
    assert_equal false, control.fetch("positive_control").fetch("validated")
  end
end
