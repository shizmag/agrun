# AGRU comparative research pilot

Experiment: `rc-nine-20261116`
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
  "experiment_id": "rc-nine-20261116",
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
| 53b112fa416751a1a96d5e6f24890175b002b1b2e7cbf29fe2c7c4d8ab5a1832 | dsl | success | fail | 0.0 | 2 | 13.842539 |
| d543ba2475069f19c720ab8ba93e108203a0a8bf392fa57063b847a7b40c33a8 | fixed-workflow | success | fail | 0.0 | 2 | 12.403809 |
| 6d32b87b06e6d4fdd8aaf7f8ebe56a6f60e021cb9d47fc7479b0492919cbf557 | single-agent | success | fail | 0.0 | 2 | 5.169019 |
| c54dbe06c766fccc3785926bb3063943cf0aead9477cb582e9eb0514f819f010 | fixed-workflow | success | fail | 0.0 | 2 | 12.708077 |
| ff68e8a46cc47a98ad975e9a39d524922762001fe9b049bf74c1929ad2d61dcf | single-agent | success | fail | 0.0 | 2 | 4.076062 |
| 4ba74bb72747888f675571481642115eaff18691c52204a1aff19aca3734bbb9 | dsl | success | fail | 0.0 | 2 | 13.520817 |
| 7c4dd78ff558e8be00d043511e1038174b4be118d84f5a128eb3ea510456efaf | single-agent | success | fail | 0.0 | 2 | 4.1952 |
| ee922a38d75f310805b832703e243a9cecc9866a2548537fc52438c35bc5385b | dsl | success | fail | 0.0 | 2 | 11.928737 |
| be1e3f031aa1eb2fe55ad4bac643c664fc95b27a7ac4ead2c94b31a4913d8f8d | fixed-workflow | success | fail | 0.0 | 2 | 13.521417 |

## Descriptive comparison

| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |
|---|---:|---:|---:|---:|---:|---:|
| dsl | 3 | 3/3 | 3/3 | 0.0 | 13.097364 | 0/3 |
| fixed-workflow | 3 | 3/3 | 3/3 | 0.0 | 12.877768 | 0/3 |
| single-agent | 3 | 3/3 | 3/3 | 0.0 | 4.480094 | 0/3 |

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
| 53b112fa416751a1a96d5e6f24890175b002b1b2e7cbf29fe2c7c4d8ab5a1832 | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 13.842539000092074 (1/1 known) | unknown | unknown | unknown |
| d543ba2475069f19c720ab8ba93e108203a0a8bf392fa57063b847a7b40c33a8 | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 12.403809000039473 (1/1 known) | unknown | unknown | unknown |
| 6d32b87b06e6d4fdd8aaf7f8ebe56a6f60e021cb9d47fc7479b0492919cbf557 | cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 12 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3 subtotal (1/1 known) | 0 subtotal (1/1 known) | 5.169019000139087 (1/1 known) | unknown | unknown | unknown |
| c54dbe06c766fccc3785926bb3063943cf0aead9477cb582e9eb0514f819f010 | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 12.708076999988407 (1/1 known) | unknown | unknown | unknown |
| ff68e8a46cc47a98ad975e9a39d524922762001fe9b049bf74c1929ad2d61dcf | cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 12 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4.076061999890953 (1/1 known) | unknown | unknown | unknown |
| 4ba74bb72747888f675571481642115eaff18691c52204a1aff19aca3734bbb9 | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 13.52081700018607 (1/1 known) | unknown | unknown | unknown |
| 7c4dd78ff558e8be00d043511e1038174b4be118d84f5a128eb3ea510456efaf | cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 12 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4.195199999958277 (1/1 known) | unknown | unknown | unknown |
| ee922a38d75f310805b832703e243a9cecc9866a2548537fc52438c35bc5385b | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 11.92873700009659 (1/1 known) | unknown | unknown | unknown |
| be1e3f031aa1eb2fe55ad4bac643c664fc95b27a7ac4ead2c94b31a4913d8f8d | cx/gpt-6-luna-low | 3 subtotal (1/1 known) | 36 subtotal (1/1 known) | 0 subtotal (1/1 known) | 0 subtotal (1/1 known) | 9 subtotal (1/1 known) | 0 subtotal (1/1 known) | 13.521417000098154 (1/1 known) | unknown | unknown | unknown |

### Per-architecture resources (separate model routes)

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dsl | cx/gpt-6-luna-low | 9 subtotal (3/3 known) | 108 subtotal (3/3 known) | 0 subtotal (3/3 known) | 0 subtotal (3/3 known) | 27 subtotal (3/3 known) | 0 subtotal (3/3 known) | 39.292093000374734 (3/3 known) | unknown | unknown | unknown |
| fixed-workflow | cx/gpt-6-luna-low | 9 subtotal (3/3 known) | 108 subtotal (3/3 known) | 0 subtotal (3/3 known) | 0 subtotal (3/3 known) | 27 subtotal (3/3 known) | 0 subtotal (3/3 known) | 38.633303000126034 (3/3 known) | unknown | unknown | unknown |
| single-agent | cx/gpt-6-luna-low | 3 subtotal (3/3 known) | 36 subtotal (3/3 known) | 0 subtotal (3/3 known) | 0 subtotal (3/3 known) | 9 subtotal (3/3 known) | 0 subtotal (3/3 known) | 13.440280999988317 (3/3 known) | unknown | unknown | unknown |
