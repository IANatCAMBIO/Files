#import "file_hash.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define HASH_CHUNK (1024 * 1024)  /* largest read buffer: 1 MB */

/*
 * file_digests — single-pass SHA-256 (+ optional MD5) of a file, F_NOCACHE,
 * cancellable, reporting its progress. The read buffer is sized to the file
 * (at most HASH_CHUNK), so hashing many small files does not map and unmap
 * 1 MB each time, and a file hashed in one read reports progress once.
 * Inputs/output are documented in file_hash.h.
 */
int
file_digests(const char *path, uint8_t sha256[FILE_SHA256_LEN],
             uint8_t md5[FILE_MD5_LEN], const atomic_int *cancel,
             file_digest_progress progress)
{
    if (!path || !sha256) return -1;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    fcntl(fd, F_NOCACHE, 1);

    /* One byte more than the file, so a file read in one go ends at once. */
    struct stat st = { 0 };
    size_t buf_len = HASH_CHUNK;
    if (fstat(fd, &st) == 0 && st.st_size < HASH_CHUNK) buf_len = (size_t)st.st_size + 1;
    uint8_t *buf = malloc(buf_len);
    if (!buf) {
        close(fd);
        return -1;
    }

    CC_SHA256_CTX sha_ctx;
    CC_SHA256_Init(&sha_ctx);
    /* MD5 is deprecated for security use; it is shown only as a checksum. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5_CTX md5_ctx;
    if (md5) CC_MD5_Init(&md5_ctx);

    int     ret  = 0;
    int64_t done = 0;
    int64_t size = (st.st_size > 0) ? st.st_size : 0;
    for (;;) {
        if (cancel && atomic_load(cancel)) { ret = -2; break; }
        ssize_t n = read(fd, buf, buf_len);
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            ret = -1;
            break;
        }
        CC_SHA256_Update(&sha_ctx, buf, (CC_LONG)n);
        if (md5) CC_MD5_Update(&md5_ctx, buf, (CC_LONG)n);
        done += n;
        if (progress) progress(done, size);
    }

    if (ret == 0) {
        CC_SHA256_Final(sha256, &sha_ctx);
        if (md5) CC_MD5_Final(md5, &md5_ctx);
    }
#pragma clang diagnostic pop

    free(buf);
    close(fd);
    return ret;
}

/*
 * digest_hex — lowercase hex string for a digest.
 * Inputs/output are documented in file_hash.h.
 */
NSString *
digest_hex(const uint8_t *digest, size_t len)
{
    static const char hex_chars[] = "0123456789abcdef";
    char out[2 * FILE_SHA256_LEN + 1];
    if (len > FILE_SHA256_LEN) len = FILE_SHA256_LEN;
    for (size_t i = 0; i < len; i++) {
        out[2 * i]     = hex_chars[digest[i] >> 4];
        out[2 * i + 1] = hex_chars[digest[i] & 0xf];
    }
    out[2 * len] = '\0';
    return @(out);
}
