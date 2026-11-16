# SQLite inherited-connection warning fix

The historical investigation in `docs/m12cs3-security-independent.md` and its
recorded warning logs remain unchanged. Store opens a writable WAL connection;
SandboxRunner previously forked Ruby for every descriptor-relative directory
listing. sqlite3's child fork hook warned and discarded inherited writable
connections before the listing block ran. The parent connection remained open,
but relying on that protective child cleanup was unnecessary.

`SandboxRunner#descriptor_children` now uses Ruby 4's `Dir.for_fd` with a duplicate
of the pinned directory descriptor. Dir owns and closes the duplicate; the
original traversal handle stays open. Lazy enumeration retains the entry cap,
sorting, descriptor-relative pathname-race protection, and unchanged process cwd.
There is no Ruby fork or inherited database connection on this path. Store code,
WAL configuration, synchronization and persistence policy are unchanged. No
warning filter or sqlite3 fork-safety bypass is installed.

A trial fresh-interpreter subprocess avoided inherited Ruby state but exceeded
the existing 1,024-directory resource-limit deadline; it was replaced with direct
descriptor enumeration, not a relaxed timeout.

Offline regression coverage verifies repeated listings of a renamed pinned
directory, handle ownership and cwd, plus copying with a writable Store, empty
captured stderr, parent connection liveness, WAL mode, integrity check and report
persistence after close/reopen.

Validation: focused sandbox export/boundary/supervisor tests: 43 runs, 150
assertions, zero failures/errors, 18 skips (explicit Docker/platform opt-ins).
Standard Ruby passes for both modified Ruby files. No provider calls were made.
This addresses the runtime's Ruby fork site, not arbitrary forks made by trusted
user programs or unrelated third-party code. Linux/Docker opt-in execution was
not exercised by this macOS offline validation.
