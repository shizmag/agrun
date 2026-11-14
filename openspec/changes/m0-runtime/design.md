## Context
M0 uses Ruby 4, stdlib, sqlite3 and standard. Shared contracts are recorded in CONTRACTS.md. The machine has OpenCode V2 rather than the historical V1 SDK.

## Goals / Non-Goals
Goals: explicit artifacts, observable execution, bounded subprocess resources, offline tests, useful optional integrations.
Non-goals: sandboxing hostile programs, remote execution, automatic provider credentials, comprehensive OpenCode protocol compatibility, live baseline benchmarks.

## Decisions
- Execute argv directly via Process.spawn with a dedicated POSIX process group. Close stdin; drain both output streams concurrently and retain at most 1 MiB per stream. TERM then KILL provides bounded cancellation even for resistant descendants.
- Require explicit live opt-in for OpenCode. Use `run --format json --standalone` and parse newline-delimited events. Preserve logs and unknown outcome when protocol evidence is incomplete. Missing usage remains unknown, not fabricated zero.
- Keep OpenSpec local and optional; initialize with tools none to avoid injecting agent-specific instructions. Import does not overwrite existing specs.
- Serena runs only when a user explicitly configures it. The installed tool has agent/ide contexts but no built-in opencode context. Baseline benchmarks do not enable it.
- Defer HTTP: current V2 API is experimental, and server lifecycle/authentication/cancellation require a separate contract and tests.

## Risks / Trade-offs
Process-group termination is POSIX-specific and cannot contain a malicious descendant that deliberately starts a new session. Output truncation can make JSON incomplete and is reported unknown. No OS sandbox or environment-secret isolation is implied. CLI event fixtures are offline compatibility assumptions, not a live provider acceptance test.

## Validation
Minitest executable fixtures cover argv literal handling, exit failures, bounded dual-stream output, timeout process-group cleanup, cancellation, OpenCode opt-in/events/incomplete output, and OpenSpec JSON/import safety. Strict OpenSpec validation runs without a model.
