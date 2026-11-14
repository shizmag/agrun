# M0 shared contracts

Ruby 4.0, stdlib plus sqlite3 and standard. Namespace `AgentRuntime`.

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
