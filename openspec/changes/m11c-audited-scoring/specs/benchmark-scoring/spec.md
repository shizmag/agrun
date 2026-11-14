## ADDED Requirements

### Requirement: Scoped audited scoring
The benchmark infrastructure SHALL derive audited-v2 scores only from a complete,
unique canonical authoritative result population under a matching pinned
environment and successful reference preflight. It SHALL retain immutable raw
evidence and separate quality results from execution failures.

#### Scenario: Complete authoritative execution
- **WHEN** every expected canonical test has a consistent structured outcome
- **THEN** quality is ordinary passed tests divided by expected tests
- **AND** stdout summaries do not influence quality

#### Scenario: Verified missing candidate implementation
- **WHEN** the reference succeeds and structured collection failure is proven to
  originate in absent required candidate functionality
- **THEN** the protocol may issue zero with candidate collection failure basis
- **AND** evidence records zero executed tests rather than invented failures

#### Scenario: Invalid or unavailable evidence
- **WHEN** identities, report completeness, process status or environment fail
  validation, or collection failure attribution is ambiguous
- **THEN** the result remains unscored with an explicit diagnostic classification

#### Scenario: Scientific trust scope
- **WHEN** audited-v2 evidence is reported
- **THEN** reports identify its protocol and scoped benign-submission assumptions
- **AND** do not claim authenticated reporting against arbitrary hostile Python
