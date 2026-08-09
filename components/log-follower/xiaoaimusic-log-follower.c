#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

static int write_all(int fd, const char *buffer, size_t size) {
    while (size) {
        ssize_t count = write(fd, buffer, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        buffer += count;
        size -= (size_t)count;
    }
    return 0;
}

static int drain_file(int fd) {
    char buffer[8192];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            if (write_all(STDOUT_FILENO, buffer, (size_t)count) != 0) return -1;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        return count < 0 ? -1 : 0;
    }
}

static int follow(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 1 : -1;
    if (lseek(fd, 0, SEEK_END) < 0) {
        close(fd);
        return -1;
    }

    int notify_fd = inotify_init1(IN_CLOEXEC);
    if (notify_fd < 0) {
        close(fd);
        return -1;
    }
    int watch = inotify_add_watch(notify_fd, path,
                                  IN_MODIFY | IN_ATTRIB | IN_MOVE_SELF |
                                      IN_DELETE_SELF | IN_IGNORED);
    if (watch < 0) {
        close(notify_fd);
        close(fd);
        return errno == ENOENT ? 1 : -1;
    }

    for (;;) {
        struct pollfd poll_fd = {.fd = notify_fd, .events = POLLIN};
        int ready;
        do {
            ready = poll(&poll_fd, 1, -1);
        } while (ready < 0 && errno == EINTR);
        if (ready < 0) break;

        char events[4096];
        ssize_t count;
        do {
            count = read(notify_fd, events, sizeof(events));
        } while (count < 0 && errno == EINTR);
        if (count < 0) break;

        int reopen = 0;
        for (char *cursor = events; cursor < events + count;) {
            const struct inotify_event *event = (const struct inotify_event *)cursor;
            if (event->mask & (IN_MOVE_SELF | IN_DELETE_SELF | IN_IGNORED)) reopen = 1;
            cursor += sizeof(*event) + event->len;
        }

        struct stat status;
        off_t offset = lseek(fd, 0, SEEK_CUR);
        if (fstat(fd, &status) == 0 && offset > status.st_size) {
            if (lseek(fd, 0, SEEK_SET) < 0) break;
        }
        if (drain_file(fd) != 0) break;
        if (reopen) {
            close(notify_fd);
            close(fd);
            return 1;
        }
    }

    close(notify_fd);
    close(fd);
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s PATH\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_DFL);
    for (;;) {
        int result = follow(argv[1]);
        if (result < 0) {
            fprintf(stderr, "log-follower failed for %s: %s\n", argv[1], strerror(errno));
            return 1;
        }
        usleep(100000);
    }
}
