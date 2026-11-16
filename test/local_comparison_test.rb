require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/local_comparison"

class LocalComparisonTest < Minitest::Test
  def test_stage_allocations_are_frozen_and_reserve_terminal_handoffs
    manifest = AgentRuntime::Benchmarks::LocalComparison.manifest
    limits = manifest.data.fetch("limits")
    assert_equal [3, 7, 2], %w[planner coder reviewer].map { |role| limits.fetch("#{role}_inference_requests") }
    assert_equal 12, limits.fetch("cell_inference_requests")
  end

  def test_exact_model_nine_cell_manifest_and_schedule
    comparison = AgentRuntime::Benchmarks::LocalComparison
    manifest = comparison.manifest
    assert_equal 9, manifest.cells.size
    assert_equal "live", manifest.data.fetch("execution_mode")
    assert_equal "cx/gpt-6-luna-low", manifest.data.fetch("models").first.fetch("model_profile").fetch("model")
    schedule = AgentRuntime::Benchmarks::AuthorizedComparison.schedule(manifest)
    assert_equal 9, schedule.map { |cell| cell.fetch("id") }.uniq.size
    assert_equal %w[single-agent fixed-workflow dsl], schedule.first(3).map { |cell| cell.fetch("solver_id") }
  end

  def test_no_live_execution_without_explicit_opt_in
    comparison = AgentRuntime::Benchmarks::LocalComparison.new(root: ".agru", assets: ".agru/nl2repo")
    assert_raises(ArgumentError) { comparison.run(authorization_path: "absent", credential_file: "absent") }
  end

  def test_temporary_ledger_requires_injected_provider
    assert_raises(ArgumentError) do
      AgentRuntime::Benchmarks::LocalComparison.new(root: ".agru", assets: ".agru/nl2repo", test_ledger_path: "temporary")
    end
  end

  def test_saved_identity_halt_rejects_run_before_provider_or_execution_state
    in_tmp do |dir|
      comparison_class = AgentRuntime::Benchmarks::LocalComparison
      root = File.join(dir, "runs")
      assets = File.join(dir, "assets")
      FileUtils.mkdir_p(assets)
      ledger_path = File.join(dir, "tokens.jsonl")
      ledger = AgentRuntime::Execution::TokenBudgetLedger.new(path: ledger_path,
        intent_digest: Digest::SHA256.file(comparison_class::INTENT).hexdigest,
        total_tokens: 1_000_000_000)
      ledger.begin_request(request_id: "saved-request", cell_id: "saved-cell",
        attempt_id: "saved-attempt", input_tokens: 10, completion_tokens: 10)
      settlement_error = assert_raises(ArgumentError) do
        ledger.settle(request_id: "saved-request", observed_model: "wrong-model",
          usage: {"prompt_tokens" => 2, "completion_tokens" => 3}, reporter: "offline-test")
      end
      assert_equal "token_budget_model_name_mismatch_not_attestation", settlement_error.message
      assert ledger.snapshot.fetch("halted")
      saved_ledger = File.binread(ledger_path)

      authorization_path = File.join(dir, "authorization.json")
      File.write(authorization_path, JSON.generate("bindings" => comparison_class.bindings(assets: assets),
        "expires_at" => Time.now.to_f + 3600))
      credential_file = File.join(dir, "credential")
      File.write(credential_file, "offline-test-only", mode: "w", perm: 0o600)
      provider_calls = 0
      provider_factory = ->(*) do
        provider_calls += 1
        flunk "halted ledger must not invoke provider factory"
      end
      comparison = comparison_class.new(root: root, assets: assets,
        provider_factory: provider_factory, test_ledger_path: ledger_path)

      error = assert_raises(ArgumentError) do
        comparison.run(authorization_path: authorization_path, credential_file: credential_file, allow_live: true)
      end
      assert_match(/\Atoken_budget_halted:/, error.message)
      assert_equal 0, provider_calls
      refute_path_exists File.join(root, "local-token-comparison")
      refute_path_exists File.join(root, "store")
      refute_path_exists root
      assert_equal saved_ledger, File.binread(ledger_path)
    end
  end
end
