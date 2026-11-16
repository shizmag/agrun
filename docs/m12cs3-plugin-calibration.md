# S3 installed plugin calibration (mock-only)

Run explicitly; no credentials or paid provider is used:

```sh
AGRU_M12CS3_PLUGIN_CALIBRATION=1 mise exec -- ruby -Itest test/m12cs3_plugin_calibration_test.rb
```

The fixture pins image `sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`
and checks installed `/usr/local/bin/opencode` SHA-256
`5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0` at launch.
Installed version is 2.3.0. Binary strings expose ordered ID/wildcard enablement
directives; direct installed execution confirmed the directory package default
export `{id, async setup(ctx)}` and `ctx.tool.hook("execute.before", callback)`.
No SDK package download is necessary. Current documentation was consulted only
as a hypothesis; the installed executable is the acceptance oracle.

Coverage:

- PL01: generated configuration loads the package, registers the hook, and
  observes a real native `read`; deterministic mock shell writes a checked file.
- PL02: identical image, workspace fixture, input and mock trigger with explicit
  `-agru.calibration.sentinel` suppresses setup/hook, while tools still execute.
- PL03: project and global config sources each get enabled controls; generated
  ID disable overrides the same inherited global/project plugin.
- PL04: malformed module and configured single-file path are invalid enabled
  controls. They do not emit setup evidence despite successful native tool work.
  The malformed case explicitly enables installed server logs and requires a
  plugin/syntax/parse diagnostic; normal JSON run output alone hid this error.
  Their silence must never be interpreted as proof of policy suppression.
- PL05: the loaded plugin cannot read a real, unchanged, unmounted host canary and cannot
  connect to the TEST-NET address `198.51.100.1:80` in network-none execution.
  This is container-boundary evidence, not a JavaScript plugin sandbox claim.

Production negatives separately restore `SandboxOpenCodeLaunch#environment`
unchanged: fresh private XDG/home, project-config disabled, empty plugin list and
the frozen `plugin.use` deny policy. Working project config and auto-discovery
packages inside the workspace produce no sentinel events while read/shell work.
A workspace-contained global-config attack is not mounted as host global config
and is not selected by the production XDG path. A generated-config injection of
the working package also produces no sentinel events while retaining production
policy. Thus `plugins: []` is not assumed to replace inherited arrays: production
is calibrated using its environment isolation plus policy, independently of the
explicit ID-disable positive/negative pair.

The global-isolation case explicitly asserts launch XDG is
`/tmp/agru-home/config`, not the image default `/tmp/config` and not attacker
`/workspace/global`. Inspected mounts must be exactly `/helper.cjs`, `/input`,
`/relay`, `/supervisor.py`, all read-only, with no host-home source or home/config
destination; inspected network mode is `none`. Raw Config.Env is not retained
in the minimized evidence object: SandboxRunner's pre-success inspection validates
all explicit env key/value entries, rejects unexpected entries and duplicate
keys (`lib/agent_runtime/execution/sandbox_runner.rb:389-391`).

Each exported repository tree is removed in an iteration ensure block after
assertions; original workspace and host-canary cleanup belongs to `in_tmp`.

The original S2 single-file `file:///workspace/plugin.mjs` fixture and
`plugin list`/`mcp list` command are not a valid startup or tool-hook positive
control. A configured local package directory is required; actual `run` is used.
The test deliberately changes only generated plugin configuration/policy for
calibration; it does not expand the production launch API or redesign runtime.
The canary is created outside the submitted workspace and its exact host path
is passed to the plugin, without mounting its contents. Its unchanged content is
checked after each execution. Broader host-boundary tests remain a separate gate.
