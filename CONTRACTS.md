# M0 shared contracts

## Comparative research additions

The compositional pilot in `programs/comparative.rb` adds deterministic inventory
and manifest-validation stages to three inference stages. These validate artifact
integrity, not benchmark correctness; hidden procedures remain evaluator-only.
`Benchmarks::Reports` groups planned arms by solver/model, retaining missing or
failed task repetitions in exclusion denominators and refusing to combine mixed
quality provenance into a macro score.

`Execution::SimulatedProvider#start(attempt_id:, cell_id:, model_profile:)` is an
explicit offline-only HTTPS simulator. It uses the real trusted provider relay,
ephemeral credentials and a private Unix volume, but its answers and usage are
synthetic. It is not evidence of provider reachability or model quality. Callers
must close it in an ensure block. Its frozen chat-completions inference contract
is specified in `docs/provider-relay-inference-contract.md`.

`Benchmarks::ReleaseIdentity.capture(root:)` binds actual implementation bytes,
including uncommitted files, in addition to the Git revision. Verification rejects
changed, missing or added files in its bounded implementation inventory; it is a
content-integrity check, not a signature or an authenticity guarantee.

## Optional model catalog evidence

Benchmark CLI manifest loading may explicitly accept `--model-catalog PATH` and
pass `catalog:` to `ExperimentManifest.new`. Requested resolution is persisted
in the manifest digest and surfaced on report arms, not served-model proof or
generic inference-parameter transport. All offline strategies share that
snapshot; live pilot restrictions remain unchanged. Store/report reconstruction
uses persisted evidence without current-catalog lookup, historical backfill,
or automatic root-step repricing. Missing pricing remains unknown. See
`docs/model-catalog.md` for declarations and dispatch limitations.

Ruby 4.0, stdlib plus sqlite3, fiddle (descriptor-relative sandbox copying),
and standard. Namespace `AgentRuntime`.

## Execution boundary

`Request = Struct.new(:run_id, :step_id, :attempt, :inputs, :config, :workspace, :timeout, :cancellation, keyword_init: true)`.
Inputs map names to decoded values (paths for repository/file artifacts).
`Result = Struct.new(:status, :outputs, :error, :duration, :usage, :cost, :logs, :session_id, :model, :retry_safe, keyword_init: true)`.
M0.1 appended optional `:retry_safe` after `:model`. Transport retries require explicit
`retry_safe: true`; existing custom executors must opt in only when replay is safe.
Transport classification alone no longer authorizes another invocation.
Statuses strings: success, failure, cancelled, timeout, unknown, blocked. Outputs map declared output names to raw values. Executors implement `execute(request)`.
Cancellation exposes `cancelled?` and `cancel!`. Config JSON string keys. No live calls unless explicit live option. Adapter classes `AgentRuntime::Adapters::OpenCodeCLI`, `Shell`, `Fake`. Files under lib/agent_runtime/adapters. Shared subprocess utility owned by integrations: `Adapters::ProcessRunner#call(argv:, cwd:, timeout:, cancellation: nil, env: {})` returns hash string keys status/stdout/stderr/exit_code/duration.
M0.1 process results additionally expose Boolean `stdout_truncated` and
`stderr_truncated`; truncated protocol output cannot establish adapter/evaluator
success. Timeout and cancellation take precedence over protocol events.

### M1.2a additive execution evidence

`Result` and the DSL are unchanged. OpenCode launches now require an explicitly
registered absolute local fixture executable and matching constructor
`fixture_sha256`; `live` alone is insufficient. Real-provider profiles are denied
in this milestone, even when credentials exist. This is a trusted local fixture
guard, not a network sandbox or protection against hostile filesystem races.

Explicit `config['model_profile']` selects the audited protocol path and requires
`budget_policy` (positive wall_seconds, max_attempts, max_concurrent_sessions).
Host-injected `budget`, `scopes` and `authorization` coordinate process-local
admission; required unsupported hard token/request/tool/cost limits reject before
launch. A runtime evidence block persists admission before spawning. Normal
`execute(request)` callers remain supported. `timeout_cleanup_grace` optionally
extends the emergency outer watchdog; primary ProcessRunner deadlines remain
unchanged and cleanup/scheduling can overshoot them.

`logs['execution']` schema `m12a-execution-v1` is saved in an immutable artifact;
attempt `execution` is a compact index with its evidence reference. Raw evidence
is explicitly redacted at persistence boundaries; native numeric token buckets
remain reconstructable. Unknown native events are retained. Root-step identity
is attempt-scoped observation identity, not a proven provider request ID. Native
step_finish is not a session-terminal event; session_reported_complete remains
unknown and invocation accounting completeness remains false. Opaque CLI costs
are not provider charges. Reproducible estimates require pinned verified pricing.

