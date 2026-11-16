require "json"
require "digest"

# Checks submitted evidence integrity only, never executes or fabricates results.
errors = []
begin
  raise ArgumentError, "usage: ruby script/m12cs2_reconstruct.rb REPORT.json" unless ARGV.length == 1
  report_path = File.realpath(ARGV.first)
  root = File.dirname(report_path)
  report = JSON.parse(File.read(report_path))
  raise ArgumentError, "unsupported schema_version" unless report.fetch("schema_version") == 1
  errors << "report status must be accepted" unless report["status"] == "accepted"
  identity = report.fetch("identity")
  raise ArgumentError, "invalid runtime_commit" unless identity.fetch("runtime_commit").is_a?(String) && identity["runtime_commit"].match?(/\A[0-9a-f]{40}\z/)
  raise ArgumentError, "invalid configured_image" unless identity.fetch("configured_image").is_a?(String) && identity["configured_image"].match?(/\A(?:sha256:|[a-z0-9][a-z0-9._\/:-]*@sha256:)[0-9a-f]{64}\z/)
  %w[supervisor_sha256 mode_catalog_sha256].each do |key|
    raise ArgumentError, "invalid #{key}" unless identity.fetch(key).is_a?(String) && identity[key].match?(/\A[0-9a-f]{64}\z/)
  end
  verify = lambda do |artifact|
    raise ArgumentError, "artifact must be an object" unless artifact.is_a?(Hash)
    path = artifact.fetch("path")
    sha = artifact.fetch("sha256")
    raise ArgumentError, "invalid relative artifact path" unless path.is_a?(String) && !path.empty? && !Pathname.new(path).absolute? && !path.include?("\0") && path.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }
    raise ArgumentError, "invalid artifact sha256" unless sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/)
    actual = File.realpath(File.join(root, path))
    raise ArgumentError, "artifact escapes report directory" unless actual.start_with?(root + File::SEPARATOR)
    raise ArgumentError, "artifact must be a nonempty regular file" unless File.file?(actual) && File.size(actual).positive?
    raise ArgumentError, "artifact hash mismatch: #{path}" unless Digest::SHA256.file(actual).hexdigest == sha
  end
  cases = report.fetch("cases")
  raise ArgumentError, "cases must be objects" unless cases.is_a?(Array) && cases.all? { |row| row.is_a?(Hash) }
  ids = cases.map { |row| row.fetch("id") }
  raise ArgumentError, "case IDs must be exactly integers 1..20, without duplicates" unless ids.all? { |id| id.is_a?(Integer) } && ids.sort == (1..20).to_a
  cases.each do |row|
    raise ArgumentError, "case #{row.fetch("id")} must pass" unless row["status"] == "pass"
    artifacts = row.fetch("artifacts")
    raise ArgumentError, "nonempty case artifacts required" unless artifacts.is_a?(Array) && !artifacts.empty?
    artifacts.each { |artifact| verify.call(artifact) }
  end
  parity = report.fetch("parity")
  raise ArgumentError, "parity must contain single/fixed/dsl exactly once" unless parity.is_a?(Array) && parity.all? { |row| row.is_a?(Hash) } && parity.map { |row| row.fetch("arm") }.sort == %w[dsl fixed single]
  parity.each do |row|
    expected = (row.fetch("arm") == "single") ? 1 : 3
    raise ArgumentError, "invalid invoked_count for #{row.fetch("arm")}" unless row.fetch("invoked_count").is_a?(Integer) && row["invoked_count"] == expected
    %w[artifact grade regrade].each { |key| verify.call(row.fetch(key)) }
  end
rescue => error
  errors << "#{error.class}: #{error.message}"
end
puts JSON.generate({"schema_version" => 1, "outcome" => errors.empty? ? "pass" : "fail",
  "scope" => "Submitted evidence integrity only; not independent proof of claimed outcomes or an authorization to freeze.", "errors" => errors})
exit(errors.empty? ? 0 : 1)
