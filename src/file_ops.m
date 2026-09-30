#import "file_ops.h"
#import "copy_progress.h"
#import "file_hash.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/clonefile.h>

/* Custom pasteboard type used to record whether the copy was a cut. */
static NSString * const kCutFlagType = @"com.salt.files.cut-flag";

/* Read/write chunk size for copy_file_chunked. */
#define COPY_CHUNK (1024 * 1024)  /* 1 MB */

/* ── C helpers ──────────────────────────────────────────────────────────── */

/*
 * unique_dest_url — returns a non-conflicting destination URL in dir.
 * Appends " copy", " copy 2", etc. until the path is free.
 *
 * Inputs:
 *   name — desired filename
 *   dir  — destination directory URL
 *
 * Output: unique destination URL.
 */
static NSURL *
unique_dest_url(NSString *name, NSURL *dir)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base    = name.stringByDeletingPathExtension;
    NSString *ext     = name.pathExtension;
    NSURL *dest       = [dir URLByAppendingPathComponent:name];
    if (![fm fileExistsAtPath:dest.path]) return dest;
    NSString *suffix = @" copy";
    NSInteger n = 2;
    while (YES) {
        NSString *candidate = ext.length > 0
            ? [NSString stringWithFormat:@"%@%@.%@", base, suffix, ext]
            : [NSString stringWithFormat:@"%@%@", base, suffix];
        dest = [dir URLByAppendingPathComponent:candidate];
        if (![fm fileExistsAtPath:dest.path]) return dest;
        suffix = [NSString stringWithFormat:@" copy %ld", (long)n++];
    }
}

/*
 * chunk_ctx_t — context passed to copy_file_chunked's chunk callback.
 */
typedef struct {
    NSString             *file_name;
    int64_t               file_total;
    int64_t              *total_done;
    int64_t               total_total;
    FileCopyProgressBlock  progress;
    volatile int32_t      *cancel;
} chunk_ctx_t;

/*
 * chunk_callback — invoked by copy_file_chunked after each 1 MB chunk.
 *
 * Inputs:
 *   file_done — bytes transferred for the current file so far
 *   ctx       — pointer to chunk_ctx_t
 */
static void
chunk_callback(int64_t file_done, void *ctx)
{
    chunk_ctx_t *c = (chunk_ctx_t *)ctx;
    *c->total_done += (int64_t)COPY_CHUNK;
    if (c->progress) {
        double bps = 0; /* instantaneous; copy_progress computes sliding window */
        c->progress(c->file_name, file_done, c->file_total,
                    *c->total_done, c->total_total, bps);
    }
}

/*
 * copy_file_chunked — copy src_fd to dst_fd in 1 MB chunks, computing
 * SHA-256 of source bytes as they are read.
 *
 * F_NOCACHE is applied to both fds to avoid polluting the page cache for
 * large files.
 *
 * Inputs:
 *   src_fd     — open readable file descriptor
 *   dst_fd     — open writable file descriptor
 *   src_digest — 32-byte output buffer; filled with SHA-256 of bytes read
 *   chunk_cb   — called after each chunk with bytes-transferred-so-far; may be NULL
 *   cb_ctx     — passed to chunk_cb unchanged
 *   cancel     — if non-NULL and *cancel != 0, aborts early (returns -2)
 *
 * Output: bytes copied on success; -1 on I/O error; -2 if cancelled.
 */
