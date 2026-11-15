# S3 LSP calibration: fixture ready, exact-version runtime unavailable

This is **not a passing installed-agent calibration**. S2 preserved LSP
configuration but observed no positive launch. Silence in both arms does not
establish suppression.

Under S3 section 6 / criterion 3, **LSP01–LSP05 are N/A for this frozen
version**, not PASS. `sandbox/m12cs3-lsp-unavailability.json` binds the reason to
the image, executable digest, version, immutable source commit, full-source
SHA-256 values and exact line excerpts. Inherited configuration cannot activate
the missing runtime. Plugin auxiliary-boundary tests may establish process
containment separately; they provide no LSP suppression credit.

Independent checks performed after classification:

- `AGRU_M12CS3_LSP_INSTALLED=1`: `test_unavailable_lsp_known_version_contract`
  passed, **1 run / 26 assertions**, verifying actual image binary digest,
  `opencode v2.3.0`, compiled schema marker, absence of `textDocument`, successful
  identical read/write triggers and no server activation in either arm.
- `AGRU_M12CS3_LSP_SOURCE=1`: public source verification passed,
  **1 run / 9 assertions**, checking the version tag commit, four full-source
  digests and exact excerpts. This explicitly opt-in test uses public GitHub
  networking only; ordinary offline tests do not fetch source.
- Local real JSON-RPC fixture: **1 run / 6 assertions**, passing. Its protocol
  validity is distinct from installed runtime availability.

The original failed positive-control run is retained below and in the manifest;
reclassifying applicability does not erase it or convert silence into disablement.

## Frozen diagnostic target

- OpenCode 2.3.0 image:
  `sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`.
- Executable: `/usr/local/bin/opencode`, expected SHA-256
  `5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0`.
- Docker diagnostics used `--pull=never --network=none`.
- Installed `debug --help` exposes agents, config, heap-dump, paths: there is
  no LSP diagnostic subcommand. `api GET /openapi.json` exposes session prompt
  operations but no public LSP operation. A standalone config diagnostic is
  therefore not an established document-operation trigger.

Target-binary embedded source, rather than a V1 schema, supplies this exact
configuration shape (minified identifiers omitted): `Config.LSP.Server` has
`command: string[]`, optional `extensions: string[]`, `disabled: boolean`,
`env: Record<string,string>`, and `initialization: Record<string,unknown>`.
Top-level `lsp` accepts a boolean or a server-name map; map entries may be
`{disabled: true}`. This is schema evidence only, not proof that a configured
server starts. The binary also contains unrelated bundled `lspServers` and
`extensionToLanguage` strings: these must not be mistaken for OpenCode's own
configuration protocol.

## Local protocol fixture

`test/support/m12cs3_lsp_server.cjs` uses Node built-ins only. It speaks real
Content-Length-framed JSON-RPC over stdio, records launch and inbound messages,
answers initialize and hover, publishes a deterministic diagnostic on didOpen,
and handles shutdown/exit. It performs no network calls or package installs.

Run the fixture's protocol check:

```sh
mise exec -- env AGRU_M12CS3_LSP=1 bundle exec ruby -Itest test/m12cs3_lsp_fixture_test.rb
```

Observed: 1 run, 6 assertions, 0 failures/errors/skips. This proves the local
server protocol, **not** installed OpenCode integration or host containment.

## Exact-version trigger investigation

The public `v2.3.0` tag resolves to commit
`a6b15d33daf6ab7d35569f6d711fdb630b9f04e7`. Source was inspected at that immutable
revision, not against current documentation or the V1 implementation:

- `packages/core/src/tool/plugin/edit.ts:254` and
  `packages/core/src/tool/plugin/write.ts:30` both say exactly:
  `// TODO: Add LSP notification and diagnostics after LSP runtime exists.`
- `packages/core/src/file-mutation.ts:138` says exactly:
  `// TODO: Notify LSP and collect diagnostics after LSP runtime exists.`
- `packages/core/src/config/normalize.ts:500-508` accepts and normalizes `lsp`;
  `packages/schema/src/config/lsp.ts` defines the preserved schema. Configuration
  acceptance is therefore compatible with absent execution support.
- A complete tarball scan of `packages/core/src` and `packages/schema/src` for
  case-insensitive `lsp` found normalization/schema and these deferred-integration
  comments, but no LSP runtime implementation. Substring false positives such as
  `colspan`, `installSpec` and `ToolsPlugin` were excluded from that conclusion.

Source permalink:
<https://github.com/anomalyco/opencode/blob/a6b15d33daf6ab7d35569f6d711fdb630b9f04e7/packages/core/src/tool/plugin/edit.ts#L254>.

The frozen binary independently contains the matching `Config.LSP.Server` schema
and no `textDocument`, `OPENCODE_EXPERIMENTAL_LSP`, `EXPERIMENTAL_LSP`, or
`LSP_TOOL` string. `publishDiagnostics` occurrences belong to the separately
bundled Claude-provider schema, not a native OpenCode document trigger. Comments
are stripped from the compiled binary, so their absence there is not evidence.
The public tag is version-correlated source evidence, not a reproducible-build
attestation linking its commit to the executable digest.

This explains why changing `.agru` to a recognized `.py`/`.ts` extension, enabling
permissions, or switching write to native edit cannot supply the missing native
runtime at this source revision. No speculative flag or third-party LSP client
was introduced to manufacture an installed positive. The remaining acceptance
gates below are **blocked**, not passing; completing them needs an explicitly
approved different build with implemented LSP support or another evidenced
native integration in this exact binary.

## Remaining acceptance gates

`test/support/m12cs3_lsp_mock.cjs` is a separately owned loopback-only mock
provider. It supplies streaming chat completions with deterministic native
`read` then `write` tool calls. Actual installed schemas require `path`, not
`file_path`. An initial non-streaming response failed with
`OpenAI Chat stream ended without finish_reason`; the fixture now emits proper
SSE chunks and finish reasons. No shared relay files were modified.

Run the installed gate with:

```sh
mise exec -- env AGRU_M12CS3_LSP_INSTALLED=1 bundle exec ruby -Itest test/m12cs3_lsp_installed_test.rb
```

Observed on the frozen image: **1 run, 6 assertions, 1 failure, 0 errors/skips**.
Both enabled and disabled arms completed native read/write on the matching
`.agru` document. Neither arm produced a launch transcript. The gate fails with
`enabled positive control never initialized; disabled silence is not a PASS`.
The test verifies the executable digest inside each container before invoking
OpenCode. The enabled config is visible in `debug config --standalone`, including
the command, extensions and transcript environment. The provider's advertised
tools include read/edit/write but not an LSP tool. Thus accepted configuration
and successful document writes still do not establish an actual LSP trigger in
this build. LSP01 positive control remains failed; LSP02–05 must not be reported
as validated containment or suppression on that basis.

Hold image, executable digest, workspace, document, mock input, trigger and
observation window constant between enabled/disabled arms. Require initialize,
initialized and a document operation in the enabled transcript; require the same
trigger to succeed and no process launch in the disabled arm. Add extension
mismatch, host/project inheritance with frozen policy, and an actual
process-host canary read-denial check. Neither fixture protocol success nor
directory separation may substitute for those observations. Shutdown handling
is tested locally; graceful shutdown by OpenCode remains unobserved.
