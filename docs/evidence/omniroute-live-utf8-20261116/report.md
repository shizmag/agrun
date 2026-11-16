# AGRU comparative research pilot

Experiment: `research-omniroute-token-operational-v1-50a3db2c5c7aebcf`
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
  "experiment_id": "research-omniroute-token-operational-v1-50a3db2c5c7aebcf",
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
| c2c4d1b0cfdea2d77504c7294783b2113617fd947cafbef8ae5081e51ea7d1b4 | single-agent | success | fail | 0.608696 | 2 | 79.034697 |
| 12e73e2e30cd42cd52c158de2540c345873ed908cb2db5048bd2ad33bf7c171e | fixed-workflow | error | completed | unknown | 0 | 10.705836 |
| d353fb2f6f1623d73f6e8c58d2292094594e4ec764a7ca60d66b4e02e3d37a1c | dsl | error | completed | unknown | 0 | 206.753426 |
| 4f8090c19abd91508f3059dcdaefc65057fe344c48db11fedb59a8322e62f808 | fixed-workflow | error | completed | unknown | 0 | 216.137949 |
| 7669e9b16fb38fd6190e82649372d8a99b2e1ab9b0815c933e8d13a3b6922f8c | dsl | error | completed | unknown | 0 | 150.957423 |
| 96987c79d7be8a72a12b81ed3f2aa64671a1d340768fee23c05e205c70b17295 | single-agent | success | fail | 0.73913 | 2 | 89.004842 |
| 0cfdcff1912cf723219eb0b866d018ea7ab4cdd881913668491f36c0c94e97e3 | dsl | error | completed | unknown | 0 | 9.54307 |
| 2a5d0fba603b48225c0b8c5b18b6be754cfd9da84f35f2813edb4ef9fd825d28 | single-agent | error | completed | unknown | 2 | 59.594052 |
| bce3642714c78802d31814c26cc2a9aad642dc971bdf5aef4c1188b5ba7ed1c9 | fixed-workflow | error | completed | unknown | 0 | 213.485954 |

## Descriptive comparison

