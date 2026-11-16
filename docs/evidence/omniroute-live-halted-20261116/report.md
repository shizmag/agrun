# AGRU comparative research pilot

Experiment: `research-omniroute-token-operational-v1-8469e273213c7b5b`
Evidence: **live_provider**


Execution failures and unobserved stages remain in the planned-cell denominator. Live configuration is not evidence that every cell reached a provider, nor attestation of served-model identity.

## Research question and setup

How do complete-task, fixed role workflow, and typed compositional execution differ in observed quality, reliability and resource use on the frozen task?

The operational comparison shares tools, public task information, model route and sandbox policy. Single agent has one inference stage; both multi-stage architectures have three. The DSL additionally branches repository inventory and validates artifact manifests. These are distinct interventions, not equal-compute treatments.

Frozen manifest (requested configuration, not served-model attestation):

```json
{
  "benchmark": {
    "name": "nl2repo",
    "revision": "781a1da1ee41fb8edb0bed22f586d69111610edf",
    "task_ids": [
      "retrying"
    ]
  },
  "execution_mode": "live",
  "experiment_id": "research-omniroute-token-operational-v1-8469e273213c7b5b",
  "limits": {
    "max_attempts": 1,
    "max_concurrent_sessions": 1,
    "max_parallelism": 1,
    "timeout": 600
  },
  "models": [
    {
      "id": "omniroute/cx/gpt-6-luna-low",
      "model": "cx/gpt-6-luna-low",
      "model_profile": {
        "execution_kind": "real_provider",
        "id": "omniroute-cx-gpt-6-luna-low",
        "model": "cx/gpt-6-luna-low",
        "pricing": {
          "source": "token-only-no-pricing",
          "status": "unknown"
        },
        "provider": "omniroute",
        "tool_policy": {
          "endpoint": "http://127.0.0.1:20128/v1/chat/completions",
          "executable": "/usr/local/bin/opencode",
          "executable_sha256": "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0",
          "image": "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1",
          "model_fallback": false,
          "route": "local-gateway"
        }
      }
    }
  ],
  "repetitions": 3,
  "schema_version": 1,
  "solver_ids": [
    "single-agent",
    "fixed-workflow",
    "dsl"
  ],
  "subset_role": "operational-exact-nine-requires-external-authorization"
}
```

## Per-cell outcomes

Every planned cell remains in the denominator, including infrastructure failures.

| Cell | Architecture | Execution | Evaluation | Score | Regrade attempts | Wall seconds |
|---|---|---|---|---:|---:|---:|
| 23c3033fd7f73dcf18a64dc6f07dc99948933b6e84855b513c77fa1e056cdf89 | single-agent | timeout | completed | unknown | 0 | 600.384364 |
| 7aac060ba76ededa65afc24d6693ea56598e6bb0c972a424c22ed168f686579d | fixed-workflow | error | completed | unknown | 0 | 93.967389 |
| 202db868a2163d82960183af4d06b5875e7ddb1d327d5a37c5a4f20bf93ed4bf | dsl | error | completed | unknown | 0 | 91.354376 |
| 83c53adf39f1f6d5ad3d58b9c093182f07ec08940fbc362cf12681965b307cb0 | fixed-workflow | error | completed | unknown | 0 | 83.796952 |
| 023e6ba103c6c3e7fc618c45b715b2d9178c186a0181a6f35c05f9d41ff07390 | dsl | error | completed | unknown | 0 | 93.331364 |
| e24f757c03434e3d8af208b239dfcc0453e35d89fbf2b7c5c2786072100e120a | single-agent | error | completed | unknown | 0 | 92.964324 |
| c4bd4575dd83c6d9bead9e4156a08b7e1d36f7ce5555cfa76f17605941ead68d | dsl | error | completed | unknown | 0 | 82.720243 |
| 588b56e9e6c9e53ba1373b7d1d0e8591fc5fad030f68cb38f0b3a31bc3627bad | single-agent | error | completed | unknown | 0 | 91.613183 |
| 8181f268fa389b02bf0afe4d362e67edf7da7ba170c350851d64b7e31eb3a9b5 | fixed-workflow | error | completed | unknown | 0 | 88.129254 |

## Descriptive comparison

| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |
|---|---:|---:|---:|---:|---:|---:|
| single-agent | 3 | 0/3 | 0/3 | unknown | 261.653957 | 1/3 |
| fixed-workflow | 3 | 0/3 | 0/3 | unknown | 88.631198 | 0/3 |
| dsl | 3 | 0/3 | 0/3 | unknown | 89.135328 | 0/3 |

