#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "usage: $0 <ELF>" >&2
    exit 2
fi

BINARY=$1
INFO=$(file "$BINARY")
echo "$INFO"

echo "$INFO" | grep -q 'ELF 32-bit LSB'
echo "$INFO" | grep -Eq 'ARM|EABI5'

MAX_GLIBC=$(LANG=C readelf -W --version-info --dyn-syms "$BINARY" 2>/dev/null \
    | grep 'Name: GLIBC_' \
    | sed -E 's/.*Name: GLIBC_([0-9.]+).*/\1/' \
    | sort -V \
    | tail -n 1)

if [ -z "$MAX_GLIBC" ]; then
    echo "未发现 GLIBC 版本符号，停止发布。" >&2
    exit 3
fi

if [ "$(printf '%s\n' "$MAX_GLIBC" 2.25 | sort -V | tail -n 1)" != "2.25" ]; then
    echo "GLIBC 要求过高：$MAX_GLIBC > 2.25" >&2
    exit 4
fi

echo "max_glibc=$MAX_GLIBC"
