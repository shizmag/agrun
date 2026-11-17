# Historical nine-cell forensics (read-only, 2026-11-17)

## Identity and scope

The actual completed live experiment is
`research-omniroute-token-staged-v2-dbb87e2dcd8df4a7`, task `retrying`.
The preserved archive is `docs/evidence/omniroute-live-success-20261116/`.
Its original source directory is
`.agru/luna-live-periodic-fixed-20261116/local-token-comparison/research-omniroute-token-staged-v2-dbb87e2dcd8df4a7/`.
Do not substitute the halted, UTF-8-failed, simulated, or earlier pilot runs.
Inspection used binary reads and SQLite `mode=ro`; no rerun, repair, regrade,
provider call, or historical evidence write was performed.

All nine execution statuses are `success`, all nine evaluation verdicts `fail`.
SA = single-agent; FW = fixed-workflow; DSL = dsl. Within architecture,
repetition order gives SA **17/23, 17/23, 14/23**, FW **17/23, 6/23, 4/23**,
DSL **4/23, 5/23, 4/23**. Means: 48/69 = 0.695652,
27/69 = 0.391304, 13/69 = 0.188406. One task with three repetitions is
not a population estimate or an architectural causal comparison.

## Exact byte references

SHA-256 hashes below were recomputed from the inspected files. They establish
byte identity, not authenticity or correctness. Paths are repository-relative.

- `docs/evidence/omniroute-live-success-20261116/report.json`: `183b769558241bcc5867f01ae4da5b079c10200599ae7c01b1c4cfe3d08acd72` (1078785 bytes).
- `docs/evidence/omniroute-live-success-20261116/frozen/experiment.json`: `5fd4bbcaf7f4fb9aa999f3a5052c29f37e01a9229c5dcc14afe0ef691966fd2b` (2541520 bytes).
- `docs/evidence/omniroute-live-success-20261116/verification.json`: `8f95bf152c6db77585b76d72edbe7a29263c9a9c892068dde8ddf73b3af9bbb5` (3981 bytes).
- `docs/evidence/omniroute-live-success-20261116/archive-verification.json`: `d36e460e63665b1924a160c98771a1f0b38dda94c85914f3dccf570bd801b2a0` (252 bytes).
- `docs/evidence/omniroute-live-success-20261116/portable-regrade.json`: `ded317ed453e821a7f10660c72eee6321ee5dd15f94442d345e7bf68b150d62e` (205508 bytes).
- `docs/evidence/omniroute-live-success-20261116/provider-audit.jsonl`: `01a37b0d4fe84b02122c03cf84cba6a55d2fdd1a5126b8b93818a79a27d29e20` (177880 bytes).
- `docs/evidence/omniroute-live-success-20261116/provider-audit-summary.json`: `259982523115d32fdd76f468435f3c5e605dca358bdb41f7a1374d61ccb9e1af` (432 bytes).
- `docs/evidence/omniroute-live-success-20261116/token-ledger-snapshot.json`: `aa29cd568be4a8fc4715c08596d09f528d888ae8e340f4494f6847f055c88518` (436 bytes).
- `docs/evidence/omniroute-live-success-20261116/execution-release-identity.json`: `d10beddfad1c30e5d70686d2f37282cbdbfcf05cdc67835e9e0f40423dd9e04c` (15017 bytes).

## Per-cell observations

The report is the source for counts and durations (seconds, not enforced budgets).
The submission digest is the legacy repository content digest, not a SHA-256 of
an archive file. Its tree is under the original Store's `objects/<digest>.tree`.

