#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#ifndef XIAOAIMUSIC_AUTH_ROOT
#define XIAOAIMUSIC_AUTH_ROOT "/data/xiaoaimusic"
#endif

#ifndef XIAOAIMUSIC_ACCESS_TOKEN_PATH
#define XIAOAIMUSIC_ACCESS_TOKEN_PATH "/tmp/xiaoaimusic-spotify-access-token"
#endif

#ifndef XIAOAIMUSIC_ACCESS_EXPIRY_PATH
#define XIAOAIMUSIC_ACCESS_EXPIRY_PATH "/tmp/xiaoaimusic-spotify-access-expiry"
#endif

#ifndef XIAOAIMUSIC_CONTROL_SOCKET_PATH
#define XIAOAIMUSIC_CONTROL_SOCKET_PATH "/tmp/xiaoaimusic-librespot-control.sock"
#endif

#define AUTH_UPDATE_COMMAND "spotify-auth-update"
#define AUTH_STATUS_COMMAND "spotify-auth-status"
#define TAKEOVER_COMMAND "takeover"
#define TAKEOVER_MESSAGE "transfer"
#define PROTOCOL_MAGIC "XIAOAIMUSIC_AUTH_V1"
#define PROTOCOL_END "END"
#define TOKEN_NAME "spotify-refresh-token"
#define AUTHORIZED_AT_NAME "spotify-authorized-at-ms"
#define REAUTH_MARKER_NAME "spotify-reauthorization-required"
#define LOCK_NAME ".spotify-auth-update.lock"
#define TOKEN_STAGE_NAME ".spotify-refresh-token.update.active"
#define AUTHORIZED_STAGE_NAME ".spotify-authorized-at.update.active"
#define TOKEN_BACKUP_NAME ".spotify-refresh-token.backup.active"
#define AUTHORIZED_BACKUP_NAME ".spotify-authorized-at.backup.active"
#define TRANSACTION_NAME ".spotify-auth-update.transaction"
#define TRANSACTION_NEW_NAME ".spotify-auth-update.transaction.new"
#define TRANSACTION_MAGIC "XIAOAIMUSIC_AUTH_TXN_V1"
#define TOKEN_MIN_LENGTH 32U
#define TOKEN_MAX_LENGTH 4096U
#define INPUT_TIMEOUT_MS 15000LL
#define MIN_AUTHORIZED_AT_MS UINT64_C(1704067200000) /* 2024-01-01 */
#define MAX_AUTHORIZED_AT_MS UINT64_C(4102444800000) /* 2100-01-01 */

static void secure_zero(void *value, size_t length) {
    volatile unsigned char *cursor = value;
    while (length-- > 0U) {
        *cursor++ = 0U;
    }
}

static long long monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (long long)now.tv_sec * 1000LL + (long long)now.tv_nsec / 1000000LL;
}

static int remaining_ms(long long deadline) {
    long long now = monotonic_ms();
    long long remaining;
    if (now < 0 || deadline < now) {
        return 0;
    }
    remaining = deadline - now;
    if (remaining > INT_MAX) {
        return INT_MAX;
    }
    return (int)remaining;
}

