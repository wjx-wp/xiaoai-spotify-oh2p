#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$REPO_ROOT/components/authorized-keys-verify/xiaoaimusic-authorized-keys-verify.c"
WORK=$(mktemp -d)
VERIFIER="$WORK/xiaoaimusic-authorized-keys-verify"
AUTH="$WORK/authorized_keys"
trap 'rm -rf -- "$WORK"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror "$SOURCE" -o "$VERIFIER"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$WORK/admin" </dev/null
ssh-keygen -q -t rsa -b 3072 -N '' -f "$WORK/mobile" </dev/null
ssh-keygen -q -t rsa -b 3072 -N '' -f "$WORK/other-mobile" </dev/null
ssh-keygen -q -t rsa -b 1024 -N '' -f "$WORK/short-mobile" </dev/null

ADMIN=$(awk '{print $2}' "$WORK/admin.pub")
MOBILE=$(awk '{print $2}' "$WORK/mobile.pub")
OTHER_MOBILE=$(awk '{print $2}' "$WORK/other-mobile.pub")
SHORT_MOBILE=$(awk '{print $2}' "$WORK/short-mobile.pub")
OPTIONS='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command="/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater"'
TAG=xiaoaimusic-mobile-auth-v1

secure_file() {
    chmod 600 "$AUTH"
    chown root:root "$AUTH"
}

write_valid() {
    {
        printf 'ssh-rsa %s administrator\n' "$ADMIN"
        printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$MOBILE" "$TAG"
    } >"$AUTH"
    secure_file
}

expect_fail() {
    if [ "$#" -eq 3 ]; then
        set -- "$1" "$2" --expected-mobile "$3"
    fi
    if "$VERIFIER" "$@" >"$WORK/unexpected.out" 2>"$WORK/expected.err"; then
        echo "Verifier unexpectedly accepted: $*" >&2
        exit 1
    fi
}

write_valid
"$VERIFIER" --require-mobile "$AUTH" --expected-mobile "$MOBILE"
expect_fail --require-mobile "$AUTH" "$OTHER_MOBILE"

printf 'ssh-rsa %s administrator\n' "$ADMIN" >"$AUTH"
secure_file
"$VERIFIER" --allow-no-mobile "$AUTH" --reject-unrestricted "$MOBILE"

# Exact and decoded-equivalent aliases of the phone key may never exist on an
# unrestricted line.  Dropbear 2017.75 ignores invalid base64 characters; this
# verifier deliberately rejects the non-canonical spelling before comparison.
write_valid
printf 'ssh-rsa %s duplicate\n' "$MOBILE" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

write_valid
INVALID_ALIAS="${MOBILE:0:20}!${MOBILE:20}"
printf 'ssh-rsa %s invalid-character-alias\n' "$INVALID_ALIAS" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

PADDING_ALIAS=$(python3 - "$MOBILE" <<'PY'
import sys

alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
value = list(sys.argv[1])
if value[-1] != "=":
    raise SystemExit("fixture unexpectedly has no padding")
position = -3 if value[-2] == "=" else -2
value[position] = alphabet[alphabet.index(value[position]) ^ 1]
print("".join(value))
PY
)
write_valid
printf 'ssh-rsa %s padding-bits-alias\n' "$PADDING_ALIAS" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

# A quoted command contains a decoy token; the real algorithm follows the
# closing quote.  It must not hide the actual duplicate phone key.
write_valid
printf 'command="echo ssh-rsa %s",no-pty ssh-rsa %s hidden-duplicate\n' \
    "$ADMIN" "$MOBILE" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

# Dropbear 2017.75 toggles quote state on an escaped quote while a conventional
# scanner often treats it as quoted data.  Its base64 decoder also ignores the
# quote after the blob.  This exact combination previously hid an unrestricted
# copy of the mobile key behind a fake ssh-ed25519 field.
write_valid
printf 'command="exec /bin/sh #\\" ssh-rsa %s" ssh-ed25519 AAAA\n' \
    "$MOBILE" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

# The device only supports RSA rescue keys. Unknown algorithms are rejected,
# rather than treated as harmless text that could distract Dropbear parsing.
write_valid
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogus unknown\n' >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

# Only a byte-exact project forced line is accepted as optioned RSA.  A forced
# administrator is not a reliable passwordless rescue path.
{
    printf 'command="/bin/false" ssh-rsa %s disabled\n' "$ADMIN"
    printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$MOBILE" "$TAG"
} >"$AUTH"
secure_file
expect_fail --require-mobile "$AUTH" "$MOBILE"

# Bare rescue keys require column zero, one literal space after the algorithm,
# and canonical LF-terminated physical lines.
write_valid
sed -i '1s/^/ /' "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
write_valid
sed -i '1s/ssh-rsa /ssh-rsa  /' "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
write_valid
sed -i $'1s/ssh-rsa /ssh-rsa\t/' "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
write_valid
printf '\r' >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
write_valid
printf '#\rssh-rsa %s injected-after-cr\n' "$MOBILE" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
write_valid
printf '\0' >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
write_valid
truncate -s -1 "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

write_valid
printf '#%*s\n' 4198 '' | tr ' ' A >>"$AUTH"
"$VERIFIER" --require-mobile "$AUTH" --expected-mobile "$MOBILE"
printf '#%*s\n' 4199 '' | tr ' ' A >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

write_valid
printf 'ssh-rsa %s %s\n' "$OTHER_MOBILE" "$TAG" >>"$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

# The mobile key itself is pinned to Android's RSA3072 key policy.
{
    printf 'ssh-rsa %s administrator\n' "$ADMIN"
    printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$SHORT_MOBILE" "$TAG"
} >"$AUTH"
secure_file
expect_fail --require-mobile "$AUTH" "$SHORT_MOBILE"

# Trusted-file constraints: no broad mode, alternate owner, symlink, or hardlink.
write_valid
chmod 644 "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
chmod 600 "$AUTH"
chown 65534:65534 "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"
chown root:root "$AUTH"
ln "$AUTH" "$WORK/authorized_keys.hardlink"
expect_fail --require-mobile "$AUTH" "$MOBILE"
rm "$WORK/authorized_keys.hardlink"
mv "$AUTH" "$WORK/authorized_keys.real"
ln -s "$WORK/authorized_keys.real" "$AUTH"
expect_fail --require-mobile "$AUTH" "$MOBILE"

echo AUTHORIZED_KEYS_VERIFIER_TESTS_OK
