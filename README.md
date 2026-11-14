# Agru: explicit agent programs and reproducible evaluation

A Ruby 4.0.9 prototype for compiling small agent programs into a validated JSON
graph, running typed steps, persisting artifacts and provenance in SQLite plus a
content-addressed store, and independently evaluating submitted repositories.

## Setup and offline quick start

Install [mise](https://mise.jdx.dev/), Git, and a C toolchain for sqlite3, then:

```sh
mise trust
mise install
mise exec -- bundle install
mise run test
mise run lint
mise run smoke
mise run benchmark-demo
```

`mise.toml` pins Ruby and project-local `GEM_HOME`/`GEM_PATH`/`BUNDLE_PATH` under `.bundle/gems`.
Use `mise exec -- bundle …` rather than a different system Ruby: native extensions
from another Ruby installation may be incompatible even with the same version.
There are no paid calls in these commands. Offline is the default.

```sh
mise exec -- ruby bin/agru doctor
mise exec -- ruby bin/agru validate programs/demo.rb
mise exec -- ruby bin/agru graph programs/demo.rb
mise exec -- ruby bin/agru run --offline
mise exec -- ruby bin/agru benchmark --suite demo --solver all --repetitions 2 --offline
mise exec -- ruby bin/agru benchmark --suite demo --solver bad --offline # expected exit 1
mise exec -- ruby bin/agru benchmark --suite demo --solver dsl --offline
mise exec -- ruby bin/agru report RUN_ID
```

`graph` prints the compiled JSON IR, not a visualization. `run` creates a local
fixture repository when no inputs are provided; pass `--inputs inputs.json` to
supply an explicit name-to-decoded-value map, e.g. `{"repository":"/path/to/repo"}`.
`--root PATH` selects the state directory (default `.agru`).

## Explicit programs

See [`programs/demo.rb`](programs/demo.rb). Inputs, executors, step inputs/outputs,
dependencies, and emitted artifacts are explicit. Compile with
`AgentRuntime.compile(path)`, validate with `Compiler.validate!`, then execute with
`Runtime.new(store: store).run(ir, inputs: {...})`. Programs are trusted Ruby code,
not sandboxed configuration. The fake patch adapter modifies a copied repository
and emits its repository plus a unified binary Git patch artifact. The dependent
public shell check is not the independent hidden evaluator.

## Benchmarks

`demo` initializes a real local Git repository from a deliberately broken Clamp
fixture and records its actual baseline commit in a generated manifest. The good
fake solver repairs it; the bad fake returns the broken baseline with execution
status `success`, proving that execution success is not a correctness verdict.
The DSL solver runs the same task through the runtime.

Benchmark results are persisted in Store and under
`.agru/benchmarks/RUN_ID/result.json` and `result.csv`. Reports include the task and
dataset revision, actual baseline commit, execution status, independent verdict,
timing, solver identity/version/configuration digest, repetition, timestamps,
artifact references, runtime IR digest when applicable, and available usage/cost.
Requested model is distinct from reported actual model. Fake costs are zero; unknown live costs are not
silently reported as zero. Hidden evaluation runs outside the solver workspace.
Repository/specification/procedure/environment digests bind each verdict to the
exact stored inputs. See [methodology](docs/methodology.md) for trust boundaries.

## Explicit live opt-in

After separately configuring OpenCode and its provider credentials:

```sh
mise exec -- ruby bin/agru benchmark --suite demo --solver opencode --live --model provider/model
```

Without `--live`, this solver returns `blocked` before calling its adapter.
`--live` permits paid calls; the timeout is enforced, but the budget is not a hard
provider-side monetary cap. Never run untrusted generated code on a sensitive host.

## Further reading

- [Architecture and extension points](docs/extensibility.md)
- [Language, IR, and execution semantics](docs/architecture.md)
- [OpenCode, OpenSpec, and opt-in Serena](docs/integrations.md)
- [Evaluation methodology and limitations](docs/methodology.md)
- [Roadmap](docs/roadmap.md)
- [Shared APIs](CONTRACTS.md)
