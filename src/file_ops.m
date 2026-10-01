#import "file_ops.h"
#import "copy_progress.h"
#import "file_hash.h"
#import "util.h"
#include <copyfile.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <fts.h>

/* Custom pasteboard type used to record whether the copy was a cut. */
static NSString * const cut_flag_type = @"com.salt.files.cut-flag";

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
 * remove_tree — deletes path and, for a folder, everything in it, without
 * following symbolic links. On the way down it clears the user lock flags
 * (UF_IMMUTABLE, UF_APPEND) on every item and gives folders owner rwx, so
 * locked items and read-only folders (Go's module cache, some installers)
 * can be emptied; folders are removed on the way back up. Keeps going
 * after a failure so as much as possible is deleted.
 *
 * Inputs:
 *   path     — item to delete
 *   fail     — receives the first path that could not be read or deleted
 *   fail_len — size of fail
 *
 * Output: 0 on success, else the errno of the first failure (fail set).
 */
static int
remove_tree(const char *path, char *fail, size_t fail_len)
{
    char *const roots[] = { (char *)path, NULL };
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) {
        snprintf(fail, fail_len, "%s", path);
        return errno;
    }

    int first_err = 0;
    FTSENT *e;
    while ((e = fts_read(fts)) != NULL) {
        int rc = 0;
        int err = 0;
        switch (e->fts_info) {
        case FTS_D:         /* folder, before its contents */
            if (e->fts_statp->st_flags & (UF_IMMUTABLE | UF_APPEND)) {
                lchflags(e->fts_accpath,
                         e->fts_statp->st_flags & ~(UF_IMMUTABLE | UF_APPEND));
            }
            if ((e->fts_statp->st_mode & S_IRWXU) != S_IRWXU) {
                chmod(e->fts_accpath, (e->fts_statp->st_mode & 07777) | S_IRWXU);
            }
            continue;
        case FTS_DP:        /* folder, after its contents */
            rc = rmdir(e->fts_accpath);
            break;
        case FTS_DNR:       /* unreadable folder, or other error */
        case FTS_ERR:
        case FTS_NS:
            rc  = -1;
            err = e->fts_errno;
            break;
        case FTS_DC:        /* cycle: impossible without following links */
            continue;
        default:            /* file, symbolic link, special file */
            if (e->fts_statp->st_flags & (UF_IMMUTABLE | UF_APPEND)) {
                lchflags(e->fts_accpath,
                         e->fts_statp->st_flags & ~(UF_IMMUTABLE | UF_APPEND));
            }
            rc = unlink(e->fts_accpath);
            break;
        }
        if (rc != 0 && first_err == 0) {
            first_err = err ? err : errno;
            snprintf(fail, fail_len, "%s", e->fts_path);
        }
    }
    fts_close(fts);
    return first_err;
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
    FileCopyLogBlock       log;         /* may be nil */
    atomic_int            *cancel;      /* may be NULL */
    int64_t                total_done;  /* bytes across the whole operation */
    NSString              *file_name;   /* file currently being copied */
    int64_t                file_total;  /* its size */
    int64_t                file_done;   /* bytes of it copied so far */
    BOOL                   streamed;    /* data events seen: not a clone */
    int                    err;         /* errno from the first COPYFILE_ERR */
} copy_ctx_t;

/*
 * log_line — sends one line to the transfer log, if there is one.
 *
 * Inputs:
 *   c      — copy context
 *   format — printf-style format, then its arguments
 */
static void
log_line(copy_ctx_t *c, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

static void
log_line(copy_ctx_t *c, NSString *format, ...)
{
    if (!c->log) return;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    c->log(line);
}

/*
 * byte_count — an exact byte count for the log: "15,000 bytes", "1 byte".
 * Thread-safe.
 *
 * Inputs:
 *   n — byte count
 *
 * Output: formatted string.
 */
static NSString *
byte_count(int64_t n)
{
    static NSNumberFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSNumberFormatter alloc] init];
        fmt.numberStyle = NSNumberFormatterDecimalStyle;
    });
    return [NSString stringWithFormat:@"%@ byte%s", [fmt stringFromNumber:@(n)],
            n == 1 ? "" : "s"];
}

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
        c->progress(c->file_name, c->file_done, c->file_total, c->total_done);
    }
}

