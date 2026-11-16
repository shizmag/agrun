# Offline security verification — 2026-11-16

**Targeted evidence, not blanket security acceptance.** No paid/provider calls were made.
Docker fixtures use simulated credentials and local upstreams. This inventory
does not close the relay review gaps in `docs/m1.2d-t1b-validation.md`.
No implementation or existing test files were changed for this verification.

## Evidence and reproduction

All logs are in `docs/evidence/research-security-2026-11-16/` (not historical
`.agru` state). Commands ran from the repository root using Ruby 4.0.9 and the
installed bundle. Set `I=sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`
in the shell before commands below. No images were pulled.

```sh
AGRU_M12D_TRANSPORT_TEST=1 mise exec -- bundle exec ruby -Itest test/m12d_installed_transport_test.rb
```

`installed-transport.log`: **1 run, 20 assertions, 0 failures/errors/skips**.
Real installed OpenCode, offline relay exchange and direct-socket negative
probes ran. Simulated usage is 12 input / 3 output / 15 total; response model
is `simulated-not-attested`. Served identity and pricing remain unknown.
Adapter aggregate usage explicitly has `stream_complete:false`, not a proven
complete billing total. Tests cover forbidden methods/paths/model/parameters,
forged identity headers, secret-path absence, socket ownership/mode, direct
network denial, cleanup and fixture removal; they are not a full relay matrix.

```sh
AGRU_SANDBOX_TEST_IMAGE="$I" AGRU_SANDBOX_PYTHON_IMAGE="$I" AGRU_SUPERVISOR_DOCKER_TEST=1 AGRU_S2_EXPORT_DOCKER=1 mise exec -- bundle exec ruby -Itest -e 'ARGV.each { |f| require_relative f }' test/sandbox_boundary_test.rb test/sandbox_supervisor_test.rb test/sandbox_export_metadata_test.rb test/m12cs3_host_escape_test.rb test/m12cs2_integrated_adversarial_test.rb test/m12c_sandbox_lifecycle_test.rb
```

`sandbox-controls-pinned.log`: **57 runs, 404 assertions, 0 failures/errors/skips**.
Controls include host-canary/environment/private-layout and Docker-socket denial,
non-root/capability/no-new-privileges/rootfs checks, direct outbound denial,
PID-limit probe, timeout/cancellation cleanup, detached/TERM-resistant writer
quiescence, read-only executable export, archive traversal/special-member/size
rejection and symlink-swap handling. Some tests are unit controls, not 57 separate
installed-container probes. Limits in inspect evidence do not independently
prove resistance to every CPU, memory or filesystem exhaustion attack.

Initial `sandbox-controls.log` used
`AGRU_SANDBOX_TEST_IMAGE=alpine@sha256:3f4d6b32e26703c6082839234f43769d5046b3ac7c910033911d1e71d8cd630a`
with the same other arguments: **57 runs, 375 assertions, 4 failures**. The
Alpine image lacks the Python supervisor (`/usr/bin/python3: not found`); these
are failed calibration attempts, not successful denial controls. Pinned agent
image retry above is the applicable evidence.

```sh
AGRU_M12C_AGENT_IMAGE="$I" AGRU_S2_EXPORT_DOCKER=1 AGRU_M12C_HOST_BOUNDARY=1 AGRU_M12C_INSTALLED_NEGATIVE=1 AGRU_M12C_MOCK_DOCKER=1 AGRU_M12C_OPENCODE_ACCEPTANCE=1 AGRU_M12CS3_LSP=1 AGRU_M12CS3_LSP_INSTALLED=1 AGRU_M12CS3_PLUGIN_CALIBRATION=1 AGRU_M12C_AUX_CALIBRATION=1 AGRU_M12CS2_PARITY=1 mise exec -- bundle exec ruby -Itest -e 'ARGV.each { |f| require_relative f }' test/m12c_private_cleanup_test.rb test/m12c_physical_host_boundary_test.rb test/m12c_installed_negative_test.rb test/m12c_mock_relay_test.rb test/m12c_sandbox_opencode_acceptance_test.rb test/m12cs3_lsp_fixture_test.rb test/m12cs3_lsp_installed_test.rb test/m12cs3_plugin_calibration_test.rb test/m12c_auxiliary_calibration_test.rb test/m12cs2_offline_parity_test.rb
```

