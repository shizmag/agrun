# Preserved halted live attempt

The initial nine-cell local OmniRoute attempt ended with a reporting error:
`live report requires live execution provenance`. Its provider audit is preserved
here unchanged. The durable ledger halted after an unexpected `keepalive` model
observation; subsequent requests were rejected before upstream dispatch.

The installed gateway contains a second, timestamped default heartbeat emitter.
Source and classifier evidence is in `../omniroute-heartbeat-source.md`. This is
a plausible explanation, not proof of the historical SSE event shape. No raw SSE
was retained. Original observations, reservations and the halt remain recorded.

`ledger-snapshot.json` captures the unresolved halt: 18,533,952 reserved tokens,
34,394 reported tokens cumulatively, and one unknown usage record. These totals
include preceding smoke executions and are not provider billing. Ledger request
IDs and relay audit request IDs are distinct identities.

This attempt is not a completed successful live comparison. Finalization from
saved records produced nine terminal outcomes: one timeout and eight errors.
There are no submissions, so independent submission regrading is unavailable
and `regrades_verified: false` is retained. `report.md` and `frozen/` preserve
the final report and integrity-verifiable execution evidence. Freeze SHA-256:
`741e212c8f4bcc447439b3e2cd4cfb9d6581afcd2cf67fc1bede947a77685cd8`.
No provider requests were made during finalization.

After the additional source-backed timestamped heartbeat classifier passed
negative controls, an append-only review resolution was recorded. Its cumulative
snapshot is `heartbeat-review-resolution.json`. This does not retrospectively
establish the historical event's shape. A subsequent execution uses a distinct
run directory and the same global ledger; this failed attempt is not overwritten.

`regression.log`: 965 tests, 5,753 assertions, zero failures/errors, 75 gated skips.
