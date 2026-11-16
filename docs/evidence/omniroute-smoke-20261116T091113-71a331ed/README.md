# Clean transport, conservative identity halt

The installed OpenCode smoke returned `OK`, exited 0, and received HTTP 200.
The relay completed streaming with `[DONE]`, a finish reason, no trailing data,
and no malformed reasons. Requested route remained `cx/gpt-6-luna-low`.

The upstream reported two distinct names: **`keepalive`**, then
**`gpt-6-luna`**. These are preserved as observations, not independent model
attestation. The collector checks every name, so ledger settlement durably
halted further requests with
`token_budget_model_name_mismatch_not_attestation`. No fallback was requested.

Reported usage was 756 input + 5 output = 761 total. Across this authorization,
four upstream responses report 3,044 tokens. Five client attempts reserved
10,243,520 tokens permanently, including the first locally rejected attempt.
The billion-token allowance is a ceiling, not a consumption target; reservations
are conservative admission accounting, not a provider-enforced billing limit.

The ledger is intentionally left halted. Do not delete it, choose an alternate
ledger path, refund reservations, or silently add `keepalive` as a model alias.
Further execution requires an evidence-based heartbeat protocol classification
and an explicit recorded continuation of the same cumulative authorization.
This smoke is transport evidence only, not comparative benchmark results.
