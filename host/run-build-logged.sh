#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOG_DIR="$REPO_ROOT/.cache"
LOG_FILE="$LOG_DIR/build-oh2p.latest.log"
EXIT_FILE="$LOG_DIR/build-oh2p.latest.exit"

mkdir -p "$LOG_DIR"
rm -f "$EXIT_FILE"
exec >"$LOG_FILE" 2>&1

"$REPO_ROOT/host/build-oh2p.sh" "$@"
STATUS=$?
printf '%s\n' "$STATUS" >"$EXIT_FILE"
exit "$STATUS"