`installed-controls-pinned.log`: **12 runs, 197 assertions, 0 failures, 1 error,
0 skips**. Auxiliary MCP diagnostic timed out after 20 seconds
(`AgentRuntime::Adapters::ProcessRunner::Error: process timeout after 20s`),
so this group is **not passing**. Remaining cases completed, including physical
host positive calibration, private cleanup, installed negative probes, mock
relay, agent shell/native-read acceptance, LSP/plugin calibration and S2 parity.
SQLite fork warnings are retained. Initial `installed-controls.log` omitted
`AGRU_M12C_AGENT_IMAGE`: 12 runs, 129 assertions, 6 errors; not control evidence.

### Sequential setup correction and revalidation

Historical binary constraint was inspected: setup requires absolute path and
exact `opencode v2.3.0`. The explicitly authorized installed binary satisfies it.

```sh
AGRU_OPENCODE_BOUNDARY=1 AGRU_OPENCODE_BOUNDARY_BINARY=/Users/vladimirkasterin/.opencode/bin/opencode mise exec -- bundle exec ruby -Itest test/m12b_provider_boundary_test.rb
AGRU_M12C_AGENT_IMAGE="$I" AGRU_M12C_AUX_CALIBRATION=1 mise exec -- bundle exec ruby -Itest test/m12c_auxiliary_calibration_test.rb
AGRU_M12C_AGENT_IMAGE="$I" AGRU_M12CS2_PARITY=1 AGRU_M12CS2_EVIDENCE_ROOT=/Users/vladimirkasterin/ruby/agru/docs/evidence/research-security-2026-11-16/parity-revalidation mise exec -- bundle exec ruby -Itest test/m12cs2_offline_parity_test.rb
```

- `provider-boundary-installed.log`: **24 runs, 154 assertions, no failures/errors/skips**.
  These are controlled loopback probes, not paid calls or Docker isolation proof.
- `auxiliary-isolated.log`: **1 run, 4 assertions, no failures/errors/skips** in
  1.63 seconds. The earlier timeout was not reproduced in isolation. Source
  inspection shows the test runs offline `--standalone mcp list`, expects no
  servers and absence of startup sentinels; it is explicitly not a positive
  MCP-startup control. No production timeout was relaxed. Contention is plausible,
  not a proven root cause; retain the failed log as timing-flake evidence.
- Repeating the combined installed command produced
  `installed-controls-revalidated.log`: **12 runs, 266 assertions, 1 error**.
  This time the error was setup, `KeyError: key not found: "AGRU_M12CS2_EVIDENCE_ROOT"`;
  auxiliary completed. Explicit parity output root fixes that setup omission.
- `parity-isolated.log`: **1 run, 55 assertions, no failures/errors/skips**.
  New parity evidence is under `parity-revalidation/`. The test reads existing
  `.agru/nl2repo` benchmark assets by default, but the new run state is outside
  `.agru`. This is fixture parity, not model-capability evidence.

All rerun commands above ran sequentially. Initial errors remain recorded but
are superseded for individual-control verification by these successful runs;
there is no claim that the earlier combined invocation passed.

## Final review update

Full regression supplied by parent: `regression-final.log` in the evidence
directory records **934 runs, 5596 assertions, 0 failures/errors, 74 skips**.
Parent also reports final smoke passed (`smoke-final.log`) and
`openspec validate m11-benchmark-infrastructure --strict` valid. These are
integration/schema checks, not additional containment controls.
This does not turn skipped controls into passes. The reviewer independently ran:

```sh
node --test test/provider_relay_test.cjs
AGRU_M12D_TRANSPORT_TEST=1 mise exec -- bundle exec ruby -Itest test/m12d_installed_transport_test.rb
mise exec -- bundle exec ruby -Itest -e 'require_relative "test/simulated_provider_test"; require_relative "test/authorized_provider_docker_test"' -- --verbose
AGRU_M12D_TRANSPORT_TEST=1 AGRU_AUTHORIZED_PROVIDER_DOCKER=1 mise exec -- bundle exec ruby -Itest -e 'require_relative "test/simulated_provider_test"; require_relative "test/authorized_provider_docker_test"'
```

Respective logs: `relay-final-review.log` (**4 Node tests pass**, no skips),
`installed-transport-final-review.log` (**1 run, 20 assertions, all pass**),
`new-default-skips.log` (**3 runs, 1 assertion, 2 skips**) and
`new-controls-enabled.log` (**3 runs, 17 assertions, all pass**).
The two added default skips are exactly
`SimulatedProviderTest#test_offline_https_exchange_binds_caller_identity`
(`AGRU_M12D_TRANSPORT_TEST`) and
`AuthorizedProviderDockerTest#test_actual_relay_lifecycle_without_provider_requests`
(`AGRU_AUTHORIZED_PROVIDER_DOCKER`). Both are offline Docker controls, now passed
with explicit opt-in. The authorized lifecycle uses a dummy credential and
`https://provider.invalid`, sends no provider request, and is not live acceptance.

