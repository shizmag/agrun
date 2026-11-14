## ADDED Requirements

### Requirement: Distinct reproducible protocols
The system SHALL distinguish pinned legacy grading from audited grading and SHALL
NOT present an unavailable protocol as an executed official evaluation.

#### Scenario: Native procedure is unsafe or unavailable
- **WHEN** trustworthy native grading prerequisites are missing
- **THEN** readiness is unavailable with a concrete reason and no quality score

### Requirement: Authoritative controlled execution
The system SHALL accept quality evidence only after actual authoritative tests
execute in a digest-pinned environment with a defined clean submission boundary.
The trusted collector's process, files and result channel SHALL NOT be writable
or impersonable by candidate code, preserving the existing M1.1 contract.
Native execution without this boundary MAY be retained as explicitly untrusted
diagnostic observations but SHALL NOT establish an authoritative quality verdict.

#### Scenario: Candidate omits an implementation file
- **WHEN** preparing an audited submission
- **THEN** original implementation files absent from the submission cannot be inherited

#### Scenario: Candidate prints a success summary
- **WHEN** untrusted output resembles a passing test summary
- **THEN** that text alone cannot establish a valid quality score

#### Scenario: Candidate replaces structured results or interrupts the collector
- **WHEN** candidate code replaces a report, exits prematurely or interferes with collection
- **THEN** the boundary rejects the observations as authoritative quality evidence

### Requirement: Evidence and status integrity
The system SHALL bind accepted results to submission, task, tests, environment and
procedure, retaining infrastructure outcomes separately from quality verdicts.
Binding SHALL include the actually consumed snapshot, trusted asset identities,
evaluator and normalizer versions, and effective resource policy.

#### Scenario: Evaluator fails
- **WHEN** grading crashes, times out, or yields incomplete observations
- **THEN** the outcome is not silently normalized to a zero or full quality score

### Requirement: Generic persisted execution
The system SHALL reuse the benchmark registry, immutable artifact store and
experiment runner for official adapters without requiring solver reruns to regrade.

#### Scenario: Independent regrading
- **WHEN** a persisted immutable submission is regraded
- **THEN** a separate attempt is retained and incompatible evidence is rejected

#### Scenario: Material evaluation identity changes
- **WHEN** submission, task, tests, procedure, normalizer, environment or effective limits change
- **THEN** prior evidence is rejected for reuse or a new explicitly identified evaluation is required

### Requirement: Honest control acceptance
The system SHALL require independently established positive and negative controls
before marking an official protocol operational.

#### Scenario: Only infrastructure fixtures pass
- **WHEN** no real official-task tests have been observed
- **THEN** milestone status remains PARTIAL or BLOCKED rather than PASS
