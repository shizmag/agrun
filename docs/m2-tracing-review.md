# M2 tracing implementation review

Review date: 2026-11-17. Scope: the in-progress local working tree, not a
committed release or a claim of live-provider readiness. This was a bounded,
independent read-only review of tracing storage, CLI/diagnostics, host runtime and
benchmark instrumentation, and provider capture wiring. Only this review document
was written during the final review pass. No paid APIs were called.

## Evidence and method

- Read `CONTRACTS.md`, current source and public-boundary diffs; use the
  codebase-memory graph to locate and trace material symbols, then confirm with
  current source. Tier 2 best-effort coverage reported no recorded issues for the
  22 tracing, runtime, benchmark, relay/launcher and focused-test paths checked.
  This is not proof of exhaustive graph or behavioral coverage.
- Final combined focused command:
  `mise exec -- bundle exec ruby -Itest -e 'ARGV.each { |file| require_relative file }' test/tracing_store_test.rb test/tracing_session_test.rb test/tracing_cli_test.rb test/tracing_historical_test.rb test/provider_trace_capture_test.rb`.
  Result: **35 tests, 187 assertions, 0 failures, 0 errors, 2 skips**.
- Both skipped provider tests explicitly require offline Docker opt-in. The
  separate Node/provider boundary fixture passed without provider credentials.
  A skipped Docker mount test is not evidence that container integration passed.
- Core owner corroborated its final checks: Store 19 tests/112 assertions,
  Session 3 tests/11 assertions, scoped Standard clean. Counts from different
  runs are not additive to the combined result above.

## Concrete findings and dispositions

| Finding discovered during review | Final disposition/evidence |
| --- | --- |
| Host architecture traces used `planned_steps`, including contract hashes, while verification only recognized `planned_stages`. | Core now recognizes both and matches hash `id` values. Store regression tests cover aliases and retained contract hashes. |
| Runtime worker threads did not inherit thread-local experiment/cell context. | Store inherits indexed context from the actual parent. Session runtime test verifies cell-linked checkpoints across the runtime worker boundary. |
| Sanitized checkpoint metadata could appear complete despite absent portable file bytes. | Session explicitly records snapshot availability; verifier reports unavailable snapshots as incomplete. A default-capture Session regression verifies this. |
| Regrading could attach new grading evidence under a finished cell, producing parent-order incidents. | Parent changed regrade to a fresh root with inherited identifying attributes and `linked_cell_trace`; current source no longer makes it a late child. |
| Native provider request identity was stored as `request_id`, but CLI request filtering uses `request`. | Session now preserves a `request` alias. Session regression looks up captured usage through that identity. |
| Relay completion was not mapped to `response_complete`, falsely making successful captures incomplete. | Session derives `response_complete` from relay `complete`, binds usage to the same local request identity, and the complete-capture Session regression passes. |
| Nonterminal native tools could be labeled successful or escape incomplete detection. | Session maps completed/error/other to success/failure/incomplete; Store recognizes incomplete, interrupted and unknown terminal evidence. |
| Default tracing originally enabled provider capture only with raw authorization, losing request/usage metadata. | AttemptAdapter now configures capture whenever tracing is enabled, passes the explicit raw Boolean, and records a capture gap if no records are available. Relay metadata mode excludes body/chunks/events/reconstruction. |
| Portable import could traverse a symlinked `blobs` directory. | Core now rejects that directory and symlink leaves, allowlists archive paths, checks declared digests and verifies the copied database. This is not hostile-race resistance. |
| Historical accounting and unresolved evidence could pass completeness despite explicit limitation markers. | Core now treats `accounting_complete:false` and `evidence_resolution:not_resolved` as completeness blockers, not integrity errors. Owner verified a temporary copy of preserved history: valid=true, complete=false, 64 entities, one accounting marker and 21 unresolved evidence markers. New core regressions cover archive round trips and resolved evidence. |
| Session payload shape differed from diagnostic assumptions. | CLI/diagnostics recognize `llm_request`, nested token buckets, `duration_ms`, native tool terminal status, numeric attempt filters and request aliases. Focused CLI tests pass. |

These dispositions combine source confirmation, focused regressions and explicitly
identified owner corroboration; they do not imply every integration path was
executed in the final pass.

## Public API and execution semantics

- `Request` and `Result` fields, normal executor `execute(request)` dispatch,
  DSL semantics, execution status versus evaluation verdict, and the explicit
  transport retry-safety requirement are not changed by the reviewed tracing
  instrumentation.
