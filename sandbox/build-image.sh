#!/bin/sh
set -eu

# Build context must contain only the Dockerfile and verified public executable.
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifact=${1:?usage: build-image.sh PATH_TO_VERIFIED_LINUX_ARM64_OPENCODE [TAG]}
tag=${2:-agru-agent-sandbox:m12cs1}
expected=5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0
actual=$(shasum -a 256 "$artifact" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo 'OpenCode binary digest mismatch' >&2; exit 1; }
context=$(mktemp -d "${TMPDIR:-/tmp}/agru-agent-image.XXXXXX")
trap 'rm -f "$context/Dockerfile" "$context/opencode"; if [ -d "$context" ]; then rmdir "$context"; fi' EXIT
trap 'exit 1' HUP INT TERM
cp "$root/Dockerfile" "$context/Dockerfile"
cp "$artifact" "$context/opencode"
docker build --platform=linux/arm64 --pull=false --tag "$tag" "$context"
docker image inspect "$tag" --format '{{.Id}}'
