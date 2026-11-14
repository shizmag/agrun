require_relative "test_helper"

class RuntimeTest < Minitest::Test
  def graph(steps)
    {"schema_version" => 1, "name" => "test", "inputs" => {}, "executors" => {"x" => {"adapter" => "custom", "config" => {}}}, "steps" => steps, "outputs" => {"result" => "c.answer"}}
  end

  def step(id, needs: [], config: {}, inputs: {}, outputs: {"answer" => "text"}, retries: 0, timeout: 2)
    {"id" => id, "executor" => "x", "inputs" => inputs, "outputs" => outputs, "needs" => needs, "config" => config, "timeout" => timeout, "retries" => retries}
  end

  def test_parallel_overlap_and_authoritative_dependencies
    in_tmp do |dir|
      mutex = Mutex.new
      entered = []
      finished = []
      overlap = Queue.new
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |request|
        if request.step_id == "c"
          raise "premature dependency" unless mutex.synchronize { finished.sort == %w[a b] }
        else
          mutex.synchronize do
            entered << request.step_id
            overlap << true if entered.size == 2
          end
          Timeout.timeout(1) { sleep(0.001) until mutex.synchronize { entered.size == 2 } }
          mutex.synchronize { finished << request.step_id }
        end
        AgentRuntime::Result.new(status: "success", outputs: {"answer" => request.step_id})
      end
      program = graph([step("a"), step("b"), step("c", needs: %w[a b])])
      report = AgentRuntime::Runtime.new(store: AgentRuntime::Store.new(dir), executors: {custom: adapter}).run(program)
      assert_equal "success", report["status"], report.inspect
      assert_equal true, overlap.pop(true)
      assert_equal %w[a b], finished.sort
    end
  end

  def test_failure_propagation_and_bounded_transport_retry
    in_tmp do |dir|
      calls = []
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |request|
        calls << request.step_id
        AgentRuntime::Result.new(status: "failure", error: {"classification" => "transport"})
      end
      report = AgentRuntime::Runtime.new(store: AgentRuntime::Store.new(dir), executors: {custom: adapter}).run(graph([step("a", retries: 2), step("c", needs: ["a"])]))
      assert_equal ["a", "a", "a"], calls
      assert_equal "failure", report["status"]
      assert_equal "cancelled", report["steps"]["c"]["status"]
      assert_equal 3, report["steps"]["a"]["attempts"].size
    end
  end

  def test_timeout_and_cancellation
    in_tmp do |dir|
      program = graph([step("c", timeout: 0.02, config: {"delay" => 0.2})])
      program["executors"]["x"]["adapter"] = "fake"
      runtime = AgentRuntime::Runtime.new(store: AgentRuntime::Store.new(dir))
      assert_equal "timeout", runtime.run(program)["status"]
      token = AgentRuntime::Cancellation.new
      token.cancel!
      assert_equal "cancelled", runtime.run(program, cancellation: token)["status"]
      token = AgentRuntime::Cancellation.new
      thread = Thread.new { runtime.run(program, cancellation: token) }
      sleep 0.005
      token.cancel!
      assert_equal "cancelled", thread.value["status"]
    end
  end

  def test_semantic_failure_is_never_automatically_repaired
    in_tmp do |dir|
      program = graph([step("c", retries: 3, config: {"operation" => "fail"})])
      program["executors"]["x"]["adapter"] = "fake"
      report = AgentRuntime::Runtime.new(store: AgentRuntime::Store.new(dir)).run(program)
      assert_equal "failure", report["status"]
      assert_equal 1, report["steps"]["c"]["attempts"].size
    end
  end

  def test_isolated_writable_inputs_for_parallel_mutations
    in_tmp do |dir|
      source = File.join(dir, "source")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "value"), "original")
      paths = Queue.new
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |request|
        path = request.inputs.fetch("repository")
        raise "shared mutable workspace" unless File.read(File.join(path, "value")) == "original"
        File.write(File.join(path, "value"), request.step_id)
        paths << path
        AgentRuntime::Result.new(status: "success", outputs: {"repository" => path})
      end
      program = graph(%w[a c].map { |id| step(id, inputs: {"repository" => "repository"}, outputs: {"repository" => "repository"}) })
      program["inputs"] = {"repository" => "repository"}
      program["outputs"] = {"a" => "a.repository", "c" => "c.repository"}
      store = AgentRuntime::Store.new(File.join(dir, "store"))
      report = AgentRuntime::Runtime.new(store: store, executors: {custom: adapter}).run(program, inputs: {repository: source})
      assert_equal "success", report["status"]
      refute_equal paths.pop, paths.pop
      assert_equal "original", File.read(File.join(source, "value"))
      report["outputs"].each { |name, artifact| assert_equal name, File.read(File.join(store.value(artifact), "value")) }
    end
  end

  def test_fake_patch_tracks_added_deleted_and_modified_files
    in_tmp do |dir|
      source = File.join(dir, "source")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "old.txt"), "old\n")
      File.write(File.join(source, "edit.txt"), "before\n")
      request = AgentRuntime::Request.new(workspace: File.join(dir, "step"), inputs: {"repository" => source}, config: {"operation" => "patch", "files" => {"old.txt" => nil, "edit.txt" => "after\n", "new.txt" => "new\n"}}, timeout: 5)
      result = AgentRuntime::Adapters::Fake.new.execute(request)
      assert_equal "success", result.status
      assert_includes result.outputs["patch"], "deleted file mode"
      assert_includes result.outputs["patch"], "new file mode"
      assert_includes result.outputs["patch"], "+after"
      assert_equal "old\n", File.read(File.join(source, "old.txt"))
    end
  end
end
