# Benchmark boundaries

Only the local Clamp fixture is implemented and verified. `configuration.json`
records **unimplemented** baseline/dataset slots; it is not an executable solver
registry. Add actual solver objects to `Runner#matrix`, which is independent from
DSL implementation except for the explicitly selected DSL solver. Models are
configuration strings, not an embedded list of providers.

An external dataset adapter should load a pinned licensed revision, normalize
rows with `Benchmarks::Manifest`, check out the recorded base commit, expose only
permitted public material, and provide a separate evaluator object to Runner.
Before claiming support:

| Dataset | Required implementation and verification |
|---|---|
| SWE-bench Pro | Official task/schema loader, repository/base revisions, dependency environment, official grading harness and its resource/network policy; validate exported scores against a pinned official sample. |
| SWE-bench Multilingual | Language-specific toolchains/environments, official multilingual task fields and grader, public/hidden split and per-language failure classification; reproduce a pinned sample in each supported language. |
| FeatureBench | Feature/task schema and repository revisions, official feature acceptance procedures, fixtures/assets and environment setup; compare independent grading against official reference outcomes. |

Do not download full datasets for M0. No official grader or real model score has
been run here. Direct LLM and OpenSpec-assisted solver baselines need actual
provider/authoring calls, opt-in authentication, budget accounting and protocol
tests before they may be labeled implemented. Optional OpenSpec artifact tooling
is not itself an OpenSpec-assisted coding solver.
