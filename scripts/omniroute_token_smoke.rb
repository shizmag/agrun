require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "securerandom"
require "open3"
require "timeout"
require_relative "../lib/agent_runtime/execution/token_budget_ledger"

abort "explicit --execute required" unless ARGV == ["--execute"]
root = File.expand_path("..", __dir__)
Dir.chdir(root)
secret = ENV.fetch("OMNIROUTE_API_KEY")
abort "invalid credential" if secret.empty? || secret.match?(/[\r\n]/)
id = "omniroute-smoke-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(4)}"
evidence = File.join(root, "docs/evidence", id)
FileUtils.mkdir_p(evidence, mode: 0o700)
ledger = AgentRuntime::Execution::TokenBudgetLedger.new(
  path: File.join(root, ".agru/authorizations/omniroute-luna6-20261116.tokens.jsonl"),
  intent_digest: Digest::SHA256.file("experiments/omniroute-luna6-token-observation.json").hexdigest,
  total_tokens: 1_000_000_000
)
ledger.begin_request(request_id: id, cell_id: id, attempt_id: id,
  input_tokens: 1_048_576 + 1_000_000, completion_tokens: 128)
image = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1"
records = []
container = "#{id}-solver"
Dir.mktmpdir("agru-trusted-") do |trusted|
  credential = File.join(trusted, "credential")
  File.write(credential, secret, mode: "w", perm: 0o600)
  config = {origin: "http://127.0.0.1:20128", approvedOrigins: ["http://127.0.0.1:20128"],
            model: "cx/gpt-6-luna-low", route: "omniroute", timeoutMs: 120_000,
            credentialFile: credential, allowTools: true,
            identity: {run_id: id, architecture: "smoke", step_id: "smoke", attempt: id},
            inference: {max_completion_tokens: 128, stream: true, stream_options: {include_usage: true}}}
  config_path = File.join(trusted, "config.json")
  File.write(config_path, JSON.generate(config), mode: "w", perm: 0o600)
  gateway_in = gateway_out = gateway_err = gateway_wait = nil
  begin
    Timeout.timeout(120) do
      gateway_in, gateway_out, gateway_err, gateway_wait = Open3.popen3("node", "scripts/local_gateway_smoke.cjs", config_path)
      Thread.new { gateway_err.read }
      ready = JSON.parse(gateway_out.gets || "{}")
      raise "gateway not ready" unless ready["ready"]
      reader = Thread.new { gateway_out.each_line { |line| records << JSON.parse(line) } }
      client_config = {tools: {"*" => false, "skill" => false}, agent: {title: {disable: true}}, provider: {mock: {npm: "@ai-sdk/openai-compatible", name: "mock",
                                                                                                                   options: {baseURL: "http://127.0.0.1:18080/v1", apiKey: "local-only"},
                                                                                                                   models: {"cx/gpt-6-luna-low" => {name: "Luna6", options: {max_completion_tokens: 128}, limit: {context: 128000, output: 128}}}}}}
      # No host directories/config/credentials enter the solver. The only bind is
      # the reviewed bridge code; its volume contains only the relay socket.
      command = ["docker", "run", "--rm", "--name", container, "--network", "none",
        "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--user", "65534:65534", "--memory", "1g", "--cpus", "1", "--pids-limit", "128",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=268435456,mode=1777",
        "-e", "HOME=/tmp", "-e", "OPENCODE_CONFIG_CONTENT=#{JSON.generate(client_config)}",
        "-v", "#{ready.fetch("relay_volume")}:/relay",
        "-v", "#{root}/lib/agent_runtime/execution/loopback_bridge.cjs:/bridge.cjs:ro",
        "--entrypoint", "sh", image, "-c",
        "node /bridge.cjs bridge >/tmp/bridge.log & sleep 1; opencode run --format json --model mock/cx/gpt-6-luna-low 'Reply OK'"]
      output, _error, status = Open3.capture3(*command)
      # Keep output protocol, but never persist the prompt-bearing user events.
      events = output.each_line.filter_map do |line|
        event = begin
          JSON.parse(line)
        rescue
          nil
        end
        event if event && %w[text finish error step_finish].include?(event["type"])
      end
      File.write(File.join(evidence, "output.json"), JSON.pretty_generate({exit: status.exitstatus, events: events}).gsub(secret, "[REDACTED]"))
      gateway_in.close
      gateway_wait.value
      reader.join
    end
  ensure
    system("docker", "rm", "-f", container, out: File::NULL, err: File::NULL)
    gateway_in&.close unless gateway_in&.closed?
    Process.kill("TERM", gateway_wait.pid) if gateway_wait&.alive?
    gateway_wait&.join
    File.write(File.join(evidence, "audit.json"), JSON.pretty_generate(records).gsub(secret, "[REDACTED]"))
    record = records.filter_map { |r| r["audit"] }.find { |r| r["status"] == 200 } || records.filter_map { |r| r["audit"] }.first || {}
    ledger.settle(request_id: id, observed_model: record["response_model"],
      usage: record["observed_usage"], reporter: "trusted-gateway")
  end
end
puts JSON.generate({evidence: evidence, request_id: id, solver_executed: true,
                    upstream_response_succeeded: records.any? { |r| r.dig("audit", "status") == 200 },
                    upstream_attempt_status: (records.any? { |r| r.dig("audit", "status") == 200 }) ? "response_observed" : "unknown"})
