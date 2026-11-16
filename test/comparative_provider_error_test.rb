require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/solvers"
require_relative "../lib/agent_runtime/benchmarks/comparative_solvers"

class ComparativeProviderErrorTest < Minitest::Test
  class FailedProvider
    def execute(request)
      AgentRuntime::Result.new(status: "failure", outputs: {}, error: {"type" => "sandbox", "message" => "provider_http_502"}, retry_safe: false)
    end
  end

  def test_fixed_and_dsl_preserve_stage_failure_at_solver_boundary
    in_tmp do |root|
      [AgentRuntime::Benchmarks::Solvers::FixedWorkflow, AgentRuntime::Benchmarks::Solvers::ComparativeDSL].each do |klass|
        workspace = File.join(root, klass.name.split("::").last)
        FileUtils.mkdir_p(File.join(workspace, "repository"))
        File.write(File.join(workspace, "repository", "README.md"), "public")
        solver = klass.new(live: true, store: AgentRuntime::Store.new(File.join(workspace, "store")), adapter: FailedProvider.new)
        result = solver.solve(task: {"id" => "offline", "benchmark" => "mock", "specification_digest" => "a" * 64, "availability" => "available", "instruction" => "read README", "metadata" => {}}, model: "offline", budget: {"timeout" => 10}, workspace: workspace)
        refute_equal "success", result["status"]
        assert_equal "provider_http_502", result.dig("error", "message"), result.inspect
      end
    end
  end
end