- Tracing is additive and opt-in through the artifact Store's tracing session and
  trace-root entry points. Provider constructors accept an optional capture
  argument; existing callers need not supply it. Trace attempt identity is added
  to executor config only when tracing is enabled, not a serialized Session.
- Enabled tracing adds host-side checkpoint work and persistent writes. Storage,
  capture-integrity or checkpoint failures can affect that enabled execution;
  tracing is not a zero-overhead, failure-isolated observer. Do not advertise
  stronger semantic transparency than this implementation provides.
- CLI `verify` and `analyze` are explicit completeness gates. **Import/export are
  transport operations:** structurally valid but incomplete historical or
  sanitized traces are intentionally transferable with success status. An
  isolated reproduction with a running trace returned verify=1, export=0 and
  import=0. This is the agreed command contract, not an integrity bypass.
- Default sanitized checkpoints and sanitized exports with omitted raw snapshots
  can be valid but incomplete. Missing usage, unexecuted planned stages after
  cancellation/failure, capture gaps and unknown outcomes likewise remain
  explicit evidence limitations, not invented success or evaluation failure.

## Portable security and residual limitations

- SHA-256 checks and manifest/database validation establish content consistency,
  **not authenticity**, provenance trust or signature verification. A party able
  to rewrite an archive and all its checksums can construct different consistent
  evidence. Directory separation is not a security sandbox.
- Raw capture and raw CLI access require explicit authorization in the supported
  entry points. Headers are never captured. Credential-key redaction is recursive
  but **not a generic free-text or base64 secret detector**. Raw prompts, outputs,
  tool bodies and repository snapshots remain sensitive; even sanitized metadata
  may contain paths, identifiers and filenames. Do not describe either mode as a
  universal privacy scrubber.
- Import rejects obvious traversal and symlink archive members but is not a
  descriptor-relative hostile concurrent-filesystem sandbox. JSON/zlib/SQLite
  handling also has no reviewed adversarial resource-exhaustion guarantee.
- Final verification must run against a quiescent store: verification performs
  multiple reads rather than one concurrent point-in-time transaction. Final
  checks in this review were quiescent. Do not infer missing evidence from a
  partial snapshot while writers are active.
- Native tool association is explicitly native-message evidence, not fabricated
  provider-request correlation. Captured native tool events do not prove all
  shell side effects were observed. Historical imports preserve observations
  and unresolved evidence references; they do not rerun or authenticate them.

## Acceptance status — r4 independently checked

The previously pending acceptance run now has local evidence:
`.agru/m2-tracing-acceptance-20261117-r4/trace-verification.json` and
`/tmp/agru-m2-acceptance-r4.log`. Both report successful original/restored
verification and `portable_regrade_verified: true`.

The reviewer independently queried both original and restored databases using
read-only SQLite connections and reran current Store verification on temporary
copies, leaving the original evidence untouched. Both matched the saved JSON:
**valid=true, complete=true, errors=[], incomplete=[], entity_count=280**.
The kind counts matched independently in both databases:

| Kind | Count |
| --- | ---: |
| experiment | 1 |
| cell | 9 |
| architecture | 9 |
| stage | 27 |
| attempt | 27 |
| handoff | 48 |
| checkpoint | 51 |
| execution_evidence | 27 |
| llm_request | 42 |
| tool | 21 |
| grading | 18 |

The saved freeze record reports `verified: true` and SHA-256
`74615816ac2abe7a0fb100df8fb062df30d949b3a7c38572b15d896417f94a1a`.
Portable regrade success was corroborated between the saved JSON and acceptance
log; the reviewer did not independently rerun grading or provider execution.
The parent additionally reports the local live-integration offline stub test
passed (6 tests/36 assertions); that result is owner-reported, not a separate
reviewer execution.

**Conclusion:** r4 acceptance evidence passes the independent trace-content and
completeness checks above. No concrete tracing blocker was found. This supersedes
the earlier pending-acceptance status, but is not paid-provider validation or a
claim that the still-running final full suite passed. The security and scope
limitations above remain applicable. No paid calls were made by this reviewer.

## Final regression corroboration

The integrating parent subsequently completed `mise run test`: 1,016 tests,
6,046 assertions, zero failures/errors, 78 environment/live opt-in skips.
`mise run lint`, `mise run smoke`, and `mise run benchmark-demo` passed. The
explicitly opted-in offline Docker capture fixture passed 3 tests/28 assertions
without skips; no paid-provider execution was performed. These results are
parent-reported, distinct from the read-only acceptance checks above.
