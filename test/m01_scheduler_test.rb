require_relative "test_helper"
require "rbconfig"
require "socket"
require_relative "../lib/agent_runtime/adapters/process_runner"

class M01SchedulerTest < Minitest::Test
  WATCHDOG = 10

  def bounded(&block)
    Timeout.timeout(WATCHDOG, &block)
  end

  def node(id, needs: [], inputs: {}, outputs: {"answer" => "text"}, retries: 0, timeout: 3)
    {"id" => id, "executor" => "x", "needs" => needs, "inputs" => inputs,
     "outputs" => outputs, "config" => {}, "timeout" => timeout, "retries" => retries}
  end

  def program(nodes, inputs: {}, emit: "c.answer")
    {"schema_version" => 1, "name" => "m01", "inputs" => inputs,
     "executors" => {"x" => {"adapter" => "scripted", "config" => {}}},
     "steps" => nodes, "outputs" => {"result" => emit}}
  end

  def success(value)
    AgentRuntime::Result.new(status: "success", outputs: {"answer" => value})
  end

  def failure(classification = "logical", **extra)
    AgentRuntime::Result.new(status: "failure", outputs: {},
      error: {"classification" => classification}, **extra)
  end

  def execute(dir, ir, concurrency: 2, cancellation: nil, inputs: {}, &script)
    adapter = Object.new
    adapter.define_singleton_method(:execute) { |request| script.call(request) }
    store = AgentRuntime::Store.new(File.join(dir, "store"))
    report = bounded do
      AgentRuntime::Runtime.new(store: store, executors: {scripted: adapter}).run(
        ir, inputs: inputs, concurrency: concurrency, cancellation: cancellation
      )
    end
    [report, store]
  end

  # The controller runs on this thread; worker exceptions are re-raised by value.
  def controlled(work, cleanup: -> {}, &controller)
    worker = Thread.new(&work)
    worker.report_on_exception = false
    bounded(&controller)
    bounded { worker.value }
  ensure
    cleanup.call if worker&.alive?
    if worker&.alive?
      worker.kill
      bounded { worker.join }
    end
  end

  def test_b01_chain_and_failure_at_each_predecessor
    [nil, "a", "b"].each do |bad|
      in_tmp do |dir|
        calls = []
        ir = program([node("a"), node("b", inputs: {"prior" => "a.answer"}),
          node("c", inputs: {"prior" => "b.answer"})])
        report, store = execute(dir, ir) do |request|
          calls << request.step_id
          if request.step_id == bad
            failure
          else
            success((request.inputs["prior"] || "") + request.step_id)
          end
        end
        if bad
          assert_equal((bad == "a") ? ["a"] : %w[a b], calls)
          assert_equal "cancelled", report.dig("steps", "c", "status")
          assert_empty report.dig("steps", "c", "attempts")
          assert_empty report["outputs"]
          refute_equal "success", report["status"]
        else
          assert_equal %w[a b c], calls
          assert_equal "abc", store.value(report.fetch("outputs").fetch("result"))
          assert_equal "success", report["status"]
        end
      end
    end
  end

  def test_b02_independent_branch_survives_failure
    in_tmp do |dir|
      calls = Queue.new
      report, = execute(dir, program([node("a"), node("b"), node("c", needs: ["b"])])) do |request|
        calls << request.step_id
        (request.step_id == "a") ? failure : success(request.step_id)
      end
      assert_equal "failure", report.dig("steps", "a", "status")
      %w[b c].each { |id| assert_equal "success", report.dig("steps", id, "status") }
      assert_equal 3, calls.size
      refute_equal "success", report["status"]
    end
  end

  def test_b03_late_fan_in_failure_in_both_orders_and_success_control
    [nil, "a", "b"].each do |bad|
      [%w[a b], %w[b a]].each do |order|
        in_tmp do |dir|
          entered = Queue.new
          gates = {"a" => Queue.new, "b" => Queue.new}
          journal = []
          lock = Mutex.new
          ir = program(order.map { |id| node(id) } + [node("c", needs: %w[a b]), node("d", needs: ["c"])])
          work = -> do
            execute(dir, ir) do |request|
              id = request.step_id
              if gates.key?(id)
                entered << id
                bounded { gates.fetch(id).pop }
                lock.synchronize { journal << id }
                (id == bad) ? failure : success(id)
              else
                assert_equal %w[a b], lock.synchronize { journal.sort }
                success(id)
              end
            end
          end
          report, = controlled(work, cleanup: -> { gates.each_value { |q| q << true } }) do
            assert_equal %w[a b], [entered.pop, entered.pop].sort
            early = bad ? (%w[a b] - [bad]).first : "a"
            gates.fetch(early) << true
            gates.fetch(bad || "b") << true
          end
          %w[c d].each do |id|
            assert_equal bad ? "cancelled" : "success", report.dig("steps", id, "status")
            assert_empty report.dig("steps", id, "attempts") if bad
          end
        end
      end
    end
  end

  def test_b04_simultaneous_failures_are_retained
    in_tmp do |dir|
      ready = Queue.new
      release = Queue.new
      ir = program([node("a"), node("b"), node("c", needs: %w[a b]), node("independent")])
      work = -> do
        execute(dir, ir) do |request|
          if %w[a b].include?(request.step_id)
            ready << true
            bounded { release.pop }
            failure(request.step_id)
          else
            success(request.step_id)
          end
        end
      end
      report, = controlled(work, cleanup: -> { 2.times { release << true } }) do
        2.times { ready.pop }
        2.times { release << true }
      end
      %w[a b].each do |id|
        assert_equal "failure", report.dig("steps", id, "status")
        assert_equal 1, report.dig("steps", id, "attempts").size
        assert_equal id, report.dig("steps", id, "attempts", 0, "error", "classification")
      end
      assert_equal "cancelled", report.dig("steps", "c", "status")
      assert_equal "success", report.dig("steps", "independent", "status")
      refute_equal "success", report["status"]
    end
  end

  def test_b05_pre_cancel_and_active_cooperative_cancel
    [true, false].each do |pre|
      in_tmp do |dir|
        token = AgentRuntime::Cancellation.new
        token.cancel! if pre
        entered = Queue.new
        release = Queue.new
        calls = []
        ir = program([node("a"), node("c", needs: ["a"]), node("other")])
        work = -> do
          execute(dir, ir, concurrency: 1, cancellation: token) do |request|
            calls << request.step_id
            entered << true
            bounded { release.pop }
            assert_same token, request.cancellation
            AgentRuntime::Result.new(status: request.cancellation.cancelled? ? "cancelled" : "success", outputs: {"answer" => "ok"})
          end
        end
        report, = controlled(work, cleanup: -> { release << true }) do
          unless pre
            entered.pop
            token.cancel!
            release << true
          end
        end
        assert_equal pre ? [] : ["a"], calls
        assert_equal "cancelled", report["status"]
        assert_empty report["outputs"]
        %w[c other].each { |id| assert_empty report.dig("steps", id, "attempts") }
      end
    end
  end

  def test_b06_ruby_timeout_fallback_is_observable_not_safe_preemption
    in_tmp do |dir|
      entered = Queue.new
      cleaned = Queue.new
      never = Queue.new
      report, = execute(dir, program([node("a", timeout: 0.1), node("c", needs: ["a"])])) do |_request|
        entered << true
        begin
          never.pop
        ensure
          cleaned << true
        end
      end
      assert_equal true, bounded { entered.pop }
      assert_equal true, bounded { cleaned.pop }
      assert_equal "timeout", report.dig("steps", "a", "status")
      assert_equal "cancelled", report.dig("steps", "c", "status")
      refute_equal "success", report["status"]
    end
  end

  def test_b07_safe_transport_retry_recovers_with_fresh_workspace
    in_tmp do |dir|
      paths = []
      report, store = execute(dir, program([node("a", retries: 1), node("c", inputs: {"prior" => "a.answer"})])) do |request|
        if request.step_id == "a"
          paths << request.workspace
          if request.attempt == 1
            File.write(File.join(request.workspace, "poison"), "bad")
            failure("transport", retry_safe: true)
          else
            refute File.exist?(File.join(request.workspace, "poison"))
            success("recovered")
          end
        else
          success(request.inputs.fetch("prior"))
        end
      end
      assert_equal "success", report["status"], report.inspect
      assert_equal 2, paths.uniq.size
      assert_equal [1, 2], report.dig("steps", "a", "attempts").map { |a| a["attempt"] }
      assert_equal "recovered", store.value(report.fetch("outputs").fetch("result"))
    end
  end

  def test_b08_unsafe_transport_failure_is_not_retried
    in_tmp do |dir|
      calls = []
      report, = execute(dir, program([node("a", retries: 2), node("c", needs: ["a"])])) do |request|
        calls << request.attempt
        failure("transport")
      end
      assert_equal [1], calls
      assert_equal 1, report.dig("steps", "a", "attempts").size
      assert_equal "cancelled", report.dig("steps", "c", "status")
      assert_empty report["outputs"]
    end
  end

  def test_b08_explicitly_unsafe_transport_failure_is_not_retried
    in_tmp do |dir|
      calls = 0
      report, = execute(dir, program([node("c", retries: 2)])) do |_request|
        calls += 1
        failure("transport", retry_safe: false)
      end
      assert_equal 1, calls
      assert_equal "failure", report.dig("steps", "c", "status")
      assert_equal "transport", report.dig("steps", "c", "attempts", 0, "error", "classification")
    end
  end

  def test_b08_safe_transport_retry_budget_is_exhausted
    [0, 1, 2].each do |budget|
      in_tmp do |dir|
        calls = []
        report, = execute(dir, program([node("a", retries: budget), node("c", needs: ["a"])])) do |request|
          calls << request.attempt
          failure("transport", retry_safe: true)
        end
        assert_equal (1..(budget + 1)).to_a, calls
        assert_equal budget + 1, report.dig("steps", "a", "attempts").size
        assert_equal "transport", report.dig("steps", "a", "attempts", -1, "error", "classification")
        assert_equal "failure", report.dig("steps", "a", "status")
        assert_equal "cancelled", report.dig("steps", "c", "status")
      end
    end
  end

  def test_b08_nontransport_terminal_results_are_not_retried
    %w[failure blocked unknown timeout cancelled].each do |status|
      in_tmp do |dir|
        calls = []
        report, = execute(dir, program([node("a", retries: 2), node("c", needs: ["a"])])) do |request|
          calls << request.step_id
          AgentRuntime::Result.new(status: status, outputs: {}, error: {"classification" => "logical"})
        end
        assert_equal ["a"], calls
        assert_equal status, report.dig("steps", "a", "status")
        assert_equal 1, report.dig("steps", "a", "attempts").size
        assert_equal "cancelled", report.dig("steps", "c", "status")
        refute_equal "success", report["status"]
      end
    end
  end

  def test_b09_invalid_results_fail_closed_with_retained_attempt
    specimens = [-> {}, -> { Object.new },
      -> { AgentRuntime::Result.new(status: "bogus", outputs: {}) },
      -> { AgentRuntime::Result.new(status: "success", outputs: nil) },
      -> { AgentRuntime::Result.new(status: "success", outputs: []) },
      -> { success(123) }, -> { raise "fixture executor error" }]
    specimens.each do |specimen|
      in_tmp do |dir|
        calls = Queue.new
        report, = execute(dir, program([node("a", retries: 2), node("c", needs: ["a"]), node("independent")])) do |request|
          calls << request.step_id
          (request.step_id == "a") ? specimen.call : success("ok")
        end
        assert_equal "failure", report.dig("steps", "a", "status"), report.inspect
        assert_equal 1, report.dig("steps", "a", "attempts").size
        assert_equal "failure", report.dig("steps", "a", "attempts", 0, "status")
        assert_equal "cancelled", report.dig("steps", "c", "status")
        assert_empty report.dig("steps", "c", "attempts")
        assert_equal "success", report.dig("steps", "independent", "status")
        assert_equal 2, calls.size
        assert_empty report["outputs"]
      end
    end
  end

  def test_b09_late_invalid_output_does_not_publish_partial_success
    in_tmp do |dir|
      ir = program([node("a", outputs: {"first" => "text", "answer" => "text"}), node("c", needs: ["a"])])
      report, = execute(dir, ir) do |_request|
        AgentRuntime::Result.new(status: "success", outputs: {"first" => "valid", "answer" => 123})
      end
      assert_equal "failure", report.dig("steps", "a", "status")
      assert_equal 1, report.dig("steps", "a", "attempts").size
      assert_equal "cancelled", report.dig("steps", "c", "status")
      assert_empty report["outputs"]
    end
  end

  def test_b10_concurrent_repository_inputs_are_isolated
    in_tmp do |dir|
      original = File.join(dir, "original")
      FileUtils.mkdir_p(original)
      File.write(File.join(original, "base"), "unchanged")
      ready = Queue.new
      gates = Queue.new
      lock = Mutex.new
      paths = []
      ir = program(%w[a c].map { |id| node(id, inputs: {"repo" => "repo"}, outputs: {"answer" => "repository"}) }, inputs: {"repo" => "repository"})
      work = -> do
        execute(dir, ir, inputs: {"repo" => original}) do |request|
          path = request.inputs.fetch("repo")
          lock.synchronize { paths << path }
          File.write(File.join(path, request.step_id), "own")
          ready << true
          bounded { gates.pop }
          assert_equal "own", File.read(File.join(path, request.step_id))
          refute File.exist?(File.join(path, (request.step_id == "a") ? "c" : "a"))
          success(path)
        end
      end
      report, store = controlled(work, cleanup: -> { 2.times { gates << true } }) do
        2.times { ready.pop }
        2.times { gates << true }
      end
      assert_equal "success", report["status"]
      assert_equal 2, paths.uniq.size
      assert_equal ["base"], Dir.children(original)
      assert_equal "unchanged", File.read(File.join(original, "base"))
      stored = store.value(report.fetch("outputs").fetch("result"))
      assert_equal %w[base c], Dir.children(stored).sort
    end
  end

  def test_b11_concurrency_bound_and_overlap
    [1, 2, 32].each do |limit|
      in_tmp do |dir|
        entered = Queue.new
        release = Queue.new
        lock = Mutex.new
        active = 0
        high = 0
        count = limit + 2
        ir = program(Array.new(count) { |i| node("s#{i}") }, emit: "s0.answer")
        work = -> do
          execute(dir, ir, concurrency: limit) do |request|
            lock.synchronize {
              active += 1
              high = [high, active].max
            }
            begin
              entered << true
              bounded { release.pop }
              success(request.step_id)
            ensure
              lock.synchronize { active -= 1 }
            end
          end
        end
        report, = controlled(work, cleanup: -> { count.times { release << true } }) do
          limit.times { entered.pop }
          assert_equal limit, lock.synchronize { active }
          count.times { release << true }
        end
        assert_equal "success", report["status"]
        assert_equal limit, high
        assert_equal count, report["steps"].size
      end
    end
  end

  def test_b11_invalid_concurrency_never_calls_executor
    [0, 33, -1, "2", nil, 1.5].each do |limit|
      in_tmp do |dir|
        calls = 0
        assert_raises(AgentRuntime::Error) do
          execute(dir, program([node("c")]), concurrency: limit) {
            calls += 1
            success("bad")
          }
        end
        assert_equal 0, calls
      end
    end
  end

  def test_b06_process_group_timeout_and_cancellation_with_descendants
    [:success, :timeout, :cancel].each do |mode|
      in_tmp do |dir|
        socket_path = File.join(dir, "ready.sock")
        server = UNIXServer.new(socket_path)
        clients = []
        pids = []
        token = AgentRuntime::Cancellation.new
        script = <<~RUBY
          require "socket"
          trap("TERM", "IGNORE") unless ARGV[1] == "success"
          child = fork do
            connection = UNIXSocket.new(ARGV[0])
            connection.puts Process.pid
            connection.gets
            exit! 0
          end
          connection = UNIXSocket.new(ARGV[0])
          connection.puts Process.pid
          connection.gets
          Process.wait(child)
        RUBY
        runner = AgentRuntime::Adapters::ProcessRunner.new
        work = -> { runner.call(argv: [RbConfig.ruby, "-e", script, socket_path, mode.to_s], cwd: dir, timeout: (mode == :timeout) ? 3 : 6, cancellation: token) }
        cleanup = -> do
          pids.each do |pid|
            Process.kill("KILL", pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
        result = controlled(work, cleanup: cleanup) do
          2.times do
            client = server.accept
            clients << client
            pids << Integer(client.gets)
          end
          if mode == :cancel
            token.cancel!
          elsif mode == :success
            clients.each { |client| client.puts "release" }
          end
        end
        assert_equal({success: "success", timeout: "timeout", cancel: "cancelled"}.fetch(mode), result["status"])
        clients.each { |client| assert_nil bounded { client.read(1) } }
      ensure
        cleanup&.call
        clients&.each(&:close)
        server&.close
      end
    end
  end

  def test_b06_precancel_does_not_spawn_local_process
    in_tmp do |dir|
      marker = File.join(dir, "spawned")
      token = AgentRuntime::Cancellation.new
      token.cancel!
      result = bounded do
        AgentRuntime::Adapters::ProcessRunner.new.call(
          argv: [RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'spawned')", marker],
          cwd: dir, timeout: 2, cancellation: token
        )
      end
      assert_equal "cancelled", result["status"]
      refute File.exist?(marker)
    end
  end
end