/*
 * copy_status_cb — copyfile(3) status callback. Reports per-file and
 * per-chunk progress, logs each file's start and finish (the bytes written
 * as measured on the copy, and whether it was an APFS clone), honours the
 * cancel flag, and aborts on the first error (copyfile's default is to skip
 * unreadable items and still return success).
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
    copy_ctx_t *c = (copy_ctx_t *)ctx;

    if (c->cancel && atomic_load(c->cancel)) return COPYFILE_QUIT;
    if (stage == COPYFILE_ERR) {
        if (c->err == 0) c->err = errno ? errno : EIO;
        return COPYFILE_QUIT;
    }

    if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START) {
        struct stat st;
        c->file_name  = @(src).lastPathComponent;
        c->file_total = (lstat(src, &st) == 0) ? st.st_size : 0;
        c->file_done  = 0;
        c->streamed   = NO;
        log_line(c, @"→ \"%s\" (%@) to \"%s\"", src, byte_count(c->file_total), dst);
        report_progress(c, 0);
    } else if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        off_t copied = 0;
        copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied);
        c->streamed = YES;
        report_progress(c, copied);
    } else if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH) {
        /* Clones produce no COPY_DATA events; account for the whole file. */
        report_progress(c, c->file_total);
        struct stat st;
        int64_t written = (lstat(dst, &st) == 0) ? st.st_size : 0;
        log_line(c, @"✓ %@ of %@ copied to \"%s\"%@", byte_count(written),
                 byte_count(c->file_total), dst,
                 (!c->streamed && c->file_total > 0)
                     ? @" (APFS clone: shares the original's blocks, no data read)" : @"");
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
    log_line(c, @"Deleted the partial copy \"%@\"", dst.path);
    if (c->cancel && atomic_load(c->cancel)) {
        return [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSUserCancelledError userInfo:nil];
    }
    return posix_error(c->err ? c->err : saved_errno, src);
}

/*
 * logged_sha256 — SHA-256 of one file, logged as two entries: that it is
 * being computed, then the digest.
 *
 * Inputs:
 *   url    — file to read
 *   role   — "source" or "destination", for the log
 *   path   — full path to log the file by
 *   digest — receives the digest
 *   c      — copy context (log, cancel flag)
 *
 * Output: YES if the file was read in full.
 */
static BOOL
logged_sha256(NSURL *url, NSString *role, NSString *path,
              uint8_t digest[FILE_SHA256_LEN], copy_ctx_t *c)
{
    log_line(c, @"Computing SHA-256 of %@ \"%@\"…", role, path);
    int rc = file_digests(url.fileSystemRepresentation, digest, NULL, c->cancel);
    if (rc != 0) {
        if (rc != -2) log_line(c, @"✗ Could not read %@ \"%@\" to hash it", role, path);
        return NO;  /* -2: cancelled, which the panel reports itself */
    }
    log_line(c, @"%@ SHA-256 of \"%@\": %@", role.capitalizedString, path,
             digest_hex(digest, FILE_SHA256_LEN));
    return YES;
}

/*
 * same_contents — SHA-256 compares a source file with its copy, logging
 * both digests and the verdict.
 *
 * Inputs:
 *   src  — source file
 *   copy — its copy (in the staging item)
 *   c    — copy context (log, cancel flag)
 *
 * Output: YES if both hash successfully and the digests match.
 */
