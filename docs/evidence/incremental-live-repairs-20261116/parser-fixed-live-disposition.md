# Parser-fixed attempt: blocked by persisted identity halt

Execution: `research-omniroute-token-staged-v2-f02a84fd2f1c3d93`.
Local evidence root: `.agru/luna-live-parser-fixed-20261116/`.

All nine request records have HTTP 429 with
`global_ledger_admission_failed` and `upstream_attempted: false`.
All nine bridge lifecycle records have `host_connection_end`.
This attempt supplies no new provider/model-quality observations.

The existing shared ledger ends in an unresolved identity violation for request
`5088b03f-7ec0-48e0-8bb8-49e9fe7ce77a`, reported model `keepalive`.
That request is absent from this attempt's provider audit; its origin must be
established separately. Do not describe it as a new response from this attempt.
Do not reset the ledger or refund reservations to retry.

Before this attempt, installed-client nine-cell offline verification passed;
Docker lifecycle tests passed 2/2, gateway/integration tests passed 4/4, lint
passed, and Ruby regression passed 974 runs / 5812 assertions / 76 skips.
These controls do not establish successful live execution.
