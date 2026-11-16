# S3 independent installed-security regression

## Final disposition (2026-11-15)

**Whole opt-in suite passed: 905 runs, 6146 assertions, zero failures/errors,
one explicitly classified skip, 455.009238 seconds.**
Log: `.agru/m12cs3-security-final-whole.log`.

The sole remaining optional opt-in is
`M12cs3LspSourceEvidenceTest#test_public_version_source_evidence`, guarded by
`AGRU_M12CS3_LSP_SOURCE=1` (`test/m12cs3_lsp_source_evidence_test.rb:7`).
This verifies public immutable GitHub source using HTTPS, unlike the offline
installed-agent tests. It was then run explicitly:
`AGRU_M12CS3_LSP_SOURCE=1 mise exec -- bundle exec ruby -Itest test/m12cs3_lsp_source_evidence_test.rb --verbose`:
**one run, nine assertions, zero failures/errors/skips**, 4.479070 seconds.
Log: `.agru/m12cs3-security-source-final.log`. Thus no optional security
environment remains unconfigured/unclassified across the final whole run and
this separate public-source verification. The whole-suite task did not forward
`--verbose` to Minitest, so the skip identification also uses the complete current
source opt-in inventory, not an invented verbose skip line.

Parent-coordinated final plugin calibration: **1 run / 64 assertions passed**,
including global effective XDG configuration verification. LSP is approved
**known-version N/A**, not active-LSP suppression PASS (installed contract 1/26,
public-source 1/9, JSON-RPC fixture 1/6). Parent reports E review closed,
conditional source checks 7/25, dirty-create/live mutation checks killed, and
redundant explicit stale-digest guard survived and documented. Parent also
reports final lint/smoke/benchmark/OpenSpec and legacy four-architecture
acceptances passed; these are parent evidence, not this worker's independent
commands. Earlier failures below are retained as historical failed attempts.

Owned-file inventory ready for parent commit:
`test/m12c_sandbox_opencode_acceptance_test.rb`,
`test/m12_experiment_execution_test.rb`,
`script/m12cs3_plugin_control.rb`, `script/m12cs3_sqlite_fork_probe.rb`, and
`docs/m12cs3-security-independent.md`. No production changes, timeout increases,
warning suppression, paid calls, commits or pushes. Work complete; no further
edits planned.

Image used without pulling:
`sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`.
All provider traffic was deterministic local mock relay traffic; no paid calls.
These are infrastructure/security observations, not model capability evidence.

## Recorded commands and results

Prefix the test commands below with `env AGRU_M12C_AGENT_IMAGE=<digest above>`.
Logs, including failed attempts, remain ignored under `.agru/m12cs3-security-*`.

* `AGRU_S2_EXPORT_DOCKER=1 AGRU_SUPERVISOR_DOCKER_TEST=1 AGRU_SANDBOX_DOCKER_TEST=1 AGRU_M12C_HOST_BOUNDARY=1 AGRU_M12C_INSTALLED_NEGATIVE=1 AGRU_M12C_AUX_CALIBRATION=1 AGRU_M12C_OPENCODE_ACCEPTANCE=1 mise run test`: 892 runs, 5703 assertions, two failures, zero errors, 34 skips. Log: `.agru/m12cs3-security-all-optins.log`.
  Failures were the truncated-JSON timeout diagnostic expectation and the old installed acceptance expectation of blocked export (actual success). The latter stops before exercising all architectures.
* `AGRU_M12CS2_PARITY=1 AGRU_M12CS2_EVIDENCE_ROOT=.agru/m12cs3-security-parity-evidence mise exec -- bundle exec ruby -Itest test/m12cs2_offline_parity_test.rb`: one run, 18 assertions, zero failures/errors/skips, 84.525 seconds. This exercises all three architectures with offline fixtures and actual installed OpenCode. Log: `.agru/m12cs3-security-parity.log`.
* `AGRU_M12C_INSTALLED_NEGATIVE=1 AGRU_M12C_AUX_ENABLED_CONTROL=1 mise exec -- bundle exec ruby -Itest test/m12c_installed_negative_test.rb --name test_installed_native_child_cannot_read_unsubmitted_host_canary`: one run, 17 assertions, pass. Existing positive control reports MCP=true, LSP=false, PLUGIN=false. It does not establish LSP or plugin suppression.
* `AGRU_M12C_INSTALLED_NEGATIVE=1 AGRU_M12C_AUX_ENABLED_CONTROL=1 mise exec -- bundle exec ruby script/m12cs3_plugin_control.rb`: one run, 17 assertions, pass; independently installed local plugin setup sentinel observed, MCP=true. The script uses the V2 auto-loaded `.opencode/plugins/security-control/index.ts` layout. Log: `.agru/m12cs3-security-plugin-enabled.log`.
* Corresponding plugin-disabled run omits `AGRU_M12C_AUX_ENABLED_CONTROL`: one run, 19 assertions, zero failures/errors/skips; sentinel absent, status success. Log `.agru/m12cs3-security-plugin-disabled.log`. This completes the plugin enabled/disabled A/B control.

