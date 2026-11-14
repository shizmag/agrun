# Evaluation methodology

## What the demo measures

The fixture is a tiny repository repair task, not evidence of general agent
capability. `demo-v1` declares a specification, broken source, and external hidden
procedure. Local initialization records the actual Git baseline commit with fixed
author/committer timestamps and identity, making the local fixture revision
reproducible. Source snapshot digests exclude Git metadata.

The solver contract is `solve(task:, model:, budget:, workspace:)`. A task given to
a solver has no hidden-procedure path. The solver gets a baseline repository and
natural-language specification, works in a dedicated directory, and returns a
status and repository path. The submitted repository—not a claimed patch—is the
authoritative evaluation input. Fake good/bad solvers verify plumbing only.

## Independent evidence

The evaluator stores the submitted tree before testing, materializes a disposable
copy, and invokes a separate Ruby process with the evaluator-owned hidden
procedure outside the solver workspace. It does not import tests from the
submission. Assertions cover boundaries, in-range preservation, floats, negative
bounds, equal bounds, and inverted bounds. Nonzero completed test exit is verdict
`fail` with execution status `completed` only with a matching `AGRU_VERDICT=` JSON
marker. Exit 0/pass and exit 1/fail are accepted; other exits, missing markers,
timeouts and infrastructure failures are
`not_evaluated`. Solver success is recorded separately.

Every evaluation report binds four content digests: `artifact` (repository tree),
`specification` (requirements plus dataset revision and baseline commit),
`procedure` (exact hidden test bytes), and `environment` (Ruby, platform, executable,
normalized overrides, and digest of inherited environment). Raw inherited values
are not exposed because they may contain credentials. The procedure and full
report are Store artifacts. Each run also persists JSON and RFC-style quoted CSV.

## Security and reproducibility limits

Directory separation is **not a security sandbox**. Solver and evaluator run as
the same OS user; malicious code could inspect other files, access the network,
or interfere with the host. Hidden tests are also visible in this source checkout
to anyone with full host access. Do not interpret hidden-test placement as an
anti-cheating guarantee. Use a disposable OS/container boundary before evaluating
untrusted code. Evaluation timeouts limit runaway processes but do not isolate
filesystem or network access.

The environment binding records provenance; it is not an executable environment
lockfile or a container-image digest. There is no claim of bit-for-bit replay
across platforms. No live agent scores or comparative performance claims are
published. Run repeated trials with pinned model/provider configuration, separate
task families, explicit cost accounting, and confidence intervals before drawing
quality or efficiency conclusions. Training contamination remains unmeasured.
