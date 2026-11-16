require "json"
require_relative "../lib/agent_runtime/execution/token_budget_ledger"

# Private host-only IPC. No credentials or request bodies cross this interface.
config = JSON.parse(File.read(ARGV.fetch(0)))
ledger = AgentRuntime::Execution::TokenBudgetLedger.new(**config.fetch("ledger").transform_keys(&:to_sym))
message = JSON.parse($stdin.read)
case message.fetch("action")
when "reserve"
  ledger.begin_request(request_id: message.fetch("request_id"), cell_id: config.fetch("cell_id"),
    attempt_id: config.fetch("attempt_id"), input_tokens: 2_048_576, completion_tokens: 32_000)
when "settle"
  ledger.settle(request_id: message.fetch("request_id"), observed_model: message["observed_model"],
    usage: message["usage"], reporter: "trusted-local-gateway")
else
  abort "unknown token ledger action"
end
puts JSON.generate(ledger.snapshot)
