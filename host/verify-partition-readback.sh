#!/usr/bin/env bash

set -euo pipefail

IMAGE=${1:-}
READBACK=${2:-}
PARTITION_SIZE=${3:-41943040}

if [ -z "$IMAGE" ] || [ -z "$READBACK" ]; then
    echo "用法：$0 <written-image> <partition-readback> [partition-size]" >&2
    exit 2
fi

[ -f "$IMAGE" ] || { echo "缺少写入镜像：$IMAGE" >&2; exit 2; }
[ -f "$READBACK" ] || { echo "缺少分区回读：$READBACK" >&2; exit 2; }

IMAGE_SIZE=$(stat -c %s "$IMAGE")
READBACK_SIZE=$(stat -c %s "$READBACK")
[ "$READBACK_SIZE" -eq "$PARTITION_SIZE" ] || {
    echo "回读长度错误：$READBACK_SIZE（预期 $PARTITION_SIZE）" >&2
    exit 3
}
[ "$IMAGE_SIZE" -le "$PARTITION_SIZE" ] || {
    echo "镜像大于分区：$IMAGE_SIZE > $PARTITION_SIZE" >&2
    exit 4
}

cmp -n "$IMAGE_SIZE" "$IMAGE" "$READBACK"

TAIL_SIZE=$((PARTITION_SIZE - IMAGE_SIZE))
ACTUAL_TAIL_SHA256=$(tail -c "$TAIL_SIZE" "$READBACK" | sha256sum | cut -d' ' -f1)
EXPECTED_TAIL_SHA256=$(head -c "$TAIL_SIZE" /dev/zero | tr '\000' '\377' | sha256sum | cut -d' ' -f1)
[ "$ACTUAL_TAIL_SHA256" = "$EXPECTED_TAIL_SHA256" ] || {
    echo "分区尾部不是全 FF" >&2
    echo "actual=$ACTUAL_TAIL_SHA256" >&2
    echo "expected=$EXPECTED_TAIL_SHA256" >&2
    exit 5
}

echo "image_size=$IMAGE_SIZE"
echo "readback_size=$READBACK_SIZE"
echo "tail_size=$TAIL_SIZE"
echo "tail_ff_sha256=$ACTUAL_TAIL_SHA256"
echo "分区回读验证通过：镜像前缀一致，剩余空间全 FF"