The complete opt-in rerun additionally enables `AGRU_SANDBOX_DOCKER_CANARY=1 AGRU_M12CS2_DOCKER_ADVERSARIAL=1 AGRU_M12CS2_PARITY=1`; its log is `.agru/m12cs3-security-complete-optins.log`. Result: 901 runs, 5669 assertions, two failures, one error, 35 skips, 225.171441 seconds. Failures: stale acceptance blocked/success expectation and `M12ExperimentExecutionTest#test_four_architectures_persist_actual_runtime_attempts_in_shared_store` report-content assertion (`test/m12_experiment_execution_test.rb:75`). Error: missing `AGRU_M12CS2_EVIDENCE_ROOT` for parity, a command configuration mistake, not a product defect. The separately configured parity command above passed. Suite source changed concurrently (run count changed), so these are not identical-snapshot comparisons. Some advertised opt-in names have no current source match; the current source is authoritative.

## SQLite fork warning investigation

`mise exec -- bundle exec ruby script/m12cs3_sqlite_fork_probe.rb > .agru/m12cs3-security-sqlite-fork.log 2>&1` preserves the actual warning. Thirty forks each closed the inherited writable connection **in the child**, while the parent's connection stayed open. Sixty before/after inserts survived close/reopen and `PRAGMA integrity_check` returned `ok`.

Source: `lib/agent_runtime/execution/sandbox_runner.rb:506` forks for descriptor-relative directory enumeration; child performs directory listing/Marshal output, not store writes. `lib/agent_runtime/store.rb:11` opens the writable metadata database. sqlite3 2.10.2 `lib/sqlite3/fork_safety.rb:9` calls `ForkSafety.discard` only when `_fork` returns zero; lines 39–49 warn and close inherited writable child connections. The parent is unaffected by that close.

This is evidence of the gem's protective child-close behavior and successful parent persistence in this bounded probe, **not** proof that arbitrary concurrent fork/database use is safe. Programs must not reuse inherited SQLite handles. Warnings were not silenced; no production fix proposed without a demonstrated bug.

## Limitations and unresolved checks

### Latest confirmation / parent-coordinated disposition

* Grouped actual-security confirmation passed **62 runs / 454 assertions / zero failures, errors or skips**, 92.365226 seconds: `.agru/m12cs3-security-targeted-confirm.log`. Earlier timeout remains recorded, not discarded.
* Parent authorized the narrow report-oracle correction. The test now seeds and verifies exact duration `0.002598999999463558`, retains parsed cost/usage and invocation-count checks, and rejects standalone numeric sentinel `999999` using numeric-token boundaries rather than matching arbitrary decimal digits. Whole file passes **three runs / 107 assertions**, no skips: `.agru/m12cs3-security-report-fixed.log`. No production code changed.
* Parent reports plugin owner corrected malformed-module diagnostic capture with `--print-logs`: **one run / 57 assertions passed**. This supersedes that arm's earlier diagnostic-capture failure, not the preserved log.
* Parent reports LSP disposition is **N/A for known-version contract**, not active LSP PASS: installed/source/protocol checks are respectively 1/26, 1/9 and 1/6. Independent earlier installed-positive failure remains evidence of unavailable initialization, not suppression.
* Final whole-suite opt-in run is recorded in `.agru/m12cs3-security-final-whole.log`; it includes actual sandbox Python/clean image variables, provider boundary binary, mock relay, native-subagent acceptance, current S3 calibrations, and parity with fresh evidence root `.agru/m12cs3-security-final-parity`. Its final result must be checked separately; no inferred pass.

### Follow-up evidence

The stale S1 acceptance oracle was reproduced in isolation before changing it (`.agru/m12cs3-security-acceptance-before.log`). With parent authorization, `test/m12c_sandbox_opencode_acceptance_test.rb` now requires confirmed container cleanup, a well-formed export digest, exact exported original README and shell-generated bytes, and unchanged source input (no generated marker leaking back). Native read/shell and optional subagent completion assertions remain intact. The native-subagent run passed all three architectures: one run, 39 assertions, no failures/errors/skips, 38.336487 seconds (`.agru/m12cs3-security-acceptance-after.log`). This is not a blind blocked-to-success substitution.

