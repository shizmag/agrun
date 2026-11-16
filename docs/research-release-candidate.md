# AGRU comparative research release candidate

## Evidence and interpretation

The installed OpenCode controlled-HTTPS nine-cell experiment is complete:
`docs/evidence/research-pilot-2026-11-16/rc/`.
Execution `rc-nine-20261116` has nine execution successes, nine immutable
submissions, 18 audited grading attempts, nine agreeing regrades and 21
attributable inference attempts. Every score is **0.0**. These are simulator
pipeline observations, not model-quality findings or architectural superiority.

* Scientific report: `docs/evidence/research-pilot-2026-11-16/rc/report.md`.
* Portable submissions, schedule, task/architecture/environment identities and
  grading evidence: `docs/evidence/research-pilot-2026-11-16/rc/experiment.json`.
* Exact execution-start content identity:
  `docs/evidence/research-pilot-2026-11-16/rc/release.json`.
* Freeze SHA256: `415017ede1f43a20da44f2c3351e5ac8ad5a906a91b1dd25e888ff7b6a36fbcd`.
* Frozen experiment digest: `d82f4f5b863ae045cebad142e8f6912a6b1f1b25bace94cc74aa59bac8c72928`.
* Fresh-store reproduction: `docs/evidence/research-pilot-2026-11-16/rc-portable-regrade.json`.

The release identity records actual execution-start bytes, including working-tree
changes, and Git revision `656d9b700db437b5f276cc85d37bc62293fdcceb`.
Later verifier, authorization and documentation commits do not rewrite this
historical identity. The archive is integrity-checkable, not cryptographically
authenticated by an external authority.

## Reproduction

Use Ruby 4.0.9 through mise, project-local gems, Docker and the pinned installed
image. Existing trusted benchmark assets are required for regrading; hidden
procedures are deliberately not exported into solver submissions.

```sh
mise exec -- bundle install
mise exec -- bundle exec ruby bin/agru bench comparative verify docs/evidence/research-pilot-2026-11-16/rc --root /nonexistent/agru-review-store
mise exec -- bundle exec ruby bin/agru bench comparative regrade-freeze docs/evidence/research-pilot-2026-11-16/rc review-regrades.json --root .agru/new-review-store --assets .agru/nl2repo
mise exec -- bundle exec ruby bin/agru bench comparative readiness new-offline-run --assets .agru/nl2repo
mise exec -- bundle exec ruby bin/agru bench comparative plan new-offline-run
mise exec -- bundle exec ruby bin/agru bench comparative run new-offline-run review-freeze --root .agru/new-offline-run --assets .agru/nl2repo --allow-simulated-execution
```

Verification returns `verified: true`; regrading returns nine matching records.
Use unused Store and export destinations: the tools refuse overwriting evidence.
Fresh execution uses the current runtime identity, not the historical RC identity.
See `docs/comparative-experiment.md` and
`docs/research-architecture-interventions.md` for the intervention contracts.

## Security and validity boundaries

Final regression: **951 runs, 5670 assertions, zero failures/errors, 75 skips**
(`docs/evidence/research-security-2026-11-16/regression-final-revalidated.log`).
The prior interrupted/stale-test failure is preserved separately, not counted as
a pass. Lint, smoke, benchmark demo, conformance (16/16), acceptance (20/20) and
benchmark contract checks passed. The 75th default skip is the new authorized
offline injected nine-cell scheduler E2E; it was explicitly enabled separately
and passed 7 tests / 34 assertions with actual audited Docker grading and no
provider requests (`authorized-scheduler-offline-e2e.log`). Historical 72 gated
tests and the two added Docker gates are classified in the security inventory;
offline controls were enabled separately. Network provenance remains unrun.

`docs/research-security-verification.md` maps actual controls, partial assurance
and skips to retained logs. Container separation is not proof against kernel or
Docker-daemon compromise. Trusted-host quota state is not tamper-proof against
an operator who deletes or rolls back all ledger state. Same-implementation
regrading demonstrates evaluator reproducibility, not independent evaluator
semantics. Single-task, three-repetition simulator results cannot establish
generalizable model or architecture quality. Client-emitted cache/reasoning zeros
are not independently reported provider measurements; accounting is incomplete.

## Subsequent live execution — not authorized by this release

No paid requests have been made. The exact-nine operational and compute
definitions are `experiments/research-authorized-operational.json` and
`experiments/research-authorized-compute.json`. The compute protocol binds equal
12-request / 384000-token per-cell admission caps across all stages. Equal caps
are not equal realized expenditure.

`docs/research-live-authorization.md` contains the actual `live-prepare` and
`live-run` commands and non-authorizing schema example. Preparation binds runtime,
collector, grader, installed assets, image/binary, origin and canonical durable
ledger path. Execution additionally requires explicit opt-in, exact authorization,
private credentials and a reviewed provider token/pricing contract. Local quota
admission is tested; authoritative real-provider token framing, reasoning/cache
charges and pricing evidence have not been established. Do not authorize on the
basis of synthetic contract tests or claim a verified provider billing ceiling.