static int read_line_until(int fd, char *buffer, size_t capacity,
                           long long deadline) {
    size_t used = 0U;

    if (capacity < 2U) {
        errno = EINVAL;
        return -1;
    }

    for (;;) {
        struct pollfd poll_fd;
        unsigned char byte;
        ssize_t count;
        int timeout = remaining_ms(deadline);
        int ready;

        if (timeout <= 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        poll_fd.fd = fd;
        poll_fd.events = POLLIN | POLLHUP;
        poll_fd.revents = 0;
        ready = poll(&poll_fd, 1, timeout);
        if (ready == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }

        count = read(fd, &byte, 1U);
        if (count == 0) {
            errno = EPROTO;
            return -1;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (byte == '\n') {
            buffer[used] = '\0';
            return (int)used;
        }
        if (byte == '\r' || byte == '\0' || used + 1U >= capacity) {
            errno = EPROTO;
            return -1;
        }
        buffer[used++] = (char)byte;
    }
}

static int require_eof_until(int fd, long long deadline) {
    for (;;) {
        struct pollfd poll_fd;
        unsigned char extra;
        ssize_t count;
        int timeout = remaining_ms(deadline);
        int ready;

        if (timeout <= 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        poll_fd.fd = fd;
        poll_fd.events = POLLIN | POLLHUP;
        poll_fd.revents = 0;
        ready = poll(&poll_fd, 1, timeout);
        if (ready == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        count = read(fd, &extra, 1U);
        if (count == 0) {
            return 0;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        errno = EPROTO;
        return -1;
    }
}

static int reject_immediate_input(int fd) {
    struct pollfd poll_fd;
    unsigned char extra;
    ssize_t count;
    int ready;

    poll_fd.fd = fd;
    poll_fd.events = POLLIN | POLLHUP;
    poll_fd.revents = 0;
    ready = poll(&poll_fd, 1, 0);
    if (ready < 0) {
        return -1;
    }
    if (ready == 0) {
        return 0;
    }
    count = read(fd, &extra, 1U);
    if (count == 0) {
        return 0;
    }
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return 0;
    }
    errno = EPROTO;
    return -1;
}

static int queue_takeover(uid_t trusted_uid) {
    static const char message[] = TAKEOVER_MESSAGE;
    struct sockaddr_un address;
    struct stat metadata;
    size_t path_length = strlen(XIAOAIMUSIC_CONTROL_SOCKET_PATH);
    ssize_t sent;
    int socket_fd;

    /*
     * Do not wait for SSH-channel EOF: some clients deliver it only during
     * teardown, which could queue a takeover after their own timeout.  Reject
     * data that is already present, otherwise perform the fixed action without
     * consuming stdin.
     */
    if (reject_immediate_input(STDIN_FILENO) != 0) {
        return -1;
    }
    if (path_length == 0U || path_length >= sizeof(address.sun_path) ||
        lstat(XIAOAIMUSIC_CONTROL_SOCKET_PATH, &metadata) != 0 ||
        !S_ISSOCK(metadata.st_mode) || metadata.st_uid != trusted_uid ||
        (metadata.st_mode & 0777) != 0600) {
        errno = EPERM;
        return -1;
    }

    socket_fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (socket_fd < 0) {
        return -1;
    }
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, XIAOAIMUSIC_CONTROL_SOCKET_PATH, path_length + 1U);
    sent = sendto(socket_fd, message, sizeof(message) - 1U, 0,
                  (const struct sockaddr *)&address,
                  offsetof(struct sockaddr_un, sun_path) + path_length + 1U);
    {
        int saved_errno = errno;
        (void)close(socket_fd);
        errno = saved_errno;
    }
    if (sent != (ssize_t)(sizeof(message) - 1U)) {
        if (sent >= 0) {
            errno = EIO;
        }
        return -1;
    }
    return 0;
}

static bool valid_authorized_at(const char *value) {
    char *end = NULL;
    unsigned long long parsed;
    size_t index;

    if (strlen(value) != 13U) {
        return false;
    }
    for (index = 0U; index < 13U; index++) {
        if (value[index] < '0' || value[index] > '9') {
            return false;
        }
    }
    errno = 0;
    parsed = strtoull(value, &end, 10);
    return errno == 0 && end != NULL && *end == '\0' &&
           parsed >= MIN_AUTHORIZED_AT_MS && parsed <= MAX_AUTHORIZED_AT_MS;
}

static bool valid_token(const char *value, size_t length) {
    size_t index;
    if (length < TOKEN_MIN_LENGTH || length > TOKEN_MAX_LENGTH) {
        return false;
    }
    for (index = 0U; index < length; index++) {
        unsigned char byte = (unsigned char)value[index];
        if (byte < 0x21U || byte > 0x7eU) {
            return false;
        }
    }
    return true;
}

static int write_all(int fd, const void *data, size_t length) {
    const unsigned char *cursor = data;
    while (length > 0U) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (written == 0) {
            errno = EIO;
            return -1;
        }
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return 0;
}

static int create_stage_file(int root_fd, const char *name,
                             const char *value, size_t length) {
    int fd = openat(root_fd, name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return -1;
    }
    if (fchmod(fd, S_IRUSR | S_IWUSR) != 0 ||
        write_all(fd, value, length) != 0 || write_all(fd, "\n", 1U) != 0 ||
        fsync(fd) != 0) {
        int saved_errno = errno;
        (void)close(fd);
        (void)unlinkat(root_fd, name, 0);
        errno = saved_errno;
        return -1;
    }
    if (close(fd) != 0) {
        int saved_errno = errno;
        (void)unlinkat(root_fd, name, 0);
        errno = saved_errno;
        return -1;
    }
    return 0;
}

static void remove_stale_stages(int root_fd) {
    static const char *const prefixes[] = {
        ".spotify-refresh-token.update.",
        ".spotify-authorized-at.update.",
        ".spotify-reauth.update."
    };
    int directory_fd = dup(root_fd);
    DIR *directory;
    struct dirent *entry;
    size_t prefix_index;

    if (directory_fd < 0) {
        return;
    }
    directory = fdopendir(directory_fd);
    if (directory == NULL) {
        (void)close(directory_fd);
        return;
    }
    while ((entry = readdir(directory)) != NULL) {
        for (prefix_index = 0U;
             prefix_index < sizeof(prefixes) / sizeof(prefixes[0]);
             prefix_index++) {
            size_t prefix_length = strlen(prefixes[prefix_index]);
            if (strncmp(entry->d_name, prefixes[prefix_index], prefix_length) == 0) {
                (void)unlinkat(root_fd, entry->d_name, 0);
                break;
            }
        }
    }
    (void)closedir(directory);
}

static int read_and_validate_token_at(int root_fd, const char *name,
                                      uid_t owner) {
    char token[TOKEN_MAX_LENGTH + 2U];
    struct stat metadata;
    ssize_t count;
    size_t used = 0U;
    int fd;
    int result = -1;

    memset(token, 0, sizeof(token));
    fd = openat(root_fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        goto out;
    }
    if (fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != owner || (metadata.st_mode & 0777) != 0600 ||
        metadata.st_nlink != 1 ||
        metadata.st_size < (off_t)(TOKEN_MIN_LENGTH + 1U) ||
        metadata.st_size > (off_t)(TOKEN_MAX_LENGTH + 1U)) {
        errno = EPERM;
        goto out_close;
    }
    while (used < (size_t)metadata.st_size) {
        count = read(fd, token + used, (size_t)metadata.st_size - used);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            goto out_close;
        }
        if (count == 0) {
            errno = EIO;
            goto out_close;
        }
        used += (size_t)count;
    }
    if (used < 1U || token[used - 1U] != '\n' ||
        !valid_token(token, used - 1U)) {
        errno = EPROTO;
        goto out_close;
    }
    result = 0;

out_close:
    {
        int saved_errno = errno;
        (void)close(fd);
        errno = saved_errno;
    }
out:
    secure_zero(token, sizeof(token));
    return result;
}

static int read_and_validate_authorized_at_at(int root_fd, const char *name,
                                              uid_t owner, char output[14]) {
    struct stat metadata;
    size_t used = 0U;
    int fd;

    fd = openat(root_fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    if (fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != owner || (metadata.st_mode & 0777) != 0600 ||
        metadata.st_nlink != 1 || metadata.st_size != 14) {
        int saved_errno = errno == 0 ? EPERM : errno;
        (void)close(fd);
        errno = saved_errno;
        return -1;
    }
    while (used < 14U) {
        ssize_t count = read(fd, output + used, 14U - used);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            int saved_errno = count == 0 ? EIO : errno;
            (void)close(fd);
            errno = saved_errno;
            return -1;
        }
        used += (size_t)count;
    }
    (void)close(fd);
    if (output[13] != '\n') {
        errno = EPROTO;
        return -1;
    }
    output[13] = '\0';
    if (!valid_authorized_at(output)) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int read_authorized_at_status(int root_fd, uid_t owner,
                                     char output[14]) {
    return read_and_validate_authorized_at_at(root_fd, AUTHORIZED_AT_NAME,
                                              owner, output);
}

static void sanitized_peer(char output[80]) {
    const char *connection = getenv("SSH_CONNECTION");
    size_t used = 0U;
    if (connection == NULL) {
        (void)snprintf(output, 80U, "unknown");
        return;
    }
    while (*connection != '\0' && *connection != ' ' && used + 1U < 80U) {
        unsigned char byte = (unsigned char)*connection++;
        if (!((byte >= '0' && byte <= '9') ||
              (byte >= 'A' && byte <= 'Z') ||
              (byte >= 'a' && byte <= 'z') || byte == '.' || byte == ':' ||
              byte == '_' || byte == '-')) {
            (void)snprintf(output, 80U, "invalid");
            return;
        }
        output[used++] = (char)byte;
    }
    if (used == 0U) {
        (void)snprintf(output, 80U, "unknown");
    } else {
        output[used] = '\0';
    }
}

static int path_exists_at(int root_fd, const char *name, bool *exists) {
    struct stat metadata;
    if (fstatat(root_fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0) {
        *exists = true;
        return 0;
    }
    if (errno == ENOENT) {
        *exists = false;
        return 0;
    }
    return -1;
}

static int unlink_if_exists_at(int root_fd, const char *name) {
    if (unlinkat(root_fd, name, 0) == 0 || errno == ENOENT) {
        return 0;
    }
    return -1;
}

static int validate_named_auth_file(int root_fd, const char *name,
                                    uid_t owner, bool token_file) {
    if (token_file) {
        return read_and_validate_token_at(root_fd, name, owner);
    }
    {
        char authorized_at[14] = {0};
        return read_and_validate_authorized_at_at(root_fd, name, owner,
                                                  authorized_at);
    }
}

static int validated_live_state(int root_fd, const char *name, uid_t owner,
                                bool token_file, bool *exists) {
    if (path_exists_at(root_fd, name, exists) != 0) {
        return -1;
    }
    if (!*exists) {
        return 0;
    }
    return validate_named_auth_file(root_fd, name, owner, token_file);
}

static int copy_trusted_file_to_new(int root_fd, const char *source_name,
                                    const char *destination_name, uid_t owner,
                                    off_t maximum_size) {
    unsigned char buffer[1024];
    struct stat metadata;
    off_t remaining;
    int source_fd = -1;
    int destination_fd = -1;
    int result = -1;

    memset(buffer, 0, sizeof(buffer));
    source_fd = openat(root_fd, source_name,
                       O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (source_fd < 0 || fstat(source_fd, &metadata) != 0) {
        goto out;
    }
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != owner ||
        (metadata.st_mode & 0777) != 0600 || metadata.st_nlink != 1 ||
        metadata.st_size < 1 || metadata.st_size > maximum_size) {
        errno = EPERM;
        goto out;
    }
    destination_fd = openat(
        root_fd, destination_name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR);
    if (destination_fd < 0 ||
        fchmod(destination_fd, S_IRUSR | S_IWUSR) != 0) {
        goto out;
    }

    remaining = metadata.st_size;
    while (remaining > 0) {
        size_t requested = remaining < (off_t)sizeof(buffer)
                               ? (size_t)remaining
                               : sizeof(buffer);
        ssize_t count = read(source_fd, buffer, requested);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0 || write_all(destination_fd, buffer, (size_t)count) != 0) {
            if (count == 0) {
                errno = EIO;
            }
            goto out;
        }
        remaining -= count;
        secure_zero(buffer, sizeof(buffer));
    }
    for (;;) {
        ssize_t count = read(source_fd, buffer, 1U);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count != 0) {
            if (count > 0) {
                errno = EIO;
            }
            goto out;
        }
        break;
    }
    if (fsync(destination_fd) != 0) {
        goto out;
    }
    if (close(destination_fd) != 0) {
        destination_fd = -1;
        goto out;
    }
    destination_fd = -1;
    result = 0;

out:
    {
        int saved_errno = errno;
        secure_zero(buffer, sizeof(buffer));
        if (destination_fd >= 0) {
            (void)close(destination_fd);
        }
        if (source_fd >= 0) {
            (void)close(source_fd);
        }
        if (result != 0) {
            (void)unlinkat(root_fd, destination_name, 0);
        }
        errno = saved_errno;
    }
    return result;
}

static int create_transaction_marker(int root_fd) {
    char value[64];
    struct stat metadata;
    int length;

    length = snprintf(value, sizeof(value), "%s", TRANSACTION_MAGIC);
    if (length < 0 || length >= (int)sizeof(value)) {
        errno = EOVERFLOW;
        return -1;
    }
    if (fstatat(root_fd, TRANSACTION_NAME, &metadata,
                AT_SYMLINK_NOFOLLOW) == 0) {
        errno = EEXIST;
        return -1;
    }
    if (errno != ENOENT ||
        create_stage_file(root_fd, TRANSACTION_NEW_NAME, value,
                          (size_t)length) != 0 ||
        renameat(root_fd, TRANSACTION_NEW_NAME, root_fd, TRANSACTION_NAME) != 0 ||
        fsync(root_fd) != 0) {
        return -1;
    }
    return 0;
}

/*
 * Returns 0 for a valid marker, 1 when no transaction is active, and -1 for
 * an untrusted or malformed marker.  Its durable presence is the commit
 * decision; every recognized phase with a marker rolls forward.
 */
static int read_transaction_marker(int root_fd, uid_t owner) {
    char contents[64];
    struct stat metadata;
    size_t used = 0U;
    int fd;

    memset(contents, 0, sizeof(contents));
    fd = openat(root_fd, TRANSACTION_NAME,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        return errno == ENOENT ? 1 : -1;
    }
    if (fstat(fd, &metadata) != 0) {
        int saved_errno = errno;
        (void)close(fd);
        errno = saved_errno;
        return -1;
    }
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != owner ||
        (metadata.st_mode & 0777) != 0600 ||
        metadata.st_nlink != 1 || metadata.st_size < 1 ||
        metadata.st_size >= (off_t)sizeof(contents)) {
        (void)close(fd);
        errno = EPERM;
        return -1;
    }
    while (used < (size_t)metadata.st_size) {
        ssize_t count = read(fd, contents + used,
                             (size_t)metadata.st_size - used);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            int saved_errno = count == 0 ? EIO : errno;
            (void)close(fd);
            errno = saved_errno;
            return -1;
        }
        used += (size_t)count;
    }
    (void)close(fd);
    contents[used] = '\0';
    if (strcmp(contents, TRANSACTION_MAGIC "\n") != 0) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int cleanup_orphan_transaction_files(int root_fd) {
    static const char *const names[] = {
        TOKEN_STAGE_NAME, AUTHORIZED_STAGE_NAME, TOKEN_BACKUP_NAME,
        AUTHORIZED_BACKUP_NAME, TRANSACTION_NEW_NAME
    };
    size_t index;

    for (index = 0U; index < sizeof(names) / sizeof(names[0]); index++) {
        if (unlink_if_exists_at(root_fd, names[index]) != 0) {
            return -1;
        }
    }
    return fsync(root_fd);
}

static int invalidate_live_access_cache(void) {
    if (unlink(XIAOAIMUSIC_ACCESS_TOKEN_PATH) != 0 && errno != ENOENT) {
        return -1;
    }
    if (unlink(XIAOAIMUSIC_ACCESS_EXPIRY_PATH) != 0 && errno != ENOENT) {
        return -1;
    }
    return 0;
}

static int finish_transaction(int root_fd, bool committed) {
    if (committed) {
        if (unlink_if_exists_at(root_fd, REAUTH_MARKER_NAME) != 0 ||
            invalidate_live_access_cache() != 0 || fsync(root_fd) != 0) {
            return -1;
        }
    }
    /*
     * Once the live pair is consistent, retire and fsync the marker first.
     * Any later crash therefore leaves only safe orphan copies/stages, which
     * the next invocation can remove without guessing a transaction phase.
     */
    if (unlink_if_exists_at(root_fd, TRANSACTION_NAME) != 0 ||
        fsync(root_fd) != 0 || cleanup_orphan_transaction_files(root_fd) != 0) {
        return -1;
    }
    return 0;
}

static int recover_interrupted_transaction(int root_fd, uid_t owner) {
    bool token_stage_exists = false;
    bool authorized_stage_exists = false;
    bool live_token_exists = false;
    bool live_authorized_exists = false;
    int marker_state = read_transaction_marker(root_fd, owner);

    if (marker_state == 1) {
        return cleanup_orphan_transaction_files(root_fd);
    }
    if (marker_state != 0 ||
        path_exists_at(root_fd, TOKEN_STAGE_NAME, &token_stage_exists) != 0 ||
        path_exists_at(root_fd, AUTHORIZED_STAGE_NAME,
                       &authorized_stage_exists) != 0) {
        return -1;
    }

    if (token_stage_exists && authorized_stage_exists) {
        /* A durable marker is the commit decision: always roll forward. */
        if (validate_named_auth_file(root_fd, TOKEN_STAGE_NAME, owner, true) != 0 ||
            validate_named_auth_file(root_fd, AUTHORIZED_STAGE_NAME, owner,
                                     false) != 0 ||
            renameat(root_fd, TOKEN_STAGE_NAME, root_fd, TOKEN_NAME) != 0 ||
            fsync(root_fd) != 0 ||
            renameat(root_fd, AUTHORIZED_STAGE_NAME, root_fd,
                     AUTHORIZED_AT_NAME) != 0 ||
            fsync(root_fd) != 0) {
            return -1;
        }
        return finish_transaction(root_fd, true);
    }

    if (!token_stage_exists && authorized_stage_exists) {
        /*
         * Token rename happened, but timestamp rename did not.  The marker
         * already committed the phone's pending_verified pair, so validate the
         * two durable halves and complete the ordered roll-forward.
         */
        if (validate_named_auth_file(root_fd, TOKEN_NAME, owner, true) != 0 ||
            validate_named_auth_file(root_fd, AUTHORIZED_STAGE_NAME, owner,
                                     false) != 0 ||
            renameat(root_fd, AUTHORIZED_STAGE_NAME, root_fd,
                     AUTHORIZED_AT_NAME) != 0 ||
            fsync(root_fd) != 0) {
            return -1;
        }
        return finish_transaction(root_fd, true);
    }

    if (!token_stage_exists && !authorized_stage_exists) {
        /* Both renames completed; finish committed cleanup idempotently. */
        if (validated_live_state(root_fd, TOKEN_NAME, owner, true,
                                 &live_token_exists) != 0 ||
            validated_live_state(root_fd, AUTHORIZED_AT_NAME, owner, false,
                                 &live_authorized_exists) != 0) {
            return -1;
        }
        if (live_token_exists && live_authorized_exists) {
            return finish_transaction(root_fd, true);
        }
        errno = EPERM;
        return -1;
    }

    errno = EPROTO;
    return -1;
}

#ifdef XIAOAIMUSIC_TEST_FAULT_INJECTION
static void test_crash_at(const char *point) {
    const char *requested = getenv("XIAOAIMUSIC_TEST_CRASH_AT");
    if (requested != NULL && strcmp(requested, point) == 0) {
        (void)kill(getpid(), SIGKILL);
        _exit(137);
    }
}
#else
static void test_crash_at(const char *point) {
    (void)point;
}
#endif

static int commit_staged_files(int root_fd, uid_t owner) {
    bool token_existed = false;
    bool authorized_existed = false;

    if (validated_live_state(root_fd, TOKEN_NAME, owner, true,
                             &token_existed) != 0 ||
        validated_live_state(root_fd, AUTHORIZED_AT_NAME, owner, false,
                             &authorized_existed) != 0 ||
        validate_named_auth_file(root_fd, TOKEN_STAGE_NAME, owner, true) != 0 ||
        validate_named_auth_file(root_fd, AUTHORIZED_STAGE_NAME, owner,
                                 false) != 0) {
        return -1;
    }

    if (token_existed &&
        (copy_trusted_file_to_new(root_fd, TOKEN_NAME, TOKEN_BACKUP_NAME,
                                  owner, (off_t)(TOKEN_MAX_LENGTH + 1U)) != 0 ||
         validate_named_auth_file(root_fd, TOKEN_BACKUP_NAME, owner, true) != 0)) {
        return -1;
    }
    if (fsync(root_fd) != 0) {
        return -1;
    }
    test_crash_at("after-first-backup");

    if (authorized_existed &&
        (copy_trusted_file_to_new(root_fd, AUTHORIZED_AT_NAME,
                                  AUTHORIZED_BACKUP_NAME, owner, 14) != 0 ||
         validate_named_auth_file(root_fd, AUTHORIZED_BACKUP_NAME, owner,
                                  false) != 0)) {
        return -1;
    }
    if (fsync(root_fd) != 0) {
        return -1;
    }
    test_crash_at("after-second-backup");

    if (create_transaction_marker(root_fd) != 0) {
        return -1;
    }
    test_crash_at("after-marker");

    if (renameat(root_fd, TOKEN_STAGE_NAME, root_fd, TOKEN_NAME) != 0 ||
        fsync(root_fd) != 0) {
        return -1;
    }
    test_crash_at("after-first-rename");
    if (renameat(root_fd, AUTHORIZED_STAGE_NAME, root_fd,
                 AUTHORIZED_AT_NAME) != 0 ||
        fsync(root_fd) != 0) {
        return -1;
    }
    test_crash_at("after-second-rename");
    return finish_transaction(root_fd, true);
}

static int commit_staged_files_protected(
    int root_fd, uid_t owner) {
    sigset_t blocked;
    sigset_t previous;
    int result;
    int saved_errno;

    if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGHUP) != 0 ||
        sigaddset(&blocked, SIGINT) != 0 || sigaddset(&blocked, SIGTERM) != 0 ||
        sigprocmask(SIG_BLOCK, &blocked, &previous) != 0) {
        return -1;
    }
