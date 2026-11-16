require_relative "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../lib/agent_runtime/execution/authorized_provider_launcher"
require_relative "../lib/agent_runtime/execution/authorized_provider"

class AuthorizedProviderDockerTest < Minitest::Test
  def test_actual_relay_lifecycle_without_provider_requests
    skip "set AGRU_AUTHORIZED_PROVIDER_DOCKER=1 for local Docker lifecycle" unless ENV["AGRU_AUTHORIZED_PROVIDER_DOCKER"] == "1"
    Dir.mktmpdir("authorized-provider-docker-") do |root|
      credential = File.join(root, "credential")
      secret = "offline-dummy-#{SecureRandom.hex(16)}"
      File.write(credential, secret, perm: 0o600)
      origin = "https://provider.invalid"
      bindings = AgentRuntime::Execution::AuthorizedProvider::BINDINGS.to_h { |key| [key, "a" * 64] }
      bindings.merge!("model" => "cx/gpt-6-luna-low", "route" => "offline-fixture",
        "upstream_origin_digest" => Digest::SHA256.hexdigest(origin))
      limits = {"requests_per_cell" => 1, "total_tokens_per_cell" => 1000,
                "completion_tokens_per_request" => 100, "seconds_per_cell" => 10,
                "money_per_cell" => 1, "money_per_experiment" => 9, "currency" => "USD"}
      expiry = Time.now.to_f + 60
      quota = {"requests" => 1, "tokens" => 1000, "money" => 1, "expiresAt" => expiry * 1000,
               "inputTokensPerByte" => 1, "inputTokenOverhead" => 1,
               "inputPricePerMillion" => 1, "outputPricePerMillion" => 1,
               "pricingEvidence" => "synthetic offline", "tokenBoundEvidence" => "synthetic offline"}
      auth = {"bindings" => bindings, "limits" => limits, "expires_at" => expiry, "quota" => quota}
      provider = AgentRuntime::Execution::AuthorizedProvider.new(reviewed_origin: origin,
        credential_file: credential, bindings: bindings, limits: limits)
      caps = {"requests" => 1, "tokens" => 1000, "money" => 1}
      cells = (["fixture"] + (1..8).map { |i| "cell#{i}" }).to_h { |id| [id, caps] }
      ledger = AgentRuntime::Execution::ProviderBudgetLedger.new(path: File.join(root, "ledger"),
        experiment_digest: bindings["experiment_digest"], cells: cells,
        totals: {"requests" => 9, "tokens" => 9000, "money" => 9}, expires_at: expiry)
      launcher = AgentRuntime::Execution::AuthorizedProviderLauncher.new(provider: provider,
        authorization: auth, quota: quota, ledger: ledger)
      begin
        launcher.start(attempt_id: "offline", cell_id: "fixture", model_profile: bindings["model"])
        # Fixture solver has no network and only the Unix volume. Inspect, never
        # connect to the socket: no HTTP or upstream provider request is sent.
        result = AgentRuntime::Adapters::ProcessRunner.new.call(argv: ["docker", "run", "--rm",
          "--network", "none", "--mount", "type=volume,src=#{launcher.relay_volume},dst=/relay",
          launcher.image, "node", "-e", <<~JS], cwd: Dir.pwd, timeout: 30)
            const fs = require('node:fs');
            const assert = require('node:assert/strict');
            const stat = fs.statSync('/relay/provider.sock');
            assert(stat.isSocket()); assert.equal(stat.mode & 0o777, 0o600);
            assert(!fs.existsSync('/credential')); assert(!fs.existsSync('/trusted'));
            assert.deepEqual(fs.readdirSync('/relay'), ['provider.sock']);
          JS
        assert_equal "success", result["status"], result.inspect
      ensure
        launcher.close
      end
      assert_empty launcher.audit_records
      assert_empty launcher.logs
      refute_includes launcher.logs, secret
      refute_includes JSON.generate(launcher.audit_records), secret
    end
  end
end
