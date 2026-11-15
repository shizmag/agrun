require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/opencode_launch"
require_relative "../lib/agent_runtime/benchmarks/live_cli"

class CatalogLiveLaunchTest < Minitest::Test
  def test_live_solver_selects_concrete_builtin_with_live_executor
    cli = AgentRuntime::Benchmarks::LiveCLI.new
    executor = Object.new
    store = Object.new
    {"single-agent" => AgentRuntime::Benchmarks::Solvers::OpenCode,
     "fixed-workflow" => AgentRuntime::Benchmarks::Solvers::FixedWorkflow,
     "dsl" => AgentRuntime::Benchmarks::Solvers::ComparativeDSL}.each do |id, klass|
      expected = {adapter: executor, live: true}
      expected[:store] = store unless id == "single-agent"
      klass.stub(:new, ->(**args) {
        assert_equal expected, args
        :selected
      }) do
        assert_equal :selected, cli.send(:live_solver, id, store: store, executor: executor)
      end
    end
    assert_raises(ArgumentError) { cli.send(:live_solver, "unknown", store: store, executor: executor) }
  end

  def test_live_cli_passes_resolved_manifest_profile_to_launch
    profile = {"id" => "custom", "provider" => "gateway", "model" => "opaque", "execution_kind" => "real_provider",
               "tool_policy" => {"endpoint" => "http://localhost:1234/v1", "route" => "opaque", "model_fallback" => false,
                                 "executable" => "/inert", "executable_sha256" => "a" * 64}}
    resolution = {"route" => {"provider" => "gateway", "wire_id" => "opaque", "endpoint" => "http://localhost:1234/v1"}, "variant" => {"parameters" => {}}}
    data = {"models" => [{"model_profile" => profile, "model_resolution" => resolution}],
            "limits" => {"timeout" => 10, "max_concurrent_sessions" => 1},
            "benchmark" => {"task_ids" => ["task"]}, "solver_ids" => ["single-agent"]}
    manifest = Struct.new(:data, :digest).new(data, "digest")
    authorization = Object.new
    authorization.define_singleton_method(:preflight!) do |scope:|
      raise "wrong route" unless scope.fetch("route") == "opaque"
    end
    previous = ENV["OMNIROUTE_API_KEY"]
    ENV["OMNIROUTE_API_KEY"] = "inert"
    constructor = lambda do |**args|
      assert_equal profile, args.fetch(:model_profile)
      assert_equal resolution, args.fetch(:model_resolution)
      raise ArgumentError, "launch reached without provider call"
    end
    AgentRuntime::Execution::OpenCodeLaunch.stub(:new, constructor) do
      error = assert_raises(ArgumentError) do
        AgentRuntime::Benchmarks::LiveCLI.new.send(:execute, "preflight", manifest, authorization, "unused")
      end
      assert_equal "launch reached without provider call", error.message
    end
  ensure
    previous ? ENV["OMNIROUTE_API_KEY"] = previous : ENV.delete("OMNIROUTE_API_KEY")
  end

  def test_exact_declared_route_and_endpoint_drive_configuration
    in_tmp do |workspace|
      executable = File.join(workspace, "opencode")
      File.write(executable, "fixture")
      profile = {"provider" => "gateway", "model" => "opaque/no-suffix", "execution_kind" => "real_provider",
                 "inference_parameters" => {"effort" => "custom"},
                 "tool_policy" => {"endpoint" => "http://localhost:1234/v1", "route" => "opaque/no-suffix", "model_fallback" => false}}
      evidence = {"route" => {"provider" => "gateway", "wire_id" => "opaque/no-suffix", "endpoint" => "http://localhost:1234/v1", "parameter_delivery" => "wire_id"},
                  "variant" => {"parameters" => {"effort" => "custom"}}}
      args = {executable: executable, executable_sha256: Digest::SHA256.file(executable).hexdigest,
              credential: "secret", model_profile: profile, model_resolution: evidence}
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(**args)
      profile["model"] = "mutated"
      assert_equal "gateway/opaque/no-suffix", launch.model_profile
      assert_includes launch.argv, "gateway/opaque/no-suffix"
      assert_equal "opaque/no-suffix", launch.scope.fetch("route")
      launch.with_environment(workspace: workspace) do |env|
        config = JSON.parse(File.read(env.fetch("OPENCODE_CONFIG")))
        assert_equal launch.model_profile, config.fetch("model")
        assert_equal "http://localhost:1234/v1", config.dig("providers", "gateway", "settings", "baseURL")
        assert_equal({"opaque/no-suffix" => {}}, config.dig("providers", "gateway", "models"))
      end
      profile["model"] = "opaque/no-suffix"
      evidence["route"]["parameter_delivery"] = "unknown"
      assert_raises(ArgumentError) { AgentRuntime::Execution::OpenCodeLaunch.new(**args) }
      evidence["route"]["parameter_delivery"] = "wire_id"
      profile["tool_policy"]["route"] = "different"
      assert_raises(ArgumentError) { AgentRuntime::Execution::OpenCodeLaunch.new(**args) }
    end
  end
end