Means use observed numeric values only; observation counts are shown explicitly. Failed/missing grades are not silently scored as zero or removed from reliability denominators. Inspect JSON for execution failure categories, tool activity, request timing, retries, usage completeness and provider errors. Null is unknown, not zero. Cached tokens must not be added to inclusive input-token totals. Estimated costs are not verified billing.

## Regrading and interpretation

Separate grading attempts evaluate the saved immutable submission. Agreement validates reproducibility of this grader on that submission, not independence of grader implementation or benchmark validity. The accompanying verification record, not this narrative, determines regrade agreement.

## Validity limitations

* Three repetitions and one task support descriptive analysis only, not statistically generalizable superiority.
* Different inference-stage counts confound operational quality/resource comparisons. An equal-compute study must freeze aggregate request/token caps across all stages; per-stage limits alone are insufficient. Do not interpret greater inference expenditure as architectural improvement.
* Model nondeterminism remains even with frozen requested inference settings. Provider route identity is not actual served-model attestation.
* Provider telemetry can be incomplete; unknown tokens, reasoning, cache usage and prices prevent complete compute/cost comparisons. Missing usage counts above do not imply every non-null usage record is complete.
* Client-emitted zero cache/reasoning observations are not independently verified provider measurements. The controlled simulator reports only input, output and total tokens.
* The audited grader is a trusted evaluator with its own environment and trust boundary; solver-directory separation alone is not a security sandbox.
* Role prompts, textual handoffs, deterministic inventory and validation overhead are architecture-specific confounders. No claim is made about all possible agent architectures.
* A hash freeze detects alteration relative to its recorded digest, not authenticity against an attacker able to replace both evidence and digest.

## Resource observations

Evidence: live_provider; synthetic: false. Totals require completeness; subtotals retain partial known evidence. Unknown is never zero. Cache/reasoning may overlap input/output and are not added. Tool events are observed events, not complete tool-call counts. Saved summaries do not expose authoritative retry/provider-error counts.

### Per-cell resources

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 23c3033fd7f73dcf18a64dc6f07dc99948933b6e84855b513c77fa1e056cdf89 | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 600.3843640000559 (1/1 known) | unknown | unknown | unknown |
| 7aac060ba76ededa65afc24d6693ea56598e6bb0c972a424c22ed168f686579d | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 93.96738900011405 (1/1 known) | unknown | unknown | unknown |
| 202db868a2163d82960183af4d06b5875e7ddb1d327d5a37c5a4f20bf93ed4bf | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 91.35437599988654 (1/1 known) | unknown | unknown | unknown |
| 83c53adf39f1f6d5ad3d58b9c093182f07ec08940fbc362cf12681965b307cb0 | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 83.79695199988782 (1/1 known) | unknown | unknown | unknown |
| 023e6ba103c6c3e7fc618c45b715b2d9178c186a0181a6f35c05f9d41ff07390 | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 93.3313639999833 (1/1 known) | unknown | unknown | unknown |
| e24f757c03434e3d8af208b239dfcc0453e35d89fbf2b7c5c2786072100e120a | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 92.9643240000587 (1/1 known) | unknown | unknown | unknown |
| c4bd4575dd83c6d9bead9e4156a08b7e1d36f7ce5555cfa76f17605941ead68d | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 82.72024299995974 (1/1 known) | unknown | unknown | unknown |
| 588b56e9e6c9e53ba1373b7d1d0e8591fc5fad030f68cb38f0b3a31bc3627bad | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 91.61318300012499 (1/1 known) | unknown | unknown | unknown |
| 8181f268fa389b02bf0afe4d362e67edf7da7ba170c350851d64b7e31eb3a9b5 | omniroute/cx/gpt-6-luna-low | 0 subtotal (1/1 known) | unknown | unknown | unknown | unknown | unknown | 88.12925399979576 (1/1 known) | unknown | unknown | unknown |

### Per-architecture resources (separate model routes)

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| single-agent | omniroute/cx/gpt-6-luna-low | 0 subtotal (2/3 known) | unknown | unknown | unknown | unknown | unknown | 784.9618710002396 (3/3 known) | unknown | unknown | unknown |
| fixed-workflow | omniroute/cx/gpt-6-luna-low | 0 subtotal (3/3 known) | unknown | unknown | unknown | unknown | unknown | 265.89359499979764 (3/3 known) | unknown | unknown | unknown |
| dsl | omniroute/cx/gpt-6-luna-low | 0 subtotal (3/3 known) | unknown | unknown | unknown | unknown | unknown | 267.4059829998296 (3/3 known) | unknown | unknown | unknown |