static BOOL
same_contents(NSURL *src, NSURL *copy, copy_ctx_t *c)
{
    uint8_t ds[FILE_SHA256_LEN], dc[FILE_SHA256_LEN];
    if (!logged_sha256(src, @"source", src.path, ds, c))         return NO;
    if (!logged_sha256(copy, @"destination", copy.path, dc, c))  return NO;
    BOOL same = memcmp(ds, dc, sizeof ds) == 0;
    log_line(c, same ? @"✓ SHA-256 match: \"%@\" and \"%@\""
                     : @"✗ SHA-256 MISMATCH: \"%@\" and \"%@\"", src.path, copy.path);
    return same;
}

/*
 * verify_copy — SHA-256 compares every regular file under src with its
 * counterpart under copy, logging each digest, and records one result per
 * file keyed by the file's final URL under dst.
 *
 * Inputs:
 *   src          — original item (file or directory)
 *   copy         — staged copy of src (same relative layout)
 *   dst          — URL the copy will be committed to (used for result keys)
 *   hash_results — receives dst-relative URL -> @YES / @NO
 *   c            — copy context (log, cancel flag)
 *
 * Output: YES if every file matched.
 */
static BOOL
verify_copy(NSURL *src, NSURL *copy, NSURL *dst, NSMutableDictionary *hash_results,
            copy_ctx_t *c)
{
    struct stat st;
    if (lstat(src.fileSystemRepresentation, &st) != 0) return NO;
    if (S_ISREG(st.st_mode)) {
        BOOL ok = same_contents(src, copy, c);
        hash_results[dst] = @(ok);
        return ok;
    }
    if (!S_ISDIR(st.st_mode)) return YES;  /* symlinks etc. carry no data */

    BOOL all_ok = YES;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:src.path];
    for (NSString *rel in e) {
        if (![e.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        BOOL ok = same_contents([src URLByAppendingPathComponent:rel],
                                [copy URLByAppendingPathComponent:rel], c);
        hash_results[[dst URLByAppendingPathComponent:rel]] = @(ok);
        if (!ok) all_ok = NO;
    }
    return all_ok;
}

/*
 * match_hidden_flag — gives url the hidden flag (UF_HIDDEN) state want,
 * logging any change. Items pass through hidden dot-names while staged or
 * set aside, and iCloud Drive (and other File Provider folders) marks a
 * dot-named item hidden once it notices it — a flag that survives the
 * rename back to a normal name.
 *
 * Inputs:
 *   url  — item to fix (not followed if a symbolic link)
 *   want — YES if it should be hidden
 *   c    — copy context (log)
 */
static void
match_hidden_flag(NSURL *url, BOOL want, copy_ctx_t *c)
{
    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) != 0) return;
    if (((st.st_flags & UF_HIDDEN) != 0) == want) return;
    u_int flags = want ? (st.st_flags | UF_HIDDEN) : (st.st_flags & ~UF_HIDDEN);
    if (lchflags(url.fileSystemRepresentation, flags) == 0) {
        log_line(c, want ? @"Set the hidden flag on \"%@\" to match the original"
                         : @"Cleared the hidden flag on \"%@\" (set by the folder's sync "
                           @"service while the item had a hidden staging name)", url.path);
    }
}

/*
 * commit_item — renames a fully staged item onto dst.
 *
 * Without replace, dst must not exist (RENAME_EXCL). With replace, the
 * existing dst is first renamed aside, the staged item renamed into place,
 * and only then is the old item deleted; if the second rename fails the old
 * item is put back. The existing dst is therefore never lost on failure.
 *
 * Each rename and deletion is logged. The item put in place, and an
 * existing item put back after a failure, get the hidden flag state they
 * should have (match_hidden_flag), whatever their dot-named detour left.
 *
 * Inputs:
 *   staged  — complete item in the destination directory
 *   dst     — final URL
 *   replace — YES to replace an existing dst
 *   hidden  — whether the item put in place should be hidden (as its
 *             source is)
 *   c       — copy context (log)
 *
 * Output: nil on success, NSError on failure (staged is left in place).
 */
