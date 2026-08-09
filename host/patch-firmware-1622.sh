#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATCH_DIR="$REPO_ROOT/upstream/xiaoai-agent/deploy/client-patch"
OTA="$REPO_ROOT/artifacts/firmware/oh2p/1.62.2/mico_all_616cd9d93_1.62.2.bin"
OUT_DIR="$REPO_ROOT/artifacts/build/oh2p/firmware-1.62.2-coexist"
SECRETS_DIR="$REPO_ROOT/.secrets"
PASSWORD_FILE=${XIAOAI_SSH_PASSWORD_FILE:-"$SECRETS_DIR/oh2p-root-password.txt"}
FIRMWARE_BASE=mico_all_616cd9d93_1.62.2
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
FIRMWARE_WORK_DIR=${XIAOAMUSIC_FIRMWARE_WORK_DIR:-"$USER_DIR/.cache/xiaoaimusic-firmware-1.62.2"}

[ -f "$OTA" ] || { echo "缺少官方 1.62.2 OTA：$OTA" >&2; exit 2; }

EXPECTED_MD5=bc81f5b40f3db5e9a9d5943616cd9d93
EXPECTED_SHA256=08c6c0c5e7dfd3de59a7e37b4709ad90ab84e8025c799a642730e97ef53c0eba
echo "$EXPECTED_MD5  $OTA" | md5sum -c -
echo "$EXPECTED_SHA256  $OTA" | sha256sum -c -

umask 077
mkdir -p "$SECRETS_DIR"
if [ ! -s "$PASSWORD_FILE" ]; then
    openssl rand -base64 24 | tr -d '\r\n' >"$PASSWORD_FILE"
    printf '\n' >>"$PASSWORD_FILE"
    echo "已生成随机 Root 密码：$PASSWORD_FILE（不要提交或公开）"
fi
SSH_PASSWORD=$(tr -d '\r\n' <"$PASSWORD_FILE")
[ "${#SSH_PASSWORD}" -ge 20 ] || { echo "SSH 密码文件过短" >&2; exit 3; }

mkdir -p "$PATCH_DIR/assets" "$OUT_DIR"
rm -rf "$PATCH_DIR/temp" "$PATCH_DIR/assets/$FIRMWARE_BASE"
rm -rf "$FIRMWARE_WORK_DIR"
mkdir -p "$FIRMWARE_WORK_DIR"
ln -s "$FIRMWARE_WORK_DIR" "$PATCH_DIR/temp"
cp "$OTA" "$PATCH_DIR/assets/$FIRMWARE_BASE.bin"
printf 'OH2P\n' >"$PATCH_DIR/assets/.model"
printf '1.62.2\n' >"$PATCH_DIR/assets/.version"

cd "$PATCH_DIR"
sed -i 's/\r$//' src/*.sh
find patches -type f -name '*.patch' -exec sed -i 's/\r$//' {} +
npm ci --no-audit --no-fund
npm run extract

ORIGINAL_ASOUND=$(sha256sum temp/squashfs-root/etc/asound.conf | cut -d' ' -f1)
ORIGINAL_INITTAB=$(sha256sum temp/squashfs-root/etc/inittab | cut -d' ' -f1)

XIAOAI_MODE=coexist SSH_PASSWORD="$SSH_PASSWORD" npm run patch

PATCHED_ASOUND=$(sha256sum temp/squashfs-root/etc/asound.conf | cut -d' ' -f1)
PATCHED_INITTAB=$(sha256sum temp/squashfs-root/etc/inittab | cut -d' ' -f1)
[ "$ORIGINAL_ASOUND" = "$PATCHED_ASOUND" ] || { echo "共存模式错误修改了 asound.conf" >&2; exit 4; }
[ "$ORIGINAL_INITTAB" = "$PATCHED_INITTAB" ] || { echo "补丁错误修改了 inittab" >&2; exit 5; }
grep -q '/data/init.sh' temp/squashfs-root/etc/rc.local
grep -q 'mkdir -p /data/etc/dropbear' temp/squashfs-root/etc/init.d/dropbear
grep -q 'return 1' temp/squashfs-root/bin/ota

npm run squashfs

cp "assets/$FIRMWARE_BASE/root.squashfs" "$OUT_DIR/root-original.squashfs"
cp "assets/$FIRMWARE_BASE/root-patched.squashfs" "$OUT_DIR/root-patched-coexist.squashfs"

PATCHED_SIZE=$(stat -c %s "$OUT_DIR/root-patched-coexist.squashfs")
[ "$PATCHED_SIZE" -lt $((0x02800000)) ] || { echo "补丁镜像超过 40 MiB 分区上限" >&2; exit 6; }

{
    echo "model=OH2P"
    echo "firmware=1.62.2"
    echo "mode=coexist"
    echo "native_asound_sha256=$PATCHED_ASOUND"
    echo "native_inittab_sha256=$PATCHED_INITTAB"
    echo "patched_size=$PATCHED_SIZE"
    sha256sum "$OUT_DIR/root-original.squashfs" "$OUT_DIR/root-patched-coexist.squashfs"
} >"$OUT_DIR/MANIFEST.txt"

echo "共存固件候选已生成：$OUT_DIR"
echo "该镜像只能在实机确认同为 OH2P 1.62.2 后使用。"
