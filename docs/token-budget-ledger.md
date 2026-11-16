# Token-only authorization ledger

`AgentRuntime::Execution::TokenBudgetLedger` is a separate trusted-host component;
it does not change `ProviderBudgetLedger` or fabricate monetary prices. Require
`agent_runtime/execution/token_budget_ledger` explicitly.

Create it with `path:`, `intent_digest:` (64 lowercase hexadecimal characters),
`total_tokens:` (1 through 1,000,000,000), and optional `model:` (only
`cx/gpt-6-luna-low`). The digest must bind the actual authorization intent. Reuse
the same absolute ledger path across cells, retries, process restarts and entire
executions. Changed intent, path-bound copied logs, model or limit are rejected.
The caller must not create a fresh ledger to bypass an existing authorization.

Before sending a request, call `begin_request(request_id:, cell_id:, attempt_id:,
input_tokens:, completion_tokens:, model:)` (`reserve!` is an alias). IDs are
nonempty strings; request IDs must be globally unique within this authorization.
Allowances are positive integers. Admission permanently charges their sum. The
gateway must enforce the completion cap and permitted route with no fallback.
For the modest smoke, reserve positive request-byte allowance plus a 1,000,000
token overhead margin and the enforced 128 completion cap. This intentionally
conservative margin is not tokenizer evidence. An input allowance based on
request bytes is an admission policy, **not an
absolute provider token guarantee**: tokenizer and provider framing are unknown.

After a response, the trusted gateway calls `settle(request_id:,
observed_model:, usage:, reporter:)` (`settle!` alias). Usage is either nil or
`{"prompt_tokens" => Integer, "completion_tokens" => Integer}` with nonnegative
counts. `observed_model: nil` records an unknown model, never the requested name.
Missing usage remains unknown. Nothing refunds the reservation, including
failures, missing usage or smaller actual counts. A differing response model name
is recorded exactly and conservatively halts admission with
`token_budget_model_name_mismatch_not_attestation`: aliases may differ, so this is uncertainty,
not proof of a route violation or independent actual-model identity. Either
reported count exceeding its allowance is durably recorded, then raises; future
admissions halt. Settlement still works for other already-admitted requests.
Malformed usage raises without settlement; its reservation remains charged.

Only trusted host code may report usage; the reporter string is provenance,
not authentication. Records include request/cell/attempt identity, requested
model, allowances, observed model, reporter and reported usage. A private 0600
append-only hash-chained log uses flock and fsync. Torn/corrupt logs fail closed.
Symlinks, hard links, wrong owners and permissive file modes are rejected.
Secure the containing directory: directory separation is not a sandbox, and
checksums do not prevent a malicious host from rewriting or deleting the ledger.
Concurrent requests already admitted cannot be recalled after a later violation.
No network calls are made by this component. `snapshot` returns `total_tokens`,
`reserved_tokens`, `request_count`, `known_usage_tokens`, `unknown_usage_count`,
`unknown_model_count`, and `halted`; unsettled reservations count as unknown.