| Architecture | Rep | Cell ID | Passed/total | Agent seconds | Submitted repository digest |
|---|---:|---|---:|---:|---|
| dsl | 1 | `79ebba2581a0e09dd1e7f0d0e5d90055e2d2cee6c70d955cab484f1b24876060` | 4/23 | 116.795701 | `5612411ab7591b6a1bbbf79d655ab59314c43f50e234a11388707e345d5b8667` |
| dsl | 2 | `014635eb00cc29053f4c9eb0cbd629b81fc476560cd51c762ad27b8143b10819` | 5/23 | 128.453509 | `6c2213288d1f35fdcd27f7a6d8925fe2479481f5f81af11d309e386617be53b3` |
| dsl | 3 | `3bc17c5fa5ba361c0fedf4178f0b5b740173f2b2ab1bb43ebb2e8fd184230a65` | 4/23 | 142.827650 | `4171e6e51ab159513be75116e16526ce50598dfdf636005378a1b2bb3c1c6016` |
| fixed-workflow | 1 | `a938b520764c8f5b2564adab3b14c165046ebcbc2fe3f7119b0df919ee8c0211` | 17/23 | 95.607438 | `60ea054a409dcec74eb713d7b26df3f297ec9922970a1d4b43d667d4137b8789` |
| fixed-workflow | 2 | `417036a1db6172ec0c6eae1734da8ac5ac7762165996a84e5bed2efba6d8740b` | 6/23 | 105.135227 | `0dd46fa271e75ae39f2657c2df43ad27fa2b0d3e2a1a8b4ffa9a788f06aa66c2` |
| fixed-workflow | 3 | `410841922136b50a9478985120589dde8aa5c4faa2e1c8bb92cca5b137a96c11` | 4/23 | 135.416369 | `97b6bbca811e507bb4d68992ac5329121bbacda1f4493699e235b74034dbb1c5` |
| single-agent | 1 | `ea69d53a9b9004e77d7019708ee533e0edf1d5cf032bd3c5b2d3265b5fcbc9bd` | 17/23 | 98.848142 | `53d93747971961f48812713305fdbb07e88f30fc03516d1259e2ea79f0ffae54` |
| single-agent | 2 | `54bd74c46837ef3dd12b5219a989b964a9205da725297a1ee5338f60b1a7d8cd` | 17/23 | 103.556997 | `888e36ccafef1d7d548867c3d0e03590766f84e448443457f0a99c65194d7019` |
| single-agent | 3 | `522315707eb4219be19839e0636952f41d1c61d595a1a21bff18f126c6ad4afd` | 14/23 | 100.697856 | `b94d0b2c57e8e4da2a18513ad0255354895984903452e71c074603ab97c77e86` |

## Budgets, observations and accounting

The frozen manifest declares cell inference requests 12, planner 3, coder 7,
reviewer 2, timeout 600 seconds, max attempts 1, concurrent sessions 1,
parallelism 1. Single-agent gets one continuous session; FW and DSL divide the
nominal 12 turns across three sessions. DSL also has deterministic inventory and
validate stages. Equal nominal turn allowance is not equal tokens, context,
compute, cost, tool opportunities or effective reasoning budget.

Native stdout event counts below are observations, not provider-request counts:
SA has 10 step_finish events in each repetition; every coder has 7; planner has
3 except DSL repetition 2 has 2; every reviewer has 2. Multiple tools can occur
within one turn. A final text event does not prove the requested handoff was
complete or successful. Current source `lib/agent_runtime/benchmarks/local_comparison.rb:108-143`
corroborates role limits and a request for an honest final handoff, but current
source is not automatically the historical execution implementation; the
execution release identity is the historical binding. Tier-2 graph coverage
reported no recorded issue for that file (best effort, not completeness proof).

The archived provider audit has 143 rows: 101 requests, 21 gateway lifecycle and
21 gateway process rows; all 101 requests report HTTP 200. Request usage sums
1,298,702 prompt + 37,324 completion = 1,336,026 total tokens. All request
accounting remains incomplete. There are 141 heartbeats: 116 early-startup and
25 timestamped-empty, not additional model requests. The cumulative ledger is
not nine-cell usage: limit 1,000,000,000; reserved 869,393,920; request count 418;
known usage 4,905,689; unknown usage/model counts 1 each; unresolved violations
empty; halted false. Reservation is not consumption or billing. Costs,
served-model attestation, complete cache/reasoning usage and session correlation
remain unknown. Requested `cx/gpt-6-luna-low` and response label `gpt-6-luna`
are not proof of the served model.

## Handoff and overwrite evidence

Read-only SQLite lookup used
`.agru/luna-live-periodic-fixed-20261116/store/metadata.sqlite3`, `runs` rows
keyed by each report cell's `execution.run_id`, and `artifacts` rows keyed by
its attempt `evidence`. Mutable database metadata is supporting correlation,
not an authenticated historical log. Object SHA-256 was checked independently.