static int64_t
copy_file_chunked(int src_fd, int dst_fd,
                   uint8_t src_digest[32],
                   void (*chunk_cb)(int64_t, void *), void *cb_ctx,
                   volatile int32_t *cancel)
{
    /* F_NOCACHE is set by the caller on src_fd; do NOT set it on dst_fd —
     * forcing uncached destination writes stalls indefinitely on some volumes. */

    CC_SHA256_CTX sha;
    CC_SHA256_Init(&sha);

    uint8_t *buf = malloc(COPY_CHUNK);
    if (!buf) return -1;

    int64_t total = 0;
    ssize_t n;
    int64_t ret = 0;

    while ((n = read(src_fd, buf, COPY_CHUNK)) > 0) {
        if (cancel && *cancel) {
            ret = -2; break;
        }
        CC_SHA256_Update(&sha, buf, (CC_LONG)n);
        if (write(dst_fd, buf, (size_t)n) != n) { ret = -1; break; }
        total += n;
        if (chunk_cb) chunk_cb(total, cb_ctx);
    }
    if (n < 0 && ret == 0) ret = -1;

    free(buf);

    if (ret == 0 && src_digest) {
        CC_SHA256_Final(src_digest, &sha);
    }
    return ret == 0 ? total : ret;
}

/*
 * copy_single_file — copy src_url to dst_url, optionally validate, delete src.
 *
 * Tries clonefile(2) first for zero-I/O CoW on the same APFS volume. Falls
 * back to a manual chunked copy (with progress callbacks) for cross-volume
 * transfers or when hash validation is required.
 *
 * Inputs:
 *   src_url       — source file URL
 *   dst_url       — destination file URL (already uniqued)
 *   is_cut        — YES = unlink src on success
 *   hash_validate — YES = SHA-256 compare src and dst (forces manual path)
 *   cancel        — cancellation flag pointer; may be NULL
 *   total_done    — running byte total shared across the operation (updated)
 *   total_total   — total bytes for the whole operation
 *   progress      — progress block; may be nil
 *   hash_results  — NSMutableDictionary<NSURL *, NSNumber *>; updated if hash_validate
 *
 * Output: nil on success, NSError on failure.
 */
static NSError *
copy_single_file(NSURL *src_url, NSURL *dst_url,
                  BOOL is_cut, BOOL hash_validate,
                  volatile int32_t *cancel,
                  int64_t *total_done, int64_t total_total,
                  FileCopyProgressBlock progress,
                  NSMutableDictionary *hash_results)
{
    /* Create destination parent directory if needed */
    NSString *dst_dir = dst_url.path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager]
        createDirectoryAtPath:dst_dir
  withIntermediateDirectories:YES attributes:nil error:nil];

    /* Fast path: APFS CoW clone — zero I/O, instant regardless of file size.
     * Skipped when hash_validate is YES because we need to read both files.
     * File size is obtained from the destination after cloning (stat on a
     * freshly created local file never blocks). */
    if (!hash_validate) {
        if (clonefile(src_url.path.UTF8String, dst_url.path.UTF8String, 0) == 0) {
            struct stat dst_st;
            int64_t sz = (stat(dst_url.path.UTF8String, &dst_st) == 0)
                         ? dst_st.st_size : 0;
            *total_done += sz;
            if (progress) {
                progress(src_url.lastPathComponent, sz, sz, *total_done, total_total, 0);
            }
            if (is_cut) {
                [[NSFileManager defaultManager] removeItemAtURL:src_url error:nil];
            }
            return nil;
        }
    }

    /* Manual chunked copy — used for cross-volume transfers or hash validation.
     * File size is read via fstat() on the already-open source fd to avoid
     * blocking on getResourceValue: from the copy thread. */
    int src_fd = open(src_url.path.UTF8String, O_RDONLY);
    if (src_fd < 0) {
        return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                               userInfo:@{NSFilePathErrorKey: src_url.path}];
    }
    fcntl(src_fd, F_NOCACHE, 1);  /* avoid polluting page cache on reads */

    struct stat src_st;
    int64_t file_total = (fstat(src_fd, &src_st) == 0) ? src_st.st_size : 0;

    int dst_fd = open(dst_url.path.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (dst_fd < 0) {
        close(src_fd);
        return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                               userInfo:@{NSFilePathErrorKey: dst_url.path}];
    }
    /* No F_NOCACHE on dst — buffered writes are faster and don't stall */

    uint8_t src_digest[32] = {0};
    chunk_ctx_t ctx = {
        .file_name   = src_url.lastPathComponent,
        .file_total  = file_total,
        .total_done  = total_done,
        .total_total = total_total,
        .progress    = progress,
        .cancel      = cancel,
    };
    int64_t copied = copy_file_chunked(src_fd, dst_fd, src_digest,
                                        chunk_callback, &ctx, cancel);
    close(src_fd);
    close(dst_fd);

    if (copied == -2) {
        unlink(dst_url.path.UTF8String);
        return [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSUserCancelledError userInfo:nil];
    }
    if (copied < 0) {
        unlink(dst_url.path.UTF8String);
        return [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
                               userInfo:@{NSFilePathErrorKey: dst_url.path}];
    }

    /* Copy POSIX permissions from source */
    NSDictionary *src_attrs = [[NSFileManager defaultManager]
                                   attributesOfItemAtPath:src_url.path error:nil];
    if (src_attrs[NSFilePosixPermissions]) {
        [[NSFileManager defaultManager]
            setAttributes:@{NSFilePosixPermissions: src_attrs[NSFilePosixPermissions]}
             ofItemAtPath:dst_url.path
                    error:nil];
    }

    /* SHA-256 validate */
    if (hash_validate) {
        uint8_t dst_digest[32];
        BOOL ok = (file_sha256(dst_url.path.UTF8String, dst_digest) == 0) &&
                  (memcmp(src_digest, dst_digest, 32) == 0);
        hash_results[dst_url] = @(ok);
    }

    /* Move-semantics: delete source after successful copy */
    if (is_cut) {
        [[NSFileManager defaultManager] removeItemAtURL:src_url error:nil];
    }

    return nil;
}