static NSError *
commit_item(NSURL *staged, NSURL *dst, BOOL replace, BOOL hidden, copy_ctx_t *c)
{
    const char *staged_p = staged.fileSystemRepresentation;
    const char *dst_p    = dst.fileSystemRepresentation;

    if (!replace || !item_exists(dst)) {
        if (renamex_np(staged_p, dst_p, RENAME_EXCL) != 0) return posix_error(errno, dst);
        log_line(c, @"Renamed \"%@\" to \"%@\"", staged.path, dst.path);
        match_hidden_flag(dst, hidden, c);
        return nil;
    }

    struct stat old_st;
    BOOL old_hidden = lstat(dst_p, &old_st) == 0 && (old_st.st_flags & UF_HIDDEN);
    NSURL *old = sibling_temp_url(dst, @"old");
    if (rename(dst_p, old.fileSystemRepresentation) != 0) {
        return posix_error(errno, dst);
    }
    log_line(c, @"Renamed the existing \"%@\" aside to \"%@\"", dst.path, old.path);
    if (rename(staged_p, dst_p) != 0) {
        int saved_errno = errno;
        rename(old.fileSystemRepresentation, dst_p);
        log_line(c, @"Renamed \"%@\" back to \"%@\"", old.path, dst.path);
        match_hidden_flag(dst, old_hidden, c);
        return posix_error(saved_errno, dst);
    }
    log_line(c, @"Renamed \"%@\" to \"%@\"", staged.path, dst.path);
    match_hidden_flag(dst, hidden, c);
    /* The new item is in place; a failed cleanup only leaves a hidden
     * ".<name>.files-old-*" item behind, never data loss. */
    if ([NSFileManager.defaultManager removeItemAtURL:old error:nil]) {
        log_line(c, @"Deleted the replaced item \"%@\"", old.path);
    } else {
        log_line(c, @"Could not delete the replaced item \"%@\"", old.path);
    }
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
    struct stat st;
    BOOL have_st = lstat(src.fileSystemRepresentation, &st) == 0;
    BOOL hidden  = have_st && (st.st_flags & UF_HIDDEN);  /* the copy should match */

    if (is_cut) {
        BOOL is_file = have_st && S_ISREG(st.st_mode);
        if (renamex_np(src.fileSystemRepresentation, staged.fileSystemRepresentation,
                       RENAME_EXCL) == 0) {
            c->file_name  = src.lastPathComponent;
            c->file_total = 0;
            c->file_done  = 0;
            report_progress(c, 0);
            if (is_file) {
                log_line(c, @"Renamed \"%@\" to \"%@\" (%@ of %@ moved on the same "
                            @"volume, no data copied)", src.path, staged.path,
                         byte_count(st.st_size), byte_count(st.st_size));
            } else {
                log_line(c, @"Renamed \"%@\" to \"%@\" (moved on the same volume, "
                            @"no data copied)", src.path, staged.path);
            }
            NSError *err = commit_item(staged, dst, replace, hidden, c);
            if (err) {
                rename(staged.fileSystemRepresentation, src.fileSystemRepresentation);
                log_line(c, @"Renamed \"%@\" back to \"%@\"", staged.path, src.path);
                match_hidden_flag(src, hidden, c);
                return err;
            }
            return nil;
        }
        if (errno != EXDEV) return posix_error(errno, src);
        log_line(c, @"\"%@\" is on another volume than \"%@\": copying it, then "
                    @"removing the original", src.path, dst.path);
    }

    log_line(c, @"Copying \"%@\" to the hidden staging item \"%@\"", src.path, staged.path);
    NSError *err = copy_tree(src, staged, c);
    if (err) return err;

    if (hash_validate && !verify_copy(src, staged, dst, hash_results, c)) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        log_line(c, @"Deleted the staging item \"%@\"", staged.path);
        return described_error([NSString stringWithFormat:
            @"SHA-256 validation failed for \"%@\". Nothing was replaced and "
             "the source was kept.", src.lastPathComponent]);
    }

    err = commit_item(staged, dst, replace, hidden, c);
    if (err) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        log_line(c, @"Deleted the staging item \"%@\"", staged.path);
        return err;
    }

    if (is_cut) {
        if (![NSFileManager.defaultManager removeItemAtURL:src error:&err]) {
            return described_error([NSString stringWithFormat:
                @"\"%@\" was copied but the original could not be removed: %@",
                src.lastPathComponent, err.localizedDescription]);
        }
        log_line(c, @"Deleted the original \"%@\"", src.path);
    }
    return nil;
}

