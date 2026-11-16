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
