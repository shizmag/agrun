## Context

Baseline 770c7b0 passes 383 tests / 2,221 assertions. Docker Desktop is now
reachable (29.8.2, Linux/aarch64); this removes a previous environmental blocker
but establishes neither asset availability nor grading correctness.

## Goals / Non-Goals

One real task with reference, empty and incorrect controls, persisted by the
generic experiment runner. Do not create a second framework or approximate native
test semantics. If external prerequisites block execution, retain reusable safe
changes and explicitly report PARTIAL rather than inventing scores.

## Decisions

Legacy identity includes pinned source revision. Audited identity is distinct;
corrections require independent failing examples and comparability notes. Quality
is never inferred from printed success or an evaluator crash. Authoritative
collection and clean implementation boundaries require task-specific evidence.
Image digests, task/specification/test identities, submission and procedure must
bind every accepted evaluation. Solver workspace never receives private assets.
Downloads require the existing explicit opt-in; cached assets may be inspected.

## Risks / Trade-offs

Docker is not a universal hostile-code sandbox. A structured pytest report written
by the same process as candidate code is not cryptographic attestation. Licensing
for local execution, instruction export and redistribution are distinct questions.
No control or protocol is operational until independently observed real tests pass.