The shared-store report failure was isolated: one run, 97 assertions, pass (`.agru/m12cs3-security-report-isolated.log`). The failed full-suite output contains legitimate `agent_duration: 0.002598999999463558`; the arbitrary string oracle `refute_includes output, "999999"` rejects those timing digits. This establishes a false-positive oracle, not shared-store contamination. No existing report test or production code changed; suggested narrow correction is structured forged-usage validation rather than unrestricted digit-substring searching.

The initial parity result really was 18 assertions in its saved log. It used the same specification and all three architectures, but the current test has additional role/output assertions. A new current-source run uses fresh destination `.agru/m12cs3-security-parity-verified`; do not equate the older assertion count with the stronger current test.

An explicit skip-environment inventory is saved in `.agru/m12cs3-security-skip-inventory.log`. The earlier full runs missed `AGRU_SANDBOX_TEST_IMAGE` and `AGRU_SANDBOX_PYTHON_IMAGE`, as well as provider-boundary/mock and newly added S3 calibration opt-ins. Targeted reruns use the pinned digest for both sandbox image variables and verbose output so remaining skips are visible.

Current-source parity passed one run / **55 assertions**, zero failures/errors/skips, 94.347171 seconds (`.agru/m12cs3-security-parity-verified.log`). The final acceptance adds manifest/digest recomputation equality and passed one run / **42 assertions**, zero failures/errors/skips (`.agru/m12cs3-security-acceptance-final.log`).

Targeted actual security suites (`sandbox_boundary`, `sandbox_supervisor`, `sandbox_export_metadata`, `m12c_private_cleanup`, `m12c_sandbox_lifecycle`, `m12cs2_integrated_adversarial`, `m12c_physical_host_boundary`, `m12c_installed_negative`, `m12cs3_host_escape`) with export/supervisor/host/negative opt-ins and both sandbox image variables: **62 runs, 452 assertions, one failure, zero errors/skips**, 153.352264 seconds (`.agru/m12cs3-security-targeted.log`). The only failure was the auxiliary Python host-write probe's 20-second timeout; cleanup was confirmed. Its isolated rerun passed one run / three assertions in 1.468091 seconds (`.agru/m12cs3-security-host-escape-isolated.log`). No timeout adjustment made. A fresh grouped confirmation is recorded separately in `.agru/m12cs3-security-targeted-confirm.log`.

The verbose targeted log establishes passing actual shell and Python host-read denial, physical macOS host-network negative with positive reachability control, installed redirect/native-child negative, malicious link/socket/export rejection, writer quiescence, resource quota, lifecycle/cancellation/timeout cleanup, immutable mode preservation and metadata checks. It has **no skips**; do not silently classify the one timeout as passed merely because the isolated rerun passed.

Host installed OpenCode loopback/provider-boundary suite: `AGRU_OPENCODE_BOUNDARY=1 AGRU_OPENCODE_BOUNDARY_BINARY=/Users/vladimirkasterin/.opencode/bin/opencode mise exec -- bundle exec ruby -Itest test/m12b_provider_boundary_test.rb --verbose`: **24 runs, 154 assertions**, zero failures/errors/skips, 74.152223 seconds (`.agru/m12cs3-security-provider-boundary.log`). This uses the installed host binary, distinct from Docker-image observations.

Shared extra calibrations (`AGRU_M12CS3_LSP=1 AGRU_M12CS3_LSP_INSTALLED=1 AGRU_M12CS3_PLUGIN_CALIBRATION=1 AGRU_M12C_MOCK_DOCKER=1`): four runs / 63 assertions / two failures / no errors/skips (`.agru/m12cs3-security-extra-calibrations.log`). Mock-relay and framed LSP fixture passed. Installed LSP positive failed (empty initialization transcript). Plugin malformed-module arm failed its diagnostic regex despite a successful installed read response; this is distinct from the independently successful plugin A/B setup sentinel. Coordinate fixes with those files' owners, not a suppression claim.

* LSP enabled control did not start. No LSP A/B suppression claim is justified yet; use a genuine LSP-triggering edit/diagnostic action before signoff.
* Guard fixture flake was not reproduced: isolated test passed four runs/ten assertions; eight adapter observations all succeeded (0.080–0.417 seconds). Twenty inherited-environment Ruby startups were 0.072–0.113 seconds; twenty cleared-environment startups were 0.029–0.053 seconds, all successful. No timeout increase or existing-test modification is justified by this evidence.
* Graph project coverage did not include this checkout; source fallback was used, not an assertion of index completeness.
* Negative host read, redirect, mount, traversal, socket, metadata and lifecycle results must be read with the complete opt-in suite's actual failures/skips. Directory separation is not itself a security sandbox.
