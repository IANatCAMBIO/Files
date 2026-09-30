#import "file_ops.h"
#import "copy_progress.h"
#import "file_hash.h"
#include <copyfile.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

/* Custom pasteboard type used to record whether the copy was a cut. */
static NSString * const kCutFlagType = @"com.salt.files.cut-flag";

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
 * item_exists — lstat-based existence test that does not follow symlinks,
 * so a dangling symlink at the destination still counts as a conflict.
 *
 * Inputs:
 *   url — file URL to test
 *
 * Output: YES if anything (file, directory, symlink) exists at url.
 */
static BOOL
item_exists(NSURL *url)
{
    struct stat st;
    return lstat(url.fileSystemRepresentation, &st) == 0;
}

/*
 * posix_error — wraps an errno value in an NSError carrying the offending path.
 *
 * Inputs:
 *   code — errno value
 *   url  — file URL the failure relates to
 *
 * Output: NSError in NSPOSIXErrorDomain.
 */
static NSError *
posix_error(int code, NSURL *url)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                           userInfo:@{NSFilePathErrorKey: url.path ?: @""}];
}

/*
 * described_error — builds an NSError with a user-facing description.
 *
 * Inputs:
 *   text — localized description shown in alerts and the transfer log
 *
 * Output: NSError in NSCocoaErrorDomain (NSFileWriteUnknownError).
 */
static NSError *
described_error(NSString *text)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

/*
 * sibling_temp_url — returns a hidden, unique URL next to dst. Items are
 * staged here and only renamed onto dst once they are complete, so an
 * interrupted or failed transfer never touches what is already at dst.
 *
 * Inputs:
 *   dst — final destination URL
 *   tag — short label embedded in the name ("tmp" or "old")
 *
 * Output: URL in the same directory as dst (same volume, so rename(2) works).
 */
static NSURL *
sibling_temp_url(NSURL *dst, NSString *tag)
{
    NSString *name = [NSString stringWithFormat:@".%@.files-%@-%@",
                      dst.lastPathComponent, tag, NSUUID.UUID.UUIDString];
    return [dst.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
}

/*
 * copy_ctx_t — state shared with copy_status_cb for one top-level item.
 */
typedef struct {
    FileCopyProgressBlock  progress;    /* may be nil */
    volatile int32_t      *cancel;      /* may be NULL */
    int64_t                total_done;  /* bytes across the whole operation */
    NSString              *file_name;   /* file currently being copied */
    int64_t                file_total;  /* its size */
    int64_t                file_done;   /* bytes of it copied so far */
    int                    err;         /* errno from the first COPYFILE_ERR */
} copy_ctx_t;

/*
 * report_progress — advances the current file to `copied` bytes and emits a
 * progress callback.
 *
 * Inputs:
 *   c      — copy context
 *   copied — bytes of the current file copied so far (monotonic)
 */
static void
report_progress(copy_ctx_t *c, int64_t copied)
{
    if (copied > c->file_done) {
        c->total_done += copied - c->file_done;
        c->file_done   = copied;
    }
    if (c->progress) {
        c->progress(c->file_name, c->file_done, c->file_total,
                    c->total_done, 0, 0);
    }
}

/*
 * copy_status_cb — copyfile(3) status callback. Reports per-file and
 * per-chunk progress, honours the cancel flag, and aborts on the first error
 * (copyfile's default is to skip unreadable items and still return success).
 *
 * Inputs:
 *   what, stage — copyfile event (COPYFILE_RECURSE_FILE / COPYFILE_COPY_DATA,
 *                 COPYFILE_START / COPYFILE_PROGRESS / COPYFILE_FINISH / COPYFILE_ERR)
 *   state       — copyfile state (queried for COPYFILE_STATE_COPIED)
 *   src, dst    — paths of the item being processed
 *   ctx         — copy_ctx_t pointer
 *
 * Output: COPYFILE_CONTINUE, or COPYFILE_QUIT on cancel or error.
 */
static int
copy_status_cb(int what, int stage, copyfile_state_t state,
               const char *src, const char *dst, void *ctx)
{
    (void)dst;
    copy_ctx_t *c = (copy_ctx_t *)ctx;

    if (c->cancel && *c->cancel) return COPYFILE_QUIT;
    if (stage == COPYFILE_ERR) {
        if (c->err == 0) c->err = errno ? errno : EIO;
        return COPYFILE_QUIT;
    }

    if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START) {
        struct stat st;
        c->file_name  = @(src).lastPathComponent;
        c->file_total = (lstat(src, &st) == 0) ? st.st_size : 0;
        c->file_done  = 0;
        report_progress(c, 0);
    } else if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        off_t copied = 0;
        copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied);
        report_progress(c, copied);
    } else if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH) {
        /* Clones produce no COPY_DATA events; account for the whole file. */
        report_progress(c, c->file_total);
    }
    return COPYFILE_CONTINUE;
}

