# Contributor guide

This is a Ruby 4.0.9 prototype. Read `CONTRACTS.md` before changing public APIs.
Use `mise exec -- bundle install` and `mise run test`, `lint`, `smoke`, and
`benchmark-demo`; dependencies must live under `.bundle/gems` to avoid native
extension conflicts with another Ruby installation. Format with Standard Ruby.

Keep offline execution deterministic and free of API/network calls. Live provider
calls require explicit opt-in; tests must not depend on credentials. Never commit
secrets or `.agru` run state. Use Minitest and preserve execution-status versus
evaluation-verdict separation. Store evidence must bind the actual submitted
repository, specification, procedure and environment. Hidden procedures must not
be copied to solver workspaces. Directory separation is not a security sandbox.

Runtime/compiler/store code, integration adapters, and benchmark/evaluation/CLI
code have separate boundaries. Coordinate shared API changes instead of silently
reaching into another component's internals. Programs are trusted Ruby code.
