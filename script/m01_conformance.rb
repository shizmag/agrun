#!/usr/bin/env ruby
require "bundler/setup"
require "optparse"
require_relative "../test/support/m01_harness"

options = {suite: "conformance"}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/m01_conformance.rb [--suite conformance|acceptance|all] [--output DIRECTORY]"
  parser.on("--suite SUITE", %w[conformance acceptance all]) { |suite| options[:suite] = suite }
  parser.on("--output DIRECTORY") { |directory| options[:output] = File.expand_path(directory) }
end.parse!
root = options[:output] || Dir.mktmpdir("agru-m01-conformance-")
FileUtils.mkdir_p(root)
cases = case options[:suite]
when "acceptance" then M01Harness::ACCEPTANCE
when "all" then M01Harness::ACCEPTANCE.merge(M01Harness::CONFORMANCE)
else M01Harness::CONFORMANCE
end
results = cases.keys.map do |id|
  directory = File.join(root, id)
  raise ArgumentError, "case evidence already exists: #{directory}" if File.exist?(directory)
  result = M01Harness.run(id, root: directory)
  puts "#{if result["match"]
            "MATCH"
          else
            result["error"] ? "ERROR" : "MISMATCH"
          end} #{id}"
  result
end
summary = {"schema_version" => 1, "offline" => true, "suite" => options[:suite],
           "planned" => cases.size, "executed" => results.size,
           "core_count" => cases.keys.map { |id| id.split(".").first }.uniq.size,
           "matching" => results.count { |r| r["match"] }, "mismatched" => results.count { |r| !r["match"] && !r["error"] },
           "errored" => results.count { |r| r["error"] }, "results" => results}
path = File.join(root, "conformance.json")
File.write(path, JSON.pretty_generate(summary) + "\n")
puts "#{summary["matching"]}/#{summary["executed"]} match; #{summary["mismatched"]} mismatched; #{summary["errored"]} errored"
puts "Evidence: #{path}"
exit(if summary["errored"].positive?
  2
else
  summary["mismatched"].positive? ? 1 : 0
end)
