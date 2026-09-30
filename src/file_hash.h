#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdint.h>

#define FILE_SHA256_LEN 32
#define FILE_MD5_LEN    16

/*
 * file_digests — computes the SHA-256 (and optionally MD5) digest of a file
 * in a single read pass. Reads bypass the unified buffer cache (F_NOCACHE),
 * so hashing a large file neither evicts useful cached data nor is answered
 * from pages still waiting to be written.
 *
 * Inputs:
 *   path   — null-terminated file-system path
 *   sha256 — FILE_SHA256_LEN-byte output buffer; must not be NULL
 *   md5    — FILE_MD5_LEN-byte output buffer; NULL to skip MD5
 *   cancel — polled before each 1 MB read; non-zero aborts; may be NULL
 *
 * Output: 0 on success, -1 on I/O error, -2 if cancelled.
 */
int file_digests(const char *path, uint8_t sha256[FILE_SHA256_LEN],
                 uint8_t md5[FILE_MD5_LEN], const atomic_int *cancel);

/*
 * digest_hex — formats a digest as a lowercase hex string.
 *
 * Inputs:
 *   digest — digest bytes
 *   len    — number of bytes (FILE_SHA256_LEN or FILE_MD5_LEN)
 *
 * Output: NSString of 2 * len hex characters.
 */
NSString *digest_hex(const uint8_t *digest, size_t len);
