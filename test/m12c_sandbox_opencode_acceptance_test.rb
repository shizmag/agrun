require_relative "test_helper"
require_relative "support/m12c_relay_docker"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require_relative "../lib/agent_runtime/adapters/sandbox_open_code_cli"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require_relative "../lib/agent_runtime/benchmarks/comparative_solvers"

class M12cSandboxOpenCodeAcceptanceTest < Minitest::Test
  def test_installed_agent_shell_and_native_read_through_three_architectures
    skip "explicit mock Docker acceptance opt-in required" unless ENV["AGRU_M12C_OPENCODE_ACCEPTANCE"] == "1"
    image = ENV.fetch("AGRU_M12C_AGENT_IMAGE")
    relay = M12cRelayDocker.new(script: ENV.fetch("AGRU_M12C_MOCK_SCRIPT", "default"))
    relay.start
    helper = File.expand_path("support/m12c_mock_relay.cjs", __dir__)
    policy = AgentRuntime::Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.relay_volume,
      helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
    runner = AgentRuntime::Execution::SandboxRunner.new(image: image,
      limits: {"cpus" => 1, "memory_bytes" => 1024 * 1024 * 1024, "pids" => 128, "tmpfs_bytes" => 128 * 1024 * 1024}, network_policy: policy)
    launch = AgentRuntime::Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
      executable_sha256: "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
      endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: true)
    adapter = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: runner, launch: launch)
    original_execute = adapter.method(:execute)
    observations = []
    adapter.define_singleton_method(:execute) do |request|
      original_execute.call(request).tap do |result|
        observations << result.logs
        warn result.logs.inspect if ENV["AGRU_M12C_DEBUG"] == "1"
      end
    end
    in_tmp do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "README.md"), "public native-read canary\n")
      store = AgentRuntime::Store.new(File.join(root, "store"))
      solvers = {
        "single-agent" => AgentRuntime::Benchmarks::Solvers::OpenCode.new(live: true, store: store, adapter: adapter),
        "fixed-workflow" => AgentRuntime::Benchmarks::Solvers::FixedWorkflow.new(live: true, store: store, adapter: adapter),
        "dsl" => AgentRuntime::Benchmarks::Solvers::ComparativeDSL.new(live: true, store: store, adapter: adapter)
      }
      solvers.each do |name, solver|
        workspace = File.join(root, name)
        FileUtils.mkdir_p(workspace)
        FileUtils.cp_r(source, File.join(workspace, "repository"))
        task = {"id" => "mock-boundary", "benchmark" => "mock", "specification_digest" => "a" * 64,
                "metadata" => {}, "availability" => "available",
                "instruction" => "Read README.md using native read, then run shell to write sandbox-positive.txt containing sandbox-positive."}
        result = solver.solve(task: task,
          model: launch.model, budget: {"timeout" => 90}, workspace: workspace)
        assert_equal "success", result.fetch("status"), "#{name}: #{result.inspect}"
        sandbox = observations.last.fetch("sandbox")
        assert_equal true, sandbox.fetch("cleanup").fetch("confirmed"), name
        export = sandbox.fetch("export")
        assert_match(/\A[0-9a-f]{64}\z/, export.fetch("digest"), name)
        assert_equal Digest::SHA256.hexdigest(JSON.generate(export.fetch("manifest"))), export.fetch("digest"), name
        assert_equal "public native-read canary\n", File.read(File.join(export.fetch("path"), "README.md")), name
        assert_equal "sandbox-positive\n", File.read(File.join(export.fetch("path"), "sandbox-positive.txt")), name
        assert_equal "public native-read canary\n", File.read(File.join(source, "README.md")), name
        refute File.exist?(File.join(source, "sandbox-positive.txt")), name
        events = observations.last.fetch("execution").fetch("events")
        read = events.find { |event| event.dig("part", "tool") == "read" }
        assert_equal "completed", read&.dig("part", "state", "status"), name
        shell = events.find { |event| event.dig("part", "tool") == "shell" }
        assert_equal "completed", shell&.dig("part", "state", "status"), name
        if ENV["AGRU_M12C_MOCK_SCRIPT"] == "native-subagent"
          child = events.find { |event| event.dig("part", "tool") == "subagent" }
          assert_equal "completed", child&.dig("part", "state", "status"), name
          refute_empty child.dig("part", "state", "output").to_s, name
        end
      end
    end
  ensure
    if relay && ENV["AGRU_M12C_DEBUG"] == "1"
      warn relay.logs("mock")
    end
    relay&.close
  end
end
