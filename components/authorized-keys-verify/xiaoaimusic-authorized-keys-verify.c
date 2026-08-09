#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define DROPBEAR_LINE_BUFFER 4200U
#define MAX_FILE_SIZE (1024U * 1024U)
#define MOBILE_RSA_BITS 3072U
#define TAG "xiaoaimusic-mobile-auth-v1"
#define OPTIONS                                                               \
    "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,"       \
    "command=\"/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater\""

struct decoded_key {
    unsigned char *bytes;
    size_t length;
    unsigned int modulus_bits;
};

struct key_list {
    struct decoded_key *keys;
    size_t count;
    size_t capacity;
};

struct verify_state {
    bool require_mobile;
    bool expected_mobile_present;
    bool reject_unrestricted_present;
    struct decoded_key expected_mobile;
    struct decoded_key reject_unrestricted;
    struct key_list seen;
    size_t mobile_lines;
    size_t administrator_lines;
};

static void free_key(struct decoded_key *key) {
    free(key->bytes);
    key->bytes = NULL;
    key->length = 0U;
    key->modulus_bits = 0U;
}

static void free_key_list(struct key_list *list) {
    size_t index;
    for (index = 0U; index < list->count; index++) {
        free_key(&list->keys[index]);
    }
    free(list->keys);
    list->keys = NULL;
    list->count = 0U;
    list->capacity = 0U;
}

static int base64_value(unsigned char value) {
    if (value >= 'A' && value <= 'Z') return (int)(value - 'A');
    if (value >= 'a' && value <= 'z') return (int)(value - 'a') + 26;
    if (value >= '0' && value <= '9') return (int)(value - '0') + 52;
    if (value == '+') return 62;
    if (value == '/') return 63;
    return -1;
}

static int decode_canonical_base64(const char *text, size_t text_length,
                                   struct decoded_key *out) {
    size_t maximum;
    size_t input_index;
    size_t output_index = 0U;

    if (text_length < 4U || text_length % 4U != 0U) return -1;
    maximum = (text_length / 4U) * 3U;
    out->bytes = malloc(maximum == 0U ? 1U : maximum);
    if (out->bytes == NULL) return -1;

    for (input_index = 0U; input_index < text_length; input_index += 4U) {
        int first = base64_value((unsigned char)text[input_index]);
        int second = base64_value((unsigned char)text[input_index + 1U]);
        unsigned char third_character = (unsigned char)text[input_index + 2U];
        unsigned char fourth_character = (unsigned char)text[input_index + 3U];
        bool final_group = input_index + 4U == text_length;
        int third;
        int fourth;

        if (first < 0 || second < 0) goto invalid;
        out->bytes[output_index++] =
            (unsigned char)(((unsigned int)first << 2U) |
                            ((unsigned int)second >> 4U));
        if (third_character == '=') {
            if (!final_group || fourth_character != '=' ||
                (second & 0x0f) != 0) goto invalid;
            continue;
        }
        third = base64_value(third_character);
        if (third < 0) goto invalid;
        out->bytes[output_index++] =
            (unsigned char)(((unsigned int)(second & 0x0f) << 4U) |
                            ((unsigned int)third >> 2U));
        if (fourth_character == '=') {
            if (!final_group || (third & 0x03) != 0) goto invalid;
            continue;
        }
        fourth = base64_value(fourth_character);
        if (fourth < 0) goto invalid;
        out->bytes[output_index++] =
            (unsigned char)(((unsigned int)(third & 0x03) << 6U) |
                            (unsigned int)fourth);
    }
    out->length = output_index;
    return 0;

invalid:
    free_key(out);
    return -1;
}

static int read_u32(const unsigned char *bytes, size_t length, size_t *offset,
                    uint32_t *value) {
    if (*offset > length || length - *offset < 4U) return -1;
    *value = ((uint32_t)bytes[*offset] << 24U) |
             ((uint32_t)bytes[*offset + 1U] << 16U) |
             ((uint32_t)bytes[*offset + 2U] << 8U) |
             (uint32_t)bytes[*offset + 3U];
    *offset += 4U;
    return 0;
}

static int positive_mpint_bits(const unsigned char *bytes, size_t length,
                               unsigned int *bits) {
    size_t index = 0U;
    unsigned char first;
    unsigned int high_bits = 0U;

    if (length == 0U || (bytes[0] & 0x80U) != 0U) return -1;
    if (length > 1U && bytes[0] == 0U) {
        if ((bytes[1] & 0x80U) == 0U) return -1;
        index = 1U;
    }
    while (index < length && bytes[index] == 0U) index++;
    if (index == length) return -1;
    first = bytes[index];
    while (first != 0U) {
        high_bits++;
        first >>= 1U;
    }
    if (length - index - 1U > (size_t)(UINT32_MAX / 8U)) return -1;
    *bits = (unsigned int)((length - index - 1U) * 8U) + high_bits;
    return 0;
}

