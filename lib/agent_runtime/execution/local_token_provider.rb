require "json"
require "tmpdir"
require "timeout"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "token_budget_ledger"
require_relative "../adapters/process_runner"

module AgentRuntime
  module Execution
    # Host credentials remain in a private file, never in the agent container.
    # A fresh single-connection bridge is created for each inference stage.
    class LocalTokenProvider
      IMAGE = "node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20".freeze
      attr_reader :process_diagnostics
      def initialize(root:, ledger:, credential:, audit_path:, offline: false)
        @root, @ledger, @credential, @audit_path = root, ledger, credential, audit_path
        @stage = 0
        @offline = offline
      end

      def start(attempt_id:, cell_id:, model_profile:, timeout: 110)
        raise ArgumentError, "token provider stage timeout invalid" unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        raise ArgumentError, "token provider model mismatch" unless model_profile.fetch("model") == TokenBudgetLedger::MODEL
        @stage += 1
        @directory = Dir.mktmpdir("agru-token-provider-")
        config = {"stageTimeoutMs" => [(timeout * 1000).ceil, 1].max, "offline" => @offline, "ruby" => RbConfig.ruby, "ledger" => @ledger, "cell_id" => cell_id,
                  "attempt_id" => "#{attempt_id}:#{@stage}", "request_limit" => 12,
                  "cell_counter" => File.join(File.dirname(@audit_path), "cell-#{Digest::SHA256.hexdigest(cell_id)}.requests"), "image" => IMAGE,
                  "gateway" => {"attempt_id" => attempt_id, "cell_id" => cell_id,
                                "model" => TokenBudgetLedger::MODEL, "credentialFile" => File.join(@directory, "credential"),
                                "origin" => "http://127.0.0.1:20128", "approvedOrigins" => ["http://127.0.0.1:20128"],
                                "route" => "local-token", "identity" => {"run_id" => cell_id, "architecture" => "local-token", "step_id" => attempt_id, "attempt" => @stage},
                                "timeoutMs" => 110000, "maxBodyBytes" => 1048576, "allowTools" => true, "allowNoTools" => true,
                                "inference" => {"max_completion_tokens" => 32000, "stream" => true, "stream_options" => {"include_usage" => true}}}}
        File.write(File.join(@directory, "credential"), @credential, perm: 0o600)
        path = File.join(@directory, "config.json")
        File.write(path, JSON.generate(config), perm: 0o600)
        @stdin, @stdout, @stderr, @wait = Open3.popen3("node", File.join(@root, "scripts/local_token_gateway.cjs"), path)
        @process_diagnostics = {"stderr" => "absent", "exit" => "running"}
        # Drain without retaining bytes: even trusted child diagnostics can contain
        # credentials. A full stderr pipe must never block ready/audit delivery.
        @stderr_reader = Thread.new do
          loop do
            @stderr.readpartial(16_384)
            @process_diagnostics["stderr"] = "observed_redacted"
          end
        rescue IOError
          nil
        end
        ready = Timeout.timeout(60) { JSON.parse(@stdout.gets || "{}") }
        raise Error, "local token provider did not start" unless ready["ready"]
        @relay_volume = ready.fetch("relay_volume")
        @reader = Thread.new do
          @stdout.each_line do |line|
            record = JSON.parse(line).fetch("audit")
            File.open(@audit_path, "a", 0o600) { |file| file.puts(JSON.generate(record.merge("trusted_cell_id" => cell_id, "trusted_stage" => @stage))) }
          end
        end
        {"volume" => ready.fetch("relay_volume"), "credential" => {"mode" => "local_gateway", "cell_id" => cell_id, "attempt_id" => attempt_id}}
      rescue
        close
        raise
      end

      def close
        @stdin&.close unless @stdin&.closed?
        if @wait && !@wait.join(5)
          Process.kill("TERM", @wait.pid)
          unless @wait.join(5)
            Process.kill("KILL", @wait.pid)
            @wait.join
          end
        end
        @reader&.join(5)
        @stderr_reader&.join(5)
        if @wait && @process_diagnostics
          status = @wait.value
          @process_diagnostics["exit"] = if status.success?
            "success"
          elsif status.signaled?
            "signal"
          else
            "failure"
          end
          File.open(@audit_path, "a", 0o600) { |file| file.puts(JSON.generate("type" => "gateway_process", "diagnostics" => @process_diagnostics)) }
        end
        if @relay_volume
          failures = []
          [["docker", "rm", "-f", @relay_volume.delete_suffix("-relay")], ["docker", "volume", "rm", @relay_volume]].each do |argv|
            result = Adapters::ProcessRunner.new.call(argv: argv, cwd: @root, timeout: 10)
            failures << result unless result["status"] == "success" || result["stderr"].to_s.match?(/No such (container|volume)/i)
          end
        end
        [@stdout, @stderr].compact.each { |io| io.close unless io.closed? }
        FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
        @stdin = @stdout = @stderr = @wait = @reader = @stderr_reader = @directory = nil
        @relay_volume = nil
        raise Error, "local token provider cleanup failed: #{failures.inspect}" if failures&.any?
      end
    end
  end
end
