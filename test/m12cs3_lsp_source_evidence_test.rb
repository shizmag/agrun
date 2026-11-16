require_relative "test_helper"
require "digest"
require "open-uri"

class M12cs3LspSourceEvidenceTest < Minitest::Test
  def test_public_version_source_evidence
    skip "set AGRU_M12CS3_LSP_SOURCE=1 for public-source verification (network, no provider calls)" unless ENV["AGRU_M12CS3_LSP_SOURCE"] == "1"
    manifest = JSON.parse(File.read(File.expand_path("../sandbox/m12cs3-lsp-unavailability.json", __dir__)))
    commit = manifest.fetch("source_commit")
    tag = JSON.parse(URI.open("https://api.github.com/repos/anomalyco/opencode/git/ref/tags/v#{manifest.fetch("version")}", &:read))
    assert_equal commit, tag.fetch("object").fetch("sha")
    manifest.fetch("source").each do |source|
      url = manifest.fetch("source_url_template").gsub("{source_commit}", commit).gsub("{path}", source.fetch("path"))
      # Immutable HTTPS GitHub URL assembled exclusively from the checked-in evidence manifest.
      content = URI.open(url, &:read) # standard:disable Security/Open
      assert_equal source.fetch("sha256"), Digest::SHA256.hexdigest(content), source.fetch("path")
      assert_equal source.fetch("excerpt"), content.lines.fetch(source.fetch("line") - 1).chomp, source.fetch("path")
    end
  end
end
