require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/registry"
require_relative "../../lib/agent_runtime/benchmarks/adapter"

class BenchmarkRegistryTest < Minitest::Test
  def adapter
    Object.new.tap do |object|
      AgentRuntime::Benchmarks::Adapter::OPERATIONS.each do |operation|
        object.define_singleton_method(operation) { |*args, **kwargs| nil }
      end
    end
  end

  def test_registration_requires_all_seven_operations_and_rejects_duplicates
    registry = AgentRuntime::Benchmarks::Registry.new
    value = adapter
    registry.register("fixture", value)
    assert_same value, registry.fetch("fixture")
    assert_equal 7, AgentRuntime::Benchmarks::Adapter::OPERATIONS.length
    assert_raises(ArgumentError) { registry.register("fixture", value) }
    assert_raises(ArgumentError) { registry.register("invalid", Object.new) }
    assert_raises(KeyError) { registry.fetch("missing") }
  end

  def test_inheriting_unimplemented_base_operations_does_not_satisfy_contract
    registry = AgentRuntime::Benchmarks::Registry.new
    assert_raises(ArgumentError) { registry.register("abstract", AgentRuntime::Benchmarks::Adapter.new) }
  end

  def test_public_task_rejects_unknown_fields_instead_of_silently_leaking_them
    task = {"id" => "one", "benchmark" => "fixture", "instruction" => "Implement",
            "specification_digest" => "a" * 64, "metadata" => {}, "availability" => "available"}
    assert_equal task, AgentRuntime::Benchmarks::Adapter.public_task(task)
    %w[hidden_tests grader_path original_source repository].each do |key|
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::Adapter.public_task(task.merge(key => "secret")) }
    end
  end
end
