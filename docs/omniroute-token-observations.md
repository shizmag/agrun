# Current OmniRoute token/model observation run

The operator explicitly authorized only Luna 6, with at most 1,000,000,000
aggregate tokens across this continuation. This is a ceiling, not a target or a
per-experiment allowance. The retained route is `cx/gpt-6-luna-low`; fallback to
other models is forbidden. See
`experiments/omniroute-luna6-token-observation.json` for the non-secret intent.

The active OpenCode provider configuration identifies `omniroute`, API base
`http://localhost:20128/v1`, and credential environment variable
`OMNIROUTE_API_KEY`. Credential values are not copied to this document, repository
or solver environments. A metadata-only authenticated `/v1/models` request
confirmed the route is listed by the local gateway. This was not inference and
does not prove the model behind that route.

This observation protocol is distinct from the previous monetary-ceiling
authorization contract: the operator currently requests token and model-name
collection, not a verified monetary ceiling. No synthetic pricing will be used
to bypass the earlier contract. Record requested route separately from response
model, retain unknown usage as unknown, avoid double-counting cached/reasoning
subtokens, and keep conservative reservations for failed or unreported requests.
Reported names are not independent served-model attestation.

The local HTTP gateway needs an explicitly trusted loopback transport; it is not
permission to disable TLS verification for HTTPS upstreams, expose credentials
to solvers or give network-disabled solver containers general network access.
Begin with a small bounded installed-OpenCode smoke before any larger matrix.

## Verified smoke (2026-11-16)

The clean installed-client result is saved at
`docs/evidence/omniroute-smoke-20261116T091529-3bce89c7/`.
OpenCode returned `OK`; the relay recorded HTTP 200 and normal streaming without
protocol errors. Requested route `cx/gpt-6-luna-low` produced reported name
`gpt-6-luna` and usage 756 input + 5 output = 761 tokens.

Earlier failures are preserved. The installed gateway emits an exact empty
heartbeat with `model: "keepalive"`; source hashes and the narrow classifier
contract are in `docs/evidence/omniroute-heartbeat-source.md`. Real content under
that name remains an identity observation. The resulting earlier ledger halt
was resolved append-only after source and negative-control review, without
rewriting the old event or refunding reservations.

At the clean smoke, six client attempts reserved 12,292,224 tokens permanently;
five upstream responses reported 3,805 tokens in total. The first locally
rejected attempt remains unknown in accounting. These are not billing totals.
The same ledger path must remain in use across subsequent executions:
`.agru/authorizations/omniroute-luna6-20261116.tokens.jsonl`.

Explicit smoke command (makes a live request and consumes another reservation):

```sh
mise exec -- ruby scripts/omniroute_token_smoke.rb --execute
```

The nine-cell token-authorized comparison is being integrated separately; the
one-request smoke must not be described as a completed live experiment matrix.
