require_relative "test_helper"
require "agent_runtime/execution/local_token_provider"

class LocalTokenProviderTest < Minitest::Test
  def test_stderr_flood_cannot_block_ready_and_is_never_persisted
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "scripts"))
      File.write(File.join(root, "scripts/local_token_gateway.cjs"), <<~JS)
        process.stderr.write('SECRET_FROM_CHILD'.repeat(100000), () => {
          console.log(JSON.stringify({ready:true,relay_volume:'agru-test-missing-stderr-relay'}));
          console.log(JSON.stringify({audit:{type:'offline_test'}}));
        });
        process.stdin.resume(); process.stdin.on('end',()=>process.exit(0));
      JS
      audit = File.join(root, "audit.jsonl")
      provider = AgentRuntime::Execution::LocalTokenProvider.new(root: root, ledger: {}, credential: "SECRET_CREDENTIAL", audit_path: audit, offline: true)
      begin
        Timeout.timeout(5) do
          provider.start(attempt_id: "a", cell_id: "c", model_profile: {"model" => AgentRuntime::Execution::TokenBudgetLedger::MODEL}, timeout: 600)
        end
        config = JSON.parse(File.read(provider.instance_variable_get(:@directory) + "/config.json"))
        assert_equal 600000, config.fetch("stageTimeoutMs")
        assert_equal 110000, config.fetch("gateway").fetch("timeoutMs")
      ensure
        provider.close
      end
      assert_equal({"stderr" => "observed_redacted", "exit" => "success"}, provider.process_diagnostics)
      records = File.read(audit)
      assert_includes records, "offline_test"
      assert_includes records, "gateway_process"
      refute_includes records, "SECRET"
    end
  end
end
