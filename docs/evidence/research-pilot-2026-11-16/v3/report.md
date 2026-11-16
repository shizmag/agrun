# AGRU comparative research pilot

Experiment: `https-bound-nine-20261116`
Evidence: **simulated_relay**

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
  "execution_mode": "offline",
  "experiment_id": "https-bound-nine-20261116",
  "limits": {
    "timeout": 120
  },
  "models": [
    {
      "id": "cx/gpt-6-luna-low",
      "served_by": "controlled_https_simulator"
    }
  ],
  "repetitions": 3,
  "schema_version": 1,
  "solver_ids": [
    "single-agent",
    "fixed-workflow",
    "dsl"
  ],
  "subset_role": "development"
}
```

## Per-cell outcomes

Every planned cell remains in the denominator, including infrastructure failures.

| Cell | Architecture | Execution | Evaluation | Score | Regrade attempts | Wall seconds |
|---|---|---|---|---:|---:|---:|
| 19cc590189c6d7a8a92905bde7be3d526621f7e6d9d06904d5d351d21af713d6 | dsl | success | fail | 0.0 | 2 | 14.648738 |
| 238b951a89ff0998ac26018a23fe499293e335e72f3d0be5bee2350467021452 | fixed-workflow | success | fail | 0.0 | 2 | 14.726074 |
| c869f036f229d496b0dce22a5318f085af5266b18d7c2921cbdbfbf1f8c9993c | single-agent | success | fail | 0.0 | 2 | 5.12941 |
| 9f749d8343121e8f5c9bb96bfb6ef75efaa60032055e93ce4312073f577e1f1e | fixed-workflow | success | fail | 0.0 | 2 | 14.263945 |
| 5f2dd91de2caa90366ecf0354f746453871abb1ea0d6904efbe68d9c5a725be3 | single-agent | success | fail | 0.0 | 2 | 4.921916 |
| 100c1aed823534e052be16450457ada51aa7a6c2ca23a698076eb0e62f856ce5 | dsl | success | fail | 0.0 | 2 | 14.141719 |
| f350d564c97aceb2bb89fcad3ecfb191c173b1b5687004e8d2aadbb883122a7a | single-agent | success | fail | 0.0 | 2 | 4.552432 |
| 4f582190fd7ee0c69cb80fbd0d2affa2410195a0cfa1cb72cbee4dc9ca4aeb90 | dsl | success | fail | 0.0 | 2 | 14.003471 |
| 30bcc51126094c6089d80981015f299d7bbe5b9dd243e1f982b99cbeff11830a | fixed-workflow | success | fail | 0.0 | 2 | 13.840721 |

## Descriptive comparison

| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |
|---|---:|---:|---:|---:|---:|---:|
| dsl | 3 | 3/3 | 3/3 | 0.0 | 14.264643 | 3/3 |
| fixed-workflow | 3 | 3/3 | 3/3 | 0.0 | 14.276913 | 0/3 |
| single-agent | 3 | 3/3 | 3/3 | 0.0 | 4.867919 | 0/3 |

Means use observed numeric values only; observation counts are shown explicitly. Failed/missing grades are not silently scored as zero or removed from reliability denominators. Inspect JSON for execution failure categories, tool activity, request timing, retries, usage completeness and provider errors. Null is unknown, not zero. Cached tokens must not be added to inclusive input-token totals. Estimated costs are not verified billing.

## Regrading and interpretation

Separate grading attempts evaluate the saved immutable submission. Agreement validates reproducibility of this grader on that submission, not independence of grader implementation or benchmark validity. The accompanying verification record, not this narrative, determines regrade agreement.

**Simulator/fixture scores are pipeline observations only, not genuine model-quality observations. No architectural superiority can be inferred from them.**

## Validity limitations

* Three repetitions and one task support descriptive analysis only, not statistically generalizable superiority.
* Different inference-stage counts confound operational quality/resource comparisons. An equal-compute study must freeze aggregate request/token caps across all stages; per-stage limits alone are insufficient. Do not interpret greater inference expenditure as architectural improvement.
* Model nondeterminism remains even with frozen requested inference settings. Provider route identity is not actual served-model attestation.
* Provider telemetry can be incomplete; unknown tokens, reasoning, cache usage and prices prevent complete compute/cost comparisons. Missing usage counts above do not imply every non-null usage record is complete.
* The audited grader is a trusted evaluator with its own environment and trust boundary; solver-directory separation alone is not a security sandbox.
* Role prompts, textual handoffs, deterministic inventory and validation overhead are architecture-specific confounders. No claim is made about all possible agent architectures.
* A hash freeze detects alteration relative to its recorded digest, not authenticity against an attacker able to replace both evidence and digest.

## Resource observations

Evidence: simulated_relay; synthetic: true. Totals require completeness; subtotals retain partial known evidence. Unknown is never zero. Cache/reasoning may overlap input/output and are not added. Tool events are observed events, not complete tool-call counts. Saved summaries do not expose authoritative retry/provider-error counts.

### Per-cell resources

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 19cc590189c6d7a8a92905bde7be3d526621f7e6d9d06904d5d351d21af713d6 | cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 14.648737999843433 (1/1 known) | unknown | unknown | unknown |
| 238b951a89ff0998ac26018a23fe499293e335e72f3d0be5bee2350467021452 | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 14.726073999889195 (1/1 known) | unknown | unknown | unknown |
| c869f036f229d496b0dce22a5318f085af5266b18d7c2921cbdbfbf1f8c9993c | cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 12 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3 subtotal (1/1 known) | 0 subtotal (1/1 known) | 5.129410000052303 (1/1 known) | unknown | unknown | unknown |
| 9f749d8343121e8f5c9bb96bfb6ef75efaa60032055e93ce4312073f577e1f1e | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 14.263945000013337 (1/1 known) | unknown | unknown | unknown |
| 5f2dd91de2caa90366ecf0354f746453871abb1ea0d6904efbe68d9c5a725be3 | cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 12 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4.921916000079364 (1/1 known) | unknown | unknown | unknown |
| 100c1aed823534e052be16450457ada51aa7a6c2ca23a698076eb0e62f856ce5 | cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 14.141718999948353 (1/1 known) | unknown | unknown | unknown |
| f350d564c97aceb2bb89fcad3ecfb191c173b1b5687004e8d2aadbb883122a7a | cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 12 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4.5524319999385625 (1/1 known) | unknown | unknown | unknown |
| 4f582190fd7ee0c69cb80fbd0d2affa2410195a0cfa1cb72cbee4dc9ca4aeb90 | cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 14.003470999887213 (1/1 known) | unknown | unknown | unknown |
| 30bcc51126094c6089d80981015f299d7bbe5b9dd243e1f982b99cbeff11830a | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 13.840720999985933 (1/1 known) | unknown | unknown | unknown |

### Per-architecture resources (separate model routes)

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dsl | cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 42.793927999679 (3/3 known) | unknown | unknown | unknown |
| fixed-workflow | cx/gpt-6-luna-low | 9 subtotal (3/3 known) | 108 subtotal (3/3 known) | 0 subtotal (3/3 known) | 0 subtotal (3/3 known) | 27 subtotal (3/3 known) | 0 subtotal (3/3 known) | 42.830739999888465 (3/3 known) | unknown | unknown | unknown |
| single-agent | cx/gpt-6-luna-low | 3 subtotal (3/3 known) | 36 subtotal (3/3 known) | 0 subtotal (3/3 known) | 0 subtotal (3/3 known) | 9 subtotal (3/3 known) | 0 subtotal (3/3 known) | 14.60375800007023 (3/3 known) | unknown | unknown | unknown |
