## ADDED Requirements

### Requirement: Shared boundary preserves architectural treatments
All three comparison arms SHALL use the same tested effective sandbox, image,
tool capabilities, network policy, task, grader conditions and resource limits.
Single invocation, fixed planner/coder/reviewer handoffs and DSL compiler/runtime,
typed dependency artifacts and separate verification SHALL retain distinct
registered semantics. Solver subprocesses and local tests SHALL remain within
the declared boundary; hidden grader procedures SHALL NOT enter solver space.

#### Scenario: Parity check retains treatment differences
- **WHEN** offline acceptance compares the three effective arm environments
- **THEN** shared boundary fields match and registered architecture fields retain their distinct invocation and handoff semantics

#### Scenario: Shell attempts an external read
- **WHEN** a solver uses shell or a subprocess to read an external host or hidden-grader canary
- **THEN** the effective sandbox denies disclosure and retains evidence of the attempted access

### Requirement: Environment identity is complete and tested before freeze
A comparison identity SHALL bind runtime, sandbox configuration, immutable image,
platform, OpenCode, tool policy, catalog, route, task, grader, architecture and
resources as detailed in the draft protocol. It SHALL remain unfrozen until
implementation and offline acceptance pass. Material changes SHALL require a
new identity and acceptance evidence. Secrets SHALL NOT enter identity data.

#### Scenario: Draft lacks implemented policy evidence
- **WHEN** only a draft protocol or manifest exists without passing effective-policy tests
- **THEN** no final frozen comparison identity is declared and dispatch remains blocked

#### Scenario: Effective configuration changes after acceptance
- **WHEN** image, runtime, tool policy, route, task, grader, architecture or resource identity changes
- **THEN** the old acceptance record cannot authorize dispatch under the changed identity

### Requirement: Acceptance is offline and end-to-end
Before freeze, tests SHALL exercise the installed executable and actual sandbox
policy without paid calls or credentials. Evidence SHALL cover permitted task
editing/testing, traversal and symlink/alias reads, shell/subprocess escape and
external writes, ambient context, network restrictions, timeout/cancellation,
resource limits, cleanup, arm parity and submitted repository/grader digest
binding. Missing evidence SHALL NOT count as a passing gate.

#### Scenario: Primitive file denial passes but shell bypasses it
- **WHEN** a file-tool probe denies an external read but shell returns the same canary
- **THEN** the boundary acceptance gate fails despite the passing primitive probe

#### Scenario: All arms complete offline acceptance
- **WHEN** installed-binary tests pass with fake provider transport for all registered arms
- **THEN** evidence records effective configuration identities and observed outcomes without authorizing live dispatch

### Requirement: Historical evidence remains quarantined
Reports SHALL preserve historical single-agent 14/23 with successful execution
and failed evaluation, contaminated fixed timeout with original null score and
supplemental partial-snapshot 13/23, and undispatched DSL. Reports SHALL NOT treat
these as a valid comparison or new-environment replicates, or backfill a new
environment identity onto them.

#### Scenario: Supplemental timeout snapshot is reported
- **WHEN** a report includes the fixed partial snapshot grade of 13/23
- **THEN** it labels the grade supplemental and retains the original timeout and null cell score

### Requirement: Live registration and outcome reporting remain explicit
New live dispatch SHALL require preregistered cells, order, identities, budgets,
stopping rules and separate explicit authorization. Reports SHALL retain blocked,
failed, timed-out and partial cells; separate execution from evaluation and
solver from grader time; and keep unknown served identity, usage and cost unknown.
Contamination or identity drift SHALL block comparative interpretation and
further dispatch pending review. A timeout SHALL NOT be described as a spending cap.

#### Scenario: Prior smoke approval exists
- **WHEN** the new sandbox environment passes offline acceptance
- **THEN** previous smoke approval does not authorize new paid dispatch or an expanded pilot

#### Scenario: A cell exposes contamination
- **WHEN** retained evidence reveals host-context contamination during a new cell
- **THEN** reporting preserves the cell and blocks comparative interpretation and further dispatch pending review
