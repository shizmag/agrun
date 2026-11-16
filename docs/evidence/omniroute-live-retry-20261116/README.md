# Authorized local OmniRoute retry: failed execution evidence

The process exited zero because orchestration and report creation completed.
**All nine planned cells ended in execution error; none persisted a submission.**
This is not a successful task comparison or model-quality measurement.

The immutable saved freeze has integrity SHA-256
`f03a94f0f6ea909986bb73fc37aa4cc7753f2504f9b894044db6388533937164`.
Integrity verification succeeds, but submission regrade verification is false:
all nine checks correctly say `no persisted submission`. There is no verifier
bug to repair and no actual submission to portable-regrade. No evaluator was
run on invented or recovered workspace contents.

Three single-agent cells record executor error `"\\xE2" from ASCII-8BIT to UTF-8`.
Other cells also terminate in error, without a top-level exception message.
The saved gateway audit contains 45 records: 38 HTTP 200 and seven HTTP 429
`aggregate_budget_exhausted`. Those are gateway request observations, not 38
successful solver stages or cells. They do not establish that the aggregate
token ceiling was reached: that gateway error also covers admission failures.
Parent-session ledger analysis is required for its precise cause and cumulative
authorization counters. This archive does not read or change the shared ledger.

`cells.json` preserves terminal classifications, `verification.json` preserves
the unavailable-regrade decisions, `freeze-verification.json` records the
read-only integrity check, and `audit.json` contains selected gateway accounting
fields only. `release-identity.json` preserves the original execution identity
(`dee741be7781809c0bfc7970116289541834c39d`); report finalization does not claim
new code executed. `report.md` retains failed-cell denominators and unknowns.

The original freeze remains private under `.agru`: it is not copied because a
full bundle may contain task assets. No hidden procedures, workspace content,
credentials, or provider request/response bodies are included. No additional
provider requests, halt resolution, execution rerun, or ledger mutations were
performed during this investigation.
