# AGRU comparative research pilot

Experiment: `research-omniroute-token-staged-v2-dbb87e2dcd8df4a7`
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
  "experiment_id": "research-omniroute-token-staged-v2-dbb87e2dcd8df4a7",
  "limits": {
    "cell_inference_requests": 12,
    "coder_inference_requests": 7,
    "max_attempts": 1,
    "max_concurrent_sessions": 1,
    "max_parallelism": 1,
    "planner_inference_requests": 3,
    "reviewer_inference_requests": 2,
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
| ea69d53a9b9004e77d7019708ee533e0edf1d5cf032bd3c5b2d3265b5fcbc9bd | single-agent | success | fail | 0.73913 | 2 | 98.848142 |
| a938b520764c8f5b2564adab3b14c165046ebcbc2fe3f7119b0df919ee8c0211 | fixed-workflow | success | fail | 0.73913 | 2 | 95.607438 |
| 79ebba2581a0e09dd1e7f0d0e5d90055e2d2cee6c70d955cab484f1b24876060 | dsl | success | fail | 0.173913 | 2 | 116.795701 |
| 417036a1db6172ec0c6eae1734da8ac5ac7762165996a84e5bed2efba6d8740b | fixed-workflow | success | fail | 0.26087 | 2 | 105.135227 |
| 014635eb00cc29053f4c9eb0cbd629b81fc476560cd51c762ad27b8143b10819 | dsl | success | fail | 0.217391 | 2 | 128.453509 |
| 54bd74c46837ef3dd12b5219a989b964a9205da725297a1ee5338f60b1a7d8cd | single-agent | success | fail | 0.73913 | 2 | 103.556997 |
| 3bc17c5fa5ba361c0fedf4178f0b5b740173f2b2ab1bb43ebb2e8fd184230a65 | dsl | success | fail | 0.173913 | 2 | 142.82765 |
| 522315707eb4219be19839e0636952f41d1c61d595a1a21bff18f126c6ad4afd | single-agent | success | fail | 0.608696 | 2 | 100.697856 |
| 410841922136b50a9478985120589dde8aa5c4faa2e1c8bb92cca5b137a96c11 | fixed-workflow | success | fail | 0.173913 | 2 | 135.416369 |

## Descriptive comparison

| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |
|---|---:|---:|---:|---:|---:|---:|
| single-agent | 3 | 3/3 | 3/3 | 0.695652 | 101.034332 | 0/3 |
| fixed-workflow | 3 | 3/3 | 3/3 | 0.391304 | 112.053011 | 0/3 |
| dsl | 3 | 3/3 | 3/3 | 0.188406 | 129.358953 | 0/3 |

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
| ea69d53a9b9004e77d7019708ee533e0edf1d5cf032bd3c5b2d3265b5fcbc9bd | omniroute/cx/gpt-6-luna-low | 10 subtotal (1/1 known) | 115595 subtotal (1/1 known) | 12800 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3891 subtotal (1/1 known) | 0 subtotal (1/1 known) | 98.84814200014807 (1/1 known) | unknown | unknown | unknown |
| a938b520764c8f5b2564adab3b14c165046ebcbc2fe3f7119b0df919ee8c0211 | omniroute/cx/gpt-6-luna-low | 12 subtotal (1/1 known) | 82114 subtotal (1/1 known) | 52608 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3028 subtotal (1/1 known) | 0 subtotal (1/1 known) | 95.60743800015189 (1/1 known) | unknown | unknown | unknown |
| 79ebba2581a0e09dd1e7f0d0e5d90055e2d2cee6c70d955cab484f1b24876060 | omniroute/cx/gpt-6-luna-low | 12 subtotal (1/1 known) | 120079 subtotal (1/1 known) | 41984 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4249 subtotal (1/1 known) | 0 subtotal (1/1 known) | 116.79570099990815 (1/1 known) | unknown | unknown | unknown |
| 417036a1db6172ec0c6eae1734da8ac5ac7762165996a84e5bed2efba6d8740b | omniroute/cx/gpt-6-luna-low | 12 subtotal (1/1 known) | 59409 subtotal (1/1 known) | 77824 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3529 subtotal (1/1 known) | 0 subtotal (1/1 known) | 105.13522700010799 (1/1 known) | unknown | unknown | unknown |
| 014635eb00cc29053f4c9eb0cbd629b81fc476560cd51c762ad27b8143b10819 | omniroute/cx/gpt-6-luna-low | 11 subtotal (1/1 known) | 44123 subtotal (1/1 known) | 115456 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4991 subtotal (1/1 known) | 0 subtotal (1/1 known) | 128.45350899989717 (1/1 known) | unknown | unknown | unknown |
| 54bd74c46837ef3dd12b5219a989b964a9205da725297a1ee5338f60b1a7d8cd | omniroute/cx/gpt-6-luna-low | 10 subtotal (1/1 known) | 36772 subtotal (1/1 known) | 94720 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4144 subtotal (1/1 known) | 0 subtotal (1/1 known) | 103.55699700000696 (1/1 known) | unknown | unknown | unknown |
| 3bc17c5fa5ba361c0fedf4178f0b5b740173f2b2ab1bb43ebb2e8fd184230a65 | omniroute/cx/gpt-6-luna-low | 12 subtotal (1/1 known) | 68409 subtotal (1/1 known) | 105216 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4490 subtotal (1/1 known) | 0 subtotal (1/1 known) | 142.8276500001084 (1/1 known) | unknown | unknown | unknown |
| 522315707eb4219be19839e0636952f41d1c61d595a1a21bff18f126c6ad4afd | omniroute/cx/gpt-6-luna-low | 10 subtotal (1/1 known) | 33153 subtotal (1/1 known) | 94464 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3954 subtotal (1/1 known) | 0 subtotal (1/1 known) | 100.69785600015894 (1/1 known) | unknown | unknown | unknown |
| 410841922136b50a9478985120589dde8aa5c4faa2e1c8bb92cca5b137a96c11 | omniroute/cx/gpt-6-luna-low | 12 subtotal (1/1 known) | 23784 subtotal (1/1 known) | 120192 subtotal (1/1 known) | 0 subtotal (1/1 known) | 5048 subtotal (1/1 known) | 0 subtotal (1/1 known) | 135.41636899998412 (1/1 known) | unknown | unknown | unknown |

### Per-architecture resources (separate model routes)

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| single-agent | omniroute/cx/gpt-6-luna-low | 30 subtotal (3/3 known) | 185520 subtotal (3/3 known) | 201984 subtotal (3/3 known) | 0 subtotal (3/3 known) | 11989 subtotal (3/3 known) | 0 subtotal (3/3 known) | 303.10299500031397 (3/3 known) | unknown | unknown | unknown |
| fixed-workflow | omniroute/cx/gpt-6-luna-low | 36 subtotal (3/3 known) | 165307 subtotal (3/3 known) | 250624 subtotal (3/3 known) | 0 subtotal (3/3 known) | 11605 subtotal (3/3 known) | 0 subtotal (3/3 known) | 336.159034000244 (3/3 known) | unknown | unknown | unknown |
| dsl | omniroute/cx/gpt-6-luna-low | 35 subtotal (3/3 known) | 232611 subtotal (3/3 known) | 262656 subtotal (3/3 known) | 0 subtotal (3/3 known) | 13730 subtotal (3/3 known) | 0 subtotal (3/3 known) | 388.0768599999137 (3/3 known) | unknown | unknown | unknown |