ProcessRunner results add `cleanup` metadata with reaping and observed errors.
Immutable artifact reconstruction, not copied attempt usage, is the accounting
authority. Independent benchmark grading remains separate from solver telemetry.

## Language/runtime

`AgentRuntime.compile(path)` => IR Hash; `Compiler.validate!(ir)` => ir. `IR.dump(ir)` canonical JSON; `IR.digest(ir)` SHA256.
DSL: `program :name do; input :repository, type: :repository; executor :developer, via: :fake, config: {...}; step :implement, with: :developer, inputs: {repository: :repository}, outputs: {repository: :repository}, config: {...}, needs: [], timeout: 10, retries: 0; emit :repository, from: 'implement.repository'; end`. Input refs `input_name` or `step.output`. Step output hash is types. Dependencies inferred from refs plus needs. No implicit global artifacts.
`Runtime.new(store:, executors: {})`; default registry fake/shell/opencode. `run(ir, inputs: {}, workspace: nil, concurrency: 2, cancellation: nil)` => report Hash with run_id,status,outputs (name=>artifact metadata), steps,ir_digest; persists report. executor config merged with step config.
`Store.new(root)` creates SQLite metadata + content store. `put(type:, value:, run_id:, step_id:, attempt:, inputs: [], metadata: {})` => artifact Hash with id,digest,type,path,etc. `value(artifact)` decoded value; repository => immutable snapshot directory path. `report(run_id)`; `save_report(report)`.
Fake config operations: `value` (config['values']=>outputs), `patch` (copy input repository to request.workspace/output and write config['files'] mapping relative paths=>contents, nil deletes; outputs repository and patch if declared), `fail`, `sleep`. Fake returns full outputs; runtime selects declared outputs. workspace is isolated per step. Original input never mutated.

## Benchmark/evaluation (owned by benchmarks stream)

Independent solver contract `solve(task:, model:, budget:, workspace:)` returns Hash status, repository path, patch, usage/cost/model/error as available. Runner isolates solver workspace; external tests remain outside. Evaluator returns execution status separate from verdict and stores exact repository/spec/procedure/environment digests via Store. Benchmark can call Runtime and compile via public API, not language internals. CLI require main library plus benchmarks/cli. Entrypoint owned by benchmarks stream.

### M0.1 evidence verification (additive)

`Store#artifact(id)` returns canonical metadata or raises `AgentRuntime::Error`.
`value(artifact)` rejects inconsistent metadata, missing/corrupt bytes or trees,
and invalid provenance. This is consistency checking, not hostile-user authentication.
Writing identical content does not silently repair missing/corrupt historical
objects or trees: existing referenced content must validate before reuse.

`Evaluator#evaluate(task:, repository:, run_id:, timeout: 30, generation: nil)`
records a unique `evaluation_id`, explicit `identity_mode` and `generation`.
Submitted mode uses the supplied canonical repository artifact as producer;
omission creates a standalone snapshot without claiming solver provenance.
`Evaluator#verify!(report:, task:, repository:, run_id:, timeout: 30,
generation: nil)` returns the report or raises `AgentRuntime::Error`. Submitted
mode requires expected generation identity; equal bytes from another generation
do not authorize reuse. Standalone verification checks its original snapshot and
current content, not the identity of an arbitrary byte-identical source path.
`Evaluator.new(store:, process_runner: nil, evaluator_version: AgentRuntime::VERSION)`
supports explicit evaluator version binding. Full binding, schema and compatibility
decisions: [M0.1 contracts](docs/m0.1-contract-decisions.md). Historical reports
remain readable, but current validity requires verification; there is no cache,
automatic reuse, crash recovery or TOCTOU prevention.

## Ownership

Main: lib/agent_runtime.rb, language/compiler/IR/runtime/store/contracts and fake, core tests, Gemfile/lock. Integrations stream: adapters except fake, integrations/, openspec/, docs/integrations.md, integration tests. Benchmarks stream: benchmarks, evaluation, CLI/bin, programs, mise.toml, README, docs except integrations, AGENTS.md, benchmark tests. Avoid editing other owned files. Use shared working directory with disjoint paths; no commits by children.
# Scoped audited NL2Repo scoring (M1.1c)

`nl2repo-audited-v2` may produce quality-bearing results with `trust: audited`
and `trust_scope: benign_ordinary_submissions` after exact authoritative canonical
collection/result validation and a fresh matching reference preflight. This is
reproducible scientific evidence for controlled ordinary coding submissions, not
authentication against arbitrary hostile Python imported into pytest. Historical
legacy/audited-v1 evidence and their stronger unresolved authentication gates are
unchanged. Invalid, incomplete, ambiguous or infrastructure-failed evidence stays
unscored; an explicit proven missing-candidate collection policy may assign zero
without claiming that expected cases executed. See `docs/m1.1c-scoring-contract.md`.