All three DSL `plan` and all three `implementation` text output artifacts are
zero bytes (SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
That is absence of a persisted text handoff, not absence of native assistant text.
FW transfers repository output rather than a named plan text artifact.
FW planner repositories are empty in repetitions 1 and 2; DSL planner repository
is empty in repetition 1. Other planners modify repository bytes, so role names
must not be mistaken for read-only permissions.

In all six multi-stage cells the coder, validation (DSL only), and reviewer
repository digests agree. Thus there is **no net persisted reviewer overwrite**
of coder repository content in these observations. Intermediate edits, undone
edits, or unexported writes remain possible. Digest equality does not establish
review quality or prove tools were read-only. No per-test counterfactual grades
of planner/coder intermediate states were executed here.

Native tool events show patch operations in DSL planners 2 and 3 and FW planner
3. This supports planner mutation, not an assertion that mutation caused lower
scores. Lost structured handoff, split-context overhead, budget allocation,
implementation strategy, tool batching and ordinary stochastic variation are
hypotheses requiring controlled interventions, not findings of causality.

## Native immutable execution artifacts

Each row gives the actual object file and its SHA-256, verified against its
metadata digest, plus parsed stdout event counts (start/finish/tool/text).
Raw prompts, shell arguments, tool outputs and assistant text are not reproduced.

- dsl repetition 1, coder: `.agru/luna-live-periodic-fixed-20261116/store/objects/9ceb9d5686d8731e2658d275b9f15879f33d2550719f0d291e68572d0b817a02`; SHA-256 `9ceb9d5686d8731e2658d275b9f15879f33d2550719f0d291e68572d0b817a02`; events 7/7/6/1. Repository output digest `5612411ab7591b6a1bbbf79d655ab59314c43f50e234a11388707e345d5b8667`.
- dsl repetition 1, planner: `.agru/luna-live-periodic-fixed-20261116/store/objects/6828d0794fb1e4b5e1601bf4ded9d31c8012947666590e9be7c94005202a604f`; SHA-256 `6828d0794fb1e4b5e1601bf4ded9d31c8012947666590e9be7c94005202a604f`; events 3/3/2/1. Repository output digest `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945`.
- dsl repetition 1, reviewer: `.agru/luna-live-periodic-fixed-20261116/store/objects/c88431b72d3e6195ff1a7e5cbf9537ba8122b66c1779c1d42d99779c4afa9ffa`; SHA-256 `c88431b72d3e6195ff1a7e5cbf9537ba8122b66c1779c1d42d99779c4afa9ffa`; events 2/2/3/1. Repository output digest `5612411ab7591b6a1bbbf79d655ab59314c43f50e234a11388707e345d5b8667`.
- dsl repetition 2, coder: `.agru/luna-live-periodic-fixed-20261116/store/objects/9040c371ebf15158256be261889b235189e072586dcde3860cefa3c99d1e3c3c`; SHA-256 `9040c371ebf15158256be261889b235189e072586dcde3860cefa3c99d1e3c3c`; events 7/7/6/2. Repository output digest `6c2213288d1f35fdcd27f7a6d8925fe2479481f5f81af11d309e386617be53b3`.
- dsl repetition 2, planner: `.agru/luna-live-periodic-fixed-20261116/store/objects/fb99ad3e08725a40ced55a1c5777b67326f6c0adffe21b77f49edd86c1919d2d`; SHA-256 `fb99ad3e08725a40ced55a1c5777b67326f6c0adffe21b77f49edd86c1919d2d`; events 2/2/1/1. Repository output digest `7e872ef7efe9da8fd0030ef34c0dd3baa5fb22179d646d87a0f9063d9d2130e5`.
- dsl repetition 2, reviewer: `.agru/luna-live-periodic-fixed-20261116/store/objects/c613937c4e815e9c5529dfe76dde12b19b51bce4f6f85866f3e68e7a93aba9ee`; SHA-256 `c613937c4e815e9c5529dfe76dde12b19b51bce4f6f85866f3e68e7a93aba9ee`; events 2/2/3/1. Repository output digest `6c2213288d1f35fdcd27f7a6d8925fe2479481f5f81af11d309e386617be53b3`.
- dsl repetition 3, coder: `.agru/luna-live-periodic-fixed-20261116/store/objects/ab51dcf611f0299b4cbe65098eff2c3b6a74a382105490bb1be79e4a0a83071b`; SHA-256 `ab51dcf611f0299b4cbe65098eff2c3b6a74a382105490bb1be79e4a0a83071b`; events 7/7/6/1. Repository output digest `4171e6e51ab159513be75116e16526ce50598dfdf636005378a1b2bb3c1c6016`.
- dsl repetition 3, planner: `.agru/luna-live-periodic-fixed-20261116/store/objects/b6e64994881a1b387b4afdffc406386f21ccb4195fb141e70974ffc2838bfd18`; SHA-256 `b6e64994881a1b387b4afdffc406386f21ccb4195fb141e70974ffc2838bfd18`; events 3/3/2/1. Repository output digest `7a5b25395c1763a8fd3b63c5c4e5bb49cc3a4647f4e2268bc8976421f57483d5`.
- dsl repetition 3, reviewer: `.agru/luna-live-periodic-fixed-20261116/store/objects/0a522ac4ba792eab2049dca9b1635ff643913a6639e8b71849f18bb73486491d`; SHA-256 `0a522ac4ba792eab2049dca9b1635ff643913a6639e8b71849f18bb73486491d`; events 2/2/6/1. Repository output digest `4171e6e51ab159513be75116e16526ce50598dfdf636005378a1b2bb3c1c6016`.
- fixed-workflow repetition 1, coder: `.agru/luna-live-periodic-fixed-20261116/store/objects/302e308db0579416547cf798b5b7ddbd812a3a0b33f1f8fa9f1d8102da3948b3`; SHA-256 `302e308db0579416547cf798b5b7ddbd812a3a0b33f1f8fa9f1d8102da3948b3`; events 7/7/6/1. Repository output digest `60ea054a409dcec74eb713d7b26df3f297ec9922970a1d4b43d667d4137b8789`.
- fixed-workflow repetition 1, planner: `.agru/luna-live-periodic-fixed-20261116/store/objects/d567909b08a6e134e3b2c6494833b486795592090e734874d3ee884496fa2657`; SHA-256 `d567909b08a6e134e3b2c6494833b486795592090e734874d3ee884496fa2657`; events 3/3/3/2. Repository output digest `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945`.
- fixed-workflow repetition 1, reviewer: `.agru/luna-live-periodic-fixed-20261116/store/objects/ea2681ec28a7da67b52807aed8193d15e251f02585592f9c2d006c52ac620453`; SHA-256 `ea2681ec28a7da67b52807aed8193d15e251f02585592f9c2d006c52ac620453`; events 2/2/2/1. Repository output digest `60ea054a409dcec74eb713d7b26df3f297ec9922970a1d4b43d667d4137b8789`.
- fixed-workflow repetition 2, coder: `.agru/luna-live-periodic-fixed-20261116/store/objects/adb39c1478a8bcc1f773b0c3ef32871c9d69db9c17a66358900d60895686308e`; SHA-256 `adb39c1478a8bcc1f773b0c3ef32871c9d69db9c17a66358900d60895686308e`; events 7/7/6/1. Repository output digest `0dd46fa271e75ae39f2657c2df43ad27fa2b0d3e2a1a8b4ffa9a788f06aa66c2`.
- fixed-workflow repetition 2, planner: `.agru/luna-live-periodic-fixed-20261116/store/objects/0d92d20a11a3a9cc00b33db244dc59e77b69a802ff07ebffae1d4dbbb0357328`; SHA-256 `0d92d20a11a3a9cc00b33db244dc59e77b69a802ff07ebffae1d4dbbb0357328`; events 3/3/2/1. Repository output digest `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945`.
- fixed-workflow repetition 2, reviewer: `.agru/luna-live-periodic-fixed-20261116/store/objects/1515a3454f4fdbe7be3dd5f48b60b20f5de742f6d195fc50a464e1d25f5046d5`; SHA-256 `1515a3454f4fdbe7be3dd5f48b60b20f5de742f6d195fc50a464e1d25f5046d5`; events 2/2/2/1. Repository output digest `0dd46fa271e75ae39f2657c2df43ad27fa2b0d3e2a1a8b4ffa9a788f06aa66c2`.
- fixed-workflow repetition 3, coder: `.agru/luna-live-periodic-fixed-20261116/store/objects/fef52c080ca919b12be79d878cb3fccb5585e8df8f57d90d163d81088c591a12`; SHA-256 `fef52c080ca919b12be79d878cb3fccb5585e8df8f57d90d163d81088c591a12`; events 7/7/6/3. Repository output digest `97b6bbca811e507bb4d68992ac5329121bbacda1f4493699e235b74034dbb1c5`.
- fixed-workflow repetition 3, planner: `.agru/luna-live-periodic-fixed-20261116/store/objects/720df7991a4dae7d035fab804671d75e1921914281b0bcdd2d1793bfc15481a6`; SHA-256 `720df7991a4dae7d035fab804671d75e1921914281b0bcdd2d1793bfc15481a6`; events 3/3/2/1. Repository output digest `d879e4fefa13d6dc72acbc0fd328da665871f2bf9886796a728b7c07092d36fc`.
- fixed-workflow repetition 3, reviewer: `.agru/luna-live-periodic-fixed-20261116/store/objects/cbda66749c158afff63df95dc9e9b852b023b8fe8ce28623c656a96880349177`; SHA-256 `cbda66749c158afff63df95dc9e9b852b023b8fe8ce28623c656a96880349177`; events 2/2/3/1. Repository output digest `97b6bbca811e507bb4d68992ac5329121bbacda1f4493699e235b74034dbb1c5`.
- single-agent repetition 1, solve: `.agru/luna-live-periodic-fixed-20261116/store/objects/0140339cfeffa9e7608daf02225ed2cc654d92f513aa9d9c4b0a5c4e0e629912`; SHA-256 `0140339cfeffa9e7608daf02225ed2cc654d92f513aa9d9c4b0a5c4e0e629912`; events 10/10/9/1. Repository output digest `53d93747971961f48812713305fdbb07e88f30fc03516d1259e2ea79f0ffae54`.
- single-agent repetition 2, solve: `.agru/luna-live-periodic-fixed-20261116/store/objects/5146fbf5e4341f8113f0c594ee4f4dcb26abc5ca6e5b315f6db0693fc7532f0a`; SHA-256 `5146fbf5e4341f8113f0c594ee4f4dcb26abc5ca6e5b315f6db0693fc7532f0a`; events 10/10/9/1. Repository output digest `888e36ccafef1d7d548867c3d0e03590766f84e448443457f0a99c65194d7019`.
- single-agent repetition 3, solve: `.agru/luna-live-periodic-fixed-20261116/store/objects/1681373931e98b1d949f9686ac41d1eed70269ef165be23404370b5add999888`; SHA-256 `1681373931e98b1d949f9686ac41d1eed70269ef165be23404370b5add999888`; events 10/10/10/2. Repository output digest `b94d0b2c57e8e4da2a18513ad0255354895984903452e71c074603ab97c77e86`.

## Verification limits

Saved `verification.json` records 9/9 checks; saved portable regrade records nine
actual grades, all matching the originals. Saved archive verification reports
integrity and regrades verified. These are preserved observations, not new
verification runs by this importer. Regrades reuse the same grader implementation,
not an independent evaluator. Unsigned freezes can be forged by changing both
content and checksums. Directory separation is not a security sandbox.
The archive intentionally omits hidden grader bodies and live raw workspaces;
original local objects may not be portable. Missing bytes must stay missing.

## Read-only importer

Require `agent_runtime/tracing/historical` explicitly. Supply an existing tracing
Store implementing `start`, `finish`, and `event` (the importer never calls
`payload`, including with raw mode). Example:

```ruby
require "agent_runtime/tracing/historical"
importer = AgentRuntime::Tracing::Historical.new(store: trace_store)
root_id = importer.import(
  report_path: "docs/evidence/omniroute-live-success-20261116/report.json",
  evidence_paths: ["docs/evidence/omniroute-live-success-20261116/provider-audit.jsonl"]
)
```

The same method accepts `frozen/experiment.json`'s report wrapper. It creates a
new import root, cells, steps and attempt observation events, preserving historical
IDs as attributes rather than overwriting trace IDs. Execution status and verdict
remain separate. Import-root success means the projection completed, not that
any benchmark passed. Repeated imports create separate projections, not deduped
historical executions. Source and explicit evidence references contain absolute
path, SHA-256 and byte length; bytes are not copied. Missing explicit files fail
before trace writes. Existing attempt evidence IDs are retained as **not resolved**,
never converted into invented paths or hashes. To bind a locally available object,
pass its actual file path in `evidence_paths`; references are not automatically
correlated to attempt IDs. No metadata database is opened by the importer.

Only allowlisted numeric/status/identity summaries are projected: no prompts,
stdout/stderr, repository contents, native tool arguments or raw audit rows.
Absent fields remain absent and explicit null remains null. No missing usage is
filled with zero, no inferred provider spans or timestamps are created, and no
model call, subprocess, grading, evidence repair, or hidden-procedure copy occurs.
The supplied Store writes only the new trace; caller must choose a separate
output location, never a historical source Store. Path names and identifiers can
still be sensitive; this is a trusted-local projection, not adversarial sanitization.


Trace Store start/finish timestamps and durations describe this local import,
not the historical experiment. Historical durations, where observed, are separate
attributes; the importer does not backdate Store clocks. Local integration with
the concurrent tracing Store produced 64 entities and zero incidents in a fresh
temporary directory. Focused Minitest: 3 runs, 19 assertions, no failures/errors;
Standard Ruby passed for the two owned Ruby files. No full-suite claim is made.
