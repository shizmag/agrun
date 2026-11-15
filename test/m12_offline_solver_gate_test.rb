require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/experiment_runner"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require "rbconfig"

class M12OfflineSolverGateTest < Minitest::Test
  def test_nl2repo_gate_accepts_only_registered_pinned_builtin_fixture_solver
    in_tmp do |root|
      path = File.join(root, "fixture")
      File.write(path, "#!#{RbConfig.ruby}\nabort 'gate must never launch'\n")
      File.chmod(0o755, path)
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: path, fixture_sha256: Digest::SHA256.file(path).hexdigest)
      solver = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, adapter: adapter)
      config = {"execution_mode" => "offline", "solver_ids" => ["agent"], "models" => [{"id" => "fixture", "provider" => "fixture", "model_profile" => {"execution_kind" => "offline_fixture"}}]}
      benchmark = AgentRuntime::Benchmarks::Adapters::NL2Repo.allocate
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: AgentRuntime::Store.new(File.join(root, "store")), root: root, registry: nil, solvers: {"agent" => solver})
      assert_nil runner.send(:validate_offline!, config, benchmark)
      File.write(path, "#!#{RbConfig.ruby}\nabort 'changed fixture must not launch'\n")
      assert_raises(ArgumentError) { runner.send(:validate_offline!, config, benchmark) }
      real = AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true)
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: AgentRuntime::Store.new(File.join(root, "other")), root: root, registry: nil, solvers: {"agent" => real})
      assert_raises(ArgumentError) { runner.send(:validate_offline!, config, benchmark) }
      custom = Object.new
      custom.define_singleton_method(:offline_fixture?) { true }
      runner = AgentRuntime::Benchmarks::ExperimentRunner.new(store: AgentRuntime::Store.new(File.join(root, "third")), root: root, registry: nil, solvers: {"agent" => custom})
      assert_raises(ArgumentError) { runner.send(:validate_offline!, config, benchmark) }
    end
  end
end
