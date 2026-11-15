## ADDED Requirements

### Requirement: Writer-quiescent repository export
The runtime SHALL accept an export only after trusted evidence establishes that
all untrusted workspace writers have terminated and been reaped. Agent-emitted
completion events SHALL NOT constitute this evidence. Detached children and open
file descriptors SHALL be included. Trusted export code SHALL remain outside
agent modification authority. Failure or incomplete evidence SHALL fail closed.

#### Scenario: Detached writer survives the immediate agent
- **WHEN** the immediate agent exits while a detached child retains a workspace descriptor
- **THEN** trusted supervision terminates and reaps that child before export
- **AND** accepted contents cannot change during export

### Requirement: One lifecycle deadline
Preparation, startup, execution, termination, quiescence, export and verification
SHALL share one monotonic deadline. Emergency cleanup SHALL have a separate,
explicit finite bound and SHALL NOT authorize submission acceptance.

#### Scenario: Deadline expires during export
- **WHEN** export exhausts the remaining lifecycle budget
- **THEN** no partial artifact is accepted and bounded cleanup is attempted

### Requirement: Safe source metadata
Exports SHALL preserve legitimate executable and read-only file permissions,
ordinary directory permissions, relative paths and contents. Privileged modes,
links, special objects, invalid paths, excessive outputs and incomplete archives
SHALL be rejected using descriptor-relative validation where applicable.

#### Scenario: Executable source is exported
- **WHEN** a safe executable script and read-only source file are exported
- **THEN** their contents and ordinary permission bits survive immutable capture

### Requirement: Offline parity evidence
All three architectures SHALL execute their distinct complete semantics through
one sandbox and mock boundary, producing independently graded and regraded
immutable submissions. Fixture outputs SHALL be labeled fixtures, not capability
results. No paid calls or reference substitution SHALL be used as this evidence.

#### Scenario: Incomplete architecture execution
- **WHEN** a workflow stops before required roles finish
- **THEN** it is recorded as incomplete and cannot satisfy parity or freeze gates
