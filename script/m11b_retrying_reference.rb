require "digest"
require "fileutils"
require "json"
require "net/http"

abort "explicit --allow-download required" unless ARGV == ["--allow-download"]
url = "https://files.pythonhosted.org/packages/ce/70/15ce8551d65b324e18c5aa6ef6998880f21ead51ebe5ed743c0950d7d9dd/retrying-1.3.4.tar.gz"
expected = "345da8c5765bd982b1d1915deb9102fd3d1f7ad16bd84a9700b85f64d24e8f3e"
uri = URI(url)
bytes = +"".b
Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
  http.request(Net::HTTP::Get.new(uri)) do |response|
    abort "source download failed" unless response.code == "200"
    response.read_body do |chunk|
      bytes << chunk
      abort "reference archive exceeds 1 MiB bound" if bytes.bytesize > 1_048_576
    end
  end
end
abort "reference archive digest mismatch" unless Digest::SHA256.hexdigest(bytes) == expected
root = File.expand_path("../.agru/nl2repo/reference", __dir__)
FileUtils.mkdir_p(root)
File.write(File.join(root, "retrying-1.3.4.tar.gz"), bytes, mode: "wb", perm: 0o600)
File.write(File.join(root, "provenance.json"), JSON.pretty_generate({"url" => url, "sha256" => expected,
  "pypi_metadata" => "https://pypi.org/pypi/retrying/1.3.4/json", "license" => "Apache 2.0",
  "upstream_license" => "https://raw.githubusercontent.com/rholder/retrying/master/LICENSE",
  "image_version" => "1.3.4-dev", "reference_version" => "1.3.4", "qualification" => "release baseline, not proven identical image source"}) + "\n")
puts "Verified Apache-declared retrying 1.3.4 release downloaded to private grading cache"
