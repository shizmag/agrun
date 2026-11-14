## ADDED Requirements

### Requirement: Frozen benchmark identity
The system SHALL bind each task and experiment to pinned dataset and task manifest
identities and SHALL retain exclusions and unavailable resources.

#### Scenario: Missing image
- **WHEN** a required pinned task image is unavailable
- **THEN** readiness is unavailable and no quality score is fabricated

### Requirement: Independent grading
The system SHALL grade only verified immutable submissions, separate execution
status from quality, and reject unauthenticated native result channels.

#### Scenario: Forged grading output
- **WHEN** submitted code prints a full-score JSON record
- **THEN** that output alone cannot establish an authoritative quality result

### Requirement: Complete experiment records
The system SHALL persist all matrix coordinates before execution and retain
not-started cells after interruption.

#### Scenario: Interrupted matrix
- **WHEN** execution stops after the first cell
- **THEN** persisted reporting includes every remaining cell as incomplete

### Requirement: Offline scientific qualification
The system SHALL prohibit provider calls in fixture mode and qualify fixture
reports as infrastructure demonstrations, not agent capability comparisons.

#### Scenario: Incompatible profile
- **WHEN** an offline experiment requests a live model profile
- **THEN** execution fails closed before invoking any solver or provider

### Requirement: Reconstructible metrics
The system SHALL derive per-arm metrics from persisted cells, distinguish
per-task macro means from pooled counts, and disclose missing repetitions.

#### Scenario: Asymmetric grading failure
- **WHEN** one repetition lacks a valid grade
- **THEN** the task is excluded from complete-task conditional quality with reason
