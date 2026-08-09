// OH2P's /bin/touchpad imports player_toggle() from libmico-common.so.
// Returning success here disables only the stock media toggle. All other
// touchpad functions (volume, mute, sensor handling) remain in the stock
// process and continue to resolve to libmico-common normally.
#include <unistd.h>

static volatile pid_t loaded_in_pid;

__attribute__((constructor)) static void remember_loader_pid(void) {
    // Retaining one libc symbol lets the common OH2P ELF gate verify the
    // library's maximum GLIBC requirement as well as its architecture.
    loaded_in_pid = getpid();
}

int player_toggle(void) {
    (void)loaded_in_pid;
    return 0;
}
