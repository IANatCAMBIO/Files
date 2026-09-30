#import <Foundation/Foundation.h>
#include <stdint.h>

/*
 * file_sha256 — compute SHA-256 digest of a file.
 *
 * Inputs:
 *   path   — null-terminated UTF-8 path of the file to hash
 *   digest — caller-supplied 32-byte buffer; filled on success
 *
 * Output: 0 on success, -1 on I/O error.
 */
int file_sha256(const char *path, uint8_t digest[32]);

/*
 * sha256_hex — format a 32-byte SHA-256 digest as a lowercase hex NSString.
 *
 * Inputs:
 *   digest — 32-byte buffer from file_sha256
 *
 * Output: 64-character lowercase hex NSString.
 */
NSString *sha256_hex(const uint8_t digest[32]);
