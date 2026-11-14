# Roadmap

## Implemented prototype

- Explicit Ruby DSL, canonical IR validation, typed artifacts and durable Store.
- Runtime DAG execution and adapter boundaries.
- Offline fixture, good/bad/DSL solvers, opt-in OpenCode solver.
- Independent external evaluation, digest-bound evidence, JSON/CSV results.
- CLI doctor, validate, graph, run, benchmark, report and offline tests.

## Next milestones (not implemented promises)

1. Isolated containers/VMs with read-only evaluation procedures, network policy,
   resource limits and captured image digests for untrusted submissions.
2. More licensed datasets with pinned revisions, explicit split policies, and
   reproducible dependency environments; richer task formats beyond Ruby Clamp.
3. Provider-side budget caps, robust token/cost accounting and repeated-trial
   aggregation with uncertainty estimates and contamination disclosures.
4. Resume/replay policies, crash recovery, richer graph visualization and reports.
5. Independent review of sandbox and artifact trust boundaries before public
   leaderboard or multi-tenant deployment.
