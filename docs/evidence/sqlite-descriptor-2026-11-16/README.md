# SQLite descriptor enumeration: real Docker controls

Revision under test: `1304414` (shared working tree; concurrent parent work may
also be present). Installed Docker image inspected successfully:
`sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`.

`real-docker-controls.log` retains combined stdout/stderr for these complete files:

- `test/sandbox_export_metadata_test.rb`
- `test/sandbox_boundary_test.rb`
- `test/sandbox_supervisor_test.rb`

Explicit opt-ins: `AGRU_S2_EXPORT_DOCKER=1`,
`AGRU_SUPERVISOR_DOCKER_TEST=1`; `AGRU_SANDBOX_TEST_IMAGE`,
`AGRU_SANDBOX_PYTHON_IMAGE`, and `AGRU_S2_EXPORT_IMAGE` all set to the digest above.
Invocation used `mise exec -- bundle exec ruby -Itest` with a wrapper loading
`test/test_helper.rb`, then requiring all three files and clearing ARGV.

The wrapper created a temporary Store and saved a `before` report before loading
the tests, retaining the Store strongly in `Minitest.after_run`. After all real
sandbox/export controls it saved an `after` report, verified the parent connection
was still open, checked `journal_mode=wal` and `integrity_check=ok`, closed/reopened
the database, and verified both reports survived. It then closed the connection
and removed only its own temporary Store directory.

Result: **43 runs, 306 assertions, zero failures/errors/skips**, 15.694630 seconds;
Store lifecycle control passed. Combined output contains no inherited SQLite
connection warnings (or other warnings). No provider calls or paid services were
used. Existing timeout, malicious-export, cancellation and detached-writer controls
were not weakened. Parent is handling the full suite separately; this is bounded
real Docker regression evidence, not a claim about arbitrary user-program forks.
