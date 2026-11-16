# Authorized provider launcher (not live execution evidence)

`Execution::AuthorizedProviderLauncher` implements the external trusted-relay
container lifecycle. Its `start(attempt_id:, cell_id:, model_profile:)`,
`relay_volume`, `image`, `close`, and `audit_records` interface follows the
simulated provider. The caller must close it in an ensure block. This change
does not integrate the nine-cell research scheduler or authorize any live run.

The solver must run with network disabled and mount only the private relay
volume. Never mount the trusted config directory or credential file in it.
The trusted root-owned Node container has a read-only filesystem, dropped
capabilities, no-new-privileges, resource limits, a private read-only credential
mount, and a pinned image. Its code sends HTTPS requests only to its reviewed
origin and fixed chat-completions path; it does not follow redirects or disable
certificate verification. This is application-level origin restriction, **not**
an OS-level egress firewall or a hostile-code security sandbox.

The authorization includes exact `bindings`, `limits`, `expires_at` and `quota`.
Quota keys are `requests`, `tokens`, `money`, `expiresAt` (epoch milliseconds),
`inputTokensPerByte`, `inputTokenOverhead`, `inputPricePerMillion`,
`outputPricePerMillion`, `pricingEvidence`, and `tokenBoundEvidence`.
The launcher checks request/token/money/expiry against authorized cell limits.
The trusted relay reserves a request, serialized-input byte-derived token upper
bound plus requested completion tokens, and corresponding price before any
upstream request. Reservations are never refunded after failures or cancellation.
Quota exhaustion and expiry reject admission. The launcher now requires a
`ProviderBudgetLedger` through `ledger:` and durably reserves the entire cell
cap before Docker spawn, with no refunds even when spawn fails. A reserved cell
or attempt cannot be restarted against that ledger.

`ProviderBudgetLedger.new(path:, experiment_digest:, cells:, totals:,
expires_at:, wall_clock:)` freezes an exact nine-cell plan. Each cell and the
experiment totals have `requests`, `tokens`, and `money` caps. Whole-plan sums
must fit totals. `reserve!(cell_id:, attempt_id:)` returns reservation evidence;
the launcher compares its experiment/caps/expiry to authorization. Persistence
uses a separate flock lock file, mode-0600 atomic JSON replacement, fsync, and
a deterministic checksum. Reopening with a different plan is rejected. Keep
one launcher alive across all inference stages of a cell.

The ledger lives on a trusted host: its checksum detects corruption, not a
malicious trusted-host rewrite, deletion, rollback, or selection of a fresh
ledger path. The scheduler/operator must bind one persistent path to the
experiment and protect that path. Reservation evidence is not a bearer token
or cryptographic signature.

**Important limitations:** the input-token bound and prices are explicitly
reviewed provider-contract assumptions, not measured tokenizer or billing
proof. Nonempty evidence labels are not independently verified. Hidden provider
tokens, tool/protocol overhead, rounding, and price changes can invalidate those
assumptions. Without suitable evidence this is request/byte-based admission,
not a defensible hard compute or monetary ceiling. There is no forced expiry
cancellation of already admitted requests or exact-nine scheduler here.
Per-request network timeouts remain enforced by the
existing relay. Do not advertise this as ready for the research live protocol.

Tests include pure offline admission logic and a recording Docker adapter.
`AGRU_AUTHORIZED_PROVIDER_DOCKER=1 mise exec -- bundle exec ruby -Itest
test/authorized_provider_docker_test.rb` also starts the actual trusted relay
with an ephemeral dummy credential and an invalid provider domain, inspects the
socket from a network-disabled fixture solver, and closes it without connecting
to the socket. It checks mode 0600, credential/config separation, empty audit and
container logs. This lifecycle test passed locally; it does not demonstrate
provider reachability or submit any inference request.
