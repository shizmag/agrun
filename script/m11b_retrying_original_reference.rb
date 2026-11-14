require "digest"
require "fileutils"
require "json"
require "net/http"

abort "explicit --allow-download required" unless ARGV == ["--allow-download"]
commit = "1d5699348d707e377aad7488da6a8a1b48a65933"
root = File.expand_path("../.agru/nl2repo/reference/original-#{commit}", __dir__)
FileUtils.mkdir_p(root)
receipt = {"commit" => commit, "version" => "1.3.4-dev", "qualification" => "metadata-matching genuine upstream control, not proven benchmark historical source", "files" => {}}
%w[LICENSE NOTICE setup.py requirements.txt README.rst HISTORY.rst AUTHORS.rst retrying.py].each do |name|
  url = "https://raw.githubusercontent.com/rholder/retrying/#{commit}/#{name}"
  uri = URI(url)
  bytes = +"".b
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
    http.request(Net::HTTP::Get.new(uri)) do |response|
      abort "source download failed: #{name}" unless response.code == "200"
      response.read_body do |chunk|
        bytes << chunk
        abort "reference file exceeds 1 MiB bound" if bytes.bytesize > 1_048_576
      end
    end
  end
  abort "Apache license missing" if name == "LICENSE" && !bytes.include?("Apache License")
  File.write(File.join(root, name), bytes, mode: "wb", perm: 0o600)
  receipt["files"][name] = {"url" => url, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize}
end
File.write(File.join(root, "provenance.json"), JSON.pretty_generate(receipt) + "\n", mode: "w", perm: 0o600)
puts JSON.pretty_generate(receipt)
