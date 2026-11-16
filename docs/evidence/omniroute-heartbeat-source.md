# Local OmniRoute heartbeat source evidence

Read-only inspection of the installed gateway on 2026-11-16 found this exact SSE
data object in both compiled chunks below:

```json
{"id":"chatcmpl-keepalive","object":"chat.completion.chunk","created":0,"model":"keepalive","choices":[{"index":0,"delta":{},"finish_reason":null}]}
```

Source files and SHA-256 of their complete bytes:

- `/opt/homebrew/lib/node_modules/omniroute/dist/.build/next/server/chunks/_1pfxrep._.js`
  `464fa6fd37f42e95dbf70b998a9e1d4c3d76a1fbfd5fe775cb24038a92ff722c`
- `/opt/homebrew/lib/node_modules/omniroute/dist/.build/next/server/chunks/_0hom0gz._.js`
  `7e27cdf37d300fa211e466b93d36def6e18278c78a3b5554337cc915ea09d4a8`

The relay excludes only structural equality with this object in SSE responses,
and increments a bounded heartbeat counter. Extra keys, usage, content or tool
deltas, changed identifiers/timestamps, and finish reasons do not qualify.
The name `keepalive` alone is not an exemption from identity observations.
This documents installed implementation bytes, not provider identity attestation
or proof of the raw shape of any earlier event. No live call was made for this
inspection; previous evidence and ledger halt events remain unchanged.

## Additional timestamped default emitter (subsequent read-only inspection)

`/opt/homebrew/lib/node_modules/omniroute/dist/.build/next/server/chunks/open-sse_08n169v._.js`
has SHA-256 `68622a13ad324c90bbff4eaf5dca93a94ce2ecebb96f7b2b02c90d28a5745ca1`.
Its `createSseHeartbeatTransform` emits the same object with
`created: Math.floor(Date.now()/1e3)`, `id: t.chunkId ?? "chatcmpl-keepalive"`,
and `model: t.chunkModel ?? "keepalive"`; its default interval is 15000 ms.

The additional classifier accepts only the default ID/model, exact original
keys and empty delta structure, with a positive safe-integer timestamp.
It does not classify configured ID/model variants. No wall-clock comparison is
used, preserving replay determinism. Constant-zero and timestamped-default
variants have separate bounded counters. Unrecognized keepalive events retain
identity observations and bounded structural diagnostics containing booleans
and fixed timestamp-kind enums only, never content or arbitrary key names.

This source evidence does not establish the shape of any historical event.
No live calls, ledger resolution, or previous evidence modifications occurred.
