# Whole-agent image

Build with `sh sandbox/build-image.sh /absolute/path/to/verified/opencode`.
Only the Dockerfile and verified executable enter the temporary build context;
no host credentials, application images, or repository contents are copied.
Build-time public Debian package networking is required. No provider calls occur.

The base repository digest and OpenCode v2.3.0 Linux ARM64 executable SHA-256
are pinned in the Dockerfile and build script. The official archive is
https://github.com/anomalyco/opencode/releases/download/v2.3.0/opencode-linux-arm64.tar.gz
with SHA-256 `3207fb5cdec448d479242c0f1a14f4f7bdfcad3a79209b5eb8f9003725e93711`.
The extracted executable SHA-256 is
`5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0`.

Debian package repositories are not snapshot-pinned: rebuilds are not guaranteed
bit-for-bit reproducible. `/opt/agru/packages.tsv` records all installed versions.
Freeze the resulting local image ID in execution evidence; never trust the tag
alone. This image supplies Node, Python, Git and C/C++ build tools, not Ruby.

Verified initial local image ID:
`sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1`.
Its `/opt/agru/packages.tsv` SHA-256 is
`01121bdfdd855515a71d367cb59e3a56becdc181a6b794c8cfebcdd00e12a272`.
Run `sh sandbox/smoke-image.sh IMMUTABLE_IMAGE_ID` for offline capability checks.
`sandbox/m12cs1-image-evidence.json` is the sanitized source-controlled summary;
full inspection/package evidence remains in ignored run state. This is offline
image capability evidence only: mock-tested/unfrozen, not comparative eligible.
The smoke tmpfs explicitly permits execution so compiled test executables work;
production workspaces likewise need execution where native tests require it.

An image alone is not a sandbox policy. The launcher must enforce a read-only
root, non-root identity, dropped capabilities, no new privileges, bounded
resources, narrowly scoped writable workspace/HOME/tmp and restricted networking.
Do not mount Docker sockets, host homes, credentials, hidden procedures or broad
repository parents. Provider credentials belong only in the enforcing relay.
