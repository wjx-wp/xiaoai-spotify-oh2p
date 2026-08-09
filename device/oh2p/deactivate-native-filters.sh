#!/bin/sh

set -u

is_bound() {
    awk -v target="$1" '$2 == target { found=1 } END { exit !found }' /proc/mounts
}

/etc/init.d/mico_aivs_lab stop >/dev/null 2>&1 || true
/etc/init.d/touchpad stop >/dev/null 2>&1 || true
is_bound /etc/init.d/mico_aivs_lab && umount /etc/init.d/mico_aivs_lab || true
is_bound /etc/init.d/touchpad && umount /etc/init.d/touchpad || true
/etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || true
/etc/init.d/touchpad start >/dev/null 2>&1 || true
echo NATIVE_FILTERS_INACTIVE
