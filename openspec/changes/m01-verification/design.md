## Context

M0 has a trusted Ruby DSL, schema-v1 IR, a bounded local scheduler, SQLite metadata
and content-addressed artifacts. Independent grading is a separate subprocess.
This milestone challenges measurement integrity rather than adding transports.

## Decisions and oracle boundaries

- Freeze observed-contract expectations before corrections. An initially green
  regression is useful if a negative control or isolated mutation detects the
  corresponding failure mode.
- Use real local grader subprocesses for substantive pass/fail controls, with
  injected process fixtures only for protocol and infrastructure variants.
- Separate solver execution status, evaluator execution status and verdict.
- Evidence content matching is not execution identity: identical content may
  share hashes but independently produced generations retain distinct IDs.
- Timeouts and cancellation are enforceable for process adapters. Arbitrary
  trusted Ruby executors are cooperative; M0 does not promise safe thread
  preemption or an OS sandbox.
- Persisted incomplete state is inspectable but not restart/resume support.
- Offline fixtures select their executable explicitly; no network-enforced
  offline boundary is claimed.

## Risks

Process groups are POSIX lifecycle cleanup, not hostile-process containment.
Filesystem permissions and separate directories are not security isolation.
Provider-side usage enforcement, live protocol compatibility, inherited-secret
isolation, official grading protocols and cross-task memory remain out of scope.
