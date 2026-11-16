require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/solvers"

class ComparativeSolversTest < Minitest::Test
  class RecordingAdapter
    attr_reader :requests

    def initialize
      @requests = []
    end

    def execute(request)
      @requests << request
      AgentRuntime::Result.new(status: "success", outputs: {"repository" => request.inputs.fetch("repository"), "text" => "role result"})
    end
  end

  def test_composed_roles_receive_task_profile_and_typed_plan
    in_tmp do |root|
      repository = File.join(root, "source")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "task.txt"), "public")
      adapter = RecordingAdapter.new
      solver = AgentRuntime::Benchmarks::Solvers::ComparativeDSL.new(store: AgentRuntime::Store.new(File.join(root, "store")), adapter: adapter, live: true)
      profile = {"id" => "test"}
      task = Struct.new(:repository, :instruction).new(repository, "Implement public requirement")
      result = solver.solve(task: task, model: "test", budget: {"timeout" => 10, "model_profile" => profile}, workspace: File.join(root, "workspace"))
      assert_equal "success", result.fetch("status")
      assert_equal 3, adapter.requests.size
      adapter.requests.each do |request|
        assert_includes request.config.fetch("prompt"), task.instruction
        assert_equal profile, request.config.fetch("model_profile")
        assert_operator request.timeout, :<=, 10
      end
      assert_equal "role result", adapter.requests[1].inputs.fetch("plan")
      assert_includes adapter.requests[1].config.fetch("prompt"), '"plan":"role result"'
      assert_includes adapter.requests.last.config.fetch("prompt"), '"implementation":"role result"'
      inventory = JSON.parse(adapter.requests[1].inputs.fetch("inventory"))
      assert_equal "inventory", inventory.fetch("kind")
      assert_equal "not_evaluated", inventory.fetch("quality_verdict")
      validation = JSON.parse(adapter.requests.last.inputs.fetch("validation"))
      assert_equal "validate", validation.fetch("kind")
      assert_equal AgentRuntime::Store.manifest(repository), validation.fetch("manifest")
      assert_includes adapter.requests.last.config.fetch("prompt"), "Independently verify"
    end
  end

  def test_reviewer_repository_mutation_is_failure
    in_tmp do |root|
      adapter = RecordingAdapter.new
      def adapter.execute(request)
        File.write(File.join(request.inputs.fetch("repository"), "mutation"), "not allowed")
        AgentRuntime::Result.new(status: "success", outputs: {"repository" => request.inputs.fetch("repository"), "text" => "review"})
      end
      request = AgentRuntime::Request.new(inputs: {"repository" => root}, config: {"role" => "reviewer"}, timeout: 600)
      result = AgentRuntime::Benchmarks::Solvers::RoleAdapter.new(adapter, "public task", 600).execute(request)
      assert_equal "failure", result.status
      assert_equal "reviewer_mutation", result.error.fetch("type")
    end
  end

  def test_expired_shared_deadline_does_not_dispatch_next_role
    adapter = RecordingAdapter.new
    wrapper = AgentRuntime::Benchmarks::Solvers::RoleAdapter.new(adapter, "task", -1)
    request = AgentRuntime::Request.new(inputs: {}, config: {"role" => "coder"}, timeout: 600)
    assert_equal "timeout", wrapper.execute(request).status
    assert_empty adapter.requests
  end

  def test_private_task_fields_are_rejected_before_workflow_dispatch
    in_tmp do |root|
      adapter = RecordingAdapter.new
      solver = AgentRuntime::Benchmarks::Solvers::FixedWorkflow.new(store: AgentRuntime::Store.new(File.join(root, "store")), adapter: adapter, live: true)
      task = {"id" => "task", "benchmark" => "test", "instruction" => "public", "specification_digest" => "digest", "metadata" => {}, "availability" => "available", "hidden_procedure" => "secret"}
      assert_raises(ArgumentError) { solver.solve(task: task, model: "test", budget: {"timeout" => 600}, workspace: root) }
      assert_empty adapter.requests
    end
  end

  def test_failed_dsl_extracts_current_partial_repository
    in_tmp do |root|
      repository = File.join(root, "source")
      FileUtils.mkdir_p(repository)
      adapter = RecordingAdapter.new
      def adapter.execute(request)
        File.write(File.join(request.inputs.fetch("repository"), "partial"), "current failure")
        AgentRuntime::Result.new(status: "failure", outputs: {"repository" => request.inputs.fetch("repository"), "text" => "partial"}, error: "failure")
      end
      solver = AgentRuntime::Benchmarks::Solvers::ComparativeDSL.new(store: AgentRuntime::Store.new(File.join(root, "store")), adapter: adapter, live: true)
      task = Struct.new(:repository, :instruction).new(repository, "public task")
      result = solver.solve(task: task, model: "test", budget: {"timeout" => 600}, workspace: File.join(root, "work"))
      refute_equal "success", result.fetch("status")
      assert result.fetch("partial_repository_artifact")
      assert_equal "current failure", File.read(File.join(result.fetch("repository"), "partial"))
    end
  end

  def test_fixed_workflow_has_separate_roles_and_dsl_has_typed_handoffs
    fixed = AgentRuntime::Benchmarks::Solvers::FixedWorkflow.program
    composed = AgentRuntime::Benchmarks::Solvers::ComparativeDSL.program
    assert_equal %w[planner coder reviewer], fixed.fetch("steps").map { |step| step.fetch("id") }
    assert_equal "text", composed.fetch("steps").first.fetch("outputs").fetch("plan")
    coder = composed.fetch("steps").find { |step| step.fetch("id") == "coder" }
    assert_equal "planner.plan", coder.fetch("inputs").fetch("plan")
    assert_equal "inventory.inventory", coder.fetch("inputs").fetch("inventory")
    assert_equal %w[coder validate], composed.fetch("steps").last.fetch("needs").sort
    assert_equal 5, composed.fetch("steps").size
    refute_equal fixed, composed
    AgentRuntime::Compiler.validate!(fixed)
    AgentRuntime::Compiler.validate!(composed)
  end

  def test_imperative_workflow_preserves_failed_role_snapshot_without_runtime_dispatch
    in_tmp do |root|
      repository = File.join(root, "source")
      FileUtils.mkdir_p(repository)
      adapter = RecordingAdapter.new
      def adapter.execute(request)
        @requests << request
        File.write(File.join(request.inputs.fetch("repository"), "partial.txt"), "evidence")
        AgentRuntime::Result.new(status: "failure", outputs: {"repository" => request.inputs.fetch("repository")}, error: "role failed")
      end
      store = AgentRuntime::Store.new(File.join(root, "store"))
      solver = AgentRuntime::Benchmarks::Solvers::FixedWorkflow.new(store: store, adapter: adapter, live: true)
      def solver.compiled_program = raise("imperative workflow must not compile a graph")
      task = Struct.new(:repository, :instruction).new(repository, "public task")
      result = solver.solve(task: task, model: "test", budget: {"timeout" => 600}, workspace: File.join(root, "work"))
      assert_equal "failure", result.fetch("status")
      assert_equal 1, adapter.requests.size
      assert_operator adapter.requests.first.timeout, :>, 120
      assert result.fetch("partial_repository_artifact")
      assert_equal "evidence", File.read(File.join(result.fetch("repository"), "partial.txt"))
    end
  end
end
