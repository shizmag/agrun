require "minitest/autorun"
require "tmpdir"
require_relative "../lib/agent_runtime/tracing/store"

class TracingStoreTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @store = AgentRuntime::Tracing::Store.new(File.join(@directory, "trace"), raw_content: true)
  end

  def teardown
    @store.close
    FileUtils.rm_rf(@directory)
  end

  def test_lifecycle_filters_redaction_and_monotonic_duration
    id = @store.start(kind: "run", attributes: {experiment_id: "e", nested: {api_key: "private"}})
    assert_equal "[REDACTED]", @store.get(id).dig("attributes", "nested", "api_key")
    assert_equal [id], @store.entities(experiment_id: "e").map { |row| row["id"] }
    assert_includes @store.verify["incomplete"], "running:#{id}"
    @store.finish(id, status: "success")
    assert_operator @store.get(id)["duration"], :>=, 0
    assert @store.verify["complete"]
    assert_raises(ArgumentError) { @store.finish(id, status: "success") }
    assert_raises(SQLite3::ConstraintException) { @store.start(kind: "run", id: id) }
  end

  def test_concurrent_connections_and_crash_reopen
    second = AgentRuntime::Tracing::Store.new(@store.root)
    threads = [@store, second].map do |store|
      Thread.new { 20.times { store.event(kind: "tool", parent_id: nil) } }
    end
    threads.each(&:value)
    assert_equal 40, @store.entities.size
    id = second.start(kind: "run")
    second.close
    assert_includes @store.verify["incomplete"], "running:#{id}"
    @store.finish(id, status: "unknown")
    assert_nil @store.get(id)["duration"]
  ensure
    second&.close
  end

  def test_payload_portability_and_raw_exclusion
    safe = @store.payload({data: [1, 2], password: "secret"})
    raw = @store.payload({password: "secret"}, raw: true)
    assert_equal "[REDACTED]", @store.read_payload(safe)["password"]
    assert_raises(ArgumentError) { @store.read_payload(raw) }
    assert_equal "[REDACTED]", @store.read_payload(raw, raw: true)["password"]
    id = @store.event(kind: "artifact", parent_id: nil, attributes: {safe: safe, raw: raw})
    archive = @store.export(File.join(@directory, "archive"))
    imported = AgentRuntime::Tracing::Store.import(archive, File.join(@directory, "imported"))
    assert imported.verify["valid"]
    assert imported.get(id).dig("attributes", "raw", "omitted")
    assert_equal [1, 2], imported.read_payload(safe)["data"]
    assert_empty Dir.glob(File.join(archive, "blobs", "raw-*"))
    assert_equal 0o700, File.stat(imported.root).mode & 0o777
    assert_equal 0o600, File.stat(File.join(imported.root, "trace.sqlite3")).mode & 0o777
    imported.close
    File.binwrite(File.join(archive, "trace.sqlite3"), "corruption")
    assert_raises(IOError) { AgentRuntime::Tracing::Store.import(archive, File.join(@directory, "bad")) }
  ensure
    imported&.close
  end

  def test_blob_and_parent_corruption
    ref = @store.payload({value: "ok"})
    @store.event(kind: "artifact", parent_id: "missing", attributes: {payload: ref})
    File.binwrite(File.join(@store.root, "blobs", "#{ref["digest"]}.zlib"), "bad")
    report = @store.verify
    refute report["valid"]
    assert report["errors"].any? { |error| error.start_with?("missing_parent:") }
    assert report["errors"].any? { |error| error.start_with?("missing_or_corrupt_blob:") }
    assert_raises(StandardError) { @store.payload({value: "ok"}) }
  end

  def test_raw_authorization_and_explicit_raw_archive
    disabled = AgentRuntime::Tracing::Store.new(File.join(@directory, "disabled"))
    assert_raises(ArgumentError) { disabled.payload({password: "secret"}, raw: true) }
    ref = @store.payload({password: "secret", text: "confidential", nested: [{authorization: "Bearer hidden"}]}, raw: true)
    @store.event(kind: "checkpoint", parent_id: nil, attributes: {payload: ref})
    archive = @store.export(File.join(@directory, "raw-archive"), include_raw: true)
    imported = AgentRuntime::Tracing::Store.import(archive, File.join(@directory, "raw-import"))
    assert_raises(ArgumentError) { imported.read_payload(ref, raw: true) }
    imported.close
    authorized = AgentRuntime::Tracing::Store.new(File.join(@directory, "raw-import"), raw_content: true)
    assert_equal "[REDACTED]", authorized.read_payload(ref, raw: true)["password"]
    assert_equal "confidential", authorized.read_payload(ref, raw: true)["text"]
    assert_equal "[REDACTED]", authorized.read_payload(ref, raw: true).dig("nested", 0, "authorization")
  ensure
    disabled&.close
    imported&.close
    authorized&.close
  end

  def test_parent_cycles_are_invalid
    @store.start(kind: "run", id: "a", parent_id: "b")
    @store.start(kind: "run", id: "b", parent_id: "a")
    refute @store.verify["valid"]
    assert_includes @store.verify["errors"], "parent_cycle:a"
  end

  def test_transactional_parent_inheritance_and_literal_search
    root = @store.start(kind: "cell", attributes: {cell_id: "c", architecture: "sequence", experiment_id: "e"})
    stage = @store.start(kind: "stage", parent_id: root, attributes: {stage: "implement"})
    tool = @store.event(kind: "tool", parent_id: stage, attributes: {summary: "SQL %_ quote ' NEEDLE", architecture: "override"})
    assert_equal [tool], @store.search("needle", filters: {cell_id: "c", stage: "implement", architecture: "override"}).map { |row| row["id"] }
    assert_equal [tool], @store.search("%_", filters: {kind: "tool"}).map { |row| row["id"] }
    assert_empty @store.search("' OR 1=1 --")
    assert_equal "e", @store.get(tool).dig("attributes", "experiment_id")
    @store.finish(stage, status: "success")
    @store.finish(root, status: "success")
    assert @store.verify["complete"]
  end

  def test_rejected_duplicates_and_out_of_order_finishes_are_durable
    id = @store.event(kind: "run", parent_id: nil)
    assert_raises(SQLite3::ConstraintException) { @store.start(kind: "run", id: id) }
    assert_raises(ArgumentError) { @store.finish(id, status: "success") }
    assert_raises(ArgumentError) { @store.finish("absent", status: "success") }
    @store.close
    @store = AgentRuntime::Tracing::Store.new(File.join(@directory, "trace"))
    assert_equal %w[duplicate_start duplicate_finish out_of_order_finish], @store.incidents.map { |row| row["kind"] }
    assert @store.verify["valid"]
    refute @store.verify["complete"]
    assert_equal 1, @store.entities.length
  end

  def test_recovery_marks_interruption_and_cannot_invent_duration
    id = @store.start(kind: "run")
    @store.close
    @store = AgentRuntime::Tracing::Store.new(File.join(@directory, "trace"))
    assert_equal "running", @store.get(id)["status"]
    @store.recover
    assert_equal "unknown", @store.get(id)["status"]
    assert_nil @store.get(id)["duration"]
    assert_includes @store.verify["incomplete"], "interrupted:#{id}"
  end

  def test_multi_process_writers_and_abrupt_exit
    root = @store.root
    @store.close
    workers = 3.times.map do |worker|
      fork do
        store = AgentRuntime::Tracing::Store.new(root)
        12.times { |index| store.event(kind: "tool", parent_id: nil, id: "worker-#{worker}-#{index}") }
        store.start(kind: "run", id: "unfinished-#{worker}")
        exit! 0
      end
    end
    workers.each { |pid| assert Process.wait2(pid).last.success? }
    @store = AgentRuntime::Tracing::Store.new(root)
    assert_equal 39, @store.entities.length
    assert_equal 3, @store.entities(status: "running").length
    assert @store.verify["valid"]
    refute @store.verify["complete"]
  end

  def test_multi_process_duplicate_identity_is_recorded
    root = @store.root
    @store.close
    workers = 2.times.map do
      fork do
        store = AgentRuntime::Tracing::Store.new(root)
        begin
          store.event(kind: "run", parent_id: nil, id: "same")
        rescue SQLite3::ConstraintException
          # Losing writer must preserve a durable incident, not overwrite the winner.
        end
        store.close
        exit! 0
      end
    end
    workers.each { |pid| assert Process.wait2(pid).last.success? }
    @store = AgentRuntime::Tracing::Store.new(root)
    assert_equal ["same"], @store.entities.map { |row| row["id"] }
    assert_equal ["duplicate_start"], @store.incidents.map { |row| row["kind"] }
    assert @store.verify["valid"]
    refute @store.verify["complete"]
  end

  def test_parent_timestamp_order_and_out_of_order_start
    parent = @store.event(kind: "run", parent_id: nil)
    child = @store.event(kind: "tool", parent_id: parent)
    assert_equal "parent_already_finished", @store.incidents.last["kind"]
    assert_includes @store.verify["errors"], "parent_timestamp_order:#{child}"
  end

  def test_machine_completeness_stages_requests_and_unavailable_snapshots
    parent = @store.start(kind: "architecture", attributes: {planned_stages: ["plan", "implement"]})
    @store.event(kind: "stage", parent_id: parent, attributes: {stage: "plan"})
    checkpoint = @store.event(kind: "checkpoint", parent_id: parent, attributes: {artifact: {id: "external-only"}, content_availability: "raw_capture_not_authorized"})
    request = @store.event(kind: "llm_request", parent_id: parent, attributes: {usage: {input_tokens: nil}, complete: false, response_complete: false, usage_request_id: "wrong", request: "expected"})
    gap = @store.event(kind: "capture_gap", parent_id: parent, attributes: {error: "unknown"})
    @store.finish(parent, status: "success")
    report = @store.verify
    assert report["valid"]
    refute report["complete"]
    ["missing_stage:#{parent}:implement", "snapshot_unavailable:#{checkpoint}", "unknown_usage:#{request}", "response_incomplete:#{request}", "request_incomplete:#{request}", "usage_uncorrelated:#{request}", "capture_gap:#{gap}", "unknown_error:#{gap}"].each do |issue|
      assert_includes report["incomplete"], issue
    end
  end

  def test_planned_steps_alias_reports_missing_stages
    root = @store.start(kind: "run", attributes: {planned_steps: ["implement", "review"]})
    @store.event(kind: "step", parent_id: root, attributes: {stage: "implement"})
    @store.finish(root, status: "success")
    assert_includes @store.verify["incomplete"], "missing_stage:#{root}:review"
    refute_includes @store.verify["incomplete"], "missing_stage:#{root}:implement"
  end

  def test_planned_steps_preserve_contract_hashes_when_matching_stage_ids
    plan = [{"id" => "implement", "inputs" => {"repository" => "repository"}}, {"id" => "review", "outputs" => {"verdict" => "json"}}]
    root = @store.start(kind: "run", attributes: {planned_steps: plan})
    @store.event(kind: "stage", parent_id: root, attributes: {stage: "implement"})
    @store.finish(root, status: "success")
    assert_equal plan, @store.get(root).dig("attributes", "planned_steps")
    assert_includes @store.verify["incomplete"], "missing_stage:#{root}:review"
    refute_includes @store.verify["incomplete"], "missing_stage:#{root}:implement"
  end

  def test_historical_missing_accounting_and_unresolved_evidence_are_incomplete
    root = @store.start(kind: "historical_import", attributes: {accounting_complete: false})
    evidence = @store.event(kind: "historical_evidence", parent_id: root, attributes: {evidence_resolution: "not_resolved"})
    @store.finish(root, status: "success")
    report = @store.verify
    assert report["valid"]
    refute report["complete"]
    assert_includes report["incomplete"], "accounting_incomplete:#{root}"
    assert_includes report["incomplete"], "evidence_unresolved:#{evidence}"
    archive = @store.export(File.join(@directory, "historical-archive"))
    imported = AgentRuntime::Tracing::Store.import(archive, File.join(@directory, "historical-import"))
    assert imported.verify["valid"]
    refute imported.verify["complete"]
    assert_equal report["incomplete"], imported.verify["incomplete"]
  ensure
    imported&.close
  end

  def test_resolved_accounting_evidence_is_not_falsely_incomplete
    @store.event(kind: "historical_evidence", parent_id: nil, attributes: {accounting_complete: true, evidence_resolution: "resolved"})
    assert @store.verify["complete"]
  end

  def test_v1_schema_migration_preserves_rows
    path = File.join(@directory, "legacy")
    legacy = AgentRuntime::Tracing::Store.new(path)
    id = legacy.event(kind: "run", parent_id: nil)
    legacy.close
    database = SQLite3::Database.new(File.join(path, "trace.sqlite3"))
    database.execute("DROP TABLE schema_migrations")
    database.execute("DROP TABLE incidents")
    database.execute("PRAGMA user_version=1")
    database.close
    migrated = AgentRuntime::Tracing::Store.new(path)
    assert_equal id, migrated.get(id)["id"]
    assert migrated.verify["complete"]
    database = SQLite3::Database.new(File.join(path, "trace.sqlite3"))
    assert_equal 2, database.get_first_value("PRAGMA user_version")
    assert_equal [1, 2], database.execute("SELECT version FROM schema_migrations ORDER BY version").flatten
  ensure
    database&.close unless database&.closed?
    migrated&.close
  end

  def test_non_llm_requests_do_not_require_usage
    @store.event(kind: "tool_request", parent_id: nil)
    assert @store.verify["complete"]
    @store.event(kind: "llm_request", parent_id: nil, attributes: {stream_complete: false})
    refute @store.verify["complete"]
  end
end
