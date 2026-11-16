# Research live protocols — NOT AUTHORIZED

No provider requests were made to prepare these files. Neither manifest grants
authorization. Schema acceptance is not proof of runnable or bounded execution.

`experiments/research-live-operational.json` defines nine cells: retrying at
NL2Repo revision `781a1da1ee41fb8edb0bed22f586d69111610edf`, three reviewed
architectures, one `cx/gpt-6-luna-low` model, three repetitions. Preserve native
architecture behavior; report realized requests, input/output tokens, wall time,
and independent grader verdict separately from execution status.

## Frozen execution and balanced schedule

Installed image: `sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`.
Installed executable SHA256:
`5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0`.
The `/usr/local/bin/opencode` policy path describes the installed container,
not permission to replace it with a host executable.

Predeclare repetition seeds 17001, 17002, 17003, shared across architectures
within each repetition. Order (one cell and one provider request at a time):

| Repetition | Seed | Order |
|---|---:|---|
| 1 | 17001 | single-agent, fixed-workflow, dsl |
| 2 | 17002 | fixed-workflow, dsl, single-agent |
| 3 | 17003 | dsl, single-agent, fixed-workflow |

These are protocol seeds, not a claim that the provider supports deterministic
sampling. Current manifest cells enumerate solver-major, not this balanced
order. The launcher must explicitly implement this schedule and record seeds;
the existing schema has no schedule/seed fields. Do not silently claim balance.

## Compute-controlled companion

`experiments/research-live-compute.json` adds proposed **per-cell aggregate**
limits of 12 upstream requests and 384000 total input+output tokens; each request
has at most 32000 completion tokens. All planning, solving, reviewing, and repair
calls must share the cell ledger. There are no automatic cell/transport retries.
Both protocols propose 600 seconds per cell and sequential execution.

These compute keys pass ExperimentManifest's positive-number schema but are
rejected by LiveCLI as `unsupported_hard_limit`. No enforcement is claimed.
Completion-token limits alone do not bound input tokens or dollar exposure.
Admission must reserve worst-case input+output before sending each request and
fail closed if usage is missing, cancellation fails, or quota cannot be proven.

## Remaining launch blockers

LiveCLI uses the historical host launcher/endpoint; an image field in policy
does not select SandboxRunner or provision the trusted HTTPS relay. The local
HTTP endpoint in these manifests is historical schema configuration, **not** an
approved live upstream. A reviewed launcher must bind the pinned installed
binary, isolated socket bridge, approved HTTPS upstream, trusted credentials,
mandatory inference contract and cancellation to each cell before any run.
The simulator proves offline transport only, not live integration or billing.
Do not add a permissive live switch to bypass these gaps.

Before authorization freeze manifest, runtime, grader, task, catalog, image,
binary, trusted relay inference and upstream-origin digests. Record exact route,
fallback=false, zero automatic retries, price schedule/currency, context bounds,
and hard aggregate quota implementation. Independently regrade each submission.
An operator must separately sign an expiring authorization bound to those
digests and **explicit finite per-cell and whole-experiment monetary ceilings**.
No numeric monetary ceiling is authorized here; pricing and bounded input
admission remain unresolved. Missing ceiling, price, quota evidence or identity
must block launch. Do not use `preflight` or `run` as validation without that
authorization and reviewed network controls.

## Offline validation only

```sh
mise exec -- bundle exec ruby -Itest test/research_live_manifest_test.rb
mise exec -- bundle exec standardrb lib/agent_runtime/benchmarks/experiment_manifest.rb test/research_live_manifest_test.rb
```

`LiveCLI plan` only parses JSON unless a catalog is supplied; it is not a full
manifest validator and never demonstrates launch readiness. Tests above construct
ExperimentManifest directly, assert nine cells and preserve single-solver pilots,
reject unreviewed subsets/permutations and reject concurrent sessions/cells.
