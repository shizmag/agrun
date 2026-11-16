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
