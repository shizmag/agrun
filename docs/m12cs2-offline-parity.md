# S2 offline parity acceptance

This is installed-OpenCode infrastructure evidence, **not model capability**.
All upstream responses are frozen mock fixtures; no paid endpoint is authorized.
Do not copy reference implementations or hidden procedures into solver workspaces.

`test/m12cs2_offline_parity_test.rb` registers the same public `retrying`
specification (`cd41306283b97f81d9cb8ec14985b47acf973dea92f492b53a4e1aaa796a4168`)
for single-agent, fixed planner/coder/reviewer, and compositional DSL
planner/coder/reviewer. It requires seven successful installed-agent invocations,
captures each submitted repository once into Store, and submits that identical
artifact to two independent audited grading calls. Solver reruns are forbidden.
The fixture implementation must be intentionally incomplete and independently
written, not a reference substitution. Failure scores are legitimate results.

## Coordination contract

E owns the isolated `s2-parity` blocks and fixture module; D owns other scripts.
The fixture observes the actual prompt and chooses `single`, `planner`,
`coder`, or `reviewer` accordingly. Each invocation should use native read and
shell tools; shell writes `s2-ROLE.txt` in its workspace. Coder/single write an
explicitly incomplete `retrying.py` fixture. Planner and reviewer must not be
collapsed into coder or bypassed. Preserve tool request observations and hashes.

The sandbox owner must complete safe writer-quiescent export before integration.
Do not weaken export checks to make this test pass. This test does not own the
production runner.

## Running after dependencies land

Set `AGRU_M12CS2_PARITY=1`, `AGRU_M12C_AGENT_IMAGE` to the pinned installed-agent
image, and `AGRU_M12CS2_EVIDENCE_ROOT` to a **new** ignored `.agru` directory.
Optionally set `AGRU_M12CS2_ASSETS` to the existing ignored NL2Repo asset root.
Run `mise exec -- ruby -Itest test/m12cs2_offline_parity_test.rb`.
No downloads, environment freeze, provider credentials, or paid calls are needed.
Freeze environment evidence only after all relevant code has been committed.

## Initial red/skip evidence

On 2026-11-15 the default invocation completed with one explicit opt-in skip.
With only `AGRU_M12CS2_PARITY=1` it failed before Docker dispatch:
`ArgumentError: unknown frozen mock script` at
`test/support/m12c_relay_docker.rb:11`. This establishes the missing mock
dependency, not safe-export correctness or grading success. No final parity,
score, executable execution, or immutable grading result is claimed yet.

The routing unit test now passes:
`node test/support/m12cs2_parity_fixture_test.cjs`. Installed-agent probes stop
before any event with `SandboxRunner::BoundaryError: effective sandbox policy mismatch`
while runner integration progresses. These are diagnostics, not frozen acceptance
evidence; full seven-invocation integration and grading/regrading remain pending.

## Completed integration (not an environment freeze)

On 2026-11-15, `.agru/m12cs2-parity-final-20261115/evidence.json`
retained all three architectures, seven successful installed-agent invocations,
three immutable mode-aware submissions, and six independent audited-v2 grading
results. Each architecture executed 23 tests, passed 3, failed 20, and received
`verdict: fail` with score `0.13043478260869565` on both grades. Grading execution
itself succeeded. The intentionally incomplete fixture is the reason for the
quality failure; this is not evidence about model capability.

The earlier red/probe results above are superseded by this completed run, but
remain useful diagnostic history. This run predates the final commit and is not
an environment freeze. `mock.jsonl` and `relay.jsonl` retain role, prompt/request
hashes, advertised tools, and request observations. The image identity is
`sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`.
The final integration passed 1 test / 55 assertions; focused mode tests passed
2 tests / 14 assertions. Each evidence cell includes the canonical Store
submission record and mode-sidecar id/digest, not merely a temporary export path.
Both grading requests bind that same immutable submission digest; each result
records the full 23-test collection/execution inventory. The route
`mock/cx/gpt-6-luna-low` is only the observed mock request identity: it provides
no actual OmniRoute execution attestation, provider identity, or pricing evidence.

## Mode identity audit

The existing Store manifest binds content and an executable boolean, not exact
permission modes (`lib/agent_runtime/store.rb:105-127`). Materialization normalizes
files to `0755` or `0644`; legitimate read-only `0444` exports lose that property
at capture. The additive `Submission#capture(preserve_modes: true)` now binds a
canonical JSON sidecar to the unchanged legacy content digest. Verification reloads
canonical Store records, and materialization restores exact ordinary file/directory
modes without changing shared Store objects. Focused tests cover read-only files,
nested/empty directories, executable files, caller metadata stripping, tampering,
and preservation through the grader's `cp -R` staging operation. The immutable
artifact root is verified before the grader deliberately makes its separate
installation working root writable; see `CONTRACTS.md`.
