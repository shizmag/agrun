require_relative "test_helper"
require "tmpdir"
require_relative "../lib/agent_runtime/execution/token_budget_ledger"

class TokenBudgetLedgerTest < Minitest::Test
  def ledger(path, **options)
    AgentRuntime::Execution::TokenBudgetLedger.new(path: path, intent_digest: "a" * 64,
      total_tokens: 20, **options)
  end

  def reserve(ledger, id)
    ledger.begin_request(request_id: id, cell_id: "cell", attempt_id: id,
      input_tokens: 6, completion_tokens: 4)
  end

  def test_restart_unknown_usage_and_no_refund
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger")
      reserve(ledger(path), "one")
      ledger(path).settle(request_id: "one", observed_model: "cx/gpt-6-luna-low", usage: nil, reporter: "gateway")
      reserve(ledger(path), "two")
      ledger(path).settle(request_id: "two", observed_model: "cx/gpt-6-luna-low",
        usage: {"prompt_tokens" => 1, "completion_tokens" => 1}, reporter: "gateway")
      assert_raises(ArgumentError) { reserve(ledger(path), "three") }
      assert_raises(ArgumentError) do
        ledger(path).settle(request_id: "two", observed_model: "cx/gpt-6-luna-low", usage: nil, reporter: "gateway")
      end
      assert_raises(ArgumentError) { reserve(ledger(path), "one") }
      assert_raises(ArgumentError) { ledger(path, total_tokens: 21) }
      assert_raises(ArgumentError) { ledger(path, intent_digest: "b" * 64) }
      assert_raises(ArgumentError) { ledger(path, model: "other") }
      copy = File.join(dir, "copy")
      File.write(copy, File.read(path), mode: "w", perm: 0o600)
      assert_raises(ArgumentError) { ledger(copy) }
    end
  end

  def test_process_race_shares_one_cumulative_limit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger")
      ledger(path)
      children = 6.times.map do |i|
        fork do
          reserve(ledger(path), i.to_s)
          exit! 0
        rescue ArgumentError
          exit! 1
        end
      end
      statuses = children.map { |pid| Process.waitpid2(pid).last.exitstatus }
      assert_equal 2, statuses.count(0)
      assert_equal 4, statuses.count(1)
    end
  end

  def test_snapshot_preserves_unknown_model_and_cumulative_usage
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger")
      reserve(ledger(path), "one")
      ledger(path).settle(request_id: "one", observed_model: nil,
        usage: {"prompt_tokens" => 2, "completion_tokens" => 1}, reporter: "gateway")
      reserve(ledger(path), "two")
      assert_equal({"total_tokens" => 20, "reserved_tokens" => 20,
                    "request_count" => 2, "known_usage_tokens" => 3,
                    "unknown_usage_count" => 1, "unknown_model_count" => 2,
                    "halted" => false}, ledger(path).snapshot)
      settlement = JSON.parse(File.readlines(path)[2])["data"]
      assert_nil settlement["observed_model"]
    end
  end

  def test_route_and_usage_violations_are_durable
    [{model: "other", usage: nil},
      {model: "cx/gpt-6-luna-low", usage: {"prompt_tokens" => 7, "completion_tokens" => 0}}].each do |input|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ledger")
        reserve(ledger(path), "one")
        error = assert_raises(ArgumentError) do
          ledger(path).settle(request_id: "one", observed_model: input[:model], usage: input[:usage], reporter: "gateway")
        end
        if input[:model] == "other"
          assert_equal "token_budget_model_name_mismatch_not_attestation", error.message
        end
        assert_raises(ArgumentError) { reserve(ledger(path), "two") }
      end
    end
  end

  def test_corruption_permissions_and_symlinks_fail_closed
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger")
      reserve(ledger(path), "one")
      File.open(path, "a") { |f| f.write("partial") }
      assert_raises(ArgumentError) { ledger(path) }
      File.chmod(0o644, path)
      assert_raises(ArgumentError) { ledger(path) }
      link = File.join(dir, "link")
      File.symlink(path, link)
      assert_raises(ArgumentError) { ledger(link) }
    end
  end
end