## Controlled provider execution (M1.2b)

Real-provider profiles additionally require a concrete scoped `LiveAuthorization`
and an isolated, digest-bound `OpenCodeLaunch`; fixture callbacks and credentials
alone cannot enable them. Authorization binds the frozen experiment, task, solver,
provider, endpoint, route and upstream model, and has a finite epoch expiry. It is
trusted local operator consent, not cryptographic authentication. Numeric token,
request, run and monetary quotas are not invented when the operator explicitly
accepts uncapped financial exposure. `AdmissionConfig#max_attempts` may be nil;
wall-time and concurrency limits remain finite. A duplicate attempt identity is
still rejected after release. Local admission is not a durable account-wide quota.

`ExperimentRunner#run(manifest:, cancellation: nil, live_authorization: nil)` accepts
the narrowly defined live retrying/single-agent manifest only through audited-v2.
`regrade` does not require another live authorization or invoke a solver. Native
CLI root-step usage is partial observation, not every provider request or charge.
Requested identities never fill missing observed identity; raw immutable execution
artifacts remain authoritative for report reconstruction.

The additive trusted step configuration `preserve_partial_outputs: true` captures
failed adapter repository outputs into attempt `partial_outputs` artifacts. These
are not successful step outputs, are never bound downstream, and do not change
execution status. Direct strict OpenCode uses this option to return an immutable
failed repository to the benchmark runner, which records `partial_submission`
without automatic grading. Collection failure remains separate evidence.

## Provisional mock-only whole-agent sandbox (M1.2c-S1)

This additive interface records coordinated implementation intent, not completed
acceptance or a frozen production contract. Race/export and quota/resource
blockers remain under review; parent integration must reconcile final signatures,
effective policy and acceptance evidence before declaring readiness. Existing
`Request` and `Result` layouts and execution-status/evaluation-verdict separation
are unchanged. No historical live path is migrated or silently substituted.

Latest integration status: quota/race/concurrent-cwd controls are reported
implemented, but snapshot consistency remains unsupported. The current runner
does not accept an export: an otherwise successful execution is converted to
`blocked` with `writer_quiescence_unsupported: tmpfs archive collected before container pause`.
Diagnostic archives are discarded, not returned as usable repository exports.
Private temporary staging modes were broadened; that change is not proof that
the temporary permission gap or writer-quiescence requirement is resolved.
The successful-export descriptions below specify intended future behavior,
not a currently available successful submission path.

Current intended interfaces (implementation may evolve during that review):

- `Execution::SandboxRunner.new(image:, limits:, process_runner: Adapters::ProcessRunner.new, network_policy: nil)`
- `Execution::SandboxRunner#call(argv:, workspace:, timeout:, cancellation: nil, env: {})`
- `Execution::SandboxRunner::MockRelayPolicy.new(volume:, helper:, helper_sha256:)`
- `Execution::SandboxOpenCodeLaunch.new(executable:, executable_sha256:, endpoint:, model:, mock_only:, provider:, wire_model:)`
- `Execution::SandboxOpenCodeLaunch#argv(prompt)`, `#environment`, `#to_h`,
  and `#with_extensions(**)` (extensions currently rejected).
- `Adapters::SandboxOpenCodeCLI.new(runner:, launch:)` and `#execute(request)`.

`SandboxRunner` owns the intended Docker execution boundary and returns a
string-keyed execution/evidence hash, not a new `Result` variant. Evidence includes
status/stdout/stderr, image/resource policy, effective container inspection,
cleanup observations and, when valid, export `path`, `manifest` and `digest`.
Invalid startup/policy, missing evidence or unconfirmed cleanup must not become
successful adapter output. Staging/export copying is a consistency mechanism,
not an independent security sandbox. Host workspaces are not execution fallback.

`SandboxOpenCodeLaunch` is a **mock-only** plan, not `OpenCodeLaunch` or
`LiveAuthorization`. It currently pins `/usr/local/bin/opencode`, verifies its
declared executable SHA-256 at startup and targets local mock HTTP
`http://127.0.0.1:18080/v1`. The intended transport keeps the agent container at
`network=none`, bridging local HTTP through a narrowly mounted UNIX relay volume.
Only the reviewed mock relay policy is admitted; this does not authorize general
networking, a real upstream, provider credentials in solver space or paid calls.
Application tool/provider policy is defense in depth, not the confinement boundary.

