# Early-startup heartbeat correction

Fresh smoke `omniroute-smoke-20261116T172937-4bd2de4a` retained HTTP 200,
usage 756 + 5 = 761, and an unrecognized empty zero-timestamp keepalive.
Its bounded diagnostics do not independently establish the complete raw frame.

Installed source `/opt/homebrew/lib/node_modules/omniroute/open-sse/utils/earlyStreamKeepalive.ts:46-56`
contains the exact additional transport frame:

```json
{"id":"chatcmpl-keepalive","object":"chat.completion.chunk","created":0,"model":"keepalive","choices":[]}
```

Source SHA-256: `7309291c712198641aaa7706ea1fc7d1411f9d324491a0e3bd8d703462dd76eb`.
The classifier previously required a single empty choice. It now additionally
accepts only this exact empty-choices constant. Changed timestamps, identifiers,
object type, usage, extra fields and content/tool-bearing variants are rejected.
Targeted heartbeat and relay telemetry tests passed 4/4 after the regression
failed against the earlier classifier.

The operator requested correction and minimal revalidation. Append-only review
acknowledges the updated source-backed contract, not historical served-model
attestation. Original violation, usage and reservations remain unchanged.
Only one additional bounded installed-client smoke follows this correction.
