require "json"
require "tmpdir"
require "timeout"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "token_budget_ledger"

module AgentRuntime
  module Execution
    # Host credentials remain in a private file, never in the agent container.
    # A fresh single-connection bridge is created for each inference stage.
    class LocalTokenProvider
      IMAGE = "node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20".freeze
      def initialize(root:, ledger:, credential:, audit_path:, offline: false)
        @root, @ledger, @credential, @audit_path = root, ledger, credential, audit_path
        @stage = 0
        @offline = offline
      end

      def start(attempt_id:, cell_id:, model_profile:)
        raise ArgumentError, "token provider model mismatch" unless model_profile.fetch("model") == TokenBudgetLedger::MODEL
        @stage += 1
        @directory = Dir.mktmpdir("agru-token-provider-")
        config = {"offline" => @offline, "ruby" => RbConfig.ruby, "ledger" => @ledger, "cell_id" => cell_id,
                  "attempt_id" => "#{attempt_id}:#{@stage}", "request_limit" => 4, "image" => IMAGE,
                  "gateway" => {"attempt_id" => attempt_id, "cell_id" => cell_id,
                                "model" => TokenBudgetLedger::MODEL, "credentialFile" => File.join(@directory, "credential"),
                                "origin" => "http://127.0.0.1:20128", "approvedOrigins" => ["http://127.0.0.1:20128"],
                                "route" => "local-token", "identity" => {"run_id" => cell_id, "architecture" => "local-token", "step_id" => attempt_id, "attempt" => @stage},
                                "timeoutMs" => 110000, "maxBodyBytes" => 1048576, "allowTools" => true,
                                "inference" => {"max_completion_tokens" => 32000, "stream" => true, "stream_options" => {"include_usage" => true}}}}
        File.write(File.join(@directory, "credential"), @credential, perm: 0o600)
        path = File.join(@directory, "config.json")
        File.write(path, JSON.generate(config), perm: 0o600)
        @stdin, @stdout, @stderr, @wait = Open3.popen3("node", File.join(@root, "scripts/local_token_gateway.cjs"), path)
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
        if @relay_volume
          Open3.capture3("docker", "rm", "-f", @relay_volume.delete_suffix("-relay"))
          Open3.capture3("docker", "volume", "rm", @relay_volume)
        end
        [@stdout, @stderr].compact.each { |io| io.close unless io.closed? }
        FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
        @stdin = @stdout = @stderr = @wait = @reader = @directory = nil
        @relay_volume = nil
      end
    end
  end
end
