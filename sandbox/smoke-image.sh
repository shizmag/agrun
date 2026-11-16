#!/bin/sh
set -eu
image=${1:?usage: smoke-image.sh IMMUTABLE_IMAGE_ID}
case "$image" in sha256:*) ;; *) echo 'immutable local image ID required' >&2; exit 1 ;; esac
docker run --rm --pull=never --network=none --read-only \
  --user=65534:65534 --cap-drop=ALL --security-opt=no-new-privileges \
  --cpus=1 --memory=1g --memory-swap=1g --pids-limit=128 \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=268435456,mode=1777 \
  --entrypoint /bin/sh "$image" -ec '
    test "$(id -u)" = 65534
    test ! -e /var/run/docker.sock
    test ! -e /Users/vladimirkasterin
    test ! -e /root/.config/opencode
    test ! -e /root/.local/share/opencode/auth.json
    test ! -e /workspace/.git
    test ! -e /workspace/.agru
    test ! -e /trusted
    test ! -e /submission
    test -z "$(find /workspace -mindepth 1 -print -quit)"
    opencode --version
    opencode --standalone run --help >/dev/null
    python3 --version
    node --version
    git --version
    cc --version | head -n 1
    mkdir -p /tmp/work
    cd /tmp/work
    python3 -c "from pathlib import Path; Path(\"answer\").write_text(\"42\"); assert Path(\"answer\").read_text() == \"42\""
    echo "int main(void) { return 0; }" > check.c
    cc check.c -o check
    ./check
  '