The adapter consumes repository input (or request workspace), prompt, timeout
and cancellation; it intends to return successful `outputs["repository"]` only
for a verified export with container and cleanup evidence. Sandbox/launch/event
observations belong in logs. It must not delegate to historical host OpenCode on
failure, retry through a live route or infer live consent from `mock_only`.
Transport replay remains disabled (`retry_safe: false`). An execution success is
not an evaluation pass or acceptance verdict.

Export paths are caller-owned temporary snapshots, not durable Store artifacts.
The caller must capture the actual export into immutable repository evidence,
bind its digest to submission/evaluation, and clean up the returned temporary
export tree after capture or on failure. A read-only filesystem mode alone does
not make caller-owned files immutable against their owner. Never grade a stale
input workspace in place of the returned export or leave cleanup implicit.

Resource policy is separate from provider quotas: CPU, memory/swap, process,
tmpfs, workspace byte/entry/depth, deadline, cancellation and descendant cleanup
must be recorded and tested according to actual enforcement. Neither token/request
quota nor wall timeout implies disk/memory/process containment or a spending cap.
Do not claim hard end-to-end bounds while race/quota blockers remain unresolved.
Current review additionally finds full timeout budgets applied per stage rather
than a shared whole-call deadline. Finite stage operations do not establish total
call or architecture deadline enforcement; bounded cleanup also needs explicit
accounting and acceptance. These end-to-end limits remain unproven.

Unknown duration, session/model identity, usage and cost remain unknown unless
observed; raw event observations do not imply complete accounting. Existing
generic model-catalog semantics remain unchanged: requested resolution is not
served-model proof or generic inference-parameter transport, and cannot fill
missing observed identity or pricing. Mock acceptance cannot authorize or backfill
historical live evidence. See `docs/m1.2c-s1-scientific-protocol.md` for the
unfrozen identity and separate offline acceptance gates.
# Opt-in exact submission modes

`Benchmarks::Submission#capture(..., preserve_modes: true)` additionally binds
ordinary file and directory permissions (including the repository root) in a
`submission-modes-v1` JSON Store artifact. Canonical repository metadata references
that sidecar by ID and digest; its payload binds the legacy repository content
digest. Verification reloads canonical metadata, never trusts caller-supplied
sidecar references, and rejects special permission bits. Existing Store content
digests and legacy submissions are unchanged; shared Store trees are not chmodded.
Materialization applies modes only to a fresh snapshot and verifies both content
and exact modes. The audited grader subsequently creates a working copy and
deliberately normalizes its root permissions; that working root is not the
immutable submission root. File/nested-directory copy preservation is separately
tested. This API does not make trusted Ruby code or directory separation a sandbox.
# Sandbox provisioning resource bounds

Before Docker creation, sandbox input provisioning accepts at most 1,024 regular
files and 1,024 directories (including the workspace root). These bounds apply to
input provisioning, independently of the existing 10,000-entry output export cap.
# Captured process text encoding

Process and sandbox stdout/stderr are decoded as UTF-8 only after capture, so
multibyte characters split across reads remain intact. Valid UTF-8 bytes are
preserved without normalization. Invalid UTF-8 is an execution failure classified
as `invalid_utf8_output`, not successful replacement-character text. The affected
text field is empty and its exact bytes are retained in `binary_output_base64`
under the stream name. Evidence consumers must not interpret empty text in that
case as absence of output. Capture truncation remains separately recorded.

## Research tracing (M2)

Tracing is opt-in and host-owned. `AgentRuntime::Store#tracing` may hold a
`Tracing::Session`; `Request` and `Result` contracts are unchanged. Runtime,
fixed-workflow and experiment instrumentation preserve the existing execution
status versus grading-verdict distinction. A regrade is a new grading observation
linked to the original cell, not a child execution that retroactively extends it.

`Tracing::Store` uses an independently versioned SQLite WAL database and compressed,
SHA-256-addressed JSON blobs. Schema migrations are transactional. Trace IDs identify
observations, not model identity attestations. Native OpenCode message IDs are not
provider request IDs; unproven tool/request associations remain explicitly unknown.
Verification separates structural integrity (`valid`) from observation completeness
(`complete`). A valid historical or sanitized archive can remain incomplete.
Export/import transport valid incomplete evidence; only verify/analyze gate
completeness. Final verification must run after writers have quiesced.

Raw capture requires explicit host configuration/CLI authorization. The default
records metadata only. Raw bodies, native tool content and repository snapshots
remain sensitive even after recursive credential-key redaction: free-text secrets
cannot be reliably removed. Provider headers are never captured. Raw export is
separately opt-in; default export omits raw blobs and marks unavailable references.
Local filesystem permission separation is not a sandbox, and evidence digests
prove byte identity rather than authenticity against a malicious host.