/*
 * collect_pairs — recursively collect (src, dst) file URL pairs.
 * Creates destination directory structure as it descends.
 *
 * Inputs:
 *   src     — source item URL (file or directory)
 *   dst_dir — destination parent directory URL
 *   pairs   — mutable array of @{@"src": NSURL, @"dst": NSURL} dictionaries
 */
static void
collect_pairs(NSURL *src, NSURL *dst_dir, NSMutableArray *pairs)
{
    NSNumber *is_dir = nil;
    [src getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];

    NSURL *dst = [dst_dir URLByAppendingPathComponent:src.lastPathComponent];

    if (is_dir.boolValue) {
        [NSFileManager.defaultManager
            createDirectoryAtURL:dst
     withIntermediateDirectories:YES attributes:nil error:nil];
        NSArray *children = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:src
          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                             options:0 error:nil];
        for (NSURL *child in children) {
            collect_pairs(child, dst, pairs);
        }
    } else {
        [pairs addObject:@{@"src": src, @"dst": dst}];
    }
}

/* ── FilesFileOps implementation ────────────────────────────────────────── */

@implementation FilesFileOps

/*
 * copy_urls:is_cut: — writes file URLs and the cut flag to the general pasteboard.
 *
 * Inputs:
 *   urls   — file URLs to write
 *   is_cut — YES to mark as cut
 */
+ (void)
copy_urls:(NSArray<NSURL *> *)urls is_cut:(BOOL)is_cut
{
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb writeObjects:urls];
    [pb setString:is_cut ? @"YES" : @"NO" forType:kCutFlagType];
}

/*
 * pasteboard_has_files — returns YES if pasteboard contains file URLs.
 */
