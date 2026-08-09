#!/bin/sh

set -eu

SOURCE=/data/etc/dropbear/authorized_keys
TARGET=/etc/dropbear/authorized_keys
UPDATER=/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater
VERIFIER=/data/xiaoaimusic/bin/xiaoaimusic-authorized-keys-verify

target_mount_record() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v target="$TARGET" '
        $5 == target { count++; device=$3; root=$4 }
        END { if (count == 1) print device "|" root; else exit 1 }
    ' /proc/self/mountinfo
}

source_filesystem_record() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v path="$SOURCE" '
        function contains(path, mountpoint) {
            return mountpoint == "/" || path == mountpoint ||
                   index(path, mountpoint "/") == 1
        }
        contains(path, $5) && length($5) > best_length {
            best_length=length($5)
            best_mount=$5
            best_root=$4
            best_device=$3
        }
        END {
            if (!best_length) exit 1
            if (best_mount == "/") relative=substr(path, 2)
            else if (path == best_mount) relative=""
            else relative=substr(path, length(best_mount) + 2)
            if (relative == "") expected=best_root
            else if (best_root == "/") expected="/" relative
            else expected=best_root "/" relative
            print best_device "|" expected
        }
    ' /proc/self/mountinfo
}

target_is_mounted() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v target="$TARGET" '$5 == target { found=1 } END { exit(found ? 0 : 1) }' \
        /proc/self/mountinfo
}

target_mount_is_project_source() {
    actual_record=$(target_mount_record) || return 1
    expected_record=$(source_filesystem_record) || return 1
    [ "$actual_record" = "$expected_record" ]
}

trusted_directory() {
    expected_private=$2
    ls -ldn "$1" 2>/dev/null | awk -v private="$expected_private" '
        NR == 1 && $1 ~ /^d/ && $3 == 0 &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" &&
        (!private || substr($1, 2, 9) == "rwx------") { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    '
}

trusted_executable() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    ls -ldn "$1" 2>/dev/null | awk '
        NR == 1 && $1 ~ /^-/ && $3 == 0 && substr($1, 4, 1) == "x" &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    '
}

analyze_project_authorized_keys() {
    "$VERIFIER" --require-mobile "$1"
}

[ ! -e "$SOURCE" ] && [ ! -L "$SOURCE" ] && exit 0
for trusted_path in /data/etc /data/etc/dropbear "$SOURCE"; do
    [ ! -L "$trusted_path" ] || {
        echo "Refusing symlink in persistent authorized_keys path: $trusted_path" >&2
        exit 2
    }
done
[ -d /data/etc ] && [ -d /data/etc/dropbear ] && [ -f "$SOURCE" ] || {
    echo 'Persistent mobile authorized_keys path is missing or invalid.' >&2
    exit 2
}
trusted_directory /data/etc 0 || {
    echo '/data/etc must be root-owned and not group/world-writable.' >&2
    exit 2
}
for private_directory in /data/xiaoaimusic /data/xiaoaimusic/bin \
    /data/etc/dropbear; do
    trusted_directory "$private_directory" 1 || {
        echo "Untrusted private directory: $private_directory" >&2
        exit 2
    }
done
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || {
    echo 'Dropbear authorized_keys mount target is missing or invalid.' >&2
    exit 2
}
trusted_executable "$UPDATER" || {
    echo 'Restricted Spotify auth updater is missing or is a symlink.' >&2
    exit 2
}
trusted_executable "$VERIFIER" || {
    echo 'Authorized-keys verifier is missing or is a symlink.' >&2
    exit 2
}

analyze_project_authorized_keys "$SOURCE" >/dev/null || {
    echo 'Persistent authorized_keys failed restricted-key or administrator-key validation.' >&2
    exit 2
}

chown root:root /data/etc/dropbear "$SOURCE" "$UPDATER" "$VERIFIER"
chmod 700 /data/etc/dropbear "$UPDATER" "$VERIFIER"
chmod 600 "$SOURCE"

if target_is_mounted; then
    target_mount_is_project_source || {
        echo 'Refusing to replace a foreign authorized_keys mount.' >&2
        exit 2
    }
    analyze_project_authorized_keys "$TARGET" >/dev/null || {
        echo 'Refusing to replace an unrecognized project authorized_keys mount.' >&2
        exit 2
    }
    if cmp -s "$SOURCE" "$TARGET"; then
        exit 0
    fi
    # A previous bind can legitimately reference the old inode after an atomic
    # replacement of SOURCE.  Provenance and canonical contents were checked
    # above, so this is the only mounted target this script may unmount.
    umount "$TARGET"
fi

mount -o bind "$SOURCE" "$TARGET"
if ! target_mount_is_project_source || ! cmp -s "$SOURCE" "$TARGET" ||
   ! analyze_project_authorized_keys "$TARGET" >/dev/null; then
    # This process just created the top mount and has not yielded to another
    # operation; undo that exact activation even if a verification utility
    # itself failed.
    umount "$TARGET" || true
    echo 'Could not activate the persistent mobile authorized_keys bind mount.' >&2
    exit 1
fi

exit 0
