require "minitest/autorun"
require "stringio"
require_relative "../lib/agent_runtime/tracing/cli"

class TracingCLITest < Minitest::Test
  class FakeStore
    attr_reader :root, :raw
    def initialize(root, raw_content: false)
      @root, @raw = root, raw_content
    end

    def entities(filters = {})
      [{"id" => "request-1", "kind" => "request", "attributes" => {"summary" => "sanitized prompt"}}].select { |entity| !filters["kind"] || entity["kind"] == filters["kind"] }
    end

    def get(id)
      entities.find { |entity| entity["id"] == id } || raise(ArgumentError, "missing entity")
    end

    def verify
      {"valid" => true, "complete" => false}
    end
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = AgentRuntime::Tracing::CLI.new(out: out, err: err, store_class: FakeStore).run(args)
    [code, out.string.empty? ? nil : JSON.parse(out.string), err.string]
  end

  def test_list_and_inspect
    code, entities = run_cli("list", "--root", "offline")
    assert_equal 0, code
    assert_equal "request-1", entities.first["id"]
    assert_equal "request-1", run_cli("inspect", "--id", "request-1")[1]["id"]
  end

  def test_filters_and_search
    assert_empty run_cli("tools")[1]
    assert_equal 1, run_cli("search", "sanitized")[1].length
    assert_empty run_cli("search", "secret")[1]
  end

  def test_errors_and_incomplete_integrity_are_nonzero
    assert_equal 1, run_cli("verify")[0]
    assert_equal 1, run_cli("inspect")[0]
    assert_equal 1, run_cli("unknown")[0]
    assert_equal 1, run_cli("list", "--raw")[0]
    assert_equal 0, run_cli("list", "--raw", "--authorize-raw")[0]
  end

  def test_diagnostics_are_deterministic_and_do_not_invent_usage
    result = run_cli("analyze")[1]
    assert_equal({"observed" => 0, "known" => 0, "unknown" => 1}, result["observations"]["tokens"])
    assert_empty result["hypotheses"]
    assert_equal result, run_cli("analyze")[1]
  end

  def test_checkpoint_diffs_include_modes_overwrites_and_reverts
    checkpoints = ["a", "b", "a"].each_with_index.map do |digest, index|
      {"id" => index.to_s, "kind" => "checkpoint", "attributes" => {"files" => {"x" => {"digest" => digest, "mode" => 420}}}}
    end
    diagnostics = AgentRuntime::Tracing::Diagnostics.new(checkpoints)
    assert_equal ["x"], diagnostics.diff(checkpoints[0], checkpoints[1])["modified"]
    assert_equal %w[overwrite revert], diagnostics.analyze["observations"]["overwrites_and_reverts"].map { |entry| entry["observation"] }
    refute diagnostics.diff({"id" => "missing"}, checkpoints[0])["complete"]
  end
end

require "tmpdir"
require_relative "../lib/agent_runtime/tracing/store"

class TracingCLIStoreTest < Minitest::Test
  def test_portable_cli_and_authorized_raw_search
    Dir.mktmpdir do |directory|
      root = File.join(directory, "store")
      store = AgentRuntime::Tracing::Store.new(root, raw_content: true)
      raw = store.payload({"text" => "confidentialneedle"}, raw: true)
      safe = store.payload({"summary" => "indexedneedle"})
      store.event(kind: "request", parent_id: nil, id: "request", attributes: {"raw" => raw, "summary" => safe, "cell_id" => "cell", "experiment_id" => "experiment", "attempt" => 2, "run_id" => "run"})
      store.close
      invoke = lambda do |*args|
        out = StringIO.new
        err = StringIO.new
        code = AgentRuntime::Tracing::CLI.new(out: out, err: err).run(args + ["--root", root])
        assert_equal 0, code, err.string
        JSON.parse(out.string)
      end
      assert_equal 1, invoke.call("search", "indexedneedle").length
      assert_equal 1, invoke.call("requests", "--cell", "cell", "--experiment", "experiment", "--attempt", "2", "--run", "run").length
      assert_empty invoke.call("requests", "--cell", "absent")
      assert_empty invoke.call("search", "confidentialneedle")
      assert_equal 1, invoke.call("search", "confidentialneedle", "--raw", "--authorize-raw").length
      assert invoke.call("verify")["valid"]
      archive = File.join(directory, "export")
      invoke.call("export", archive)
      imported = File.join(directory, "imported")
      assert invoke.call("import", archive, "--destination", imported)["imported"]
    end
  end
end

class TracingDiagnosticsMetadataTest < Minitest::Test
  def test_relay_usage_tool_failure_and_retry_observations
    entities = [
      {"id" => "llm", "kind" => "llm_request", "duration" => 0.001, "attributes" => {
        "duration_ms" => 1200, "usage" => {"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14,
                                           "prompt_tokens_details" => {"cached_tokens" => 3}, "completion_tokens_details" => {"reasoning_tokens" => 2}}
      }},
      {"id" => "tool", "kind" => "tool", "status" => "failure", "attributes" => {"tool_status" => "error"}},
      {"id" => "retry", "kind" => "attempt", "attributes" => {"attempt" => 2}}
    ]
    observations = AgentRuntime::Tracing::Diagnostics.new(entities).analyze.fetch("observations")
    assert_equal 1, observations["requests"]
    assert_equal 14, observations.dig("tokens", "observed")
    assert_equal 1.2, observations.dig("latency", "observed")
    assert_equal 3, observations.dig("token_buckets", "prompt_tokens_details.cached_tokens", "observed")
    assert_equal 2, observations.dig("token_buckets", "completion_tokens_details.reasoning_tokens", "observed")
    assert_equal({"failure" => 1}, observations["tool_statuses"])
    assert_equal 1, observations["retries"]
  end
end