+ (BOOL)
pasteboard_has_files
{
    return [NSPasteboard.generalPasteboard
                canReadObjectForClasses:@[NSURL.class]
                                options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
}

/*
 * pasteboard_is_cut — returns YES if the pasteboard cut flag is set.
 */
+ (BOOL)
pasteboard_is_cut
{
    NSString *flag = [NSPasteboard.generalPasteboard stringForType:kCutFlagType];
    return [flag isEqualToString:@"YES"];
}

/*
 * urls_from_pasteboard — reads file URLs from the general pasteboard.
 *
 * Output: array of NSURL, empty if none found.
 */
+ (NSArray<NSURL *> *)
urls_from_pasteboard
{
    NSArray *items =
        [NSPasteboard.generalPasteboard
             readObjectsForClasses:@[NSURL.class]
                           options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    return items ?: @[];
}

/*
 * run_copy_srcs:to:is_cut:hash_validate:conflict:cancel_flag:progress:completion: —
 * core copy engine. Runs entirely on a background queue.
 *
 * Inputs:
 *   srcs          — source URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = delete sources on success
 *   hash_validate — YES = SHA-256 verify each file
 *   conflict      — called when a destination file already exists; nil = keep both
 *   cancel_flag   — pointer to int32_t cancel flag; may be NULL
 *   progress      — chunk callback; may be nil
 *   completion    — called on main queue when done
 */
+ (void)
run_copy_srcs:(NSArray<NSURL *> *)srcs
           to:(NSURL *)dest
       is_cut:(BOOL)is_cut
hash_validate:(BOOL)hash_validate
     conflict:(FilesConflictBlock)conflict
  cancel_flag:(volatile int32_t *)cancel_flag
     progress:(FileCopyProgressBlock)progress
   completion:(void (^)(NSError *, NSDictionary<NSURL *, NSNumber *> *))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        /* Build (src, dst) pairs, resolving conflicts at the top-level item. */
        NSMutableArray *pairs = [NSMutableArray array];
        NSError *first_err = nil;

        for (NSURL *src in srcs) {
            NSURL *naive_dst = [dest URLByAppendingPathComponent:src.lastPathComponent];
            NSNumber *is_dir = nil;
            [src getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];

            NSURL *top_dst;
            if (!is_dir.boolValue &&
                [NSFileManager.defaultManager fileExistsAtPath:naive_dst.path]) {
                FilesConflictResolution res = conflict
                    ? conflict(src, naive_dst)
                    : FilesConflictKeepBoth;
                if (res == FilesConflictCancel) {
                    first_err = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:NSUserCancelledError userInfo:nil];
                    break;
                }
                top_dst = (res == FilesConflictKeepBoth)
                    ? unique_dest_url(src.lastPathComponent, dest)
                    : naive_dst;
            } else {
                top_dst = naive_dst;
            }

            if (is_dir.boolValue) {
                [NSFileManager.defaultManager
                    createDirectoryAtURL:top_dst
             withIntermediateDirectories:YES attributes:nil error:nil];
                NSArray *children = [NSFileManager.defaultManager
                    contentsOfDirectoryAtURL:src
                  includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                     options:0 error:nil];
                for (NSURL *child in children) {
                    collect_pairs(child, top_dst, pairs);
                }
            } else {
                [pairs addObject:@{@"src": src, @"dst": top_dst}];
            }
        }

        NSMutableDictionary *hash_results =
            hash_validate ? [NSMutableDictionary dictionary] : nil;
        __block int64_t total_done = 0;

        if (!first_err) {
            for (NSDictionary *pair in pairs) {
                if (cancel_flag && *cancel_flag) {
                    first_err = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:NSUserCancelledError userInfo:nil];
                    break;
                }
                NSError *err = copy_single_file(pair[@"src"], pair[@"dst"],
                                                 is_cut, hash_validate,
                                                 cancel_flag,
                                                 &total_done, 0,
                                                 progress, hash_results);
                if (err && !first_err) first_err = err;
                if (err && err.code == NSUserCancelledError) break;
            }
        }

        /* For cut operations, remove source directories after all files moved */
        if (is_cut && !first_err) {
            for (NSURL *src in srcs) {
                NSNumber *is_dir = nil;
                [src getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
                if (is_dir.boolValue) {
                    [NSFileManager.defaultManager removeItemAtURL:src error:nil];
                }
            }
        }

        NSDictionary *frozen_results = [hash_results copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(first_err, frozen_results);
        });
    });
}

/*
 * paste_to_directory:progress:hash_validate:completion: — reads pasteboard
 * URLs then delegates to run_copy_srcs:.
 *
 * Inputs:
 *   dest          — destination directory URL
 *   progress      — chunk progress callback; may be nil
 *   hash_validate — YES = SHA-256 verify
 *   completion    — called on main queue
 */
