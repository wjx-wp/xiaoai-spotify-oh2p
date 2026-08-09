#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/probe-presence-capabilities.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$REPO_ROOT/.secrets/known_hosts_oh2p"
)

sshpass -f "$REPO_ROOT/.secrets/oh2p-root-password.txt" \
    ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
        echo BLUETOOTH_SYSFS
        ls -la /sys/class/bluetooth 2>/dev/null || true
        for command in bluetoothctl btmgmt hciconfig hcitool rfkill iw; do
            command -v "$command" 2>/dev/null || true
        done
        hciconfig -a 2>/dev/null || true
        echo BLUETOOTH_PROCESSES
        ps w | grep -Ei "bluetooth|bluealsa|bluez|bt_audio|btservice" | grep -v grep || true
        echo UBUS
        ubus list 2>/dev/null | grep -Ei "bluetooth|wireless|network.device|network.interface" || true
        echo NETWORK_TOOLS
        busybox --list 2>/dev/null | grep -E "^(arp|arping|httpd|nc|netstat|ping)$" || true
        ip neigh show 2>/dev/null || arp -an 2>/dev/null || true
    '
