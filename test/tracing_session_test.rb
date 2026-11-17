require_relative "test_helper"
require_relative "../lib/agent_runtime/tracing/session"

class TracingSessionTest < Minitest::Test
  def with_session(raw: true)
    Dir.mktmpdir do |root|
      artifacts = AgentRuntime::Store.new(File.join(root, "artifacts"))
      trace = AgentRuntime::Tracing::Store.new(File.join(root, "traces"), raw_content: raw)
      session = AgentRuntime::Tracing::Session.new(trace: trace, artifacts: artifacts, raw_content: raw)
      artifacts.tracing = session
      yield root, artifacts, trace, session
    ensure
      trace&.close
    end
  end

  def test_runtime_preserves_cell_hierarchy_and_portable_checkpoints
    with_session do |root, artifacts, trace, session|
      repository = File.join(root, "source")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "example"), "source")
      cell = session.start("cell", attributes: {"cell_id" => "cell", "architecture" => "dsl"})
      ir = {"schema_version" => 1, "name" => "example", "inputs" => {"repository" => "repository"},
            "executors" => {"fake" => {"adapter" => "fake", "config" => {}}},
            "steps" => [{"id" => "copy", "executor" => "fake", "inputs" => {"repository" => "repository"}, "outputs" => {"repository" => "repository"}, "needs" => [], "config" => {}, "timeout" => 1, "retries" => 0}],
            "outputs" => {"repository" => "copy.repository"}}
      adapter = Object.new
      adapter.define_singleton_method(:execute) { |request| AgentRuntime::Result.new(status: "success", outputs: request.inputs, logs: {"execution" => {"events" => [], "completion" => "completed"}}) }
      report = session.within(cell, {"cell_id" => "cell", "architecture" => "dsl"}) do
        AgentRuntime::Runtime.new(store: artifacts, executors: {fake: adapter}).run(ir, inputs: {"repository" => repository})
      end
      session.finish(cell, "success")
      assert_equal "success", report["status"]
      checkpoints = trace.entities("kind" => "checkpoint", "cell_id" => "cell")
      assert_equal 2, checkpoints.size
      assert_equal %w[before after], checkpoints.map { |entry| entry["attributes"]["boundary"] }
      assert_equal "source", trace.read_payload(checkpoints.first["attributes"]["snapshot"], raw: true)["manifest"].first["content"].unpack1("m0")
      assert trace.verify["complete"], trace.verify.inspect
    end
  end

  def test_capture_requires_digest_and_links_request_usage
    with_session do |_, _, trace, session|
      parent = session.start("attempt", attributes: {"cell_id" => "one"})
      payload = {"request_id" => "request", "complete" => true, "usage" => {"total_tokens" => 3}, "request_body" => {"messages" => [{"content" => "hello"}]}}
      json = JSON.generate(payload)
      envelope = {"payload" => payload, "payload_json" => json, "digest" => Digest::SHA256.hexdigest(json)}
      session.provider_records(parent: parent, records: [envelope])
      session.finish(parent, "success")
      request = trace.entities("request" => "request").fetch(0)
      assert_equal parent, request["parent_id"]
      assert request["attributes"]["usage_correlated"]
      assert trace.verify["complete"], trace.verify.inspect
      envelope["digest"] = "bad"
      assert_raises(AgentRuntime::Error) { session.provider_records(parent: parent, records: [envelope]) }
    end
  end

  def test_default_checkpoint_is_explicitly_unavailable
    with_session(raw: false) do |root, _, trace, session|
      repository = File.join(root, "repo")
      FileUtils.mkdir_p(repository)
      parent = session.start("attempt")
      session.checkpoint(parent: parent, repository: repository, run_id: "run", stage: "stage", attempt: 1, boundary: "before")
      session.finish(parent, "success")
      refute trace.verify["complete"]
      assert trace.verify["incomplete"].any? { |reason| reason.start_with?("snapshot_unavailable:") }
    end
  end
end
