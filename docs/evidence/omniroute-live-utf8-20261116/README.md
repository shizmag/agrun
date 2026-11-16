# UTF-8 repaired live run: partial execution, incomplete evaluation

Nine planned cells: two single-agent cells completed with audited scores 14/23
and 17/23. A third single-agent submission was persisted but evaluation was
unavailable: incomplete or ambiguously attributed candidate results. The old
normalizer incorrectly treated evaluator process success as an available score
and raised a finite-score exception. Commit `14bfb67` corrects that distinction;
it does not fabricate a score or rewrite this historical run.

The remaining six fixed/DSL cells failed with provider HTTP 403/502 diagnostics.
Gateway observations: 73 HTTP 200, four `cell_request_limit` rejections, and two
`inference_policy` rejections. Exit zero is not nine-cell success.

Portable regrade ran against all three actual persisted submissions using a new
Store and separately supplied trusted assets. Its full machine result is included;
overall verification remains false. Missing submissions and unavailable evaluation
must not be converted into passes. No new provider calls or ledger changes occurred.

The original report and release identity remain unchanged. The original freeze
is retained privately: its report/summary contain embedded execution evidence,
so it was not copied wholesale without a complete body-level disclosure audit.
This archive contains selected accounting fields, outcomes, evaluator results,
and report only; no task repositories or hidden procedure files are copied.
Parent session supplies cumulative authorization-ledger counters separately.
