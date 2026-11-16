# First authorized smoke — rejected before upstream

The installed OpenCode solver executed, but the trusted relay rejected its
request with `inference_policy` (HTTP 403). OpenCode supplied tool definitions
while the smoke's trusted inference contract omitted tool permission.

This is **not provider reachability or model-quality evidence**. No upstream
request was admitted. The smoke script's console `inference_attempted: true`
described the client attempt, not successful upstream admission; `audit.json`
is the authoritative boundary record. The 2,048,704-token ledger reservation is
retained despite the local rejection. Reported usage and response model are
unknown, not zero or the requested route.

The original audit and filtered client output are preserved unchanged.
