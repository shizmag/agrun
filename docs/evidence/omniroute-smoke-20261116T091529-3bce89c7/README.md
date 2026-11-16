# Clean authorized installed-OpenCode smoke

Installed OpenCode returned `OK` through the trusted host-local OmniRoute relay
with the solver container network disabled. HTTP 200, normal SSE completion,
no malformed reasons, and no relay error were recorded. The exact source-backed
gateway heartbeat is classified separately; response model observations contain
only `gpt-6-luna`. Requested route: `cx/gpt-6-luna-low`.

Reported usage: 756 prompt + 5 completion = 761 total tokens. Upstream cache and
reasoning details remain unknown; model names remain unattested observations.
No verified billing or benchmark-quality claim is made.

The cumulative ledger snapshot records six client attempts, five upstream
responses reporting 3,805 tokens, and 12,292,224 permanently reserved tokens.
The first locally rejected attempt retains unknown usage and its reservation.
There are no unresolved violations. The earlier identity halt was resolved by
an append-only source/classifier review, not deletion or rewriting of history.

`execution_identity.json` records the actual revision and implementation hashes.
`audit.json`, `output.json`, and `ledger_snapshot.json` retain execution evidence.
This one-request, 128-completion-token smoke is not the nine-cell live benchmark.