/*
 * pasteboard_is_cut — reads the cut flag written by copy_urls:is_cut:.
 *
 * Output: YES if the general pasteboard's files were cut (to be moved).
 */
static BOOL
pasteboard_is_cut(void)
{
    NSString *flag = [NSPasteboard.generalPasteboard stringForType:cut_flag_type];
    return [flag isEqualToString:@"YES"];
}

/*
 * urls_from_pasteboard — reads file URLs from the general pasteboard.
 *
 * Output: array of file URLs, empty if none.
 */
static NSArray<NSURL *> *
urls_from_pasteboard(void)
{
    NSArray *items =
        [NSPasteboard.generalPasteboard
             readObjectsForClasses:@[NSURL.class]
                           options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    return items ?: @[];
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
    [pb setString:is_cut ? @"YES" : @"NO" forType:cut_flag_type];
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
 * run_copy_srcs:to:is_cut:hash_validate:conflict:cancel_flag:progress:log:completion: —
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
 *   cancel_flag   — non-zero (atomic) aborts the operation; may be NULL
 *   progress      — progress callback; may be nil
 *   log           — transfer-log callback; may be nil
 *   completion    — called on main queue with the first error (nil on
 *                   success) and per-file hash results (nil unless hash_validate)
 */
+ (void)
run_copy_srcs:(NSArray<NSURL *> *)srcs
           to:(NSURL *)dest
       is_cut:(BOOL)is_cut
hash_validate:(BOOL)hash_validate
     conflict:(FilesConflictBlock)conflict
  cancel_flag:(atomic_int *)cancel_flag
     progress:(FileCopyProgressBlock)progress
          log:(FileCopyLogBlock)log
   completion:(void (^)(NSError *, NSDictionary<NSURL *, NSNumber *> *))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *hash_results =
            hash_validate ? [NSMutableDictionary dictionary] : nil;
        copy_ctx_t ctx = { .progress = progress, .log = log, .cancel = cancel_flag };
        NSString *dest_path = dest.URLByStandardizingPath.path;
        NSError *first_err  = nil;

        for (NSURL *src in srcs) {
            if (cancel_flag && atomic_load(cancel_flag)) {
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
                log_line(&ctx, @"Duplicating \"%@\" in its own folder as \"%@\"",
                         src.path, dst.path);
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
                    log_line(&ctx, @"\"%@\" already exists: keeping both, saving as \"%@\"",
                             [dest URLByAppendingPathComponent:src.lastPathComponent].path,
                             dst.path);
                } else {
                    replace = YES;
                    log_line(&ctx, @"\"%@\" already exists: replacing it once the new "
                                   @"one is complete", dst.path);
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
 * transfer_urls:to:is_cut:completion: — copies or moves srcs into dest:
 * through the progress panel, or silently (Keep Both on clashes) when
 * files_pref_simple_copies is on. Honours files_pref_hash_validation.
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
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL hash = [ud boolForKey:files_pref_hash_validation];
    if (![ud boolForKey:files_pref_simple_copies]) {
        [FilesCopyProgress begin_copy:srcs to:dest is_cut:is_cut
                        hash_validate:hash
                           completion:completion];
        return;
    }
    [self run_copy_srcs:srcs to:dest is_cut:is_cut hash_validate:hash
               conflict:nil cancel_flag:NULL progress:nil log:nil
             completion:^(NSError *err, NSDictionary<NSURL *, NSNumber *> *hash_results) {
        if (completion) completion(err);
    }];
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
    NSArray<NSURL *> *srcs = urls_from_pasteboard();
    if (srcs.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
        return;
    }
    BOOL is_cut = pasteboard_is_cut();
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
 * create_item_in:name:folder:completion: — creates an empty folder or file
 * under a unique name, off the main thread.
 *
 * Inputs:
 *   parent     — parent directory URL
 *   name       — desired name
 *   folder     — YES for a folder, NO for an empty file
 *   completion — called on main queue with the new URL, or nil and an error
 */
+ (void)
create_item_in:(NSURL *)parent
          name:(NSString *)name
        folder:(BOOL)folder
    completion:(void (^)(NSURL *, NSError *))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *dest  = unique_dest_url(name, parent);
        NSError *err = nil;
        BOOL ok;
        if (folder) {
            ok = [NSFileManager.defaultManager createDirectoryAtURL:dest
                                        withIntermediateDirectories:NO attributes:nil error:&err];
        } else {
            int fd = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
            ok = (fd >= 0);
            if (ok) close(fd); else err = posix_error(errno, dest);
        }
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

/*
 * empty_trash: — remove_tree on every item in ~/.Trash, off the main queue.
 * Inputs/output are documented in file_ops.h.
 */
+ (void)
empty_trash:(void (^)(NSArray<NSURL *> *failed, NSArray<NSString *> *reasons))completion
{
    NSURL *trash = files_directory_url(NSTrashDirectory);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *>    *failed   = [NSMutableArray array];
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        NSError *list_err = nil;
        NSArray<NSURL *> *items = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:trash includingPropertiesForKeys:nil
                             options:0 error:&list_err];
        if (!items) {
            [failed addObject:trash];
            [failures addObject:[NSString stringWithFormat:@"Trash — %@",
                                 list_err.localizedDescription ?: @"cannot be read"]];
        }
        for (NSURL *item in items) {
            char fail[PATH_MAX];
            int err = remove_tree(item.fileSystemRepresentation, fail, sizeof fail);
            if (err == 0) continue;

            /* Name the Trash item, and the inner path when that is what failed. */
            NSString *fail_path = @(fail);
            NSString *where     = [fail_path hasPrefix:[item.path stringByAppendingString:@"/"]]
                ? [NSString stringWithFormat:@" (at %@)",
                   [fail_path substringFromIndex:item.path.length + 1]]
                : @"";
            [failed addObject:item];
            [failures addObject:[NSString stringWithFormat:@"%@ — %s%@",
                                 item.lastPathComponent, strerror(err), where]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(failed, failures);
        });
    });
}

/*
 * empty_trash_with_finder: — `empty trash` sent to Finder from Files itself
 * (so macOS attributes the request to Files), on a private serial queue:
 * Finder may take minutes and ask for a password, and NSAppleScript must
 * not run on two threads at once. Inputs/output are documented in
 * file_ops.h.
 */
+ (void)
empty_trash_with_finder:(void (^)(NSString *error))completion
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("files.finder-empty-trash", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:
            @"with timeout of 3600 seconds\n"
            @"  tell application \"Finder\" to empty trash\n"
            @"end timeout\n"];
        NSDictionary *info = nil;
        NSString *error = nil;
        if (![script executeAndReturnError:&info]) {
            NSInteger code = [info[NSAppleScriptErrorNumber] integerValue];
            if (code == -1743) {        /* errAEEventNotPermitted */
                error = @"Files is not allowed to control Finder. Turn on Finder under "
                        @"Files in System Settings ▸ Privacy & Security ▸ Automation, "
                        @"then try again.";
            } else if (code == -128) {  /* userCanceledErr: password prompt */
                error = @"Finder did not empty the Trash because the password prompt "
                        @"was cancelled.";
            } else {
                error = [NSString stringWithFormat:@"Finder could not empty the Trash: %@",
                         info[NSAppleScriptErrorMessage] ?: @(code).stringValue];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    });
}

@end
