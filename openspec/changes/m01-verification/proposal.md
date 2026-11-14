# M0.1 independent verification hardening

## Why

Future experiments require independent evidence that malformed programs, stale
artifacts, interrupted execution and evaluator infrastructure failures cannot
produce false scientific success.

## What Changes

- Freeze contract-oriented test oracles and a traceability matrix.
- Add deterministic offline adversarial, acceptance and conformance suites.
- Correct only defects established by tests and independent review.
- Record reproducible acceptance evidence and explicit remaining boundaries.

## Impact

Ruby DSL and schema-v1 IR remain. No provider calls, HTTP transport, crash
recovery, distributed execution, OS sandbox, memory integration or official
external benchmark support are added. Public semantic clarifications must be
documented with their regression evidence.
