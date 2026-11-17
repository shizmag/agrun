# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/agent_runtime/tracing/historical"

class TracingHistoricalTest < Minitest::Test
  class RecordingStore
    attr_reader :records

    def initialize
      @records = []
    end

    def start(**record)
      id = "node-#{@records.length}"
      @records << record.merge(id: id)
      id
    end

    def finish(id, **record)
      @records << record.merge(id: id)
    end

    def event(**record)
      @records << record
    end

    def payload(*)
      raise "raw payload must never be copied"
    end
  end

  def test_imports_actual_nine_cells_without_touching_source_or_copying_raw_data
    path = File.expand_path("../docs/evidence/omniroute-live-success-20261116/report.json", __dir__)
    original = File.binread(path)
    store = RecordingStore.new
    AgentRuntime::Tracing::Historical.new(store: store).import(report_path: path)
    cells = store.records.select { |r| r[:kind] == "historical_cell" }
    expected = {"single-agent" => [17, 17, 14], "fixed-workflow" => [17, 6, 4], "dsl" => [4, 5, 4]}
    expected.each do |solver, scores|
      assert_equal scores, cells.map { |r| r[:attributes] }.select { |c| c["solver_id"] == solver }.sort_by { |c| c["repetition"] }.map { |c| c["passed"] }
    end
    assert_equal 9, cells.length
    assert cells.all? { |c| c[:attributes]["verdict"] == "fail" }
    assert_equal original, File.binread(path)
    assert_equal Digest::SHA256.hexdigest(original), store.records.first[:provenance]["source"]["sha256"]
    refute JSON.generate(store.records).include?("stdout")
    refute JSON.generate(store.records).include?("prompt\"")
    assert store.records.any? { |r| r[:attributes]&.dig("evidence_resolution") == "not_resolved" }
  end

  def test_freeze_wrapper_missing_observations_and_explicit_references
    Dir.mktmpdir do |directory|
      source = File.join(directory, "report.json")
      evidence = File.join(directory, "events.jsonl")
      File.write(evidence, "secret prompt bytes")
      File.write(source, JSON.generate("report" => {"cells" => [{"id" => "old", "score" => nil}]}))
      store = RecordingStore.new
      AgentRuntime::Tracing::Historical.new(store: store).import(report_path: source, evidence_paths: [evidence])
      assert_equal Digest::SHA256.file(evidence).hexdigest, store.records.first[:attributes]["evidence"][0]["sha256"]
      cell = store.records.find { |r| r[:kind] == "historical_cell" }
      assert_nil cell[:attributes]["score"]
      refute cell[:attributes].key?("passed")
      assert_equal "/report/cells/0", cell[:provenance]["pointer"]
      assert store.records.any? { |r| r[:id] == cell[:id] && r[:status] == "unknown" }
      refute JSON.generate(store.records).include?("secret prompt bytes")
    end
  end

  def test_missing_reference_fails_before_writing_trace
    store = RecordingStore.new
    path = File.expand_path("../docs/evidence/omniroute-live-success-20261116/report.json", __dir__)
    assert_raises(ArgumentError) do
      AgentRuntime::Tracing::Historical.new(store: store).import(report_path: path, evidence_paths: ["/nonexistent/agru-historical-evidence"])
    end
    assert_empty store.records
  end
end