#ifdef XIAOAIMUSIC_TEST_COMMIT_DELAY_MS
    {
        struct timespec pause;
        pause.tv_sec = XIAOAIMUSIC_TEST_COMMIT_DELAY_MS / 1000;
        pause.tv_nsec = (XIAOAIMUSIC_TEST_COMMIT_DELAY_MS % 1000) * 1000000L;
        while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
        }
    }
#endif
    /*
     * Token is intentionally renamed first.  The durable marker lets the next
     * invocation roll forward an unmaskable kill between renames, or finish cache
     * invalidation when both renames are already durable.  Maskable disconnect
     * signals stay blocked until that entire committed phase is complete.
     */
    result = commit_staged_files(root_fd, owner);
    saved_errno = errno;
    if (result != 0) {
        /* Best-effort orphan cleanup/roll-forward while the lock is held. */
        (void)recover_interrupted_transaction(root_fd, owner);
    }
    if (sigprocmask(SIG_SETMASK, &previous, NULL) != 0 && result == 0) {
        saved_errno = errno;
        result = -1;
    }
    errno = saved_errno;
    return result;
}

static int acquire_auth_lock(int root_fd, uid_t owner, int *result_fd) {
    struct stat metadata;
    int fd = openat(root_fd, LOCK_NAME,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR);

    if (fd < 0) {
        return -1;
    }
    if (fstat(fd, &metadata) != 0) {
        int saved_errno = errno;
        (void)close(fd);
        errno = saved_errno;
        return -1;
    }
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != owner ||
        (metadata.st_mode & 0777) != 0600 || metadata.st_nlink != 1) {
        (void)close(fd);
        errno = EPERM;
        return -1;
    }
    if (fchmod(fd, S_IRUSR | S_IWUSR) != 0 ||
        fstat(fd, &metadata) != 0) {
        int saved_errno = errno;
        (void)close(fd);
        errno = saved_errno;
        return -1;
    }
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != owner ||
        (metadata.st_mode & 0777) != 0600 || metadata.st_nlink != 1) {
        (void)close(fd);
        errno = EPERM;
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int saved_errno = errno;
        (void)close(fd);
        errno = saved_errno;
        return -1;
    }
    *result_fd = fd;
    return 0;
}

