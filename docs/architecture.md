# M0 architecture and execution semantics

Agru is a single-process Ruby runtime. Trusted Ruby authoring builds declarations;
it does not execute steps. `Language` compiles those declarations through
`Compiler.validate!` into schema-version **1** JSON IR. The runtime accepts this IR,
not the DSL evaluator. `IR.dump` recursively sorts object keys; array order remains
significant. `IR.digest` is SHA-256 over that canonical serialization.

## Language and static guarantees

See `programs/demo.rb` for a real patch-producing program followed by a public
check. Inputs and named step outputs have types; bindings reference either an
input name or `step.output`. Output references infer dependencies, with `needs:`
adding explicit ordering. `input_types:` optionally constrains a binding's type.
Final `emit` declarations reference existing artifacts. The compiler checks
duplicate identifiers, unknown executors/references/types, missing outputs,
incompatible declared binding types, dependency cycles, and positive step
timeouts/retry bounds. It does not verify prompt meaning, generated code, or
whether an executor implements its declared outputs. Runtime checks cover those
output names and concrete artifact value types. `json` accepts JSON-compatible
data, not an application-specific structural schema.

DSL source is **trusted Ruby**, evaluated with `instance_eval`. It is not a
sandbox for untrusted source. Shell configuration and external agents can execute
code with the host user's permissions. Compiler validation is not a security
boundary.

## Scheduling and attempts

The engine schedules ready DAG nodes into at most `concurrency` local threads
(default 2, maximum 32). Every dependency must finish successfully before its
dependent can start. Failed prerequisites cancel downstream steps; unrelated
branches may finish. Cancellation prevents new work and is passed to active
executors. Each attempt receives its own directory and writable copies of
filesystem input artifacts; no shared writable repository is scheduled.

Only a failure explicitly classified `transport` is retried, up to `retries`
additional attempts (0–10). This is not semantic repair. Each attempt is persisted
before invocation and after termination. A process crash can leave a running
record: restart/resume and crash reconciliation are deferred. Subprocess adapters
enforce their own deadline and process-group cleanup; custom in-process executors
also receive a Ruby Timeout guard, which is not a safe sandbox for hostile code.

Execution success/failure/cancelled/timeout/unknown/blocked is independent from
evaluation pass/fail/not_evaluated. An infrastructure failure is not a negative
correctness verdict. A passing check covers only its recorded procedure.

## Persistence and evaluation

`Store` maintains SQLite run/attempt/artifact records and SHA-256-addressed object
files. Each artifact generation has a UUID plus run/step/attempt/input provenance;
identical content can have multiple generation records. Repository artifacts are
sorted file manifests preserving executable flags, excluding `.git`, rejecting
symlinks. Empty directories and Git metadata are not snapshot content. File
objects are read-only and reads check their digest; this is API immutability,
not protection against a privileged local writer. Workspaces are materialized
copies, never mutable references to the stored snapshot.

The independent evaluator snapshots the submission, then executes a disposable
copy. Its report binds exact SHA-256 versions of repository, specification,
procedure, and environment/configuration. Reuse checks require all four to match;
verification never transfers automatically to edited content. Hidden procedure
paths are withheld from the public solver task; host filesystem access is not
sandboxed. Benchmark solvers implement `solve(task:, model:, budget:, workspace:)`
without depending on the DSL. Only the DSL solver imports the compiler/runtime.

## Deliberate M0 boundaries

No distributed queue, server, autonomous repair, general memory, or universal
verification. SQLite is local; execution is not resumable. Resource controls are
wall-clock time, parallelism, retries and bounded process capture, not OS CPU,
RAM, network or filesystem containment. Model token/cost limits cannot be
guaranteed by the CLI transport; missing usage remains null. Live benchmark
claims require a proper sandbox and verified official graders first.
