# Live OmniRoute nine-cell archive

Source (unchanged): `.agru/luna-live-periodic-fixed-20261116/local-token-comparison/research-omniroute-token-staged-v2-dbb87e2dcd8df4a7`.
This is the completed live matrix, not an earlier failed attempt. No new model/API calls were made while archiving or regrading.

## Results

All **9/9 solver executions succeeded**; original verification has **9/9 verified checks**. Execution success is not benchmark success: all nine evaluation verdicts are `fail`.

Scores follow each architecture's order in the saved report:

| Architecture | Passed / 23, three observations | Mean score |
|---|---|---:|
| single-agent | 17/23, 17/23, 14/23 | 0.695652 |
| fixed-workflow | 17/23, 6/23, 4/23 | 0.391304 |
| dsl | 4/23, 5/23, 4/23 | 0.188406 |

One task and three repetitions support descriptive evidence only. Different inference-stage counts mean these are not equal-compute treatments.

## Portable verification and reproduction

`frozen/experiment.json` and `frozen/SHA256SUMS` are byte-for-byte copies, including submitted repositories, frozen contract, release identity and original grading records. Only targeted report, verification and provider-audit files were copied; workspaces, credentials, authorization files, raw console and evaluator assets were not archived. Hidden grader bodies are not included. Public repository tests remain part of actual submissions. Digests establish integrity, not authenticity.

Direct comparative CLI invocation (the general `bin/agru benchmark` entry point does not dispatch this CLI):

```sh
mise exec -- bundle exec ruby -Ilib -ragent_runtime -ragent_runtime/benchmarks/comparative_cli \
  -e 'exit AgentRuntime::Benchmarks::ComparativeCLI.new.run(ARGV)' -- \
  verify docs/evidence/omniroute-live-success-20261116/frozen \
  --root .agru/absent-success-archive-root
```

Saved result: `archive-verification.json`, `integrity_verified: true`, `regrades_verified: true`. The supplied root did not exist before or after verification; no source Store was required.

```sh
mise exec -- bundle exec ruby -Ilib -ragent_runtime -ragent_runtime/benchmarks/comparative_cli \
  -e 'exit AgentRuntime::Benchmarks::ComparativeCLI.new.run(ARGV)' -- \
  regrade-freeze docs/evidence/omniroute-live-success-20261116/frozen \
  docs/evidence/omniroute-live-success-20261116/portable-regrade.json \
  --root .agru/omniroute-success-archive-fresh-regrade-20261116 --assets .agru/nl2repo
```

Saved result: `portable-regrade.json`, `verified: true`, **9 actual grades, 9/9 matches_original**. Fresh Store and separately supplied trusted local evaluator assets were used; no provider calls. This reproduces the same evaluator implementation, not an independent evaluator. Reruns require a new nonexistent Store and evidence destination.

## Audit and accounting limits

`provider-audit-summary.json` derives from the copied audit: 143 rows comprise 101 request records, 21 gateway lifecycle records and 21 gateway process records. All 101 requests report HTTP 200. Observed heartbeats total 141: 116 early-startup and 25 timestamped-empty. These are diagnostic observations, not model requests.

Request-level observed usage sums to 1,298,702 prompt + 37,324 completion = 1,336,026 total tokens. All 101 request records mark accounting incomplete. Report-level client summaries use different observations/semantics; do not silently reconcile them or add cached tokens to inclusive input totals. Requested model is `cx/gpt-6-luna-low`; response label `gpt-6-luna` is not served-model attestation. Session correlation, authoritative billing/prices and complete cache/reasoning accounting remain unknown.

`token-ledger-snapshot.json` safely extracts only the final ledger object from `.agru/luna-live-periodic-fixed-console.log`: admission limit 1,000,000,000; reserved 869,393,920; request count 418; known usage 4,905,689; unknown usage/model counts 1 each; unresolved violations empty; halted false. This cumulative ledger includes earlier attempts, **not just these nine cells**. Reservations are not consumed tokens or billed charges.

`execution-release-identity.json` exposes the original report's execution identity; the freeze retains its own release identity. Credential-pattern screening covered archived text and decoded submission contents; submitted paths contained no hidden/grader/collector procedures. Original source copies were checked for byte equality.
