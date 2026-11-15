## ADDED Requirements

### Requirement: Evidence-bound execution
The runtime SHALL preserve ordered raw observations, attempt and session identity,
frozen configuration, process outcome and explicit completion evidence separately
from independent grading. Missing or truncated completion SHALL NOT establish
successful execution. Cancellation and timeout SHALL override late success.

#### Scenario: Incomplete successful process
- **WHEN** a fixture exits zero without required completion evidence
- **THEN** execution is incomplete and partial evidence remains inspectable

### Requirement: Honest request accounting
The runtime SHALL aggregate distinct authoritative request observations without
double counting; missing usage SHALL remain unknown. Cost estimates SHALL retain
versioned pricing provenance and SHALL NOT be labeled provider charges.

#### Scenario: Duplicate usage observation
- **WHEN** the same request is reported twice
- **THEN** its usage is counted once and duplicate evidence is retained

### Requirement: Capability-aware admission
The runtime SHALL atomically reserve shared supported local capacity before
launch and SHALL reject required unsupported hard limits. Offline execution SHALL
require explicit local fixture identity and SHALL deny real provider selection.

#### Scenario: Unsupported hard monetary limit
- **WHEN** a policy requires hard monetary enforcement through the CLI
- **THEN** admission is rejected before launch and the decision is persisted

### Requirement: Reconstructable scientific reports
Reports SHALL distinguish fixture telemetry, provider observations and independent
grading, include all solver roles and attempts, and retain unknownness when
reconstructed from immutable persisted execution evidence.

#### Scenario: Multiple solver roles
- **WHEN** planner, coder and verifier execute the same task workflow
- **THEN** all roles contribute to usage independently of the quality verdict
