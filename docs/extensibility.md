# Extension points

## Executors versus benchmark solvers

Runtime executors implement `execute(request)` and return `AgentRuntime::Result`.
Requests carry decoded named inputs, merged config, a workspace, timeout, and
cancellation token. Register custom executors through
`Runtime.new(store: store, executors: {...})`. Outputs must match declared types.
No implicit global artifact channel exists. See `CONTRACTS.md` for exact structs.

Benchmark solvers instead implement:

```ruby
def solve(task:, model:, budget:, workspace:)
  # Copy task.repository; never modify the baseline.
  {"status" => "success", "repository" => submitted_directory,
   "model" => model, "usage" => {}, "cost" => nil}
end
```

The Runner supplies a public task and creates the solver directory. A solver may
also return a patch or a runtime run ID for provenance. Implementations included
are `Benchmarks::Solvers::Fake`, `OpenCode`, and `DSL`. Live adapters must require
explicit opt-in; implementing a solver must not make offline commands call APIs.
Budget keys currently used are `timeout` and `evaluation_timeout` (seconds).

## Tasks and evaluators

Create `Benchmarks::Task` with ID, instruction, repository path, actual baseline
commit, dataset revision, specification hash, and evaluator-only hidden test path.
Pass it to `Benchmarks::Runner#run`. Keep hidden procedures outside the repository.
The CLI intentionally exposes only `--suite demo`; add another suite in CLI
dispatch only after documenting its dataset licensing and acceptance procedure.

Custom evaluation runners can be injected through
`Evaluation::Evaluator.new(store:, process_runner:)`; they implement the shared
`Adapters::ProcessRunner#call` API. A future container evaluator should preserve
the same exact-input bindings and execution/verdict separation. Do not replace
an independent correctness procedure with a solver's self-reported success.

## Language, artifact types, and configurations

The M0 operation is a typed step; a new domain operation normally needs only a
new executor and a program declaration, not new Ruby syntax. If syntax is truly
needed, add a declaration method in `lib/agent_runtime/language.rb`, specify its
serialized representation in `lib/agent_runtime/ir.rb`, and add compilation and
execution tests before exposing it. Breaking IR changes require a schema bump.

For a new artifact type, extend `Compiler::TYPES` and `Store` value validation,
serialization, and materialization together. Add round-trip, invalid-value,
digest/provenance and immutability tests. Do not introduce opaque mutable values.

A new evaluator implements `evaluate(task:, repository:, run_id:, timeout:)` and
is supplied to `Runner.new(evaluator:)`. Preserve the four exact-version bindings
and return distinct execution status and verdict. Test grader infrastructure
failures separately from negative assertion outcomes.

Load normalized tasks with `Benchmarks::Manifest.load(path)`: dataset/revision,
repository/base commit, instruction, public tests, external evaluation, limits,
metadata and specification are required. A future dataset adapter converts an
official pinned dataset row to this format and supplies its official grader;
declaring a slot in documentation is not dataset support. `Runner#matrix` accepts
tasks, a named solver hash, models and repetition count, retaining every run.

Models are provider-qualified strings in executor `config: {model: ...}` or CLI
`--model`. No model is hardcoded. `--live` is always necessary for OpenCode; setup,
permissions and optional MCP tools are described in `docs/integrations.md`.
