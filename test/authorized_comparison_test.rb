require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/authorized_comparison"

class AuthorizedComparisonTest < Minitest::Test
  Comparison = AgentRuntime::Benchmarks::AuthorizedComparison

  def test_exact_nine_frozen_schedule
    cells = Comparison.schedule
    assert_equal 9, cells.size
    assert_equal 9, cells.map { |cell| cell.fetch("id") }.uniq.size
    assert_equal [%w[single-agent fixed-workflow dsl], %w[fixed-workflow dsl single-agent], %w[dsl single-agent fixed-workflow]], cells.each_slice(3).map { |row| row.map { |cell| cell.fetch("solver_id") } }
    assert_equal [1, 2, 3], cells.map { |cell| cell.fetch("repetition") }.uniq
    assert_equal "live", Comparison.manifest.data.fetch("execution_mode")
    compute = Comparison.manifest(protocol: "compute")
    assert_equal 9, Comparison.schedule(compute).size
    refute_equal Comparison.manifest.digest, compute.digest
  end

  def test_no_default_live_execution
    error = assert_raises(ArgumentError) { Comparison.new.run(root: "unused", assets: "unused", destination: "unused", authorization_path: "unused", origin: "https://provider.invalid", credential_file: "unused", ledger_path: "unused") }
    assert_equal "--allow-live-execution required", error.message
  end

  def test_one_launcher_shared_across_three_stages_and_closed_on_failure
    events = []
    launcher = Object.new
    launcher.define_singleton_method(:start) { |**options| events << [:start, options] }
    launcher.define_singleton_method(:close) { events << :close }
    launcher.define_singleton_method(:audit_records) { [{"reserved" => true}] }
    launcher.define_singleton_method(:logs) { "trusted log" }
    evidence = []
    factory = -> {
      events << :factory
      launcher
    }
    executor = ->(request, active) {
      assert_same launcher, active
      events << request.step_id
    }
    adapter = Comparison::CellAdapter.new(launcher_factory: factory, executor: executor, evidence: evidence)
    assert_raises(RuntimeError) do
      adapter.with_cell({"id" => "cell-1"}) do
        3.times { |index| adapter.execute(AgentRuntime::Request.new(step_id: index, timeout: 600)) }
        raise "cancelled"
      end
    end
    assert_equal 1, events.count(:factory)
    assert_equal 1, events.count(:close)
    assert_equal [0, 1, 2], events.grep(Integer)
    assert_equal "cell-1", evidence.first.fetch("cell_id")
    assert_raises(RuntimeError) { adapter.execute(:outside) }
  end

  def test_prepare_does_not_authorize_or_start_a_launcher
    result = Comparison.prepare(origin: "https://provider.invalid", assets: ".agru/nl2repo", ledger_path: File.join(File.realpath(Dir.tmpdir), "agru-authorization-test-ledger.json"))
    refute result.fetch("authorized")
    refute result.fetch("provider_requests_performed")
    assert_equal [17001, 17002, 17003], result.fetch("schedule").map { |cell| cell.fetch("seed") }.uniq
    assert_equal Comparison.manifest.digest, result.fetch("bindings").fetch("experiment_digest")
  end

  def test_launch_failure_is_terminal_and_provider_evidence_is_saved
    evidence = []
    launcher = Object.new
    launcher.define_singleton_method(:start) { |**| raise "offline launch failure" }
    launcher.define_singleton_method(:close) {}
    launcher.define_singleton_method(:audit_records) { [] }
    launcher.define_singleton_method(:logs) { "failed startup" }
    adapter = Comparison::CellAdapter.new(launcher_factory: -> { launcher }, executor: ->(*) { flunk "must not execute" }, evidence: evidence)
    store = Object.new
    saved = []
    store.define_singleton_method(:save_report) { |report| saved << Marshal.load(Marshal.dump(report)) }
    runner = Comparison.const_get(:Runner, false).new(cell_adapter: adapter, store: store, root: ".agru/test", registry: nil, solvers: {})
    cell = {"id" => "failed-cell", "transitions" => []}
    report = {"cells" => [cell]}
    runner.send(:execute_cell, report, cell, nil)
    assert_equal "completed", cell.fetch("status")
    assert_equal "error", cell.fetch("execution_status")
    assert_includes cell.fetch("error"), "offline launch failure"
    assert_equal evidence, saved.last.fetch("provider_evidence")
  end

  def test_authorization_binds_ledger_path_and_collector_bytes
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      options = {origin: "https://provider.invalid", assets: root}
      first = Comparison.bindings(**options, ledger_path: File.join(root, "first.json"))
      second = Comparison.bindings(**options, ledger_path: File.join(root, "second.json"))
      refute_equal first.fetch("runtime_digest"), second.fetch("runtime_digest")
      identity = AgentRuntime::Benchmarks::ReleaseIdentity.capture(root: File.expand_path("..", __dir__))
      collector = "script/nl2repo_audited_collector.py"
      assert_equal Digest::SHA256.file(File.expand_path("../#{collector}", __dir__)).hexdigest, identity.fetch("files").fetch(collector)
      File.write(File.join(root, "environment.json"), "changed")
      changed = Comparison.bindings(**options, ledger_path: File.join(root, "first.json"))
      refute_equal first.fetch("task_digest"), changed.fetch("task_digest")
    end
  end

  def test_complete_nine_cell_injected_execution_and_actual_audited_regrade
    skip "explicit offline audited Docker opt-in required" unless ENV["AGRU_AUTHORIZED_OFFLINE_E2E"] == "1"
    Dir.mktmpdir do |directory|
      root = File.realpath(directory)
      assets = File.expand_path(ENV.fetch("AGRU_AUTHORIZED_ASSETS", ".agru/nl2repo"))
      ledger = File.join(root, "budget.json")
      credential = File.join(root, "credential")
      File.write(credential, "offline-unused", perm: 0o600)
      contract = {"version" => 1, "reviewed" => true, "provider" => "https://provider.invalid", "model" => "cx/gpt-6-luna-low", "evidence" => "offline injection only, not live billing evidence",
                  "inputTokensPerByte" => 4, "inputTokenOverhead" => 100, "inputPriceNanosPerMillion" => 1, "outputPriceNanosPerMillion" => 1}
      authorization = {"bindings" => Comparison.bindings(origin: "https://provider.invalid", assets: assets, ledger_path: ledger),
                       "limits" => {"requests_per_cell" => 12, "total_tokens_per_cell" => 384000, "completion_tokens_per_request" => 32000,
                                    "seconds_per_cell" => 600, "money_per_cell" => 1, "money_per_experiment" => 9, "currency" => "USD"},
                       "expires_at" => Time.now.to_i + 3600, "reviewed_contract" => contract,
                       "reviewed_contract_digest" => Digest::SHA256.hexdigest(JSON.generate(contract)), "quota" => {}}
      path = File.join(root, "authorization.json")
      authorization["quota"] = contract.slice("inputTokensPerByte", "inputTokenOverhead", "inputPriceNanosPerMillion", "outputPriceNanosPerMillion").merge("requests" => 12, "tokens" => 384000, "moneyNanos" => 1, "expiresAt" => authorization.fetch("expires_at") * 1000)
      File.write(path, JSON.generate(authorization))
      starts = []
      factory = -> {
        launcher = Object.new
        launcher.define_singleton_method(:start) { |**values| starts << values }
        launcher.define_singleton_method(:close) {}
        launcher.define_singleton_method(:audit_records) { [] }
        launcher.define_singleton_method(:logs) { "offline injected execution, no upstream" }
        launcher
      }
      executor = ->(request, _launcher) {
        repository = request.inputs&.fetch("repository", nil) || request.workspace
        FileUtils.mkdir_p(repository)
        File.write(File.join(repository, "offline-marker.txt"), "synthetic ordinary submission")
        AgentRuntime::Result.new(status: "success", outputs: {"text" => "offline synthetic completion", "repository" => repository}, logs: "", duration: 0, usage: {}, cost: nil)
      }
      destination = File.join(root, "freeze")
      Comparison.new(launcher_factory: factory, executor: executor).run(root: File.join(root, "run"), assets: assets, destination: destination,
        authorization_path: path, origin: "https://provider.invalid", credential_file: credential, ledger_path: ledger, allow_live: true)
      report = JSON.parse(File.read(File.join(destination, "experiment.json"))).fetch("report")
      assert_equal 9, starts.size
      assert_equal 9, report.fetch("cells").size
      assert report.fetch("cells").all? { |cell| cell.fetch("grading_attempts", []).size == 2 }, report.fetch("cells").map { |cell| cell.slice("solver_id", "status", "error", "execution_status", "grading_attempts") }.inspect
      assert_equal 9, report.fetch("provider_evidence").size
    end
  end
end
