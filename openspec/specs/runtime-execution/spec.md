# Runtime execution

## Purpose
Define the M0 contract for deterministic, inspectable local agent workflows without implicit model calls.

## Requirements

### Requirement: Explicit artifact dataflow
The runtime SHALL compile named typed inputs, executor definitions, steps and emitted outputs to canonical IR. Step references SHALL induce dependencies and artifacts SHALL be stored explicitly rather than in implicit global state.

#### Scenario: A downstream step consumes a prior output
- **WHEN** a step references `implement.repository`
- **THEN** it waits for `implement` and receives the decoded repository artifact

### Requirement: Safe process execution
Process adapters SHALL execute argument arrays without implicit shell interpolation, use a workspace working directory, capture bounded stdout and stderr, and enforce cancellation and timeouts against the process group.

#### Scenario: An executable exceeds its deadline
- **WHEN** the deadline expires while a process or descendant is running
- **THEN** the runtime records timeout and terminates the local process group

### Requirement: Explicit paid execution opt-in
OpenCode execution SHALL be blocked by default and SHALL require explicit live opt-in. Malformed or incomplete successful-process output SHALL NOT be reported as a successful model result.

#### Scenario: A default offline run requests OpenCode
- **WHEN** no explicit live option has been supplied
- **THEN** the adapter reports blocked without starting OpenCode

### Requirement: Optional external integrations
OpenSpec import, inspection and validation SHALL be optional local operations. Serena SHALL remain opt-in and disabled in baseline benchmarks.

#### Scenario: The baseline test suite runs
- **WHEN** integration tests execute
- **THEN** they use local fixture executables without provider API calls or Serena sessions