| Architecture | Planned cells | Successful execution | Numeric quality observations | Mean observed score | Mean observed wall seconds | Missing usage |
|---|---:|---:|---:|---:|---:|---:|
| single-agent | 3 | 2/3 | 2/3 | 0.673913 | 75.877864 | 0/3 |
| fixed-workflow | 3 | 0/3 | 0/3 | unknown | 146.77658 | 0/3 |
| dsl | 3 | 0/3 | 0/3 | unknown | 122.417973 | 0/3 |

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
| c2c4d1b0cfdea2d77504c7294783b2113617fd947cafbef8ae5081e51ea7d1b4 | omniroute/cx/gpt-6-luna-low | 6 subtotal (1/1 known) | 24923 subtotal (1/1 known) | 48512 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3236 subtotal (1/1 known) | 0 subtotal (1/1 known) | 79.0346969999373 (1/1 known) | unknown | unknown | unknown |
| 12e73e2e30cd42cd52c158de2540c345873ed908cb2db5048bd2ad33bf7c171e | omniroute/cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 111 subtotal (1/1 known) | 10496 subtotal (1/1 known) | 0 subtotal (1/1 known) | 24 subtotal (1/1 known) | 10 subtotal (1/1 known) | 10.705835999920964 (1/1 known) | unknown | unknown | unknown |
| d353fb2f6f1623d73f6e8c58d2292094594e4ec764a7ca60d66b4e02e3d37a1c | omniroute/cx/gpt-6-luna-low | 10 subtotal (1/1 known) | 30559 subtotal (1/1 known) | 90496 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4462 subtotal (1/1 known) | 0 subtotal (1/1 known) | 206.75342600001022 (1/1 known) | unknown | unknown | unknown |
| 4f8090c19abd91508f3059dcdaefc65057fe344c48db11fedb59a8322e62f808 | omniroute/cx/gpt-6-luna-low | 10 subtotal (1/1 known) | 5897 subtotal (1/1 known) | 121088 subtotal (1/1 known) | 0 subtotal (1/1 known) | 4985 subtotal (1/1 known) | 0 subtotal (1/1 known) | 216.1379490001127 (1/1 known) | unknown | unknown | unknown |
| 7669e9b16fb38fd6190e82649372d8a99b2e1ab9b0815c933e8d13a3b6922f8c | omniroute/cx/gpt-6-luna-low | 9 subtotal (1/1 known) | 15525 subtotal (1/1 known) | 84096 subtotal (1/1 known) | 0 subtotal (1/1 known) | 1801 subtotal (1/1 known) | 0 subtotal (1/1 known) | 150.95742299989797 (1/1 known) | unknown | unknown | unknown |
| 96987c79d7be8a72a12b81ed3f2aa64671a1d340768fee23c05e205c70b17295 | omniroute/cx/gpt-6-luna-low | 7 subtotal (1/1 known) | 4884 subtotal (1/1 known) | 84608 subtotal (1/1 known) | 0 subtotal (1/1 known) | 3769 subtotal (1/1 known) | 0 subtotal (1/1 known) | 89.00484200008214 (1/1 known) | unknown | unknown | unknown |
| 0cfdcff1912cf723219eb0b866d018ea7ab4cdd881913668491f36c0c94e97e3 | omniroute/cx/gpt-6-luna-low | 1 subtotal (1/1 known) | 111 subtotal (1/1 known) | 10496 subtotal (1/1 known) | 0 subtotal (1/1 known) | 25 subtotal (1/1 known) | 10 subtotal (1/1 known) | 9.543070000130683 (1/1 known) | unknown | unknown | unknown |
| 2a5d0fba603b48225c0b8c5b18b6be754cfd9da84f35f2813edb4ef9fd825d28 | omniroute/cx/gpt-6-luna-low | 5 subtotal (1/1 known) | 5288 subtotal (1/1 known) | 52480 subtotal (1/1 known) | 0 subtotal (1/1 known) | 2407 subtotal (1/1 known) | 0 subtotal (1/1 known) | 59.59405199997127 (1/1 known) | unknown | unknown | unknown |
| bce3642714c78802d31814c26cc2a9aad642dc971bdf5aef4c1188b5ba7ed1c9 | omniroute/cx/gpt-6-luna-low | 10 subtotal (1/1 known) | 9461 subtotal (1/1 known) | 108160 subtotal (1/1 known) | 0 subtotal (1/1 known) | 5538 subtotal (1/1 known) | 0 subtotal (1/1 known) | 213.4859539999161 (1/1 known) | unknown | unknown | unknown |

### Per-architecture resources (separate model routes)

| Cell / architecture | Model | requests | input | cache_read | cache_write | output | reasoning | wall_seconds | tool_events | retries | provider_errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| single-agent | omniroute/cx/gpt-6-luna-low | 18 subtotal (3/3 known) | 35095 subtotal (3/3 known) | 185600 subtotal (3/3 known) | 0 subtotal (3/3 known) | 9412 subtotal (3/3 known) | 0 subtotal (3/3 known) | 227.6335909999907 (3/3 known) | unknown | unknown | unknown |
| fixed-workflow | omniroute/cx/gpt-6-luna-low | 21 subtotal (3/3 known) | 15469 subtotal (3/3 known) | 239744 subtotal (3/3 known) | 0 subtotal (3/3 known) | 10547 subtotal (3/3 known) | 10 subtotal (3/3 known) | 440.32973899994977 (3/3 known) | unknown | unknown | unknown |
| dsl | omniroute/cx/gpt-6-luna-low | 20 subtotal (3/3 known) | 46195 subtotal (3/3 known) | 185088 subtotal (3/3 known) | 0 subtotal (3/3 known) | 6288 subtotal (3/3 known) | 10 subtotal (3/3 known) | 367.2539190000389 (3/3 known) | unknown | unknown | unknown |