static int validate_ssh_rsa_blob(struct decoded_key *key) {
    static const unsigned char type[] = "ssh-rsa";
    size_t offset = 0U;
    uint32_t field_length;
    unsigned int ignored_bits;

    if (read_u32(key->bytes, key->length, &offset, &field_length) != 0 ||
        field_length != sizeof(type) - 1U ||
        field_length > key->length - offset ||
        memcmp(key->bytes + offset, type, field_length) != 0) return -1;
    offset += field_length;
    if (read_u32(key->bytes, key->length, &offset, &field_length) != 0 ||
        field_length > key->length - offset ||
        positive_mpint_bits(key->bytes + offset, field_length,
                            &ignored_bits) != 0) return -1;
    offset += field_length;
    if (read_u32(key->bytes, key->length, &offset, &field_length) != 0 ||
        field_length > key->length - offset ||
        positive_mpint_bits(key->bytes + offset, field_length,
                            &key->modulus_bits) != 0) return -1;
    offset += field_length;
    return offset == key->length ? 0 : -1;
}

static int decode_rsa_token(const char *text, size_t text_length,
                            struct decoded_key *key) {
    memset(key, 0, sizeof(*key));
    if (decode_canonical_base64(text, text_length, key) != 0 ||
        validate_ssh_rsa_blob(key) != 0) {
        free_key(key);
        return -1;
    }
    return 0;
}

static bool same_key(const struct decoded_key *left,
                     const struct decoded_key *right) {
    return left->length == right->length &&
           memcmp(left->bytes, right->bytes, left->length) == 0;
}

static int remember_unique_key(struct key_list *list,
                               struct decoded_key *candidate) {
    size_t index;
    if (list->count == list->capacity) {
        size_t new_capacity = list->capacity == 0U ? 8U : list->capacity * 2U;
        struct decoded_key *resized;
        if (new_capacity < list->capacity ||
            new_capacity > SIZE_MAX / sizeof(*resized)) return -1;
        resized = realloc(list->keys, new_capacity * sizeof(*resized));
        if (resized == NULL) return -1;
        list->keys = resized;
        list->capacity = new_capacity;
    }
    for (index = 0U; index < list->count; index++) {
        if (same_key(&list->keys[index], candidate)) return -1;
    }
    list->keys[list->count++] = *candidate;
    candidate->bytes = NULL;
    candidate->length = 0U;
    return 0;
}

static bool whitespace(unsigned char value) {
    return value == ' ' || value == '\t';
}

static bool final_token_is_tag(const char *line, size_t length) {
    size_t end = length;
    size_t start;
    size_t tag_length = strlen(TAG);

    while (end > 0U && whitespace((unsigned char)line[end - 1U])) end--;
    start = end;
    while (start > 0U && !whitespace((unsigned char)line[start - 1U])) start--;
    return end - start == tag_length &&
           memcmp(line + start, TAG, tag_length) == 0;
}

/*
 * Do not attempt to accept arbitrary Dropbear option syntax.  Dropbear 2017.75
 * has unusual quote/backslash scanning and a permissive base64 decoder; a
 * parser that is merely "shell-like" can therefore disagree about where the
 * real ssh-rsa field begins.  This verifier accepts only two byte-canonical
 * forms: a column-zero bare rescue RSA key, or this project's exact forced
 * mobile line.  Every other non-comment line fails closed.
 */
static int locate_canonical_key(const char *line, size_t length,
                                const char **blob, size_t *blob_length,
                                bool *bare, bool *mobile) {
    static const char bare_prefix[] = "ssh-rsa ";
    static const char mobile_prefix[] = OPTIONS " ssh-rsa ";
    size_t start;
    size_t cursor;
    size_t tag_length = strlen(TAG);

    start = 0U;
    while (start < length && whitespace((unsigned char)line[start])) start++;
    if (start == length || line[start] == '#') return 1;

    *bare = false;
    *mobile = false;
    if (length > sizeof(bare_prefix) - 1U &&
        memcmp(line, bare_prefix, sizeof(bare_prefix) - 1U) == 0) {
        start = sizeof(bare_prefix) - 1U;
        if (whitespace((unsigned char)line[start])) return -1;
        *bare = true;
    } else if (length > sizeof(mobile_prefix) - 1U + 1U + tag_length &&
               memcmp(line, mobile_prefix,
                      sizeof(mobile_prefix) - 1U) == 0) {
        start = sizeof(mobile_prefix) - 1U;
        if (whitespace((unsigned char)line[start])) return -1;
        *mobile = true;
    } else {
        return -1;
    }

    cursor = start;
    while (cursor < length && !whitespace((unsigned char)line[cursor])) cursor++;
    if (cursor == start) return -1;
    *blob = line + start;
    *blob_length = cursor - start;

    if (*mobile) {
        if (cursor + 1U + tag_length != length || line[cursor] != ' ' ||
            memcmp(line + cursor + 1U, TAG, tag_length) != 0) return -1;
    } else if (final_token_is_tag(line, length)) {
        /* The project tag is reserved for the exact forced-command line. */
        return -1;
    }
    return 0;
}

