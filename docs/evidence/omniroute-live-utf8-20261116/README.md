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

Portable comparison details: cells `c2c4d1b0cfdea2d77504c7294783b2113617fd947cafbef8ae5081e51ea7d1b4`
and `96987c79d7be8a72a12b81ed3f2aa64671a1d340768fee23c05e205c70b17295`
match their original 14/23 and 17/23 results. Cell
`2a5d0fba603b48225c0b8c5b18b6be754cfd9da84f35f2813edb4ef9fd825d28`
returns `unavailable`, no score, and does not match an original normalized result
because the original normalization raised before persisting one. Overall false
is therefore not disagreement about either available numeric score.

Disclosure audit is incomplete: `experiment.json` includes report and summary
execution envelopes in addition to submission manifests and frozen contract.
Those envelopes have not been proven free of embedded agent/provider text.
Consequently this archive deliberately does not claim to contain a portable,
byte-identical freeze. The original private freeze is unchanged and remains the
source used for portable regrade. Exact historical 403 request bodies were not
recorded, so their rejected message shape cannot be reconstructed honestly.
