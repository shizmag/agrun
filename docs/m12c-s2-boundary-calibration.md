# S2 physical-host boundary calibration

Run explicitly, with no provider credentials or external traffic:

```sh
AGRU_M12C_HOST_BOUNDARY=1 AGRU_M12C_AGENT_IMAGE=sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1 mise exec -- ruby -Itest test/m12c_physical_host_boundary_test.rb
```

The test uses a real TCP listener in the macOS Ruby process, not a container
canary called a host listener. A bridge-network Node container must receive its
synthetic response through `host.docker.internal` before the negative control is
meaningful. The same Node probe under `SandboxRunner` must read an explicitly
submitted workspace file, fail to reach that listener, fail to see an unsubmitted
synthetic host file, and fail to see `/var/run/docker.sock`. Listener connection
counts must remain unchanged after the negative control. Docker inspection must
show `NetworkMode=none`, and cleanup must be confirmed.

Observed on macOS with Docker 29.8.2: **1 run, 12 assertions, 0 failures,
0 errors, 0 skips**. Standard Ruby passes for the added test. Node image:
`node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20`.

This is process/network evidence, not accepted artifact evidence. At the time of
the run, the probe exited zero but the runner returned `blocked` with
`writer_quiescence_unsupported: tmpfs archive collected before container pause; no accepted export`.
The test deliberately does not turn that into a successful export claim.

## Limits and remaining acceptance work

These finite controls do not prove general sandbox security. They do not yet
exercise injected provider redirects, installed OpenCode native-subagent host
reads, or malicious plugin/MCP/LSP/auxiliary configurations. They do not establish
non-disclosure through every path, arbitrary host service denial, IPv6 denial,
kernel isolation, or protection from a compromised Docker daemon. Existing
container-only TCP/UDP controls are distinct from this physical-host calibration.
No production files were changed for this test.

## Installed negative acceptance follow-up

`test/m12c_installed_negative_test.rb` adds explicitly opted-in installed-binary
controls using `AGRU_M12C_INSTALLED_NEGATIVE=1` and `AGRU_M12C_AGENT_IMAGE`.
Distinct mock scripts `native-host-negative` and `redirect-negative` preserve the
existing script allowlist entries, including `s2-parity`.

The native script requests a real native child, then an absolute unsubmitted host
read followed by `/workspace/README.md`. Assertions require observed child tool
results, a denied/not-found host read, visible workspace content, completed child,
and no unique synthetic host value in the audit/output. Submitted project config
also contains plugin/MCP/LSP sentinels. Absence of their output alone is not proof
that each extension startup path was positively calibrated.

The redirect script injects a 302 pointing at an actual macOS host listener after
a bridge-network positive connection. Assertions require injection audit, relay
redirect denial, and no additional listener connections.

First actual installed runs: **2 runs, 7 assertions, 2 failures**. Neither reached
OpenCode: the supervisor runner rejected effective policy before starting the
container. Docker 29.8.2 inspection reports `CapAdd` as
`["CAP_KILL","CAP_SETGID","CAP_SETUID"]`; the in-progress runner expected
`["KILL","SETGID","SETUID"]`. Cleanup was confirmed. These installed scenarios
are therefore pending, not passing isolation evidence. JavaScript syntax checking
and Standard Ruby checks pass. No production inspection predicate was weakened.

After parent inspection normalization: the exact installed command below passes
**2 runs, 26 assertions, 0 failures, 0 errors, 0 skips**:

```sh
AGRU_M12C_INSTALLED_NEGATIVE=1 AGRU_M12C_AGENT_IMAGE=sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1 mise exec -- ruby -Itest test/m12c_installed_negative_test.rb
```

The native child performs both real reads, returns `File not found` for the host
path and `VISIBLE_NATIVE_POSITIVE_12C` for the workspace, then reaches its final
response; the parent emits background completion. The unique host canary remains
absent from audit/stdout/stderr. Its run now requires successful accepted export.
The sentinel script is positively executed in a separate network-none container
and creates its marker; the marker is removed before submission and absent from
the accepted sandbox export. This calibrates script execution/output, but does
not separately establish that each installed plugin/MCP/LSP mechanism would start
under an enabled configuration. That stronger per-mechanism positive control
remains a gap. The negative does exercise actual installed OpenCode with hostile
submitted configuration and frozen global/project-disable settings.

The redirect run records `injected_redirect:true` and relay
`decision:deny,reason:redirect`; the actual host listener stays at its single
positive-control connection. It may time out while OpenCode retries rejected
provider requests; this is no-follow/no-egress evidence, not a successful model
completion. Latest physical-host rerun with the Python-equipped agent image:
**1 run, 12 assertions, 0 failures, 0 errors, 0 skips**.

### Auxiliary mechanism follow-up

Enabled installed-startup control (same image, runner, mock relay and workspace;
project-disable flag removed and global plugin/MCP/LSP overrides/policies removed):

```sh
AGRU_M12C_AUX_ENABLED_CONTROL=1 AGRU_M12C_INSTALLED_NEGATIVE=1 AGRU_M12C_AGENT_IMAGE=sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1 mise exec -- ruby -Itest test/m12c_installed_negative_test.rb -n /native/
```

Actual result: **1 run, 17 assertions, 0 failures, 0 errors, 0 skips**;
diagnostic `AUX_CALIBRATION MCP=true LSP=false PLUGIN=false`.
MCP now uses documented V2 `mcp.servers` syntax. Its distinct sentinel starts
through installed OpenCode with configuration enabled, and the frozen negative
requires its marker absent. This closes MCP startup calibration specifically.

Plugin `file:///workspace/plugin.mjs` with module-side-effect sentinel did not
start in the enabled control. Custom LSP `.md` sentinel did not start during
native reads either. Neither mechanism is positively calibrated; these exact
fixtures are unsupported/untriggered in the exercised installed startup path,
not proof that OpenCode generally lacks plugin/LSP support. Frozen configuration
still fails closed in these probes, but plugin/LSP isolation claims remain
explicitly unverified. A `mcp list` diagnostic alone reports
`No MCP servers configured` even when `debug config` shows the accepted server
document, so it is recorded in `test/m12c_auxiliary_calibration_test.rb` as a
non-startup diagnostic, not a security positive control.
