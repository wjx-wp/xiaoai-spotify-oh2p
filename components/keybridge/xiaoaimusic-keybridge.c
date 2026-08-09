#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static long long monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

static int parse_code(const char *value) {
    char *end = NULL;
    long code = strtol(value, &end, 10);
    if (!value[0] || !end || *end || code < 0 || code > KEY_MAX) return -1;
    return (int)code;
}

static void run_action(const char *action) {
    pid_t pid = fork();
    if (pid != 0) return;
    execl(action, action, (char *)NULL);
    dprintf(STDERR_FILENO, "keybridge exec %s failed: %s\n", action, strerror(errno));
    _exit(127);
}

static int send_control(const char *path, const char *command) {
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    size_t path_len = strlen(path);
    if (path_len >= sizeof(address.sun_path)) {
        close(fd);
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(address.sun_path, path, path_len + 1);
    ssize_t sent = sendto(fd, command, strlen(command), 0,
                          (const struct sockaddr *)&address, sizeof(address));
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return sent == (ssize_t)strlen(command) ? 0 : -1;
}

static int valid_control_command(const char *command) {
    return !strcmp(command, "play") ||
           !strcmp(command, "pause") ||
           !strcmp(command, "toggle") ||
           !strcmp(command, "next") ||
           !strcmp(command, "previous") ||
           !strcmp(command, "transfer");
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage: %s --send-command COMMAND [--control-socket PATH]\n"
            "       %s [--input PATH] [--observe] "
            "[--play-code CODE --control-socket PATH --command COMMAND "
            "--action FALLBACK]\n"
            "commands: play pause toggle next previous transfer\n",
            program, program);
}

int main(int argc, char **argv) {
    const char *input_path = "/dev/input/event0";
    const char *action = "/data/xiaoaimusic/spotify-button-action.sh";
    const char *control_socket = "/tmp/xiaoaimusic-librespot-control.sock";
    const char *command = "toggle";
    int play_code = -1;
    int observe = 0;
    int one_shot = 0;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--input") && i + 1 < argc) {
            input_path = argv[++i];
        } else if (!strcmp(argv[i], "--play-code") && i + 1 < argc) {
            play_code = parse_code(argv[++i]);
        } else if (!strcmp(argv[i], "--action") && i + 1 < argc) {
            action = argv[++i];
        } else if (!strcmp(argv[i], "--control-socket") && i + 1 < argc) {
            control_socket = argv[++i];
        } else if (!strcmp(argv[i], "--command") && i + 1 < argc) {
            command = argv[++i];
        } else if (!strcmp(argv[i], "--send-command") && i + 1 < argc) {
            command = argv[++i];
            one_shot = 1;
        } else if (!strcmp(argv[i], "--observe")) {
            observe = 1;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (one_shot) {
        if (observe || play_code >= 0 || !valid_control_command(command)) {
            usage(argv[0]);
            return 2;
        }
        if (send_control(control_socket, command) != 0) {
            fprintf(stderr, "keybridge local control failed: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    }

    if (!observe && play_code < 0) {
        usage(argv[0]);
        return 2;
    }
    if (!observe && !valid_control_command(command)) {
        usage(argv[0]);
        return 2;
    }
    if (!observe) {
        struct stat status;
        if (stat(action, &status) != 0 || !(status.st_mode & S_IXUSR)) {
            fprintf(stderr, "keybridge action is not executable: %s\n", action);
            return 2;
        }
    }

    signal(SIGCHLD, SIG_IGN);
    int fd = open(input_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "keybridge open %s failed: %s\n", input_path, strerror(errno));
        return 1;
    }

    fprintf(stderr, "keybridge ready input=%s mode=%s play_code=%d\n",
            input_path, observe ? "observe" : "active", play_code);
    long long last_action_ms = 0;
    for (;;) {
        struct input_event event;
        unsigned char *cursor = (unsigned char *)&event;
        size_t remaining = sizeof(event);
        while (remaining) {
            ssize_t count = read(fd, cursor, remaining);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) {
                fprintf(stderr, "keybridge read failed: %s\n",
                        count == 0 ? "end of input" : strerror(errno));
                close(fd);
                return 1;
            }
            cursor += count;
            remaining -= (size_t)count;
        }

        if (event.type != EV_KEY) continue;
        if (observe) {
            fprintf(stderr, "KEY code=%u value=%d\n", event.code, event.value);
            fflush(stderr);
        }
        if (event.code != (unsigned int)play_code || event.value != 0) continue;
        long long now = monotonic_ms();
        if (last_action_ms && now - last_action_ms < 300) continue;
        last_action_ms = now;
        if (send_control(control_socket, command) != 0) {
            dprintf(STDERR_FILENO, "keybridge local control failed: %s; using fallback\n",
                    strerror(errno));
            run_action(action);
        }
    }
}
