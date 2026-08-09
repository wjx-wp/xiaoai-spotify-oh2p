#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for script in "$REPO_ROOT"/host/*.sh "$REPO_ROOT"/device/oh2p/*.sh; do
    bash -n "$script"
done

echo "shell syntax OK"