### Security control matrix

PASS below means the named bounded test passed, not exhaustive assurance.

Additional reviewer-owned adversarial test:
`mise exec -- bundle exec ruby -Itest test/research_adversarial_controls_test.rb`
passed **1 run / 7 assertions / no failures/errors/skips**, recorded in
`adversarial-upstream-final.log`. The Ruby test also executes Node assertions for
three loopback HTTPS scenarios: valid usage followed by missing `[DONE]`, an
unterminated frame over 1 MiB, and an upstream that never responds. It requires
one attributable error record per exchange, incomplete accounting and absence
of the synthetic credential in records. Errors are respectively
`upstream_protocol`, `response_frame_size`, and `request_timeout`. No paid calls.
Initial harness attempts had a wrong cleanup method and hung in cleanup; retained
`adversarial-upstream.log` is failed harness evidence, not a passing control.
The corrected harness uses `cancelUpstream` and a ten-second watchdog. It uses
`AGRU_RESEARCH_NODE` when set, otherwise Homebrew Node if present or PATH Node.

| Control | Actual evidence | Status / limitation |
|---|---|---|
| Host files/env/private layout and Docker socket denial | `sandbox-controls-pinned.log`, SandboxBoundaryTest and M12cs3HostEscapeTest | PASS; not kernel escape proof |
| Non-root, caps, no-new-privileges, rootfs, direct network denial | `sandbox-controls-pinned.log`; installed transport negative sockets | PASS bounded container probes |
| PID limits, timeout, cancellation and writer quiescence | SandboxBoundaryTest, SandboxSupervisorTest, M12cSandboxLifecycleTest in pinned log | PASS; inspect limits are not exhaustive exhaustion attacks |
| Export traversal, special entries, size, symlink races and permission preservation | SandboxExportMetadataTest, M12cs2IntegratedAdversarialTest in pinned log | PASS bounded adversarial fixtures |
| Installed hooks/config/credential/dispatch negative controls | `provider-boundary-installed.log` | PASS 24 historical version-frozen probes; host calibration only |
| LSP/plugin negative and positive calibration | `installed-controls-revalidated.log` | PASS individual controls; whole invocation had parity setup error |
| Auxiliary MCP diagnostic | `auxiliary-isolated.log` | PASS diagnostic only; positive MCP startup NOT_TESTED |
| Relay method/path/model/inference allowlist and mandatory configuration | `relay-final-review.log` configuration case; installed transport log | PASS tested contract; arbitrary upstream behavior not implied |
| Upload admission bounds, deadline, reusable slots | `relay-final-review.log`, unfinished uploads case | PASS |
| Cancellation during unfinished upload and closed admission | `relay-final-review.log`, cancellation case | PASS |
| HTTPS/TLS validation, redirects, CR-framed SSE | `relay-final-review.log`, offline HTTPS case | PASS local controlled HTTPS; not full SSE fuzzing |
| Truncated streaming response, oversized incomplete frame, stalled upstream | `adversarial-upstream-final.log`, ResearchAdversarialControlsTest | PASS offline adversaries; no complete accounting promoted from partial usage; synthetic credential absent from error records |
| Rejected-request attribution without credentials | `relay-final-review.log`, configuration/attribution case | PASS |
| Caller identity propagation through reusable simulated provider | `new-controls-enabled.log`, SimulatedProviderTest | PASS synthetic exchange |
| Authorized production launcher Docker lifecycle and solver UID socket access | `authorized-socket-enabled-revalidated.log`, AuthorizedProviderDockerTest | PASS 1 run / 6 assertions / zero skips; UID 65534 connects to mode-0600 socket and sends a locally rejected request; no upstream inference |
| Real upstream credential isolation under inference, served identity and actual billing | None (no paid calls authorized) | NOT_TESTED |
| Durable local cross-process budget reservations | Commit `0e27abb`, `test/provider_budget_ledger_test.rb`; parent reports combined budget tests 10 runs / 43 assertions passing | PASS reported local tests: fork contention admits exactly one of four processes, reopen rejects cell/attempt reuse and changed expiry/corruption, expiry fails closed. Full-envelope reservations have no refund path; not external account charging proof |
| Actual upstream retry/restart charging and account-wide reconciliation | No external calls | NOT_TESTED; local durable reservations do not attest external invoices or other clients |
| CPU/memory/disk exhaustion resistance, malicious daemon/kernel escape | No comprehensive attack evidence | NOT_TESTED beyond bounded limits/PID/export probes |
| Public-source LSP provenance refresh | Default network-gated source evidence test | NOT_TESTED intentionally offline |

