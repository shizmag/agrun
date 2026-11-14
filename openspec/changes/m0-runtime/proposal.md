# M0 artifact workflow runtime

## Why
Agent workflows need reproducible dataflow, resumable local execution, observable costs and an offline baseline before live integrations can be evaluated responsibly.

## What Changes
- Add Ruby DSL compilation, canonical IR and artifact validation.
- Add persisted execution and explicit fake, shell and opt-in OpenCode executors.
- Add safe process execution and optional local OpenSpec integration.
- Document Serena opt-in and defer HTTP transport until its experimental V2 contract is stabilized and tested.

## Capabilities

### New Capabilities
- `runtime-execution`: typed workflow execution, process safety and offline integration contracts.

### Modified Capabilities
None.

## Impact
Local Ruby library and CLI; SQLite persistence; optional installed OpenCode and OpenSpec binaries. No paid API calls during development or baseline tests.
