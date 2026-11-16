require "json"
require "tmpdir"
require "securerandom"
require "fileutils"
require_relative "simulated_provider"
require_relative "provider_budget_ledger"

module AgentRuntime
  module Execution
    # One non-restartable relay per authorized cell. Solver gets only the socket
    # volume and must remain --network none. This is not an experiment scheduler.
    class AuthorizedProviderLauncher
      attr_reader :relay_volume, :image, :logs

      def initialize(provider:, authorization:, quota:, ledger:)
        @provider = provider
        @authorization = JSON.parse(JSON.generate(authorization))
        @quota = JSON.parse(JSON.generate(quota))
        raise ArgumentError, "authorized_provider_ledger_required" unless ledger.is_a?(ProviderBudgetLedger)
        @ledger = ledger
        @image = SimulatedProvider::IMAGE
        @prefix = "agru-authorized-#{SecureRandom.hex(8)}"
        @relay_volume = "#{@prefix}-relay"
      end

      def start(attempt_id:, cell_id:, model_profile:)
        raise "authorized provider already started" if @started
        @started = true
        config = @provider.relay_config(authorization: @authorization,
          attempt_id: attempt_id, cell_id: cell_id)
        model = model_profile.is_a?(Hash) ? model_profile["model"] : model_profile
        raise ArgumentError, "authorized_provider_model_mismatch" unless model == config.fetch("model")
        limits = @authorization.fetch("limits")
        unless @authorization["quota"] == @quota &&
            @quota["requests"] == limits["requests_per_cell"] &&
            @quota["tokens"] == limits["total_tokens_per_cell"] &&
            @quota["moneyNanos"].is_a?(Integer) && @quota["moneyNanos"] == limits["money_per_cell"] &&
            @quota["moneyNanos"] <= limits["money_per_experiment"] &&
            @quota["expiresAt"] == @authorization.fetch("expires_at") * 1000
          raise ArgumentError, "authorized_provider_quota_mismatch"
        end
        reservation = @ledger.reserve!(cell_id: cell_id, attempt_id: attempt_id)
        unless reservation["experiment_digest"] == @authorization.fetch("bindings").fetch("experiment_digest") &&
            reservation["caps"] == {"requests" => @quota["requests"], "tokens" => @quota["tokens"], "money" => @quota["moneyNanos"]} &&
            reservation["expires_at"] == @authorization.fetch("expires_at") &&
            reservation.fetch("totals").fetch("money") <= limits.fetch("money_per_experiment")
          raise ArgumentError, "authorized_provider_ledger_mismatch"
        end
        @root = Dir.mktmpdir("agru-authorized-provider-")
        File.chmod(0o700, @root)
        %w[provider_relay.cjs authorized_provider_relay.cjs].each do |name|
          File.write(File.join(@root, name), File.read(File.join(__dir__, name)), perm: 0o600)
        end
        credential = File.expand_path(config.fetch("credentialFile"))
        config = config.merge("credentialFile" => "/credential", "quota" => @quota,
          "reviewedContract" => @authorization.fetch("reviewed_contract"),
          "reviewedContractDigest" => @authorization.fetch("reviewed_contract_digest"),
          "socket" => "/relay/provider.sock")
        File.write(File.join(@root, "relay.json"), JSON.generate(config), perm: 0o600)
        docker!("volume", "create", @relay_volume)
        @volume_created = true
        # Only this trusted, read-only Node process has network access. It accepts
        # a fixed origin/path; the untrusted solver never joins its network.
        docker!("run", "--detach", "--name", @prefix, "--read-only", "--user", "0:0",
          "--cap-drop", "ALL", "--cap-add", "CHOWN", "--security-opt", "no-new-privileges", "--pids-limit", "64",
          "--memory", "256m", "--cpus", "1", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m",
          "--mount", "type=bind,src=#{@root},dst=/trusted,readonly",
          "--mount", "type=bind,src=#{credential},dst=/credential,readonly",
          "--mount", "type=volume,src=#{@relay_volume},dst=/relay",
          @image, "node", "/trusted/authorized_provider_relay.cjs", "/trusted/relay.json")
        @container_created = true
        50.times do
          result = docker("exec", @prefix, "test", "-S", "/relay/provider.sock")
          return self if result["status"] == "success"
          sleep 0.1
        end
        raise "authorized provider relay did not become ready"
      rescue
        close
        raise
      end

      def close
        return if @closed
        @closed = true
        if @container_created
          docker("stop", "--time", "2", @prefix)
          result = docker("logs", @prefix)
          @logs = result["stdout"].to_s + result["stderr"].to_s
          @audit = result["stdout"].to_s.lines.filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          docker("rm", "--force", @prefix)
        end
        docker("volume", "rm", "--force", @relay_volume) if @volume_created
        FileUtils.remove_entry(@root) if @root && File.directory?(@root)
      end

      def audit_records = Array(@audit)

      private

      def docker(*argv)
        Adapters::ProcessRunner.new.call(argv: ["docker", *argv], cwd: Dir.pwd, timeout: 30)
      end

      def docker!(*argv)
        result = docker(*argv)
        raise "authorized provider Docker operation failed" unless result["status"] == "success"
        result
      end
    end
  end
end
