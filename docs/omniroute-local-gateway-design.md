# Trusted host-local OmniRoute gateway (design, not live authorization)

## Current boundary

The reviewed external provider path remains unchanged: `AuthorizedProvider`
requires a reviewed HTTPS origin; `provider_relay.cjs` sends only fixed-path
HTTPS chat-completions requests and rejects redirects. The solver has
`--network none` and receives only a private Unix relay socket volume.

The configured OmniRoute origin is host-local HTTP on port 20128. Container
`localhost` is not host loopback. Neither changing that origin to
`host.docker.internal` nor allowing HTTP in the external relay is an acceptable
fix. A host Unix socket bind mount also must not be assumed to work across the
Docker Desktop Linux VM boundary.

Only the exact requested model `cx/gpt-6-luna-low` is in scope. Do not discover
and silently substitute another model, normalize the name, or enable fallback.
No provider inference or metadata request was made for this design.

## Smallest distinct implementation boundary

Introduce a separate, explicitly selected `LocalGateway` authorization and
launcher, not a flag that relaxes `AuthorizedProvider` or the HTTPS relay.
Its trusted host worker must connect to the numeric address `127.0.0.1:20128`
and the fixed path `/v1/chat/completions`, without DNS, proxies, redirects,
arbitrary URLs, agent-selected headers, or environment-derived alternate routes.
Reject IPv6/IPv4 aliases and alternate ports unless separately reviewed as a
different transport. Read the bearer credential only in that host worker;
never copy the OpenCode config, environment, or credential into solver storage.
The configured `localhost` name is a setup observation, not a DNS authorization.

Freeze and bind the worker bytes, Node executable, model, literal destination,
gateway configuration identity, request limits, deadline, and transport kind to
the authorization digest. Freeze the gateway process/configuration where the
operator can do so. A successful TCP connection to loopback does not attest the
identity or routing policy of the process listening there. Gateway-side aliases,
fallback, provider retries, or model rewrites must be disabled or independently
reviewed; a response `model` field is not served-model attestation.

## Crossing into the solver's private volume

Two viable routing options need platform validation:

1. **Native Linux:** a trusted host worker can own a Unix socket in a private
   bind-mounted directory. Mount only that directory into the network-disabled
   solver. Verify ownership and permissions, cleanup, cancellation, and socket
   visibility in the actual runtime. Do not expose config or credentials there.
2. **Docker Desktop/macOS:** use a trusted helper container to own the Unix socket
   in the private named volume. It exchanges bounded framed messages with the
   trusted host worker over a private, supervised `docker exec -i` stdio pipe.
   The host worker alone performs loopback HTTP. Use a pinned helper image and
   fixed executable/argv; never mount the Docker socket or give the solver Docker
   access. The helper is trusted code, not a solver-controlled command runner.
   This avoids a new TCP listener, private CA, host networking, and claims that
   host Unix sockets cross the VM. Implement and test framing, backpressure,
   cancellation, concurrent request correlation, maximum message sizes, bounded
   buffering, child-exit handling, and teardown before authorizing live use.

A host HTTPS bridge reachable through Docker Desktop is a larger alternative:
it needs authenticated access, trustworthy certificate provisioning, firewall
and bind-address review, and a separate transport identity. It is not equivalent
to a loopback-only HTTP worker and should not be introduced implicitly.

## Token-only authorization is a separate contract

The existing external authorization requires reviewed prices and money limits.
Do not use dummy prices, zero money, or a fabricated billing ceiling to bypass
it. Add a versioned token-only local-gateway contract if this path is implemented.
Its caller still owns user consent and the cumulative experiment authorization.

Before admitting a cell, atomically persist its entire token reservation against
the aggregate cap of **1,000,000,000 tokens**, including all prior authorized
work and concurrently admitted cells. Admission must survive process restarts,
reject duplicate attempts, and never refund reservations after uncertain
completion, disconnect, cancellation, or missing usage. Unknown actual usage is
unknown, never zero. Per-request admission must reserve a reviewed input-token
upper bound plus the maximum output tokens before sending bytes. Byte length
alone is not a proven bound for gateway-injected prompts, reasoning tokens,
retries, hidden overhead, or rewritten requests. Without an adequate bound or
enforceable upstream cap, fail closed rather than assert the aggregate limit.
Persist actual usage separately from reserved tokens and surface missing or
inconsistent usage as incomplete accounting, not a successful zero-token call.

## Required offline acceptance tests before live use

- Existing external HTTP rejection and TLS verification tests still pass.
- Host worker rejects every destination except the literal reviewed loopback
  endpoint, never follows redirects, and ignores proxy environment variables.
- Wrong model and every fallback/alternate route are rejected before forwarding.
- Fake local upstream observes the exact model, inference fields and fixed path;
  no real credentials or provider/network dependencies are needed by tests.
- Solver remains network-disabled and cannot inspect host config, credentials,
  Docker control, transport framing control, or another attempt's socket.
- Private-volume stdio bridge passes real Docker Desktop visibility and teardown
  tests; disconnects, oversize frames, malformed frames, partial writes, process
  death and concurrent requests fail closed with bounded memory and time.
- Restart/concurrent admission and missing-usage cases retain reservations;
  aggregate reservation cannot exceed 1,000,000,000 tokens.
- Audit distinguishes requested model, gateway response assertion, unverified
  served identity, actual usage, and conservative reservations. Secrets never
  appear in audit, process arguments, test fixtures, or repository artifacts.

This document is a routing proposal only. It does not change public APIs,
enable inference, authorize a run, or establish gateway model identity.