static void respond(const char *message) {
    (void)write_all(STDOUT_FILENO, message, strlen(message));
}

int main(void) {
    char magic[64];
    char authorized_at[32];
    char token[TOKEN_MAX_LENGTH + 1U];
    char end_marker[16];
    char peer[80];
    char status_authorized_at[14] = {0};
    const char *original_command;
    struct rlimit no_core = {0, 0};
    struct stat root_metadata;
    long long deadline;
    int root_fd = -1;
    int lock_fd = -1;
    uid_t trusted_uid;
    int token_length;
    int result = 74;
    bool stages_created = false;
    bool transaction_marker_exists = false;

    memset(token, 0, sizeof(token));
    umask(S_IRWXG | S_IRWXO);
    (void)setrlimit(RLIMIT_CORE, &no_core);
    (void)prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    (void)prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    (void)signal(SIGPIPE, SIG_IGN);
    openlog("xiaoaimusic-auth-update", LOG_PID, LOG_AUTHPRIV);
    sanitized_peer(peer);

#ifndef XIAOAIMUSIC_ALLOW_NON_ROOT
    if (geteuid() != 0) {
        syslog(LOG_ERR, "status=reject reason=not_root peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
#endif
    trusted_uid = geteuid();
    original_command = getenv("SSH_ORIGINAL_COMMAND");
    if (original_command == NULL ||
        (strcmp(original_command, AUTH_UPDATE_COMMAND) != 0 &&
         strcmp(original_command, AUTH_STATUS_COMMAND) != 0 &&
         strcmp(original_command, TAKEOVER_COMMAND) != 0)) {
        syslog(LOG_WARNING, "status=reject reason=original_command peer=%s", peer);
        respond("ERR command\n");
        result = 64;
        goto out;
    }

    deadline = monotonic_ms();
    if (deadline < 0) {
        respond("ERR unavailable\n");
        goto out;
    }
    deadline += INPUT_TIMEOUT_MS;
    if (strcmp(original_command, TAKEOVER_COMMAND) == 0) {
        if (queue_takeover(trusted_uid) != 0) {
            syslog(LOG_WARNING, "status=reject reason=takeover peer=%s", peer);
            respond("ERR takeover\n");
            result = 69;
            goto out;
        }
        syslog(LOG_NOTICE, "status=success action=takeover peer=%s", peer);
        respond("OK takeover_queued\n");
        result = 0;
        goto out;
    }
    if (strcmp(original_command, AUTH_STATUS_COMMAND) == 0) {
        char response[40];
        if (reject_immediate_input(STDIN_FILENO) != 0) {
            syslog(LOG_WARNING, "status=reject reason=status_input peer=%s", peer);
            respond("ERR protocol\n");
            result = 64;
            goto out;
        }
        if (lstat(XIAOAIMUSIC_AUTH_ROOT, &root_metadata) != 0 ||
            !S_ISDIR(root_metadata.st_mode) ||
            root_metadata.st_uid != trusted_uid ||
            (root_metadata.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
            syslog(LOG_ERR, "status=error reason=root_directory peer=%s", peer);
            respond("ERR unavailable\n");
            goto out;
        }
        root_fd = open(XIAOAIMUSIC_AUTH_ROOT,
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (root_fd < 0) {
            syslog(LOG_ERR, "status=error reason=auth_status_root peer=%s",
                   peer);
            respond("ERR unavailable\n");
            goto out;
        }
        if (acquire_auth_lock(root_fd, trusted_uid, &lock_fd) != 0) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
                syslog(LOG_NOTICE, "status=reject reason=busy peer=%s", peer);
                respond("ERR busy\n");
                result = 75;
            } else {
                syslog(LOG_ERR, "status=error reason=status_lock peer=%s",
                       peer);
                respond("ERR unavailable\n");
            }
            goto out;
        }
        if (recover_interrupted_transaction(root_fd, trusted_uid) != 0 ||
            read_and_validate_token_at(root_fd, TOKEN_NAME, trusted_uid) != 0 ||
            read_authorized_at_status(root_fd, trusted_uid,
                                      status_authorized_at) != 0 ||
            snprintf(response, sizeof(response), "OK auth_status %s\n",
                     status_authorized_at) >= (int)sizeof(response)) {
            syslog(LOG_ERR, "status=error reason=auth_status peer=%s", peer);
            respond("ERR unavailable\n");
            goto out;
        }
        respond(response);
        syslog(LOG_NOTICE, "status=success action=auth_status peer=%s", peer);
        result = 0;
        goto out;
    }
    if (read_line_until(STDIN_FILENO, magic, sizeof(magic), deadline) < 0 ||
        strcmp(magic, PROTOCOL_MAGIC) != 0 ||
        read_line_until(STDIN_FILENO, authorized_at, sizeof(authorized_at),
                        deadline) < 0 ||
        !valid_authorized_at(authorized_at) ||
        (token_length = read_line_until(STDIN_FILENO, token, sizeof(token),
                                        deadline)) < 0 ||
        !valid_token(token, (size_t)token_length) ||
        read_line_until(STDIN_FILENO, end_marker, sizeof(end_marker), deadline) < 0 ||
        strcmp(end_marker, PROTOCOL_END) != 0 ||
        require_eof_until(STDIN_FILENO, deadline) != 0) {
        syslog(LOG_WARNING, "status=reject reason=protocol peer=%s", peer);
        respond("ERR protocol\n");
        result = 64;
        goto out;
    }

    if (lstat(XIAOAIMUSIC_AUTH_ROOT, &root_metadata) != 0 ||
        !S_ISDIR(root_metadata.st_mode) || root_metadata.st_uid != trusted_uid ||
        (root_metadata.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        syslog(LOG_ERR, "status=error reason=root_directory peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
    root_fd = open(XIAOAIMUSIC_AUTH_ROOT,
                   O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root_fd < 0) {
        syslog(LOG_ERR, "status=error reason=trusted_paths peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
    if (acquire_auth_lock(root_fd, trusted_uid, &lock_fd) != 0) {
        if (errno == EWOULDBLOCK || errno == EAGAIN) {
            syslog(LOG_NOTICE, "status=reject reason=busy peer=%s", peer);
            respond("ERR busy\n");
            result = 75;
        } else {
            syslog(LOG_ERR, "status=error reason=lock_open peer=%s", peer);
            respond("ERR unavailable\n");
        }
        goto out;
    }
    if (recover_interrupted_transaction(root_fd, trusted_uid) != 0) {
        syslog(LOG_ERR, "status=error reason=transaction_recovery peer=%s",
               peer);
        respond("ERR unavailable\n");
        goto out;
    }
    remove_stale_stages(root_fd);

    (void)unlinkat(root_fd, TOKEN_STAGE_NAME, 0);
    (void)unlinkat(root_fd, AUTHORIZED_STAGE_NAME, 0);
    if (create_stage_file(root_fd, TOKEN_STAGE_NAME, token,
                          (size_t)token_length) != 0) {
        syslog(LOG_ERR, "status=error reason=stage_write peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
    stages_created = true;
    if (create_stage_file(root_fd, AUTHORIZED_STAGE_NAME, authorized_at,
                          strlen(authorized_at)) != 0) {
        syslog(LOG_ERR, "status=error reason=stage_write peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
    secure_zero(token, sizeof(token));

    if (read_and_validate_token_at(root_fd, TOKEN_STAGE_NAME, trusted_uid) != 0 ||
        read_and_validate_authorized_at_at(root_fd, AUTHORIZED_STAGE_NAME,
                                           trusted_uid,
                                           status_authorized_at) != 0) {
        syslog(LOG_ERR, "status=error reason=stage_verify peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
    /* From here on, the transaction marker owns cleanup and crash recovery. */
    stages_created = false;
    if (commit_staged_files_protected(root_fd, trusted_uid) != 0) {
        if (path_exists_at(root_fd, TRANSACTION_NAME,
                           &transaction_marker_exists) == 0 &&
            !transaction_marker_exists) {
            stages_created = true;
        }
        syslog(LOG_ERR, "status=error reason=commit peer=%s", peer);
        respond("ERR unavailable\n");
        goto out;
    }
    syslog(LOG_NOTICE, "status=success peer=%s", peer);
    respond("OK auth_updated\n");
    result = 0;

out:
    secure_zero(token, sizeof(token));
    if (root_fd >= 0) {
        if (stages_created) {
            (void)unlinkat(root_fd, TOKEN_STAGE_NAME, 0);
            (void)unlinkat(root_fd, AUTHORIZED_STAGE_NAME, 0);
            (void)fsync(root_fd);
        }
    }
    if (lock_fd >= 0) {
        (void)close(lock_fd);
    }
    if (root_fd >= 0) {
        (void)close(root_fd);
    }
    closelog();
    return result;
}
