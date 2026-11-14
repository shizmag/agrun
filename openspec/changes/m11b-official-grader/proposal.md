## Why

M1.1 has no validated official-task score. Establish a real positive/negative
control before claiming that repository correctness is measured.

## What Changes

- Independently audit the pinned native protocol and available task assets.
- Separate historical compatibility from an explicitly versioned audited path.
- Integrate deterministic submissions through existing registry/store interfaces.
- Retain fail-closed readiness when assets, authorization, or trustworthy controls
  are unavailable; document real execution separately from infrastructure tests.

## Capabilities

### New Capabilities
- `official-grading`: pinned, independently controlled official evaluation.

### Modified Capabilities

None. Existing runtime and scientific benchmark guarantees remain in force.

## Impact

Ruby benchmark adapters, CLI integration, offline tests, and protocol evidence.
No new scheduler/store, paid provider calls, redistribution of reference source,
push, deployment, or merge.
