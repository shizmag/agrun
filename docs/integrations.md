# M0 integrations

## Verified local tools and sources

Inspected on 2026-11-14, without sending a model prompt:

| Tool | Installed version | Inspection |
| --- | --- | --- |
| Ruby | 4.0.9 (parent environment) | local executable fixtures use `RbConfig.ruby` |
| OpenCode | 2.3.0 | `opencode --help`, `opencode run --help`, `opencode --version` |
| OpenSpec | 1.16.0 | init/show/validate help; actual init and strict validation |
| Serena | 2.1.0 | version/help, context list, MCP-server help, agent context instructions |

Official sources consulted:
- [OpenCode V2 CLI](https://opencode.ai/docs/cli): automated `run`, default shared service and explicit standalone server.
- [OpenCode API](https://opencode.ai/docs/api): experimental HTTP surface, `/api/session`, `/api/session/{sessionID}/prompt`, event subscriptions.
- [OpenCode JavaScript client](https://opencode.ai/docs/build/client): `@opencode/client`, `OpenCode.make`, `client.session.create`, `client.session.prompt`; live-only event streams.
- [Serena running](https://oraios.github.io/serena/02-usage/020_running.html) and [MCP clients](https://oraios.github.io/serena/02-usage/030_clients.html).

Do not substitute historical `@opencode-ai/sdk` V1 route examples for the current V2 client. The CLI help is authoritative for the installed flags. The public CLI guide does not establish the complete JSON event schema: M0 event decoding is tested with local fixtures, not claimed as live-provider verified.

## Process and shell boundary

`AgentRuntime::Adapters::ProcessRunner#call(argv:, cwd:, timeout:, cancellation: nil, env: {})` uses direct `Process.spawn`, a POSIX process group, closed stdin and concurrent stdout/stderr drainage. It retains at most 1 MiB per stream, uses a monotonic deadline and sends TERM then KILL after 200 ms. Missing executables return failure. Cancellation before execution starts does not spawn a process. It never interpolates shell syntax.

Shell executor configuration:

```ruby
{"argv" => ["ruby", "-e", "puts 'local task'"], "env" => {"EXAMPLE" => "value"}}
```

Shell returns stdout, stderr and exit_code outputs. To deliberately use shell syntax, explicitly choose an interpreter argv such as `["sh", "-c", "..."]`; this is trusted code execution, **not a sandbox**. Environment variables are inherited with explicit overrides. Existing provider credentials may therefore be visible to a live executable; logs can contain secrets and require access controls. Process groups do not contain a malicious process that creates a new session. Import path checks do not provide adversarial race-free filesystem isolation.

Both Shell and OpenCode use decoded input `repository` as cwd when present, otherwise the attempt workspace. The runtime supplies an isolated repository copy; the adapters never modify the original immutable artifact. OpenCode returns this same repository path for artifact ingestion.

OpenCode also returns a real Git binary-capable patch against the pre-execution snapshot, including untracked additions and deletions. `Adapters::GitPatch#capture` uses temporary private Git metadata instead of changing the working repository's index or HEAD. Git must be installed; capture rejects patches at the 1 MiB process-output limit rather than silently submitting truncated diffs. Snapshot operations each have a 10-second limit outside the provider execution timeout. Result model is event-observed only (nil when absent); `outputs["requested_model"]` retains the requested model separately. Explicit permission/approval error events are blocked; no blanket approval flag is passed.

## OpenCode CLI: blocked by default

```ruby
{"live" => true, "prompt" => "Review the local changes", "model" => "provider/model"}
```

Only explicit config `live: true` (JSON boolean) or trusted constructor `live: true` enables invocation. Arguments are `opencode run --format json --standalone`, optional model/agent/session, `--`, then a single literal prompt. No `--auto` flag is supplied. Permission prompts are not auto-approved and may cause a timeout; standalone execution avoids reusing a background session server but still loads installed user/project configuration and may use configured MCP/tools. Review those configurations before enabling live execution. No live or paid provider calls were made during implementation.

The adapter decodes JSON lines with text and step_finish events. It extracts sessionID, observed step token dictionaries and costs. Missing usage/cost stays nil (unknown), never fabricated zero. A zero-exit process without a finish event or with malformed JSON is unknown, not success. Process timeout/cancellation remain timeout/cancelled even when JSON is truncated. Outputs include text and the workspace repository path, not an invented content artifact; the runtime owns artifact ingestion. This does not prove every task objective was satisfied.

HTTP transport is **deferred**, not silently emulated. Before adding it, define server lifecycle/authentication, session ownership, event correlation and reconnect behavior, permission interaction, cancellation and cost aggregation against the experimental V2 contract. The JavaScript client is a documented future integration option, not a Ruby dependency.

## OpenSpec: initialized and optional

`Integrations::OpenSpec` also exposes `status(change:)`,
`instructions(change:, artifact:)`, and `import_artifacts(change:, store:, run_id:)`.
The last method reads existing change files into immutable text artifacts; it
does not author specifications. Run the no-model example with
`mise exec -- ruby integrations/openspec/import_example.rb`; its small program
binds imported specification text as a typed input.

Initialized with current CLI `openspec init --tools none --no-animation .`; this creates schema configuration without generating unrelated agent skills. Canonical M0 requirements live in `openspec/specs/runtime-execution/spec.md`; `openspec/changes/m0-runtime/` contains proposal, design, tasks and deltas. Incomplete core/live/deferred tasks remain unchecked.

```ruby
require "agent_runtime/integrations/openspec"
specs = AgentRuntime::Integrations::OpenSpec.new(workspace: Dir.pwd)
specs.inspect                         # openspec list --specs --json
specs.inspect(item: "runtime-execution")
specs.validate                        # strict --all JSON, no model
specs.import(source: "/path/spec.md", name: "local-capability")
```

Import accepts simple names, copies only a regular source file, refuses existing destination directories and rejects direct destination symlinks. It does not automatically rewrite or validate user text. CLI inspection/validation return process fields plus decoded data. No installation, initialization, spec mutation or external command occurs when the optional Ruby file is required. Telemetry is disabled for adapter subprocesses through `OPENSPEC_TELEMETRY=0` and `DO_NOT_TRACK=1`.

## Serena: explicit opt-in, baseline disabled

Serena is a semantic MCP tool integration, not an executor or an automatic runtime dependency. `serena context list` on 2.1.0 includes **agent**, **ide**, **desktop-app**, codex and other contexts; there is **no built-in opencode context**. For an explicit OpenCode MCP setup, choose a real installed context, for example:

```sh
serena start-mcp-server --context agent --project /absolute/path/to/repository --transport stdio
```

Configure that command in the user's OpenCode MCP configuration only after user opt-in. `agent` is verified installed and its printed instructions state “You are running in an agent context”; desktop-app is the CLI default, not an OpenCode-specific profile. No Serena MCP server or project was auto-initialized here. The MCP `initial_instructions` tool was unavailable in the exposed catalog, so it was not fabricated or claimed as called; local `serena print-system-prompt --only-instructions --context agent` successfully printed the instructions as a documented CLI fallback.

**All M0 baseline benchmarks and tests disable Serena.** A later explicit A/B evaluation must record context, language-server/backend, project configuration, added tools, setup/cold-start time, provider/model, prompt, tokens/cost and task outcome separately. Installation alone is not evidence of a speed or quality benefit.

## Offline validation

```sh
bundle exec ruby -Itest test/integrations/adapters_test.rb
openspec validate --all --strict --json --no-interactive
```

Fixtures are temporary local Ruby executables, including a path with spaces. Tests cover literal arguments, exit codes, missing executables, cancellation before/during execution, resistant descendant termination, bounded dual-stream capture, default OpenCode blocking, event decoding, malformed/incomplete/nonzero output, and OpenSpec import/inspection/validation. They require no network, provider account or running OpenCode/Serena server. Live protocol compatibility, real permission interactions and remote API lifecycle are explicitly unverified.
