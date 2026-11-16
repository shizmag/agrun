# Post-fix offline lifecycle validation

Installed-client nine-cell lifecycle after UTF-8 capture and twelve-request
cell-admission fixes: nine successful executions, nine persisted submissions,
two grading attempts per cell, verified freeze and verified portable regrade.
This remains synthetic transport evidence, not live model-quality evidence.
No API calls were made. See `summary.json` for exact counters and freeze digest.

Additional focused validation: complete real-Docker UTF-8/binary capture fixture
passed (1 test, 7 assertions); fixed/DSL failed-provider solver propagation passed
(1 test, 4 assertions). The latter injects a failed adapter and traverses real
solver/runtime/storage paths; it does not contact a provider.

`pre-contract-update-regression.log` preserves the full regression run that
identified two old tests expecting silent UTF-8 replacement (968 runs, 5775
assertions, two failures, 75 skips). Those expectations were intentionally updated
to the explicit failure/lossless Base64 contract, not suppressed. The affected
suites subsequently pass: lifecycle 10 tests/66 assertions; adapter integration
19 tests/76 assertions. The nine-cell run predates the additive failed-stage
top-level error propagation changes; those are covered by the focused solver test.
