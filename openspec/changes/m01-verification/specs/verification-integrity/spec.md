## ADDED Requirements

### Requirement: Independent evidence and outcome separation
The harness SHALL distinguish artifact generation, evaluation execution and task
verdict. Missing, malformed, interrupted or stale evidence SHALL NOT establish a
passing solution. Evidence SHALL bind the submitted repository, specification,
procedure and relevant environment.

#### Scenario: Evidence from a different submission
- **WHEN** a previously passing artifact or evaluation contract changes
- **THEN** the prior result does not authorize current validation

#### Scenario: Evaluator infrastructure failure
- **WHEN** an evaluator crashes or exceeds its deadline
- **THEN** persisted history records an evaluation error rather than a passing solution or substantive quality failure

#### Scenario: Same bytes from another generation
- **WHEN** a caller verifies evidence while supplying a different producer generation, even within the same run and with identical bytes
- **THEN** verification rejects the association rather than inheriting a verdict

### Requirement: Fail-closed explicit evidence reuse
The evaluator SHALL expose explicit point-in-time evidence verification that checks
authoritative stored records, submitted generation, report integrity and current
artifact, specification, procedure and evaluation-environment bindings. Historical
reports SHALL remain historical unless verified for the current context. Standalone
evaluation SHALL identify itself rather than claim solver-generation provenance.

#### Scenario: Missing evidence record
- **WHEN** verification encounters missing or inconsistent stored evidence
- **THEN** it fails without repairing evidence or claiming current validation

### Requirement: Safe retry opt-in
An executor result SHALL authorize transport replay only with explicit retry-safe
opt-in, remaining budget and no cancellation. Classification alone SHALL NOT imply
that an external side effect is safe to repeat.

#### Scenario: Transport failure without safe replay
- **WHEN** an executor returns transport failure without retry-safe opt-in
- **THEN** the runtime retains the failed attempt and does not invoke it again

### Requirement: Deterministic offline conformance
The project SHALL provide a bounded offline conformance suite with independent
expected outcomes and persisted execution evidence, including correct and
incorrect patches, stale evidence, evaluator failures, parallel isolation and
interruption. Local fixtures SHALL NOT invoke paid providers.

#### Scenario: Repeated infrastructure verification
- **WHEN** a developer runs the conformance task without model credentials
- **THEN** each case exposes expected and actual outcome, match status and execution references
