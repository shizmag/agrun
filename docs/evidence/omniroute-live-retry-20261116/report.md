# AGRU comparative research pilot

Experiment: `research-omniroute-token-operational-v1-d03025578fd3e148`
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
  "experiment_id": "research-omniroute-token-operational-v1-d03025578fd3e148",
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
| 7e29596aecee18ab99c0b72bcc9cd1f3b0bef1b583e16719a8dea5bd3e4831ef | single-agent | error | completed | unknown | 0 | 193.612221 |
| 6328a359a670fbdf5c50b5809fd8c18128510a6dc95ec2be036ab94fc116f48f | fixed-workflow | error | completed | unknown | 0 | 120.557762 |
| eba68826fc46c32a5c5301a7efdd68b9c89815694894353145266a21f10cd0ef | dsl | error | completed | unknown | 0 | 96.284102 |
| 70151c112de3ae7f16fdc88a76ca540fa77e2f1f01ae8cc6b273918cb7ec1d94 | fixed-workflow | error | completed | unknown | 0 | 38.730882 |
| 6e8cb47c19451fd7861b5e5315d7855eaa9fa40a4054bbb07662a41681b96039 | dsl | error | completed | unknown | 0 | 137.581875 |
| ff2b5bfc25962b8680c5d482780cc71361407ca8e32af49f2d06e05bf7069e9e | single-agent | error | completed | unknown | 0 | 166.322097 |
| 8650f2d3ffaedcfc8d09cb3323c320d9e3a696a82640a6be4634d6e6c8d80d93 | dsl | error | completed | unknown | 0 | 39.399405 |
| 8b47028b49c669f45ce35e99e3f87fc6805244070b9a63e667658d31523a9b43 | single-agent | error | completed | unknown | 0 | 157.103801 |
| 09439088c28fae44b5b6fb69e9bae7bc5f42bf061f80ffa1a70a70e38b06eb6f | fixed-workflow | error | completed | unknown | 0 | 93.571028 |

## Descriptive comparison

| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |
|---|---:|---:|---:|---:|---:|---:|
| single-agent | 3 | 0/3 | 0/3 | unknown | 172.34604 | 3/3 |
| fixed-workflow | 3 | 0/3 | 0/3 | unknown | 84.286557 | 1/3 |
| dsl | 3 | 0/3 | 0/3 | unknown | 91.088461 | 1/3 |

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
| 7e29596aecee18ab99c0b72bcc9cd1f3b0bef1b583e16719a8dea5bd3e4831ef | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 193.6122210000176 (1/1 known) | unknown | unknown | unknown |
| 6328a359a670fbdf5c50b5809fd8c18128510a6dc95ec2be036ab94fc116f48f | omniroute/cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 10957 subtotal (1/1 known) | 20992 subtotal (1/1 known) | 0 subtotal (1/1 known) | 1240 subtotal (1/1 known) | 0 subtotal (1/1 known) | 120.55776200001128 (1/1 known) | unknown | unknown | unknown |
| eba68826fc46c32a5c5301a7efdd68b9c89815694894353145266a21f10cd0ef | omniroute/cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 10958 subtotal (1/1 known) | 20992 subtotal (1/1 known) | 0 subtotal (1/1 known) | 75 subtotal (1/1 known) | 0 subtotal (1/1 known) | 96.28410199983045 (1/1 known) | unknown | unknown | unknown |
| 70151c112de3ae7f16fdc88a76ca540fa77e2f1f01ae8cc6b273918cb7ec1d94 | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 38.73088199994527 (1/1 known) | unknown | unknown | unknown |
| 6e8cb47c19451fd7861b5e5315d7855eaa9fa40a4054bbb07662a41681b96039 | omniroute/cx/gpt-6-luna-low | 5 subtotal (1/1 known) | 1938 subtotal (1/1 known) | 52480 subtotal (1/1 known) | 0 subtotal (1/1 known) | 1273 subtotal (1/1 known) | 0 subtotal (1/1 known) | 137.581875000149 (1/1 known) | unknown | unknown | unknown |
| ff2b5bfc25962b8680c5d482780cc71361407ca8e32af49f2d06e05bf7069e9e | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 166.32209699996747 (1/1 known) | unknown | unknown | unknown |
| 8650f2d3ffaedcfc8d09cb3323c320d9e3a696a82640a6be4634d6e6c8d80d93 | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 39.39940500003286 (1/1 known) | unknown | unknown | unknown |
| 8b47028b49c669f45ce35e99e3f87fc6805244070b9a63e667658d31523a9b43 | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 157.10380100016482 (1/1 known) | unknown | unknown | unknown |
| 09439088c28fae44b5b6fb69e9bae7bc5f42bf061f80ffa1a70a70e38b06eb6f | omniroute/cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 11032 subtotal (1/1 known) | 20992 subtotal (1/1 known) | 0 subtotal (1/1 known) | 66 subtotal (1/1 known) | 0 subtotal (1/1 known) | 93.57102799997665 (1/1 known) | unknown | unknown | unknown |

### Per-architecture resources (separate model routes)

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| single-agent | omniroute/cx/gpt-6-luna-low | unknown | unknown | unknown | unknown | unknown | unknown | 517.0381190001499 (3/3 known) | unknown | unknown | unknown |
| fixed-workflow | omniroute/cx/gpt-6-luna-low | 6 subtotal (2/3 known) | 21989 subtotal (2/3 known) | 41984 subtotal (2/3 known) | 0 subtotal (2/3 known) | 1306 subtotal (2/3 known) | 0 subtotal (2/3 known) | 252.8596719999332 (3/3 known) | unknown | unknown | unknown |
| dsl | omniroute/cx/gpt-6-luna-low | 8 subtotal (2/3 known) | 12896 subtotal (2/3 known) | 73472 subtotal (2/3 known) | 0 subtotal (2/3 known) | 1348 subtotal (2/3 known) | 0 subtotal (2/3 known) | 273.2653820000123 (3/3 known) | unknown | unknown | unknown |
