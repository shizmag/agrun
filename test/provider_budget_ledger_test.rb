require_relative "test_helper"
require "tmpdir"
require_relative "../lib/agent_runtime/execution/provider_budget_ledger"

class ProviderBudgetLedgerTest < Minitest::Test
  def ledger(path, expiry: 200)
    caps = {"requests" => 12, "tokens" => 384000, "money" => 1}
    AgentRuntime::Execution::ProviderBudgetLedger.new(path: path, experiment_digest: "a" * 64,
      cells: (1..9).to_h { |i| ["cell#{i}", caps] },
      totals: {"requests" => 108, "tokens" => 3456000, "money" => 9},
      expires_at: expiry, wall_clock: -> { 100 })
  end

  def test_reopen_rejects_reuse_and_corruption
    Dir.mktmpdir do |root|
      path = File.join(root, "ledger")
      ledger(path).reserve!(cell_id: "cell1", attempt_id: "one")
      assert_raises(ArgumentError) { ledger(path).reserve!(cell_id: "cell1", attempt_id: "two") }
      assert_raises(ArgumentError) { ledger(path).reserve!(cell_id: "cell2", attempt_id: "one") }
      assert_raises(ArgumentError) { ledger(path, expiry: 300) }
      File.write(path, File.read(path).sub('"one"', '"tampered"'))
      assert_raises(ArgumentError) { ledger(path) }
    end
  end

  def test_concurrent_processes_admit_cell_only_once
    Dir.mktmpdir do |root|
      path = File.join(root, "ledger")
      ledger(path)
      children = 4.times.map do |i|
        fork do
          ledger(path).reserve!(cell_id: "cell1", attempt_id: "attempt#{i}")
          exit! 0
        rescue ArgumentError
          exit! 1
        end
      end
      statuses = children.map { |pid| Process.waitpid2(pid).last.exitstatus }
      assert_equal 1, statuses.count(0)
      assert_equal 3, statuses.count(1)
    end
  end

  def test_expiry
    Dir.mktmpdir do |root|
      assert_raises(ArgumentError) do
        ledger(File.join(root, "ledger"), expiry: 100).reserve!(cell_id: "cell1", attempt_id: "one")
      end
    end
  end

  def test_deleted_ledger_cannot_be_recreated_when_lock_remains
    Dir.mktmpdir do |root|
      path = File.join(root, "ledger")
      ledger(path).reserve!(cell_id: "cell1", attempt_id: "one")
      File.unlink(path)
      assert_raises(ArgumentError) { ledger(path) }
    end
  end
end
