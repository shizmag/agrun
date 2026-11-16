require_relative "test_helper"
require "tmpdir"
require_relative "../lib/agent_runtime/execution/authorized_provider"
require_relative "../lib/agent_runtime/execution/authorized_provider_launcher"

class AuthorizedProviderTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("authorized-provider-test-")
    @credential = File.join(@root, "credential")
    File.write(@credential, "offline-test-only", perm: 0o600)
    @bindings = AgentRuntime::Execution::AuthorizedProvider::BINDINGS.to_h { |key| [key, "a" * 64] }
    @bindings.merge!("route" => "reviewed-route", "model" => "cx/gpt-6-luna-low",
      "upstream_origin_digest" => Digest::SHA256.hexdigest("https://provider.example"))
    @limits = {"requests_per_cell" => 12, "total_tokens_per_cell" => 384000,
               "completion_tokens_per_request" => 32000, "seconds_per_cell" => 600,
               "money_per_cell" => 1, "money_per_experiment" => 9, "currency" => "USD"}
  end

  def teardown
    File.unlink(@credential)
    Dir.rmdir(@root)
  end

  def provider(origin: "https://provider.example")
    AgentRuntime::Execution::AuthorizedProvider.new(reviewed_origin: origin,
      credential_file: @credential, bindings: @bindings, limits: @limits, wall_clock: -> { 100 })
  end

  def authorization
    {"bindings" => @bindings.dup, "limits" => @limits.dup, "expires_at" => 101}
  end

  def config(instance = provider, auth = authorization)
    instance.relay_config(authorization: auth, attempt_id: "attempt", cell_id: "cell")
  end

  def test_configuration_only_contains_no_secret_or_tls_override
    result = config
    assert_equal ["https://provider.example"], result.fetch("approvedOrigins")
    assert_equal @credential, result.fetch("credentialFile")
    refute_includes JSON.generate(result), "offline-test-only"
    refute result.key?("caFile")
    refute result.key?("rejectUnauthorized")
    assert result.frozen?
    assert result.fetch("inference").frozen?
  end

  def test_exact_authorization_and_expiry_are_required
    auth = authorization
    auth["limits"]["requests_per_cell"] = 13
    assert_raises(ArgumentError) { config(provider, auth) }
    auth = authorization
    auth["expires_at"] = 100
    assert_raises(ArgumentError) { config(provider, auth) }
    auth = authorization
    auth["bindings"]["experiment_digest"] = "b" * 64
    assert_raises(ArgumentError) { config(provider, auth) }
  end

  def test_rejects_unreviewed_endpoint_forms
    %w[http://provider.example https://user:secret@provider.example https://provider.example/path https://provider.example?key=x].each do |origin|
      assert_raises(ArgumentError) { provider(origin: origin) }
    end
  end

  def test_credentials_must_be_private
    File.chmod(0o644, @credential)
    assert_raises(ArgumentError) { provider }
  end

  def test_limits_are_not_silently_defaulted
    @limits.delete("money_per_cell")
    assert_raises(ArgumentError) { provider }
  end

  def test_launcher_builds_isolated_trusted_container_without_running_docker
    quota = {"requests" => 12, "tokens" => 384000, "money" => 1, "expiresAt" => 101000}
    auth = authorization.merge("quota" => quota)
    klass = Class.new(AgentRuntime::Execution::AuthorizedProviderLauncher) do
      attr_reader :commands

      def docker(*argv)
        (@commands ||= []) << argv
        {"status" => "success", "stdout" => ""}
      end
    end
    caps = {"requests" => 12, "tokens" => 384000, "money" => 1}
    cells = (["cell"] + (1..8).map { |i| "cell#{i}" }).to_h { |id| [id, caps] }
    ledger = AgentRuntime::Execution::ProviderBudgetLedger.new(path: File.join(@root, "ledger"),
      experiment_digest: @bindings["experiment_digest"], cells: cells,
      totals: {"requests" => 108, "tokens" => 3456000, "money" => 9}, expires_at: 101, wall_clock: -> { 100 })
    launcher = klass.new(provider: provider, authorization: auth, quota: quota, ledger: ledger)
    launcher.start(attempt_id: "attempt", cell_id: "cell", model_profile: "cx/gpt-6-luna-low")
    run = launcher.commands.find { |cmd| cmd.first == "run" }
    assert_includes run, "--read-only"
    assert_includes run, "no-new-privileges"
    assert_includes run, "type=bind,src=#{@credential},dst=/credential,readonly"
    refute_includes run.join(" "), "offline-test-only"
    launcher.close
    assert launcher.commands.any? { |cmd| cmd.first == "stop" }
    assert_raises(RuntimeError) do
      launcher.start(attempt_id: "attempt", cell_id: "cell", model_profile: "cx/gpt-6-luna-low")
    end
  ensure
    launcher&.close
    %w[ledger ledger.lock].each do |name|
      path = File.join(@root, name)
      File.unlink(path) if File.exist?(path)
    end
  end
end
