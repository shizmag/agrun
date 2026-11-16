# Authorized Luna 6 smoke — upstream response observed

Installed OpenCode returned `OK` and exited 0 through the trusted-host loopback
relay and network-disabled solver container. The relay recorded an attempted
upstream request and HTTP 200. Requested route: `cx/gpt-6-luna-low`; reported
response model: `gpt-6-luna`. This is not independent served-model attestation.

Reported usage: 756 prompt tokens, 5 completion tokens, 761 total. Cached and
reasoning detail counts were not reported by the upstream. Client-emitted zeros
are not a substitute for those missing upstream measurements. The client cost
field of zero is not verified billing.

Two integration failures remain visible in the unchanged original evidence:
the relay classified the response as `upstream_protocol` /
`response_invalid_or_incomplete`, despite delivery of text and usage; subsequent
ledger settlement raised `token_budget_usage_invalid` on nullable observation
fields. The permanent 2,048,704-token reservation remains intact. Corrections
and any later settlement must be supplemental records, not edits to these files.

This establishes observed gateway inference transport, not benchmark quality or
a complete clean transport verification. No task was solved or graded here.
