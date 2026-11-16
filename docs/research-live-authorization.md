# Research live protocols — NOT AUTHORIZED

## Implemented exact-nine authorization path

`comparative live-prepare` and `comparative live-run` now assemble the shared
`ExperimentRunner`, three native solvers and audited NL2Repo grader. The new
frozen definition is `experiments/research-authorized-operational.json`.
`--protocol compute` selects `experiments/research-authorized-compute.json` and
requires exactly 12 requests and 384000 aggregate input/output tokens per cell,
shared across stages and identical for all arms. Prices and money ceilings are
still explicitly operator supplied; neither definition grants authorization. The two
historical `research-live-*` files below remain proposals, not authorization.
The existing `LiveCLI` single-cell path is not this scheduler.

Preparation performs no provider requests:

```sh
bin/agru bench comparative live-prepare --origin-config /private/reviewed-origin.json --assets .agru/nl2repo --ledger /private/budget.json
```

The origin file is a JSON object with `reviewed_origin`, a reviewed HTTPS origin
without a path, query, fragment or embedded credentials. Save the returned exact
`bindings` into a separate operator authorization JSON object, adding `limits`,
`expires_at` (epoch seconds), and `quota`. Do not copy the other preparation
output fields into authorization. `limits` requires positive explicit
`requests_per_cell`, `total_tokens_per_cell`, `completion_tokens_per_request`,
`seconds_per_cell` (600), `money_per_cell`, `money_per_experiment`, and `currency`
(`USD`). The experiment money ceiling must cover all nine cell reservations.
Money limits are integer USD nanos (one USD = 1000000000 nanos).
`quota` requires `requests`, `tokens`, `moneyNanos`, `expiresAt` (epoch milliseconds),
`inputTokensPerByte`, `inputTokenOverhead`, `inputPriceNanosPerMillion`,
`outputPriceNanosPerMillion`, `pricingEvidence`, and `tokenBoundEvidence`.
Authorization also requires `reviewed_contract` with `version: 1`, `reviewed: true`,
`provider` equal to the origin, `model` equal to the frozen wire model, and
nonempty `evidence`; `reviewed_contract_digest` is SHA256 of compact JSON of that
object, preserving key order. Operator estimates
are not independent evidence of a provider's billable-token or pricing contract;
an unreviewed contract must not be represented as a hard financial ceiling.

Only after external review and explicit operator authorization:

```sh
bin/agru bench comparative live-run /private/evidence --allow-live-execution \
  --authorization /private/authorization.json \
  --origin-config /private/reviewed-origin.json \
  --credential-file /private/provider-key --ledger /private/budget.json \
  --assets .agru/nl2repo --root .agru/authorized-nine
```

The credential must be a private regular non-symlink file; it is mounted only
into the trusted relay. No live command is the default. Bindings are rechecked
against the canonical absolute ledger path and complete local asset file inventory;
the ledger parent must already exist and must not traverse symlinks. A different
ledger path requires new authorization. Deleting both ledger and lock as a trusted
operator is outside the accidental-restart threat model, not a supported reset.
Bindings are also rechecked
against current implementation bytes before starting any cell. Changing code
after preparation requires new preparation and authorization. The ledger
reserves the full cell envelope once before launching; the same relay/socket is
reused sequentially for every inference stage in that cell, preventing three
fresh stage quotas. No automatic retry/restart or reservation refund is allowed.
The solver bridge targets `/relay/provider.sock`; solver networking remains
disabled. Repetition seeds 17001–17003 and the exact Latin order below are stored
in execution metadata. Seeds are protocol labels, not deterministic-provider
guarantees. The report in `experiment.json` keeps execution status separate from grader outcome;
`provider-evidence.json` records cell relay audit evidence, including on failure.

No provider request was authorized or performed during this implementation.
Offline fake-launcher tests cover lifecycle reuse and failure cleanup; they are
not external provider reachability, billing, or model-quality evidence.

## Non-authorizing numeric schema example

This wrapper is deliberately **NOT AUTHORIZED** and is not accepted as an
authorization file. All numbers are dummy examples, not provider pricing or
token guarantees. `bindings` must be replaced by the exact preparation output;
the contract digest must be computed from the reviewed replacement object.

```json
{
  "authorized": false,
  "authorization_shape_only": {
    "bindings": "REPLACE_WITH_EXACT_PREPARE_BINDINGS_OBJECT",
    "expires_at": 1,
    "limits": {
      "requests_per_cell": 12, "total_tokens_per_cell": 384000,
      "completion_tokens_per_request": 32000, "seconds_per_cell": 600,
      "money_per_cell": 1000000000, "money_per_experiment": 9000000000,
      "currency": "USD"
    },
    "quota": {
      "requests": 12, "tokens": 384000, "moneyNanos": 1000000000,
      "expiresAt": 1000, "inputTokensPerByte": 4, "inputTokenOverhead": 100,
      "inputPriceNanosPerMillion": 1000000000,
      "outputPriceNanosPerMillion": 1000000000,
      "pricingEvidence": "DUMMY NOT REVIEWED",
      "tokenBoundEvidence": "DUMMY NOT REVIEWED"
    },
    "reviewed_contract": {
      "version": 1, "reviewed": false,
      "provider": "https://provider.invalid", "model": "cx/gpt-6-luna-low",
      "evidence": "DUMMY NOT REVIEWED",
      "inputTokensPerByte": 4, "inputTokenOverhead": 100,
      "inputPriceNanosPerMillion": 1000000000,
      "outputPriceNanosPerMillion": 1000000000
    },
    "reviewed_contract_digest": "RECOMPUTE_AFTER_EXTERNAL_REVIEW"
  }
}
```

## Historical proposal appendix — legacy LiveCLI only

The remaining sections describe the older proposal manifests and legacy
single-cell LiveCLI restrictions, not missing features of the implemented
authorized scheduler above. They are historical cautions, not authorization
or reviewed billing evidence.

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
