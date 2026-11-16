require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/comparative_experiment"
require_relative "../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../lib/agent_runtime/benchmarks/registry"
require_relative "../lib/agent_runtime/benchmarks/comparative_cli"

class ComparativeExperimentTest < Minitest::Test
  def test_contract_tracks_image_and_schedule_but_not_execution_identity
    report = {"manifest" => {"experiment_id" => "first"}, "cells" => [],
              "simulation" => {"image" => "sha256:first", "attempts" => []},
              "schedule" => {"seed" => 1, "cell_order" => []}}
    contract = AgentRuntime::Benchmarks::ComparativeExperiment
    original = AgentRuntime::IR.digest(contract.frozen_contract(report))
    report["manifest"]["experiment_id"] = "second"
    report["run_id"] = "another-execution"
    assert_equal original, AgentRuntime::IR.digest(contract.frozen_contract(report))
    report["simulation"]["image"] = "sha256:second"
    refute_equal original, AgentRuntime::IR.digest(contract.frozen_contract(report))
    report["simulation"]["image"] = "sha256:first"
    report["schedule"]["seed"] = 2
    refute_equal original, AgentRuntime::IR.digest(contract.frozen_contract(report))
  end

  def test_regrades_and_freeze_integrity
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "store"))
      registry = AgentRuntime::Benchmarks::Registry.new
      registry.register("fixture", AgentRuntime::Benchmarks::FixtureAdapter.new(store: store))
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: store, root: File.join(root, "runs"), registry: registry,
        solvers: {"direct" => AgentRuntime::Benchmarks::FixtureSolvers.build("direct")})
      manifest = {"schema_version" => 1, "experiment_id" => "comparison", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["one"]},
                  "solver_ids" => ["direct"], "models" => [{"id" => "fixture"}], "repetitions" => 1, "limits" => {"timeout" => 10},
                  "execution_mode" => "offline", "subset_role" => "development"}
      experiment = AgentRuntime::Benchmarks::ComparativeExperiment.new(store: store, runner: runner)
      assert_raises(ArgumentError) { experiment.run(manifest: manifest, evidence_kind: "live_provider") }
      assert_raises(ArgumentError) { experiment.run(manifest: manifest, evidence_kind: "simulated_relay") }
      verification = experiment.run(manifest: manifest, evidence_kind: "offline_fixture")
      forged = Marshal.load(Marshal.dump(verification))
      forged.fetch("checks").first["regrade_attempt_id"] = forged.fetch("checks").first.fetch("original_grading_attempt_id")
      assert_raises(ArgumentError) { experiment.freeze(experiment_id: "comparison", destination: File.join(root, "forged"), verification: forged) }
      assert verification.fetch("verified")
      refute verification.fetch("provider_evidence")
      assert_equal 2, store.report("comparison").fetch("cells").first.fetch("grading_attempts").size
      destination = File.join(root, "freeze")
      experiment.freeze(experiment_id: "comparison", destination: destination, verification: verification)
      assert AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(destination).fetch("integrity_verified")
      assert_raises(Errno::EEXIST) { experiment.freeze(experiment_id: "comparison", destination: destination, verification: verification) }
      path = File.join(destination, "experiment.json")
      payload = JSON.parse(File.read(path))
      missing = Marshal.load(Marshal.dump(payload))
      missing["submissions"] = []
      missing_bytes = JSON.pretty_generate(missing) + "\n"
      File.write(path, missing_bytes)
      File.write(File.join(destination, "SHA256SUMS"), "#{Digest::SHA256.hexdigest(missing_bytes)}  experiment.json\n")
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(destination) }
      portable = Marshal.load(Marshal.dump(payload))
      portable.fetch("submissions").first.fetch("repository_manifest").first["content"] = ["modified"].pack("m0")
      portable_bytes = JSON.pretty_generate(portable) + "\n"
      File.write(path, portable_bytes)
      File.write(File.join(destination, "SHA256SUMS"), "#{Digest::SHA256.hexdigest(portable_bytes)}  experiment.json\n")
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(destination) }
      payload.fetch("report").fetch("cells").first.fetch("grading_attempts").last.fetch("request")["procedure_digest"] = "different"
      payload.fetch("verification")["report_digest"] = AgentRuntime::IR.digest(payload.fetch("report"))
      bytes = JSON.pretty_generate(payload) + "\n"
      File.write(path, bytes)
      File.write(File.join(destination, "SHA256SUMS"), "#{Digest::SHA256.hexdigest(bytes)}  experiment.json\n")
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(destination) }
      File.write(path, "tampered")
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ComparativeExperiment.verify_freeze(destination) }
      experiment.verify_regrades(experiment_id: "comparison", evidence_kind: "offline_fixture")
      assert_raises(ArgumentError) { experiment.freeze(experiment_id: "comparison", destination: File.join(root, "stale"), verification: verification) }
    end
  end

  def test_cli_rejects_missing_freeze
    _, error = capture_io do
      assert_equal 1, AgentRuntime::Benchmarks::ComparativeCLI.new.run(["verify", "/nonexistent/agru-freeze"])
    end
    assert_includes error, "No such file"
  end
end
