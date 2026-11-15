require "json"
require "digest"

# Verifies submitted offline evidence, not the truth of a test's claimed outcome.
# Paths are relative to the report directory and may not escape it via symlinks.
errors = []
count = 0
begin
  raise ArgumentError, "usage: ruby script/m12cs1_reconstruct.rb REPORT.json" unless ARGV.length == 1
  report_path = File.realpath(ARGV.first)
  root = File.dirname(report_path)
  manifest = JSON.parse(File.read(File.expand_path("../sandbox/m12cs1-categories.json", __dir__)))
  expected = manifest.fetch("categories")
  raise ArgumentError, "invalid required category manifest" unless expected.size == 24 && expected.uniq.size == 24
  report = JSON.parse(File.read(report_path))
  raise ArgumentError, "unsupported report schema_version" unless report.fetch("schema_version") == 1
  rows = report.fetch("categories")
  raise ArgumentError, "categories must be an array of objects" unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
  count = rows.size
  ids = rows.map { |row| row.fetch("id") }
  errors << "missing categories: #{(expected - ids).join(", ")}" unless (expected - ids).empty?
  errors << "extra categories: #{(ids - expected).join(", ")}" unless (ids - expected).empty?
  errors << "duplicate category IDs" unless ids.uniq.size == ids.size
  rows.each do |row|
    id = row.fetch("id")
    errors << "#{id}: status is not pass" unless row["status"] == "pass"
    artifacts = row["artifacts"]
    unless artifacts.is_a?(Array) && !artifacts.empty?
      errors << "#{id}: nonempty artifacts required"
      next
    end
    artifacts.each do |artifact|
      raise ArgumentError, "artifact must be an object" unless artifact.is_a?(Hash)
      path = artifact.fetch("path")
      sha = artifact.fetch("sha256")
      raise ArgumentError, "invalid relative artifact path" unless path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.split("/").include?("..")
      raise ArgumentError, "invalid SHA-256" unless sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/)
      resolved = File.realpath(File.join(root, path))
      raise ArgumentError, "artifact escapes report directory" unless resolved.start_with?(root + File::SEPARATOR)
      raise ArgumentError, "artifact is not a regular file" unless File.file?(resolved)
      raise ArgumentError, "artifact SHA-256 mismatch" unless Digest::SHA256.file(resolved).hexdigest == sha
    rescue KeyError, ArgumentError, SystemCallError => e
      errors << "#{id}: #{e.message}"
    end
  end
rescue JSON::ParserError, KeyError, ArgumentError, TypeError, SystemCallError => e
  errors << e.message
end
puts JSON.pretty_generate({"schema_version" => 1, "outcome" => errors.empty? ? "pass" : "fail",
                           "category_count" => count, "errors" => errors,
                           "scope" => "Reported category statuses and artifact integrity only; not independent proof of containment or authorization to freeze/dispatch"})
exit(errors.empty? ? 0 : 1)