+ (void)
paste_to_directory:(NSURL *)dest
          progress:(FileCopyProgressBlock)progress
     hash_validate:(BOOL)hash_validate
        completion:(void (^)(NSError *, NSDictionary<NSURL *, NSNumber *> *))completion
{
    NSArray<NSURL *> *srcs = [self urls_from_pasteboard];
    if (srcs.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, nil); });
        return;
    }
    BOOL is_cut = [self pasteboard_is_cut];
    if (is_cut) [NSPasteboard.generalPasteboard clearContents];

    [self run_copy_srcs:srcs to:dest is_cut:is_cut hash_validate:hash_validate
             conflict:nil cancel_flag:NULL progress:progress completion:completion];
}

/*
 * paste_to_directory:completion: — convenience wrapper that reads the hash
 * preference from NSUserDefaults and routes through FilesCopyProgress.
 *
 * Inputs:
 *   dest       — destination directory URL
 *   completion — called on main queue; error is nil on success
 */
+ (void)
paste_to_directory:(NSURL *)dest completion:(void (^)(NSError *))completion
{
    NSArray<NSURL *> *srcs = [self urls_from_pasteboard];
    if (srcs.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
        return;
    }
    BOOL is_cut = [self pasteboard_is_cut];
    if (is_cut) [NSPasteboard.generalPasteboard clearContents];

    BOOL hash = [NSUserDefaults.standardUserDefaults
                     boolForKey:@"files.copy.hash_validation"];

    [FilesCopyProgress begin_copy:srcs to:dest is_cut:is_cut
                    hash_validate:hash
                       completion:completion];
}

/*
 * move_to_trash:completion: — moves urls to the system trash.
 *
 * Inputs:
 *   urls       — file URLs to trash
 *   completion — called on main queue; error is nil on success
 */
+ (void)
move_to_trash:(NSArray<NSURL *> *)urls
   completion:(void (^)(NSError *))completion
{
    if (urls.count == 0) {
        if (completion) completion(nil);
        return;
    }
    [NSWorkspace.sharedWorkspace recycleURLs:urls
                           completionHandler:^(NSDictionary *new_urls, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(err);
        });
    }];
}

/*
 * create_folder_in:name:completion: — creates a directory in parent.
 *
 * Inputs:
 *   parent     — parent directory URL
 *   name       — folder name; defaults to "untitled folder" if nil/empty
 *   completion — called on main queue with new URL or error
 */
+ (void)
create_folder_in:(NSURL *)parent
             name:(NSString *)name
       completion:(void (^)(NSURL *, NSError *))completion
{
    if (name.length == 0) name = @"untitled folder";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *dest  = unique_dest_url(name, parent);
        NSError *err = nil;
        BOOL ok = [NSFileManager.defaultManager
                       createDirectoryAtURL:dest
                  withIntermediateDirectories:NO attributes:nil error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok ? dest : nil, ok ? nil : err);
        });
    });
}

/*
 * rename_url:to:completion: — renames a file or directory.
 *
 * Inputs:
 *   url        — current URL
 *   new_name   — new filename (last path component only)
 *   completion — called on main queue with new URL or error
 */
+ (void)
rename_url:(NSURL *)url
        to:(NSString *)new_name
completion:(void (^)(NSURL *, NSError *))completion
{
    if (new_name.length == 0) {
        NSError *err = [NSError errorWithDomain:NSCocoaErrorDomain
                                           code:NSFileWriteInvalidFileNameError
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"Name cannot be empty"}];
        if (completion) completion(nil, err);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *dest  = [url.URLByDeletingLastPathComponent
                            URLByAppendingPathComponent:new_name];
        NSError *err = nil;
        BOOL ok = [NSFileManager.defaultManager moveItemAtURL:url toURL:dest error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok ? dest : nil, ok ? nil : err);
        });
    });
}

@end
