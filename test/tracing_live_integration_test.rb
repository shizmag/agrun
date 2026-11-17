require_relative "../test/test_helper"
require_relative "../lib/agent_runtime/benchmarks/local_comparison"

class TracingLiveIntegrationTest < Minitest::Test
  Comparison = AgentRuntime::Benchmarks::LocalComparison

  class FakeProvider
    attr_reader :closed, :started

    def initialize(records: [], fail_start: false, fail_close: false)
      @records, @fail_start, @fail_close = records, fail_start, fail_close
    end

    def start(**options)
      @started = options
      raise "fake provider start failure" if @fail_start
      {"volume" => "agru-local-0123456789abcdef-relay"}
    end

    def close
      @closed = true
      raise "fake provider close failure" if @fail_close
    end

    def trace_capture_records
      raise "capture read before provider stopped" unless @closed
      @records
    end
  end

  # Scoped runtime substitution only: never launches Docker or a provider process.
  def replacing(object, method, replacement)
    original = object.method(method)
    object.define_singleton_method(method) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method, original)
  end

  def request(attempt_id = nil)
    request = AgentRuntime::Request.new
    request.run_id, request.step_id, request.attempt = "run", "coder", 1
    request.config = {"role" => "coder", "prompt" => "fake-only prompt"}
    request.config["trace_attempt_id"] = attempt_id if attempt_id
    request.timeout = 30
    request
  end

  def active_cell(directory)
    File.write(File.join(directory, "active-cell.json"), JSON.generate("cell_id" => "cell",
      "deadline" => Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60))
  end

  def envelope
    payload = {"request_id" => "provider-request", "complete" => true, "usage" => {"total_tokens" => 3},
               "request_body" => {"messages" => [{"content" => "DO_NOT_COPY_RAW"}]}}
    serialized = JSON.generate(payload)
    {"payload" => payload, "payload_json" => serialized, "digest" => Digest::SHA256.hexdigest(serialized)}
  end

  def with_trace(directory, raw: false)
    trace = AgentRuntime::Tracing::Store.new(File.join(directory, "trace"), raw_content: raw)
    session = AgentRuntime::Tracing::Session.new(trace: trace, artifacts: nil, raw_content: raw)
    attempt = session.start("attempt")
    yield trace, session, attempt
  ensure
    trace&.close
  end

  def stub_execution(error: nil)
    fake = Object.new
    fake.define_singleton_method(:execute) do |_request|
      raise error if error
      AgentRuntime::Result.new.tap { |result| result.status, result.logs = "success", {} }
    end
    replacing(AgentRuntime::Adapters::SandboxOpenCodeCLI, :new, ->(**) { fake }) { yield }
  end

  def test_enabled_capture_uses_private_directory_and_real_attempt_parent_without_raw_copy
    in_tmp do |dir|
      active_cell(dir)
      with_trace(dir) do |trace, session, attempt|
        capture = nil
        provider = FakeProvider.new(records: [envelope])
        factory = ->(trace_capture:) {
          capture = trace_capture
          provider
        }
        adapter = Comparison::AttemptAdapter.new(provider_factory: factory, directory: dir, model_profile: {}, tracing: session)
        stub_execution do
          assert_equal "success", adapter.execute(request(attempt)).status
        end
        assert provider.closed
        assert_equal attempt, capture.fetch(:trace_id)
        assert_equal false, capture.fetch(:raw_authorized)
        assert File.directory?(capture.fetch(:directory))
        assert_equal 0o700, File.stat(capture.fetch(:directory)).mode & 0o777
        db = trace.instance_variable_get(:@db)
        row = db.get_first_row("SELECT * FROM entities WHERE kind='llm_request'")
        assert_equal attempt, row.fetch("parent_id")
        attributes = JSON.parse(row.fetch("attributes"))
        assert_equal "provider-request", attributes.fetch("request")
        refute attributes.key?("payload")
        assert_empty Dir.glob(File.join(trace.root, "blobs", "**", "*"))
        refute JSON.generate(attributes).include?("DO_NOT_COPY_RAW")
      end
    end
  end

  def test_raw_opt_in_is_forwarded_and_payload_is_ingested_only_when_enabled
    in_tmp do |dir|
      active_cell(dir)
      with_trace(dir, raw: true) do |trace, session, attempt|
        capture = nil
        factory = ->(trace_capture:) {
          capture = trace_capture
          FakeProvider.new(records: [envelope])
        }
        adapter = Comparison::AttemptAdapter.new(provider_factory: factory, directory: dir, model_profile: {}, tracing: session)
        stub_execution { adapter.execute(request(attempt)) }
        assert_equal true, capture.fetch(:raw_authorized)
        row = trace.instance_variable_get(:@db).get_first_row("SELECT * FROM entities WHERE kind='llm_request'")
        assert JSON.parse(row.fetch("attributes")).key?("payload")
      end
    end
  end

  def test_disabled_trace_preserves_zero_argument_factory_and_has_no_capture_directory
    in_tmp do |dir|
      active_cell(dir)
      provider = FakeProvider.new
      adapter = Comparison::AttemptAdapter.new(provider_factory: -> { provider }, directory: dir, model_profile: {})
      stub_execution { assert_equal "success", adapter.execute(request).status }
      assert provider.closed
      assert_empty Dir.glob(File.join(dir, "provider-capture-*"))
    end
  end

  def test_failure_paths_still_close_and_record_an_explicit_gap
    [:start, :execute, :close].each do |failure|
      in_tmp do |dir|
        active_cell(dir)
        with_trace(dir) do |trace, session, attempt|
          provider = FakeProvider.new(fail_start: failure == :start, fail_close: failure == :close)
          adapter = Comparison::AttemptAdapter.new(provider_factory: ->(trace_capture:) { provider },
            directory: dir, model_profile: {}, tracing: session)
          stub_execution(error: (failure == :execute) ? "fake execution failure" : nil) do
            assert_raises(RuntimeError) { adapter.execute(request(attempt)) }
          end
          assert provider.closed
          row = trace.instance_variable_get(:@db).get_first_row("SELECT * FROM entities WHERE kind='capture_gap'")
          assert_equal attempt, row.fetch("parent_id")
        end
      end
    end
  end

  def test_trace_options_do_not_bypass_live_gate_or_create_trace_output
    in_tmp do |dir|
      destination = File.join(dir, "trace")
      comparison = Comparison.new(root: dir, assets: dir)
      error = assert_raises(ArgumentError) do
        comparison.run(authorization_path: "absent", credential_file: "absent", trace_root: destination, raw_content: true)
      end
      assert_equal "explicit local live opt-in required", error.message
      refute_path_exists destination
    end
  end

  def test_run_wires_store_session_and_closes_trace_store_on_assembly_failure
    in_tmp do |dir|
      assets = File.join(dir, "assets")
      FileUtils.mkdir_p(assets)
      authorization = File.join(dir, "authorization.json")
      credential = File.join(dir, "credential")
      File.write(credential, "fake-unused", perm: 0o600)
      File.write(authorization, JSON.generate("bindings" => Comparison.bindings(assets: assets), "expires_at" => Time.now.to_f + 3600))
      comparison = Comparison.new(root: File.join(dir, "runs"), assets: assets,
        provider_factory: ->(*) { flunk "no provider expected" }, test_ledger_path: File.join(dir, "tokens.jsonl"))
      created = nil
      original_new = AgentRuntime::Tracing::Store.method(:new)
      replacing(AgentRuntime::Tracing::Store, :new, ->(*args, **kwargs) { created = original_new.call(*args, **kwargs) }) do
        replacing(AgentRuntime::Benchmarks::NL2RepoAuditedGrader, :new, ->(store:, **) {
          assert_instance_of AgentRuntime::Tracing::Session, store.tracing
          assert_same created, store.tracing.trace
          assert_equal true, store.tracing.raw_content
          raise "fake assembly failure"
        }) do
          assert_raises(RuntimeError) do
            comparison.run(authorization_path: authorization, credential_file: credential, allow_live: true,
              trace_root: File.join(dir, "trace"), raw_content: true)
          end
        end
      end
      assert created
      assert_raises(ArgumentError, SQLite3::Exception) { created.instance_variable_get(:@db).execute("SELECT 1") }
    end
  end
end