Highest-priority untested items: real-upstream credential/billing/identity
acceptance (requires separate explicit authorization), end-to-end external
retry/restart charging and reconciliation, and positive MCP startup if startup
enforcement is a required claim. Durable local reservation behavior is now
tested, not an open missing control. The isolated MCP 1-run/4-assertion pass is
explicitly diagnostic: it asserts `No MCP servers configured` and absence of
`MCP_STARTED` and `PLUGIN_STARTED`; it cannot prove positive startup. Broader
exhaustion and SSE fuzzing remain assurance limits.

## Every default skip classified

```sh
mise exec -- bundle exec ruby -Itest -e 'Dir["test/**/*test.rb"].select { |f| File.read(f).match?(/\bskip[ (]/) }.each { |f| require_relative f }' -- --verbose
```

`default-skip-inventory.log`: **112 runs, 227 assertions, 0 failures/errors,
72 skips**. This deliberately runs files containing skip sites, not the full
regression suite owned by the parent. The log preserves each skipped method.

| Class | Skips | Relevance and explicit rerun status |
|---|---:|---|
| M12bProviderBoundaryTest | 24 | Host installed hooks/config/credential/dispatch calibration, not Docker containment proof; all 24 passed with explicit installed binary. |
| SandboxBoundaryTest | 8 | Core sandbox controls; ran successfully with pinned image. |
| SandboxSupervisorTest | 9 | Quiescence/provisioning/export; ran successfully. |
| M12cs2IntegratedAdversarialTest | 9 | Integrated export adversaries; ran successfully. |
| M12cSandboxLifecycleTest | 6 | Cancellation/deadline/disappearance/loader boundary; ran successfully. |
| SandboxExportMetadataTest | 1 | Installed permission-preserving export; ran successfully. |
| M12cs3HostEscapeTest | 1 | Installed host escape probe; ran successfully. |
| M12cPrivateCleanupTest | 2 | Private cleanup; completed in installed group. |
| M12cInstalledNegativeTest | 2 | Installed negative controls; completed in installed group. |
| M12cPhysicalHostBoundaryTest | 1 | macOS physical-host positive/negative calibration; completed. |
| M12cMockRelayTest | 1 | Mock socket/relay acceptance; completed. |
| M12cSandboxOpenCodeAcceptanceTest | 1 | Installed shell/native-read boundary; completed. |
| M12cs2OfflineParityTest | 1 | Offline scientific parity, not standalone security proof; completed. |
| M12cs3LspFixtureTest | 1 | LSP fixture calibration; completed. |
| M12cs3LspInstalledTest | 1 | Installed LSP calibration; completed. |
| M12cs3PluginCalibrationTest | 1 | Plugin calibration; completed. |
| M12cAuxiliaryCalibrationTest | 1 | MCP diagnostic, not startup positive proof; isolated rerun passed after initial timeout. |
| M12cs3LspSourceEvidenceTest | 1 | Public-source network provenance, not runtime enforcement; intentionally not run offline. |
| M12dInstalledTransportTest | 1 | Current provider-relay installed boundary; passed explicit rerun. |

Provider historical probe attempted with
`AGRU_OPENCODE_BOUNDARY=1 mise exec -- bundle exec ruby -Itest test/m12b_provider_boundary_test.rb`:
`provider-boundary.log`, **24 runs, 0 assertions, 24 errors**:
`KeyError: key not found: "AGRU_OPENCODE_BOUNDARY_BINARY"`. No binary was guessed
and was superseded by the explicit installed-binary successful rerun above.

## Remaining gaps and limits

- Upload deadline/cancellation, CR-framed SSE, mandatory inference configuration
  and bounded admission now have independently rerun Node evidence (four passing
  tests); installed transport also passed again. Earlier relay gaps are historical,
  not current defect claims. The matrix above states remaining assurance limits;
  these tests do not imply complete production-provider acceptance.
- No paid upstream, authentic served-model identity, complete cost accounting,
  or credential-bearing live launch was exercised. Fixture secrets are synthetic.
- No kernel/container escape proof, hostile Docker daemon defense or formal
  isolation guarantee. Docker Desktop containment and directory separation must
  not be confused with a general security sandbox.
- This is concurrent shared-repository evidence, not an immutable commit attestation.
  No full-suite/lint result is inferred from these targeted commands.
- Graph project `Users-vladimirkasterin-ruby-agru`, generation
  `2026-11-16T06:51:20Z`, was consulted. Coverage for the eight initial transport,
  sandbox and fixture paths reported `no_recorded_issue`/`metadata_match`;
  best-effort only. Commands and current source were used for actual verdicts.
