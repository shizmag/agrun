## Context

Baseline is 813c00e (326 tests, 1702 assertions). Docker Desktop daemon is
unreachable. Official protocol verification is a separate blocked gate, not an
offline fixture assertion.

## Goals / Non-Goals

Deliver a complete offline experimental vertical slice and pinned external
integration. Do not redesign the runtime or claim fixture coding capability.

## Decisions

Use existing Store and benchmark namespace. Freeze contracts in
`docs/m1.1-contracts.md`, independently approved before implementation. Fail closed
on missing assets, mutable environment identities and unauthenticated native
scores. Explicit missingness and complete-repetition aggregation prevent inflated
quality. Regrading consumes the immutable prior submission, never the solver.

## Risks / Trade-offs

Containers are not a complete hostile-code security boundary. Native Python test
processes may expose trusted context and forge output; native compatibility alone
does not establish score authority. Official readiness remains provisional until
the trusted collector and real positive/negative controls are validated.
