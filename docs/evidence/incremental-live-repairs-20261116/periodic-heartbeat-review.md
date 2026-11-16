# Periodic empty-choice heartbeat review

Run `research-omniroute-token-staged-v2-6fd2b22413f9deea` recorded request
`ba4d4cba-04d7-489c-9356-1d1459875db6` with HTTP 200 and usage
10824 + 3551 = 14375. Unknown empty positive-timestamp keepalive frames caused
an identity halt. All nine cells failed; no submission was persisted.

Installed source `/opt/homebrew/lib/node_modules/omniroute/open-sse/utils/sseHeartbeat.ts:70-92`
emits the default periodic OpenAI frame with exact default ID/object/model,
`choices: []`, and `created: Math.floor(Date.now() / 1000)`.
Source SHA-256: `b86d0963b724e4d92107392aa22f66ed6aadcfbbba839f363d832709dfc30247`.
The prior diagnostics cannot independently prove the rejected choice count.
This review acknowledges that limitation, not served-model attestation.

Commit `06fa09f` recognizes only that exact positive-safe-integer timestamped
default. Offline HTTPS tests replay startup plus four periodic frames, model
content, usage and DONE: only gpt-6-luna remains in model observations; usage is
observed once. Content-bearing keepalive remains an identity observation.
Ten targeted Node tests and seven ledger tests passed.

The operator's continuation authorization remains limited to Luna6 within the
same aggregate billion-token ceiling. An append-only acknowledgment preserves
the original violation, usage and all reservations. No ledger reset or refund.
