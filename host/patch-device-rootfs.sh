#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATCH_DIR="$REPO_ROOT/upstream/xiaoai-agent/deploy/client-patch"
SOURCE_ROOTFS=${1:-}
EXPECTED_SHA256=${2:-}
EXPECTED_MODEL=${EXPECTED_MODEL:-OH2P}
EXPECTED_ROM=${EXPECTED_ROM:-1.56.20}
OUT_DIR="$REPO_ROOT/artifacts/build/oh2p/firmware-${EXPECTED_ROM}-coexist-from-device"
SECRETS_DIR="$REPO_ROOT/.secrets"
PASSWORD_FILE=${XIAOAI_SSH_PASSWORD_FILE:-"$SECRETS_DIR/oh2p-root-password.txt"}
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
WORK_DIR=${XIAOAMUSIC_DEVICE_FIRMWARE_WORK_DIR:-"$USER_DIR/.cache/xiaoaimusic-device-firmware-${EXPECTED_ROM}"}
IMAGE_MAX_SIZE=$((0x02800000))

if [ -z "$SOURCE_ROOTFS" ] || [ -z "$EXPECTED_SHA256" ]; then
    echo "用法：$0 <system0.factory.bin> <expected-sha256>" >&2
    exit 2
fi

[ -f "$SOURCE_ROOTFS" ] || { echo "缺少设备备份：$SOURCE_ROOTFS" >&2; exit 2; }
echo "$EXPECTED_SHA256  $SOURCE_ROOTFS" | sha256sum -c -

SOURCE_SIZE=$(stat -c %s "$SOURCE_ROOTFS")
[ "$SOURCE_SIZE" -eq "$IMAGE_MAX_SIZE" ] || {
    echo "设备备份大小不是 40 MiB：$SOURCE_SIZE" >&2
    exit 3
}

VERSION_TEXT=$(unsquashfs -cat "$SOURCE_ROOTFS" usr/share/mico/version)
printf '%s\n' "$VERSION_TEXT" | grep -Fq "option HARDWARE '$EXPECTED_MODEL'"
printf '%s\n' "$VERSION_TEXT" | grep -Fq "option ROM '$EXPECTED_ROM'"

umask 077
mkdir -p "$SECRETS_DIR"
if [ ! -s "$PASSWORD_FILE" ]; then
    openssl rand -base64 24 | tr -d '\r\n' >"$PASSWORD_FILE"
    printf '\n' >>"$PASSWORD_FILE"
    echo "已生成随机 Root 密码：$PASSWORD_FILE（不要提交或公开）"
fi
SSH_PASSWORD=$(tr -d '\r\n' <"$PASSWORD_FILE")
[ "${#SSH_PASSWORD}" -ge 20 ] || { echo "SSH 密码文件过短" >&2; exit 4; }

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$PATCH_DIR/assets"
unsquashfs -d "$WORK_DIR/squashfs-root" "$SOURCE_ROOTFS"

ORIGINAL_ASOUND=$(sha256sum "$WORK_DIR/squashfs-root/etc/asound.conf" | cut -d' ' -f1)
ORIGINAL_INITTAB=$(sha256sum "$WORK_DIR/squashfs-root/etc/inittab" | cut -d' ' -f1)
ORIGINAL_VERSION=$(sha256sum "$WORK_DIR/squashfs-root/usr/share/mico/version" | cut -d' ' -f1)

if [ -L "$PATCH_DIR/temp" ]; then
    rm "$PATCH_DIR/temp"
elif [ -e "$PATCH_DIR/temp" ]; then
    echo "拒绝删除非符号链接的补丁工作目录：$PATCH_DIR/temp" >&2
    exit 5
fi
ln -s "$WORK_DIR" "$PATCH_DIR/temp"
printf '%s\n' "$EXPECTED_MODEL" >"$PATCH_DIR/assets/.model"

cd "$PATCH_DIR"
sed -i 's/\r$//' src/*.sh
find patches -type f -name '*.patch' -exec sed -i 's/\r$//' {} +
XIAOAI_MODE=coexist SSH_PASSWORD="$SSH_PASSWORD" bash src/patch.sh

PATCHED_ASOUND=$(sha256sum "$WORK_DIR/squashfs-root/etc/asound.conf" | cut -d' ' -f1)
PATCHED_INITTAB=$(sha256sum "$WORK_DIR/squashfs-root/etc/inittab" | cut -d' ' -f1)
PATCHED_VERSION=$(sha256sum "$WORK_DIR/squashfs-root/usr/share/mico/version" | cut -d' ' -f1)

[ "$ORIGINAL_ASOUND" = "$PATCHED_ASOUND" ] || { echo "共存模式错误修改了 asound.conf" >&2; exit 6; }
[ "$ORIGINAL_INITTAB" = "$PATCHED_INITTAB" ] || { echo "补丁错误修改了 inittab" >&2; exit 7; }
[ "$ORIGINAL_VERSION" = "$PATCHED_VERSION" ] || { echo "补丁错误修改了版本文件" >&2; exit 8; }
grep -Fq '/data/init.sh' "$WORK_DIR/squashfs-root/etc/rc.local"
grep -Fq 'mkdir -p /data/etc/dropbear' "$WORK_DIR/squashfs-root/etc/init.d/dropbear"
grep -Fq 'return 1' "$WORK_DIR/squashfs-root/bin/ota"
grep -Fq 'return 1' "$WORK_DIR/squashfs-root/bin/flash.sh"
grep -Fq 'ttyS0::askfirst:/bin/login' "$WORK_DIR/squashfs-root/etc/inittab"

PATCHED_IMAGE="$OUT_DIR/root-patched-coexist.squashfs"
rm -f "$PATCHED_IMAGE"
mksquashfs "$WORK_DIR/squashfs-root" "$PATCHED_IMAGE" \
    -comp xz -b 131072 \
    -noappend -all-root -always-use-fragments -no-xattrs -no-exports

PATCHED_SIZE=$(stat -c %s "$PATCHED_IMAGE")
[ "$PATCHED_SIZE" -lt "$IMAGE_MAX_SIZE" ] || {
    echo "补丁镜像超过 40 MiB 分区上限：$PATCHED_SIZE" >&2
    exit 9
}

cp "$SOURCE_ROOTFS" "$OUT_DIR/system0.factory.bin"
{
    echo "model=$EXPECTED_MODEL"
    echo "firmware=$EXPECTED_ROM"
    echo "source=device-system0-backup"
    echo "mode=coexist"
    echo "source_size=$SOURCE_SIZE"
    echo "patched_size=$PATCHED_SIZE"
    echo "native_asound_sha256=$PATCHED_ASOUND"
    echo "native_inittab_sha256=$PATCHED_INITTAB"
    echo "version_file_sha256=$PATCHED_VERSION"
    sha256sum "$OUT_DIR/system0.factory.bin" "$PATCHED_IMAGE"
} >"$OUT_DIR/MANIFEST.txt"

unsquashfs -s "$PATCHED_IMAGE"
unsquashfs -cat "$PATCHED_IMAGE" usr/share/mico/version | grep -F "option ROM '$EXPECTED_ROM'"
unsquashfs -cat "$PATCHED_IMAGE" usr/share/mico/version | grep -F "option HARDWARE '$EXPECTED_MODEL'"

echo "设备同版本共存固件候选已生成：$PATCHED_IMAGE"
