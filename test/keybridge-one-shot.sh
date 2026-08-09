#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNTIME_DIR=$(mktemp -d /tmp/xiaoaimusic-keybridge-test.XXXXXX)

cleanup() {
    rm -f "$RUNTIME_DIR/keybridge" "$RUNTIME_DIR/control.sock" \
        "$RUNTIME_DIR/ready" "$RUNTIME_DIR/received"
    rmdir "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cc -O2 -Wall -Wextra -Werror \
    "$REPO_ROOT/components/keybridge/xiaoaimusic-keybridge.c" \
    -o "$RUNTIME_DIR/keybridge"

python3 -c '
import socket
import sys

receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
receiver.bind(sys.argv[1])
open(sys.argv[2], "w").close()
payload = receiver.recv(64)
with open(sys.argv[3], "wb") as output:
    output.write(payload)
' "$RUNTIME_DIR/control.sock" "$RUNTIME_DIR/ready" "$RUNTIME_DIR/received" &
receiver_pid=$!

attempt=0
while [ ! -e "$RUNTIME_DIR/ready" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 200 ] || {
        kill "$receiver_pid" 2>/dev/null || true
        echo 'Unix datagram receiver did not become ready' >&2
        exit 1
    }
    sleep 0.01
done

"$RUNTIME_DIR/keybridge" --send-command next \
    --control-socket "$RUNTIME_DIR/control.sock"
wait "$receiver_pid"
[ "$(cat "$RUNTIME_DIR/received")" = next ]

if "$RUNTIME_DIR/keybridge" --send-command arbitrary \
    --control-socket "$RUNTIME_DIR/control.sock" >/dev/null 2>&1; then
    echo 'keybridge accepted an invalid local control command' >&2
    exit 1
else
    invalid_rc=$?
fi
[ "$invalid_rc" -eq 2 ]

echo 'keybridge one-shot runtime test passed'
