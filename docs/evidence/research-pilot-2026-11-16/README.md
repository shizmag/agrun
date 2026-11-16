# Controlled HTTPS pilot

The newest execution is `rc/` (`rc-nine-20261116`), with updated DSL usage
aggregation. Its freeze SHA256 is
`415017ede1f43a20da44f2c3351e5ac8ad5a906a91b1dd25e888ff7b6a36fbcd`.
`rc-independent-verification.log` records verification without the original Store;
`rc-portable-regrade.json` records nine matching fresh-store audited evaluations.
CLI-observed cache/reasoning zeros in the RC report are explicit installed-client
observations, not independently reported provider measurements: the simulator
reports only input, output and total tokens. Accounting remains incomplete.

The corrected `v2/` freeze is also retained. The original top-level freeze is retained as
historical evidence; it predates frozen-contract and verifier hardening.

Execution `https-bound-nine-20261116` ran installed OpenCode in pinned Docker
sandboxes against the controlled HTTPS relay and deterministic provider simulator.
This is **simulated-relay evidence**, not live-model capability evidence. No paid
provider calls were made. Three architectures each ran three repetitions of the
frozen retrying task in a persisted seeded Latin-square schedule.

All nine executions succeeded, all nine audited scores were zero, and all nine
independent regrades matched (18 grading attempts). There were 21 inference
attempts bound to outer experiment cells. Execution success is not task success;
these results do not support a model-quality or architecture-ranking claim.

`v2/experiment.json` embeds report, relay logs, regrade bindings, submitted
repository manifests and the canonical frozen contract. `release.json` records
execution-start content identity, not publication-checkout identity. No hidden
grading procedure bodies or Git history are bundled. `status.json` records counts;
`report.md` is the scientific rendering. The active-cell binding is sequential,
trusted-process coordination, not a concurrency-safe or security boundary.

```sh
mise exec -- bundle exec ruby bin/agru bench comparative verify docs/evidence/research-pilot-2026-11-16/v2
```

V2 SHA256: `756852b4b81daa24fd6d5b6e15e8b84ce3759f305a3f0e223bad75e339db53b2`.
Verification establishes internal consistency, not external authenticity.
SQLite inherited-connection warnings occurred during execution; all cells and
regrades completed. Record independent review separately without rewriting these
frozen bytes.

## Portable evaluator reproduction

`portable-regrade.json` records nine fresh audited evaluations restored from the
V2 portable submission manifests into a new Store, without reading the original
run Store. Trusted hidden assets were supplied separately from `.agru/nl2repo`;
none were copied into this bundle. All nine reproduced results matched their
original scores and verdicts. This uses the same evaluator implementation: it is
reproducibility evidence, not an independently implemented evaluator or a new
solver execution. It does not modify the frozen experiment or historical scores.
