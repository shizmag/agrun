# Trusted relay inference contract

The relay accepts only chat-completions requests for its frozen model. Trusted
launchers must supply `inference` with all of:

```json
{"max_completion_tokens":32000,"stream":true,"stream_options":{"include_usage":true}}
```

The trusted token ceiling may be an integer from 1 through 32000. Optional
`temperature` must be finite and within 0–2. All configured fields must be
present and structurally equal in every submitted request. Missing fields are
not filled from agent-selected or provider defaults. Temperature omission freezes
the provider default: agents cannot add it. Legacy `max_tokens`, seeds, reasoning
controls, and all other undeclared inference fields are denied. Invalid trusted
configuration fails before the credential is read.

`messages` must be a nonempty array of objects. Messages are task data, not a
place for transport controls; the only top-level task-data fields admitted are
`messages`, `tools`, and `tool_choice`.

Tools are disabled unless the trusted launcher explicitly sets `allowTools:true`.
That opt-in allows dynamic OpenCode function definitions, not arbitrary hosted
provider tools: at most 128 uniquely named functions, ASCII names of 1–64
characters, descriptions at most 32768 characters, object parameter schemas at
most 131072 UTF-8 bytes each, and optional boolean `strict`. Unknown tool/function
keys are denied. The global 1 MiB request limit applies as well. Tool choice is
always automatic: omission uses the chat-completions automatic default; explicit
`auto` requires nonempty tools. Named and `required` choices are denied.
The trusted local staged launcher explicitly freezes `allowNoTools:true`: only
that opt-in admits `none`, and only with absent or empty tools, for OpenCode's
restrictive final response turn. Other launchers still deny `none`. This does
not prove the request is temporally final or permit arbitrary choice values.
Schema contents and message contents remain untrusted task data, not executable
relay code. Programs/tool execution have the separate sandbox boundary.

The installed offline fixture supplies this contract with tools enabled. Any
other trusted launcher constructing relay configuration must adopt the same
required streaming controls; old `{max_completion_tokens:32000}` configuration
now intentionally fails closed. No orchestration/CLI implementation is changed
by this relay patch.
