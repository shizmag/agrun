require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/open_code_cli"
require "rbconfig"
require "socket"
require "timeout"

class M12RuntimeTimeoutTest < Minitest::Test
  def program(timeout: 3)
    {"schema_version" => 1, "name" => "timeout-evidence", "inputs" => {},
     "executors" => {"local" => {"adapter" => "local", "config" => {"prompt" => "offline fixture"}}},
     "steps" => [{"id" => "work", "executor" => "local", "inputs" => {},
                  "outputs" => {"answer" => "text"}, "needs" => [],
                  "config" => {}, "timeout" => timeout, "retries" => 0}],
     "outputs" => {"answer" => "work.answer"}}
  end

  def test_real_runner_timeout_preserves_partial_logs_and_cleanup_in_store
    in_tmp do |root|
      server = UNIXServer.new(File.join(root, "ready.sock"))
      connections = []
      pids = []
      executable = File.join(root, "fixture")
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require "socket"
        STDOUT.sync = true
        trap("TERM", "IGNORE")
        child = fork do
          connection = UNIXSocket.new(#{server.path.inspect})
          connection.puts Process.pid
          sleep
        end
        puts %q({"type":"text","part":{"text":"partial timeout evidence"}})
        connection = UNIXSocket.new(#{server.path.inspect})
        connection.puts Process.pid
        sleep
      RUBY
      File.chmod(0o755, executable)
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable,
        fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true)
      # Capture the actual runner result without replacing supervision or time.
      process_runner = adapter.instance_variable_get(:@runner)
      call = process_runner.method(:call)
      captured = nil
      process_runner.define_singleton_method(:call) { |**args| captured = call.call(**args) }
      store_root = File.join(root, "store")
      store = AgentRuntime::Store.new(store_root)
      worker = Thread.new { AgentRuntime::Runtime.new(store: store, executors: {local: adapter}).run(program) }
      worker.report_on_exception = false
      Timeout.timeout(10) do
        2.times do
          connection = server.accept
          connections << connection
          pids << Integer(connection.gets)
        end
      end
      assert worker.alive?, "both processes must be ready before the execution deadline"
      report = Timeout.timeout(10) { worker.value }
      assert_equal "timeout", report.fetch("status")
      assert_equal "timeout", captured.fetch("status")
      assert_equal true, captured.dig("cleanup", "reaped")
      assert_empty captured.dig("cleanup", "errors")
      connections.each do |connection|
        assert IO.select([connection], nil, nil, 0.5), "fixture survived runtime completion"
        assert_nil connection.read(1)
      end
      reloaded = AgentRuntime::Store.new(store_root)
      assert_equal report, reloaded.report(report.fetch("run_id"))
      attempt = report.fetch("steps").fetch("work").fetch("attempts").fetch(0)
      assert_equal "timeout", attempt.fetch("status")
      logs = JSON.parse(reloaded.value(attempt.fetch("log")))
      assert_includes JSON.generate(logs), "partial timeout evidence"
      assert_includes JSON.generate(logs), '"cleanup"'
      assert_includes JSON.generate(logs), '"reaped":true'
      db = SQLite3::Database.new(File.join(store_root, "metadata.sqlite3"), readonly: true)
      rows = db.execute("SELECT data FROM attempts WHERE run_id = ?", [report.fetch("run_id")])
      assert_equal [attempt], rows.map { |row| JSON.parse(row.fetch(0)) }
      assert_empty report.fetch("outputs")
    ensure
      pids&.each do |pid|
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      worker&.join(2)
      connections&.each(&:close)
      server&.close
      db&.close
    end
  end

  def test_generic_adapter_still_has_outer_watchdog
    in_tmp do |root|
      entered = Queue.new
      exited = Queue.new
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |_request|
        entered << true
        begin
          sleep 30
        ensure
          exited << true
        end
      end
      store = AgentRuntime::Store.new(root)
      worker = Thread.new { AgentRuntime::Runtime.new(store: store, executors: {local: adapter}).run(program(timeout: 0.2)) }
      Timeout.timeout(5) { entered.pop }
      report = Timeout.timeout(5) { worker.value }
      assert_equal true, exited.pop
      assert_equal "timeout", report.fetch("status")
      attempt = report.fetch("steps").fetch("work").fetch("attempts").fetch(0)
      assert_equal "timeout", attempt.fetch("status")
      assert_equal "timeout", attempt.dig("error", "classification")
      refute attempt.key?("log"), "outer watchdog synthesizes its own timeout result"
      assert_equal report, AgentRuntime::Store.new(root).report(report.fetch("run_id"))
    ensure
      worker&.join(2)
    end
  end
end
