require_relative "test_helper"

class M12ExecutionPersistenceTest < Minitest::Test
  def test_execution_summary_and_evidence_survive_store_reload
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "store"))
      trace = {"schema_version" => "m12a-execution-v1", "attempt_id" => "observation-1",
               "session_id" => "ses-fixture", "outcome" => "success",
               "events" => [{"sequence" => 1, "raw" => {"type" => "step_finish"}}],
               "usage" => {"completeness" => "unavailable", "input_tokens" => nil},
               "admission" => {"admitted" => true}, "raw" => "large",
               "stdout" => "captured", "stderr" => "diagnostic"}
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |_request|
        AgentRuntime::Result.new(status: "success", outputs: {"answer" => "ok"},
          logs: {"execution" => trace}, session_id: "ses-fixture")
      end
      ir = {"schema_version" => 1, "name" => "evidence", "inputs" => {},
            "executors" => {"local" => {"adapter" => "local", "config" => {}}},
            "steps" => [{"id" => "work", "executor" => "local", "inputs" => {},
                         "outputs" => {"answer" => "text"}, "needs" => [],
                         "config" => {}, "timeout" => 2, "retries" => 0}],
            "outputs" => {"answer" => "work.answer"}}
      report = AgentRuntime::Runtime.new(store: store, executors: {local: adapter}).run(ir)
      store = AgentRuntime::Store.new(File.join(root, "store"))
      persisted = store.report(report.fetch("run_id"))
      attempt = persisted.fetch("steps").fetch("work").fetch("attempts").fetch(0)
      assert_equal "observation-1", attempt.dig("execution", "attempt_id")
      assert_equal "unavailable", attempt.dig("execution", "usage", "completeness")
      refute attempt.fetch("execution").key?("events"), "large raw evidence belongs in artifact, not SQLite summary"
      %w[raw stdout stderr].each { |key| refute attempt.fetch("execution").key?(key) }
      evidence = JSON.parse(store.value(attempt.fetch("log"))).fetch("execution")
      assert_equal trace, evidence
      trace["events"].clear
      trace["usage"]["completeness"] = "fabricated"
      assert_equal 1, JSON.parse(store.value(attempt.fetch("log"))).dig("execution", "events").size
      assert_equal "unavailable", store.report(report.fetch("run_id")).dig("steps", "work", "attempts", 0, "execution", "usage", "completeness")
    end
  end
end
