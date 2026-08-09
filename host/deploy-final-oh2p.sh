#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$REPO_ROOT/artifacts/build/oh2p/xiaoaimusic-oh2p.tar.gz"
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
REMOTE_PACKAGE=/tmp/xiaoaimusic-oh2p-final.tar.gz

if [[ -z "$DEVICE_IP" ]]; then
    echo "Usage: $0 DEVICE_IP" >&2
    exit 2
fi
for required in "$PACKAGE" "$PASSWORD_FILE" "$KNOWN_HOSTS"; do
    [[ -f "$required" && ! -L "$required" ]] || {
        echo "Missing or unsafe deployment input: $required" >&2
        exit 2
    }
done
for command_name in sshpass ssh scp sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing host command: $command_name" >&2
        exit 2
    }
done

expected_sha256=$(sha256sum "$PACKAGE" | awk '{print $1}')
ssh_options=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" scp -O "${ssh_options[@]}" \
    "$PACKAGE" "root@$DEVICE_IP:$REMOTE_PACKAGE"

sshpass -f "$PASSWORD_FILE" ssh "${ssh_options[@]}" \
    "root@$DEVICE_IP" sh -s -- "$REMOTE_PACKAGE" "$expected_sha256" <<'REMOTE'
set -eu

remote_package=$1
expected_sha256=$2
stage=

cleanup() {
    rm -f "$remote_package"
    if [ -n "$stage" ]; then
        case "$stage" in
            /tmp/xiaoaimusic-install.*) rm -rf "$stage" ;;
        esac
    fi
}
trap cleanup EXIT HUP INT TERM

actual_sha256=$(sha256sum "$remote_package" | awk '{print $1}')
[ "$actual_sha256" = "$expected_sha256" ] || {
    echo PACKAGE_HASH_MISMATCH >&2
    exit 3
}

stage=$(mktemp -d /tmp/xiaoaimusic-install.XXXXXX)
case "$stage" in
    /tmp/xiaoaimusic-install.*) ;;
    *) echo "Unsafe installation stage: $stage" >&2; exit 3 ;;
esac

tar -xzf "$remote_package" -C "$stage"
"$stage/xiaoaimusic-oh2p/install.sh"
/data/xiaoaimusic/install-autostart.sh

echo FINAL_PACKAGE_INSTALLED
REMOTE

echo "FINAL_DEPLOYMENT_OK device=$DEVICE_IP package_sha256=$expected_sha256"
