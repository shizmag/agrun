# M2 local research tracing

Tracing is local and opt-in. No telemetry service, paid request, or model call is
required to inspect, verify, export, import, or analyze traces. Historical findings
are in [m2-historical-forensics.md](m2-historical-forensics.md); they are not causal
claims about orchestration quality.

## Capture

```sh
mise exec -- bundle exec ruby bin/agru run --offline --root .agru/demo \
  --trace-root .agru/demo-traces
# Explicitly sensitive checkpoint/tool capture:
mise exec -- bundle exec ruby bin/agru run --offline --root .agru/demo-raw \
  --trace-root .agru/demo-raw-traces --trace-raw --authorize-raw
```

Programmatic integration:

```ruby
trace = AgentRuntime::Tracing::Store.new(trace_root, raw_content: false)
artifacts.tracing = AgentRuntime::Tracing::Session.new(
  trace: trace, artifacts: artifacts, raw_content: false
)
# Run Runtime/ExperimentRunner with artifacts as the shared Store.
# Close trace when writers have stopped.
```

Provider capture requires a private existing directory and explicit configuration:
`trace_capture: {directory: path, raw_authorized: false, trace_id: attempt_id}`.
The three local relay providers expose `trace_capture_records` for host ingestion.
`Session#provider_records(parent:, records:)` verifies exact `payload_json` bytes
against the envelope SHA-256 before recording the request. Metadata-only capture
retains usage/model/timing; `raw_authorized: true` adds effective wire bodies,
ordered response chunks, events and reconstruction. Request IDs are relay IDs;
served model strings are observations, not attestations.

## Query and transport

Every command below accepts `--root TRACE_ROOT`. Root defaults to `.agru` and
points directly to the directory containing `trace.sqlite3`, not the artifact Store.

```sh
bin/agru trace list --root .agru/demo-traces
bin/agru trace timeline --root .agru/demo-traces --cell CELL_ID
bin/agru trace requests --root .agru/demo-traces --architecture dsl
bin/agru trace tools --root .agru/demo-traces --stage coder
bin/agru trace handoffs --root .agru/demo-traces
bin/agru trace inspect ENTITY_ID --root .agru/demo-traces
bin/agru trace diff BEFORE_ID AFTER_ID --root .agru/demo-traces
bin/agru trace search needle --root .agru/demo-traces
bin/agru trace verify --root .agru/demo-traces
bin/agru trace analyze --root .agru/demo-traces
bin/agru trace export .agru/trace-export --root .agru/demo-traces
bin/agru trace import .agru/trace-export --root .agru/trace-restored
# Raw search/read/export additionally requires BOTH flags:
bin/agru trace export .agru/private-export --root .agru/demo-raw-traces \
  --include-raw --authorize-raw
```

Available filters: experiment, cell, architecture, run, stage, attempt, request,
tool, kind, status and parent. Request usage is exact per captured request when
available; missing values remain unknown. Native cached/reasoning usage buckets
are separate and not added again to total tokens. Timing includes relay duration
and TTFT where observed. Checkpoint diffs include bytes and modes; comparisons
are grouped by experiment/cell/run so unrelated cells do not become overwrites.
Observations and hypotheses are separate. No observed differences establish
architectural causality by themselves.

## Completeness and failure evidence

`verify` and `analyze` exit nonzero for incomplete evidence. Capture gaps,
interrupted/running observations, duplicate/out-of-order incidents, missing
planned stages, unknown LLM usage, incomplete responses and unavailable snapshots
are explicit. Metadata-only repository checkpoints cannot reconstruct source, so
sanitized traces can be valid but incomplete. Import/export may succeed for such
valid incomplete evidence; run `verify` separately. `Store#recover` marks stranded
running observations unknown instead of fabricating success. Cross-process
monotonic duration is unknown, never synthesized from wall-clock subtraction.

SQLite WAL, a busy timeout, transactional writes and in-process synchronization
support concurrent writers. Verify a quiescent store, not a live moving target.
Blob hashes are integrity checks, not signatures. Directories are mode 0700,
files mode 0600. Raw authorization does not make content safe to publish; prompts,
repository files and tool strings can contain arbitrary secrets that key-based
redaction cannot identify. Do not commit `.agru` or raw exports.

## Installed offline acceptance

```sh
mise exec -- bundle exec ruby script/m2_tracing_acceptance.rb \
  .agru/m2-acceptance-new .agru/nl2repo
```

This intentionally executes installed OpenCode inside the digest-pinned sandbox,
using a controlled HTTPS simulator and network-none containers, never a paid
upstream. It runs all nine cells, the real audited grader, repeated grading,
portable evaluator reproduction, trace export/import and completeness checks.
The simulated result is infrastructure evidence, **not model-quality evidence**.
The script refuses an existing destination. Source `.agru/nl2repo` assets must
already exist; it does not fetch dependencies or credentials.

### Acceptance recorded on 2026-11-17

The local installed run `m2-tracing-acceptance-20261117-r4` passed with **nine
cells, 27 stages/attempts, 42 provider requests, 21 observed shell tools, 48
handoffs, 51 checkpoints and 18 original/repeated grading records**. Every cell
has an observed tool. The original and raw-authorized exported/imported traces
both verified `valid: true`, `complete: true`, with 280 entities and no reported
integrity/completeness defects. Portable regrading verified the frozen submission
bundle (`74615816ac2abe7a0fb100df8fb062df30d949b3a7c38572b15d896417f94a1a`).
Private local evidence is under `.agru/m2-tracing-acceptance-20261117-r4/`,
including `trace-verification.json`; it is deliberately not committed.

Earlier local acceptance attempts are retained, not repaired: the initial attempt
failed relay startup; r2/r3 did not observe native tools. The successful scenario
selects the tool actually advertised by installed OpenCode (`shell`, with only
its required `command` argument). These are capture-infrastructure experiments,
not evidence of benchmark-solving ability or architectural superiority. The
controlled probe writes `.agru-trace-probe`, emits stdout/stderr, and then ends the
assistant response. No paid upstream was called.

Historical imports intentionally remain **incomplete**: explicit incomplete
accounting and unresolved historical artifact references are verification
blockers, even when their preserved metadata is structurally valid.

Final regression gates: `mise run test` completed **1,016 tests / 6,046
assertions / 0 failures / 0 errors / 78 skips** (explicit environment/live opt-ins).
`mise run lint`, `mise run smoke`, and `mise run benchmark-demo` passed. The
explicit offline Docker provider-capture run passed 3 tests / 28 assertions with
no skips; the Node capture fixtures passed 6 tests. Independent review and its
scope/limitations are recorded in `docs/m2-tracing-review.md`.
