# Release-candidate nine-cell simulator execution

Execution-start Git revision: `656d9b700db437b5f276cc85d37bc62293fdcceb`.
Exact runtime content identity is embedded in `experiment.json` and copied to
`release.json`; this includes working-tree bytes, not merely the Git revision.

```sh
mise exec -- bundle exec ruby bin/agru bench comparative run rc-nine-20261116 docs/evidence/research-pilot-2026-11-16/rc --root .agru/rc-nine-20261116 --assets .agru/nl2repo --allow-simulated-execution > .agru/rc-nine-20261116.log 2>&1
mise exec -- bundle exec ruby bin/agru bench comparative verify docs/evidence/research-pilot-2026-11-16/rc
```

The captured log is `run.log`. Verification passed with freeze SHA256
`415017ede1f43a20da44f2c3351e5ac8ad5a906a91b1dd25e888ff7b6a36fbcd`.
All nine executions succeeded and all nine audited regrades matched (18 grading
attempts, 21 inference attempts). All scores remain zero. No paid calls occurred.

Each DSL and fixed-workflow cell reports three accepted request observations,
36 known input tokens and 9 known output tokens. Single-agent cells report one,
12 and 3 respectively. Coverage remains explicitly incomplete: these are known
subtotals, not complete token totals or monetary estimates. This demonstrates
telemetry plumbing, not model quality or an architecture advantage.

The provider is a deterministic controlled HTTPS simulator. Hidden evaluator
assets remain external. Existing older archives are unchanged. SQLite fork
warnings are preserved in the log; all evaluations nevertheless completed.
