## ADDED Requirements

### Requirement: Scoped provider-capable admission
The runtime SHALL compare explicit authorization with the frozen experiment,
provider route and exact model before launching a provider-capable executable.
Credentials alone SHALL NOT authorize execution. Unsupported required hard
financial or request guarantees SHALL be rejected, not silently downgraded.

#### Scenario: Missing authorization
- **WHEN** a live experiment has no concrete scoped authorization
- **THEN** no provider-capable executable is launched
- **AND** the preflight denial is retained without credentials

#### Scenario: Authorized uncapped exposure
- **WHEN** the operator explicitly approves an exact route and model without
  numerical token, request, run or financial limits
- **THEN** the runtime does not invent such quotas
- **AND** finite process deadlines, local concurrency and cleanup remain enforced

### Requirement: Independent evidence and grading
The runtime SHALL retain immutable execution and submission evidence and SHALL
keep requested identity distinct from observed identity. Unknown usage SHALL
remain unknown and estimates SHALL NOT be labeled actual charges.

#### Scenario: Regrading a live submission
- **WHEN** an immutable live-generated submission is independently regraded
- **THEN** no additional solver or model request occurs
- **AND** grading evidence references the same immutable submission

#### Scenario: Partial request visibility
- **WHEN** native CLI events do not cover every retry or auxiliary request
- **THEN** reports explicitly classify accounting as partial
- **AND** mock observations are not presented as real-provider validation