/*
 * copy_tree — copies src (file, directory tree, or symlink) to dst, which
 * must not exist. Uses copyfile(3) so APFS clones are used where possible and
 * xattrs, ACLs, Finder info, flags and timestamps are preserved; symlinks are
 * copied as links. A partial dst is removed on failure.
 *
 * Inputs:
 *   src — source URL
 *   dst — destination URL (must not exist)
 *   c   — copy context (progress, cancel flag)
 *
 * Output: nil on success; NSUserCancelledError on cancel; otherwise an error.
 */
static NSError *
copy_tree(NSURL *src, NSURL *dst, copy_ctx_t *c)
{
    copyfile_state_t state = copyfile_state_alloc();
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (const void *)&copy_status_cb);
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, c);

    c->err = 0;
    int rc = copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation,
                      state,
                      COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE
                      | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC);
    int saved_errno = errno;
    copyfile_state_free(state);

    if (rc == 0) return nil;

    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    if (c->cancel && *c->cancel) {
        return [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSUserCancelledError userInfo:nil];
    }
    return posix_error(c->err ? c->err : saved_errno, src);
}

/*
 * same_contents — SHA-256 compares two regular files.
 *
 * Inputs:
 *   a, b — file URLs
 *
 * Output: YES if both hash successfully and the digests match.
 */
static BOOL
same_contents(NSURL *a, NSURL *b)
{
    uint8_t da[32], db[32];
    return file_sha256(a.fileSystemRepresentation, da) == 0
        && file_sha256(b.fileSystemRepresentation, db) == 0
        && memcmp(da, db, sizeof da) == 0;
}

/*
 * verify_copy — SHA-256 compares every regular file under src with its
 * counterpart under copy, recording one result per file keyed by the file's
 * final URL under dst.
 *
 * Inputs:
 *   src          — original item (file or directory)
 *   copy         — staged copy of src (same relative layout)
 *   dst          — URL the copy will be committed to (used for result keys)
 *   hash_results — receives dst-relative URL -> @YES / @NO
 *
 * Output: YES if every file matched.
 */
