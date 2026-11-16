require_relative "test_helper"
require "tmpdir"
require_relative "../lib/agent_runtime/benchmarks/comparative_experiment"

class IndependentFreezeAdversarialTest < Minitest::Test
  SOURCE = File.expand_path("../docs/evidence/research-pilot-2026-11-16/v2", __dir__)

  def test_portable_adversarial_mutations
    skip "research evidence unavailable" unless File.directory?(SOURCE)
    mutations = {
      "missing release" => ->(p) { p.delete("release_identity") },
      "corrupt release" => ->(p) { p["release_identity"]["files"].values.first.replace("0" * 64) },
      "different valid release" => ->(p) {
        identity = p["release_identity"]
        identity["files"][identity["files"].keys.first] = "0" * 64
        identity["content_digest"] = Digest::SHA256.hexdigest(JSON.generate(identity["files"]))
      },
      "duplicate checks" => ->(p) { p["verification"]["checks"] << p["verification"]["checks"].first.dup },
      "wrong named pair" => ->(p) { p["verification"]["checks"].first["original_grading_attempt_id"] = p["verification"]["checks"].first["regrade_attempt_id"] },
      "missing submission" => ->(p) { p["submissions"].pop },
      "duplicate submission" => ->(p) { p["submissions"] << p["submissions"].first.dup }
    }
    mutations.each do |name, mutate|
      Dir.mktmpdir("agru-freeze-negative") do |dir|
        payload = JSON.parse(File.read(File.join(SOURCE, "experiment.json")))
        mutate.call(payload)
        bytes = JSON.generate(payload)
        File.write(File.join(dir, "experiment.json"), bytes)
        File.write(File.join(dir, "SHA256SUMS"), "#{Digest::SHA256.hexdigest(bytes)}  experiment.json\n")
        assert_raises(ArgumentError, KeyError, name) { AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(dir) }
        puts "REJECT #{name} (outer checksum recomputed)"
      end
    end
    Dir.mktmpdir("agru-freeze-byte") do |dir|
      File.write(File.join(dir, "experiment.json"), File.binread(File.join(SOURCE, "experiment.json")) + " ")
      File.write(File.join(dir, "SHA256SUMS"), File.read(File.join(SOURCE, "SHA256SUMS")))
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(dir) }
      puts "REJECT byte tamper (original checksum)"
    end
  end
end
