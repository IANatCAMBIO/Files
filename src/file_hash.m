#import "file_hash.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#define HASH_CHUNK (1024 * 1024)  /* 1 MB read buffer */

/*
 * file_sha256 — compute SHA-256 digest of a file in 1 MB chunks.
 *
 * Inputs:
 *   path   — null-terminated UTF-8 file path
 *   digest — 32-byte output buffer
 *
 * Output: 0 on success, -1 on I/O error or if path is NULL.
 */
int
file_sha256(const char *path, uint8_t digest[32])
{
    if (!path || !digest) return -1;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    uint8_t *buf = malloc(HASH_CHUNK);
    if (!buf) {
        close(fd);
        return -1;
    }

    ssize_t n;
    int ret = 0;
    while ((n = read(fd, buf, HASH_CHUNK)) > 0) {
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    }
    if (n < 0) {
        ret = -1;
    }

    free(buf);
    close(fd);

    if (ret == 0) {
        CC_SHA256_Final(digest, &ctx);
    }
    return ret;
}

/*
 * sha256_hex — format a 32-byte SHA-256 digest as a lowercase hex NSString.
 *
 * Inputs:
 *   digest — 32-byte buffer produced by file_sha256
 *
 * Output: 64-character lowercase hex NSString.
 */
NSString *
sha256_hex(const uint8_t digest[32])
{
    char hex[65];
    for (int i = 0; i < 32; i++) {
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    }
    hex[64] = '\0';
    return [NSString stringWithUTF8String:hex];
}