static int verify_line(const char *line, size_t length,
                       struct verify_state *state) {
    const char *blob;
    size_t blob_length;
    struct decoded_key key;
    bool bare;
    bool mobile;
    int located = locate_canonical_key(line, length, &blob, &blob_length,
                                       &bare, &mobile);

    if (located == 1) return 0;
    if (located != 0) return -1;
    if (decode_rsa_token(blob, blob_length, &key) != 0) return -1;
    if (mobile) {
        if (key.modulus_bits != MOBILE_RSA_BITS ||
            (state->expected_mobile_present &&
             !same_key(&key, &state->expected_mobile)) ||
            ++state->mobile_lines != 1U) {
            free_key(&key);
            return -1;
        }
    } else {
        state->administrator_lines++;
        if (state->reject_unrestricted_present &&
            same_key(&key, &state->reject_unrestricted)) {
            free_key(&key);
            return -1;
        }
    }
    if (remember_unique_key(&state->seen, &key) != 0) {
        free_key(&key);
        return -1;
    }
    return 0;
}

static int verify_contents(unsigned char *contents, size_t length,
                           struct verify_state *state) {
    size_t line_start = 0U;
    size_t index;

    if (length == 0U || contents[length - 1U] != '\n') return -1;
    for (index = 0U; index < length; index++) {
        if ((contents[index] < 0x20U && contents[index] != '\n') ||
            contents[index] == 0x7fU) return -1;
        if (contents[index] == '\n') {
            size_t line_length = index - line_start;
            if (line_length >= DROPBEAR_LINE_BUFFER ||
                verify_line((const char *)contents + line_start, line_length,
                            state) != 0) return -1;
            line_start = index + 1U;
        }
    }
    return line_start == length && state->administrator_lines >= 1U &&
                   state->mobile_lines <= 1U &&
                   (!state->require_mobile || state->mobile_lines == 1U)
               ? 0
               : -1;
}

static int read_trusted_file(const char *path, unsigned char **contents,
                             size_t *length) {
    struct stat metadata;
    unsigned char *buffer;
    size_t used = 0U;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);

    if (fd < 0 || fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != 0 || (metadata.st_mode & 0777) != 0600 ||
        metadata.st_nlink != 1 || metadata.st_size <= 0 ||
        (uintmax_t)metadata.st_size > MAX_FILE_SIZE) {
        if (fd >= 0) (void)close(fd);
        return -1;
    }
    buffer = malloc((size_t)metadata.st_size);
    if (buffer == NULL) {
        (void)close(fd);
        return -1;
    }
    while (used < (size_t)metadata.st_size) {
        ssize_t count = read(fd, buffer + used, (size_t)metadata.st_size - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            free(buffer);
            (void)close(fd);
            return -1;
        }
        used += (size_t)count;
    }
    if (close(fd) != 0) {
        free(buffer);
        return -1;
    }
    *contents = buffer;
    *length = used;
    return 0;
}

int main(int argc, char **argv) {
    struct verify_state state;
    unsigned char *contents = NULL;
    size_t length = 0U;
    int result = 1;

    memset(&state, 0, sizeof(state));
    if (argc != 3 && argc != 5) {
        fputs("usage: verifier MODE FILE [--expected-mobile|--reject-unrestricted RSA_BLOB]\n",
              stderr);
        return 2;
    }
    if (strcmp(argv[1], "--require-mobile") == 0) {
        state.require_mobile = true;
    } else if (strcmp(argv[1], "--allow-no-mobile") != 0) {
        fputs("invalid verifier mode\n", stderr);
        return 2;
    }
    if (argc == 5) {
        struct decoded_key *argument_key;
        if (strcmp(argv[3], "--expected-mobile") == 0) {
            state.expected_mobile_present = true;
            argument_key = &state.expected_mobile;
        } else if (strcmp(argv[3], "--reject-unrestricted") == 0) {
            state.reject_unrestricted_present = true;
            argument_key = &state.reject_unrestricted;
        } else {
            fputs("invalid verifier key policy\n", stderr);
            return 2;
        }
        if (decode_rsa_token(argv[4], strlen(argv[4]), argument_key) != 0) {
            fputs("invalid verifier RSA key\n", stderr);
            return 2;
        }
    }
    if (read_trusted_file(argv[2], &contents, &length) == 0 &&
        verify_contents(contents, length, &state) == 0) result = 0;
    if (result != 0) fputs("authorized_keys verification failed\n", stderr);
    free(contents);
    free_key(&state.expected_mobile);
    free_key(&state.reject_unrestricted);
    free_key_list(&state.seen);
    return result;
}
