# M0 local acceptance record

Verified on macOS arm64 with Ruby 4.0.9, mise 2026.11.7 and locked gems.
No paid model request, provider request, background service or dataset download
was used. These are offline plumbing results, **not AI capability scores**.

| Check | Observed result |
|---|---|
| `mise exec -- bundle install --local` | 3 direct dependencies, 21 installed gems |
| `mise run test` | 42 runs, 182 assertions, 0 failures, 0 errors, 0 skips |
| `mise run lint` | StandardRB exit 0 |
| `mise run smoke` | doctor, compilation and dependent patch/public-check execution exit 0 |
| `mise run benchmark-demo` | six retained runs, expected four pass/two fail verdicts; command exit 0 |
| OpenSpec strict validation | 2 items passed, 0 failed |
| OpenSpec status/apply instructions | existing `m0-runtime` JSON retrieved successfully |
| OpenSpec import example | existing files imported and typed-input program completed |

Final observed demo batch:

| Solver | Repetition | Run ID | Execution | Independent verdict |
|---|---:|---|---|---|
| fake-good | 1 | benchmark-64ce6571-1c8a-432d-9225-cd8b8862f688 | success | pass |
| fake-good | 2 | benchmark-d527b0d3-f3e3-4bd0-8646-aaa17a597312 | success | pass |
| fake-bad | 1 | benchmark-7ca68c25-c0e5-49b8-8fbc-fe82d16eb0e5 | success | fail |
| fake-bad | 2 | benchmark-0c662f53-a0cb-4afa-a8db-57e151c0dda5 | success | fail |
| dsl | 1 | benchmark-53abd05f-6afd-4517-b3d7-8f20248b2da5 | success | pass |
| dsl | 2 | benchmark-4418cff7-a6db-4b82-a5d5-ed4056f020aa | success | pass |

Local state is deliberately ignored by Git: each run has `report.json` and
`report.csv` under `.agru/benchmarks/<run-id>/`, plus SQLite metadata and
content-addressed artifacts under `.agru/store/`. Use `bin/agru report <run-id>`
under mise to inspect one. Regenerating produces new run IDs while retaining the
fixed fixture revision and expected verdicts.

OpenCode 2.3.0 is installed and its CLI protocol is exercised using local fixture
executables. **Live provider execution was not tested**. OpenSpec 1.16.0 was
actually exercised locally. Serena 2.1.0 CLI/context were inspected, but MCP/model
execution and memory isolation were not verified; it remains disabled in demo
benchmarks. HTTP transport and official external graders remain unimplemented.