static BOOL
verify_copy(NSURL *src, NSURL *copy, NSURL *dst, NSMutableDictionary *hash_results)
{
    struct stat st;
    if (lstat(src.fileSystemRepresentation, &st) != 0) return NO;
    if (S_ISREG(st.st_mode)) {
        BOOL ok = same_contents(src, copy);
        hash_results[dst] = @(ok);
        return ok;
    }
    if (!S_ISDIR(st.st_mode)) return YES;  /* symlinks etc. carry no data */

    BOOL all_ok = YES;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:src.path];
    for (NSString *rel in e) {
        if (![e.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        BOOL ok = same_contents([src URLByAppendingPathComponent:rel],
                                [copy URLByAppendingPathComponent:rel]);
        hash_results[[dst URLByAppendingPathComponent:rel]] = @(ok);
        if (!ok) all_ok = NO;
    }
    return all_ok;
}

/*
 * commit_item — renames a fully staged item onto dst.
 *
 * Without replace, dst must not exist (RENAME_EXCL). With replace, the
 * existing dst is first renamed aside, the staged item renamed into place,
 * and only then is the old item deleted; if the second rename fails the old
 * item is put back. The existing dst is therefore never lost on failure.
 *
 * Inputs:
 *   staged  — complete item in the destination directory
 *   dst     — final URL
 *   replace — YES to replace an existing dst
 *
 * Output: nil on success, NSError on failure (staged is left in place).
 */
static NSError *
commit_item(NSURL *staged, NSURL *dst, BOOL replace)
{
    const char *staged_p = staged.fileSystemRepresentation;
    const char *dst_p    = dst.fileSystemRepresentation;

    if (!replace || !item_exists(dst)) {
        return renamex_np(staged_p, dst_p, RENAME_EXCL) == 0
            ? nil : posix_error(errno, dst);
    }

    NSURL *old = sibling_temp_url(dst, @"old");
    if (rename(dst_p, old.fileSystemRepresentation) != 0) {
        return posix_error(errno, dst);
    }
    if (rename(staged_p, dst_p) != 0) {
        int saved_errno = errno;
        rename(old.fileSystemRepresentation, dst_p);
        return posix_error(saved_errno, dst);
    }
    /* The new item is in place; a failed cleanup only leaves a hidden
     * ".<name>.files-old-*" item behind, never data loss. */
    [NSFileManager.defaultManager removeItemAtURL:old error:nil];
    return nil;
}

/*
 * transfer_item — copies or moves one top-level item to dst.
 *
 * The item is staged under a hidden sibling name of dst and committed with
 * commit_item only once it is complete (and, if requested, hash-verified),
 * so cancel, I/O errors and validation failures leave dst untouched.
 * Moves try rename(2) first; across volumes they copy, verify, commit, and
 * only then delete the source.
 *
 * Inputs:
 *   src           — source item URL
 *   dst           — final destination URL
 *   replace       — YES to replace an existing dst (user chose Replace)
 *   is_cut        — YES = move (source removed on success)
 *   hash_validate — YES = SHA-256 verify copied files before committing
 *   c             — copy context (progress, cancel flag)
 *   hash_results  — receives per-file verification results; may be nil
 *
 * Output: nil on success, NSError otherwise.
 */
static NSError *
transfer_item(NSURL *src, NSURL *dst, BOOL replace, BOOL is_cut,
              BOOL hash_validate, copy_ctx_t *c, NSMutableDictionary *hash_results)
{
    NSURL *staged = sibling_temp_url(dst, @"tmp");

    if (is_cut) {
        if (renamex_np(src.fileSystemRepresentation, staged.fileSystemRepresentation,
                       RENAME_EXCL) == 0) {
            c->file_name  = src.lastPathComponent;
            c->file_total = 0;
            c->file_done  = 0;
            report_progress(c, 0);
            NSError *err = commit_item(staged, dst, replace);
            if (err) {
                rename(staged.fileSystemRepresentation, src.fileSystemRepresentation);
            }
            return err;
        }
        if (errno != EXDEV) return posix_error(errno, src);
    }

    NSError *err = copy_tree(src, staged, c);
    if (err) return err;

    if (hash_validate && !verify_copy(src, staged, dst, hash_results)) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        return described_error([NSString stringWithFormat:
            @"SHA-256 validation failed for \"%@\". Nothing was replaced and "
             "the source was kept.", src.lastPathComponent]);
    }

    err = commit_item(staged, dst, replace);
    if (err) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        return err;
    }

    if (is_cut && ![NSFileManager.defaultManager removeItemAtURL:src error:&err]) {
        return described_error([NSString stringWithFormat:
            @"\"%@\" was copied but the original could not be removed: %@",
            src.lastPathComponent, err.localizedDescription]);
    }
    return nil;
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
 * Each top-level source is handled by transfer_item (staged copy, then
 * rename into place). Before that:
 *   - copying a folder into itself or one of its subfolders is rejected;
 *   - an item pasted into its own folder is duplicated (" copy" suffix) on
 *     copy, and skipped on cut;
 *   - an existing file or folder at the destination triggers `conflict`.
 *
 * Inputs:
 *   srcs          — source URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = move sources
 *   hash_validate — YES = SHA-256 verify each copied file before committing
 *   conflict      — called when the destination item exists; nil = keep both
 *   cancel_flag   — pointer to int32_t cancel flag; may be NULL
 *   progress      — progress callback; may be nil
 *   completion    — called on main queue with the first error (nil on
 *                   success) and per-file hash results (nil unless hash_validate)
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
        NSMutableDictionary *hash_results =
            hash_validate ? [NSMutableDictionary dictionary] : nil;
        copy_ctx_t ctx = { .progress = progress, .cancel = cancel_flag };
        NSString *dest_path = dest.URLByStandardizingPath.path;
        NSError *first_err  = nil;

        for (NSURL *src in srcs) {
            if (cancel_flag && *cancel_flag) {
                first_err = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSUserCancelledError userInfo:nil];
                break;
            }

            NSString *src_path = src.URLByStandardizingPath.path;
            if ([dest_path isEqualToString:src_path] ||
                [dest_path hasPrefix:[src_path stringByAppendingString:@"/"]]) {
                first_err = described_error([NSString stringWithFormat:
                    @"\"%@\" can't be copied into itself.", src.lastPathComponent]);
                break;
            }

            NSURL *dst   = [dest URLByAppendingPathComponent:src.lastPathComponent];
            BOOL replace = NO;
            if ([dst.URLByStandardizingPath.path isEqualToString:src_path]) {
                if (is_cut) continue;              /* moving onto itself: no-op */
                dst = unique_dest_url(src.lastPathComponent, dest);
            } else if (item_exists(dst)) {
                FilesConflictResolution res = conflict ? conflict(src, dst)
                                                       : FilesConflictKeepBoth;
                if (res == FilesConflictCancel) {
                    first_err = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:NSUserCancelledError userInfo:nil];
                    break;
                }
                if (res == FilesConflictKeepBoth) {
                    dst = unique_dest_url(src.lastPathComponent, dest);
                } else {
                    replace = YES;
                }
            }

            NSError *err = transfer_item(src, dst, replace, is_cut, hash_validate,
                                         &ctx, hash_results);
            if (err && !first_err) first_err = err;
            if (err.code == NSUserCancelledError &&
                [err.domain isEqualToString:NSCocoaErrorDomain]) break;
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
 * transfer_urls:to:is_cut:completion: — copies or moves srcs into dest with
 * the progress panel, honouring the "files.copy.hash_validation" preference.
 *
 * Inputs:
 *   srcs       — source file/directory URLs
 *   dest       — destination directory URL
 *   is_cut     — YES = move instead of copy
 *   completion — called on main queue; error is nil on success
 */
+ (void)
transfer_urls:(NSArray<NSURL *> *)srcs
           to:(NSURL *)dest
       is_cut:(BOOL)is_cut
   completion:(void (^)(NSError *))completion
{
    BOOL hash = [NSUserDefaults.standardUserDefaults
                     boolForKey:@"files.copy.hash_validation"];
    [FilesCopyProgress begin_copy:srcs to:dest is_cut:is_cut
                    hash_validate:hash
                       completion:completion];
}

/*
 * paste_to_directory:completion: — copies (or, after a cut, moves) the
 * pasteboard's files into dest via transfer_urls:to:is_cut:completion:.
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

    [self transfer_urls:srcs to:dest is_cut:is_cut completion:completion];
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
