## ADDED Requirements

### Requirement: Offline integration boundary
M0 adapters SHALL execute explicit argument arrays and enforce timeout and cancellation without implicit shell interpolation. OpenCode SHALL require explicit live opt-in; tests SHALL use local fixture executables and SHALL NOT make paid provider calls.

#### Scenario: A fixture executable is used for protocol tests
- **WHEN** a local fixture emits newline-delimited OpenCode JSON events
- **THEN** the adapter captures text, terminal-step usage, session identity and observed cost without contacting a provider

### Requirement: Optional specification workflow
OpenSpec integration SHALL support local import, JSON inspection and strict validation without being required for core library loading. Serena SHALL be disabled for baseline benchmarks.

#### Scenario: A specification is imported
- **WHEN** a valid unused name and a local source file are provided
- **THEN** the source is copied to the workspace specs directory without overwriting existing material
