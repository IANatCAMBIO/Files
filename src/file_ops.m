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
static NSString * const cut_flag_type = @"com.cambio.files.cut-flag";

/* ── C helpers ──────────────────────────────────────────────────────────── */

/* The user lock flags: Finder's "Locked" (uchg) and append-only (uappnd). */
#define LOCK_FLAGS (UF_IMMUTABLE | UF_APPEND)

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
 * unique_dest_url — returns a non-conflicting destination URL in dir.
 * Appends " copy", " copy 2", etc. until nothing (not even a dangling
 * symlink) exists at the path.
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
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext  = name.pathExtension;
    NSURL *dest    = [dir URLByAppendingPathComponent:name];
    if (!item_exists(dest)) return dest;
    NSString *suffix = @" copy";
    NSInteger n = 2;
    while (YES) {
        NSString *candidate = ext.length > 0
            ? [NSString stringWithFormat:@"%@%@.%@", base, suffix, ext]
            : [NSString stringWithFormat:@"%@%@", base, suffix];
        dest = [dir URLByAppendingPathComponent:candidate];
        if (!item_exists(dest)) return dest;
        suffix = [NSString stringWithFormat:@" copy %ld", (long)n++];
    }
}

/*
 * real_path — the canonical path of an existing item: symbolic links
 * resolved and each name in its on-disk case (realpath(3)), so two
 * spellings of one folder compare equal.
 *
 * Inputs:
 *   url — file URL; should exist
 *
 * Output: canonical path, or the standardized path if realpath fails.
 */
static NSString *
real_path(NSURL *url)
{
    char buf[PATH_MAX];
    return realpath(url.fileSystemRepresentation, buf) ? @(buf)
                                                       : url.URLByStandardizingPath.path;
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
            if (e->fts_statp->st_flags & LOCK_FLAGS) {
                lchflags(e->fts_accpath, e->fts_statp->st_flags & ~LOCK_FLAGS);
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
            if (e->fts_statp->st_flags & LOCK_FLAGS) {
                lchflags(e->fts_accpath, e->fts_statp->st_flags & ~LOCK_FLAGS);
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
 * copy_ctx_t — state shared with copy_status_cb for one top-level item,
 * plus the whole job's step accounting (see FileCopyProgressBlock in
 * file_ops.h for what a step is).
 */
typedef struct {
    FileCopyProgressBlock  progress;      /* may be nil */
    FileCopyLogBlock       log;           /* may be nil */
    atomic_int            *cancel;        /* may be NULL */
    BOOL                   is_cut;        /* the job is a move */
    BOOL                   hash_validate; /* SHA-256 verify each file as it lands */

    int64_t                files_total;   /* regular files the job will touch */
    int64_t                steps_total;   /* steps the job will take */
    int64_t                steps_done;    /* steps finished */

    int                    file_steps;    /* steps the current file costs (1, 2 or 5) */
    int                    file_step;     /* steps of it finished */
    double                 step_frac;     /* 0..1 through the step in progress */

    NSString              *file_name;     /* file currently being worked on */
    int64_t                file_total;    /* its size */
    BOOL                   is_regular;    /* it is a regular file (has data to hash) */
    uint8_t                src_digest[FILE_SHA256_LEN];  /* its source's SHA-256 */

    CFAbsoluteTime         started;       /* when the job began */
    int64_t                bytes_done;    /* bytes of the files already finished */
    int64_t                file_bytes;    /* bytes of the file in progress */

    BOOL                   downloading;   /* an iCloud download is in progress */
    double                 dl_frac;       /* 0..1 through that download */

    BOOL                   hash_failed;   /* a copy did not match its source */
    int                    err;           /* errno from the first COPYFILE_ERR */
} copy_ctx_t;

/*
 * log_line — sends one line to the transfer log, if there is one. Callers
 * whose arguments are costly to compute test c->log first.
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
 * remove_logged — deletes one of the engine's own items (a partial copy, a
 * staging item, a replaced item set aside) with remove_tree, so locked
 * contents go too. Does nothing if nothing is there.
 *
 * Only a failure is logged: a cleanup that worked is bookkeeping the
 * transfer log leaves out, while one that did not leaves a hidden item
 * behind that the user may want to know about.
 *
 * Inputs:
 *   url  — item to delete
 *   what — how the log names it, e.g. "the staging item"
 *   c    — copy context (log)
 */
static void
remove_logged(NSURL *url, NSString *what, copy_ctx_t *c)
{
    if (!item_exists(url)) return;
    char fail[PATH_MAX];
    int err = remove_tree(url.fileSystemRepresentation, fail, sizeof fail);
    if (err != 0) {
        log_line(c, @"✗ Could not delete %@ \"%@\" (%s at \"%s\")",
                 what, url.path, strerror(err), fail);
    }
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

/* A rate measured over less than this is noise — a cloned gigabyte can
 * land in a millisecond — so none is reported until the job has run for
 * this long. */
static const double rate_min_elapsed = 0.1;

/*
 * report — hands the progress block the two fractions its bars show: how
 * far through the current file's steps the job is, and how far through all
 * of the job's steps, plus the rate the job has averaged. While an iCloud
 * placeholder is downloading, the file's fraction is that download's
 * instead, since the download is the work the user is waiting on and is
 * not one of the file's steps.
 *
 * Inputs:
 *   c — copy context
 */
static void
report(copy_ctx_t *c)
{
    if (!c->progress) return;
    double file_frac = c->downloading ? c->dl_frac
        : (c->file_steps > 0 ? (c->file_step + c->step_frac) / c->file_steps : 0.0);
    double job_frac = c->steps_total > 0
        ? (c->steps_done + c->step_frac) / (double)c->steps_total : 0.0;

    double  elapsed = CFAbsoluteTimeGetCurrent() - c->started;
    int64_t moved   = c->bytes_done + c->file_bytes;
    double  rate    = (moved > 0 && elapsed >= rate_min_elapsed) ? moved / elapsed : 0.0;

    c->progress(c->files_total, MIN(file_frac, 1.0), MIN(job_frac, 1.0), rate);
}

/*
 * step_start — begins one of the current file's steps. Logs the line the
 * panel puts in the transfer log and shows as its status, numbered
 * "[2/4]" when the file takes more than one step, and reports the step as
 * just begun.
 *
 * Inputs:
 *   c      — copy context
 *   format — printf-style description of the step, then its arguments
 */
static void
step_start(copy_ctx_t *c, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

static void
step_start(copy_ctx_t *c, NSString *format, ...)
{
    c->step_frac = 0.0;
    if (c->log) {
        va_list args;
        va_start(args, format);
        NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        c->log(c->file_steps > 1
               ? [NSString stringWithFormat:@"[%d/%d] %@", c->file_step + 1,
                  c->file_steps, line]
               : line);
    }
    report(c);
}

/*
 * step_progress — moves the step in progress to frac of the way through
 * and reports it, so a bar advances within a long read or write.
 *
 * Inputs:
 *   c    — copy context
 *   frac — 0..1; values outside that range are clamped
 */
static void
step_progress(copy_ctx_t *c, double frac)
{
    c->step_frac = frac < 0.0 ? 0.0 : (frac > 1.0 ? 1.0 : frac);
    report(c);
}

/*
 * step_done — finishes the step in progress and reports it.
 *
 * Inputs:
 *   c — copy context
 */
static void
step_done(copy_ctx_t *c)
{
    c->steps_done++;
    c->file_step++;
    c->step_frac = 0.0;
    report(c);
}

/* How often download_placeholders polls the downloads it waits for. */
#define DOWNLOAD_POLL_USEC 100000

/*
 * placeholder_files — the regular files at or under url whose contents are
 * only in iCloud (SF_DATALESS placeholders, "compressed,dataless" in
 * ls -lO). Symbolic links are not followed and other volumes are not
 * entered. Enumerating a placeholder folder may itself wait for iCloud.
 *
 * Inputs:
 *   url    — item to walk
 *   bytes  — receives the files' total size
 *   cancel — polled during the walk; non-zero stops it. May be NULL.
 *
 * Output: the placeholders' URLs; empty if there are none or on cancel.
 */
static NSArray<NSURL *> *
placeholder_files(NSURL *url, int64_t *bytes, const atomic_int *cancel)
{
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    *bytes = 0;
    char *const roots[] = { (char *)url.fileSystemRepresentation, NULL };
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) return files;

    FTSENT *e;
    while ((e = fts_read(fts)) != NULL) {
        if (cancel && atomic_load(cancel)) break;
        if (e->fts_info == FTS_F && (e->fts_statp->st_flags & SF_DATALESS)) {
            [files addObject:[NSURL fileURLWithFileSystemRepresentation:e->fts_path
                                                            isDirectory:NO relativeToURL:nil]];
            *bytes += e->fts_statp->st_size;
        }
    }
    fts_close(fts);
    return files;
}

/*
 * is_placeholder — YES while the file's contents are only in iCloud.
 *
 * Inputs:
 *   url — file URL
 */
static BOOL
is_placeholder(NSURL *url)
{
    struct stat st;
    return lstat(url.fileSystemRepresentation, &st) == 0 && (st.st_flags & SF_DATALESS);
}

/*
 * download_placeholders — downloads the iCloud placeholders in src before
 * it is moved or copied. Renaming a placeholder out of iCloud Drive, or
 * cloning it, makes the kernel download it inside that one system call,
 * which reports nothing for as long as the download takes; downloading
 * first lets the transfer report it. All downloads are started at once;
 * their bytes come from the progress iCloud publishes for each file (as
 * Finder shows it) and drive the current file's bar (c->downloading, so
 * the step count is left alone — a download is not one of the file's
 * steps). A file whose download cannot be started is left to the transfer
 * itself. Once they
 * finish, each downloaded file's size must equal the size it had as a
 * placeholder, so a truncated download fails the transfer.
 *
 * Inputs:
 *   src — item about to be moved or copied
 *   c   — copy context (progress, log, cancel flag)
 *
 * Output: nil once nothing in src is a placeholder (or nothing more can be
 *         downloaded); NSUserCancelledError on cancel; an error naming the
 *         file if a download's size does not match.
 */
static NSError *
download_placeholders(NSURL *src, copy_ctx_t *c)
{
    int64_t total = 0;
    NSArray<NSURL *> *files = placeholder_files(src, &total, c->cancel);
    if (files.count == 0) return nil;

    /* Written by the publishing handlers (main thread), read by the poll;
     * the handlers retain both, so a late one is harmless. */
    NSMutableDictionary<NSString *, NSProgress *> *published = [NSMutableDictionary dictionary];
    NSLock *lock = [NSLock new];

    NSMutableArray *subscribers         = [NSMutableArray array];
    NSMutableArray<NSURL *> *pending    = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary dictionary];
    for (NSURL *file in files) {
        NSString *path = file.path;
        [subscribers addObject:[NSProgress addSubscriberForFileURL:file
                                             withPublishingHandler:^NSProgressUnpublishingHandler(NSProgress *p) {
            [lock lock];
            published[path] = p;
            [lock unlock];
            return nil;
        }]];
        NSError *err = nil;
        if ([NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:file error:&err]) {
            struct stat st;
            sizes[path] = @(lstat(file.fileSystemRepresentation, &st) == 0 ? st.st_size : 0);
            [pending addObject:file];
        } else {
            log_line(c, @"Could not start downloading \"%@\" from iCloud (%@); the "
                        @"transfer will wait for it instead", path, err.localizedDescription);
        }
    }

    int64_t to_download = 0;
    for (NSNumber *n in sizes.allValues) to_download += n.longLongValue;
    if (pending.count) {
        log_line(c, @"Downloading %@ from iCloud (%@) before the transfer",
                 pending.count == 1 ? [NSString stringWithFormat:@"\"%@\"", pending.firstObject.path]
                                    : [NSString stringWithFormat:@"%lu files",
                                       (unsigned long)pending.count],
                 byte_count(to_download));
    }

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    c->downloading = YES;
    c->dl_frac     = 0.0;
    NSError *result = nil;
    while (pending.count) {
        if (c->cancel && atomic_load(c->cancel)) {
            result = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSUserCancelledError userInfo:nil];
            break;
        }
        [pending filterUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(NSURL *file, NSDictionary *bindings) { return is_placeholder(file); }]];

        int64_t done = to_download;  /* less what pending files still lack */
        [lock lock];
        for (NSURL *file in pending) {
            int64_t size = sizes[file.path].longLongValue;
            int64_t got  = MIN(MAX(published[file.path].completedUnitCount, 0), size);
            done -= size - got;
        }
        [lock unlock];
        c->dl_frac = to_download > 0 ? (double)done / (double)to_download : 1.0;
        report(c);
        if (pending.count) usleep(DOWNLOAD_POLL_USEC);
    }
    c->downloading = NO;

    for (id subscriber in subscribers) [NSProgress removeSubscriber:subscriber];
    if (!result) {
        for (NSString *path in sizes) {
            int64_t expected = sizes[path].longLongValue;
            struct stat st;
            int64_t got = lstat(path.fileSystemRepresentation, &st) == 0 ? st.st_size : -1;
            if (got != expected) {
                log_line(c, @"✗ \"%@\" downloaded as %@ but iCloud reported %@",
                         path, got < 0 ? @"nothing" : byte_count(got), byte_count(expected));
                return described_error([NSString stringWithFormat:
                    @"\"%@\" did not download completely from iCloud (got %@, expected %@).",
                    path.lastPathComponent, got < 0 ? @"nothing" : byte_count(got),
                    byte_count(expected)]);
            }
        }
    }
    if (!result && to_download > 0) {
        log_line(c, @"✓ Downloaded %@ from iCloud in %@; sizes match what iCloud reported",
                 byte_count(to_download),
                 files_format_duration(CFAbsoluteTimeGetCurrent() - start));
    }
    return result;
}

/*
 * step_sha256 — SHA-256 of one file as the step now in progress, moving
 * that step's bar as the file is read. The step's line has already been
 * logged (step_start), so only a failure is logged here.
 *
 * Inputs:
 *   path   — file to read
 *   role   — "source" or "copy", for the failure message
 *   digest — receives the digest
 *   c      — copy context (log, cancel flag)
 *
 * Output: YES if the file was read in full.
 */
static BOOL
step_sha256(const char *path, NSString *role, uint8_t digest[FILE_SHA256_LEN],
            copy_ctx_t *c)
{
    int rc = file_digests(path, digest, NULL, c->cancel, ^(int64_t done, int64_t total) {
        if (total > 0) step_progress(c, (double)done / (double)total);
    });
    if (rc == 0) return YES;
    if (rc != -2) {  /* -2: cancelled, which the panel reports itself */
        log_line(c, @"✗ Could not read the %@ of \"%@\" to hash it", role, c->file_name);
    }
    return NO;
}

/*
 * copy_status_cb — copyfile(3) status callback. It drives every step of
 * every file in the tree being copied: it logs each step as it begins,
 * reports progress within it, honours the cancel flag and aborts on the
 * first error (copyfile's default is to skip unreadable items and still
 * return success).
 *
 * A regular file takes five steps with hash validation on — its source is
 * hashed before copyfile writes anything, its staged copy straight after,
 * the two digests are compared, and the staged copy is then renamed into
 * place or deleted — and two without: copy it into a staging file, then
 * rename it into place. The copy stops at the first mismatch. APFS clones
 * are hashed like any other copy, and a file's last line gives the SHA-256
 * both sides agreed on.
 *
 * Inputs:
 *   what, stage — copyfile event (COPYFILE_RECURSE_FILE / COPYFILE_COPY_DATA,
 *                 COPYFILE_START / COPYFILE_PROGRESS / COPYFILE_FINISH / COPYFILE_ERR)
 *   state       — copyfile state (queried for COPYFILE_STATE_COPIED)
 *   src, dst    — paths of the item being processed
 *   ctx         — copy_ctx_t pointer
 *
 * Output: COPYFILE_CONTINUE, or COPYFILE_QUIT on cancel, error or a hash
 *         mismatch (c->hash_failed set).
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

    if (what == COPYFILE_RECURSE_DIR && stage == COPYFILE_FINISH) {
        /* copyfile locks a copied folder as soon as it creates it, so
         * nothing could be copied into a locked one. Unlock it for now:
         * its COPYFILE_RECURSE_DIR_CLEANUP pass locks it again. */
        struct stat st;
        if (lstat(dst, &st) == 0 && (st.st_flags & LOCK_FLAGS)) {
            lchflags(dst, st.st_flags & ~LOCK_FLAGS);
        }
    } else if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START) {
        struct stat st;
        BOOL have_st  = lstat(src, &st) == 0;
        c->file_name  = @(src).lastPathComponent;
        c->file_total = have_st ? st.st_size : 0;
        c->file_bytes = 0;
        c->is_regular = have_st && S_ISREG(st.st_mode);
        c->file_steps = c->is_regular ? (c->hash_validate ? 5 : 2) : 1;
        c->file_step  = 0;

        if (c->hash_validate && c->is_regular) {
            step_start(c, @"Hashing source \"%@\"", c->file_name);
            if (!step_sha256(src, @"source", c->src_digest, c)) {
                if (c->err == 0) c->err = EIO;
                return COPYFILE_QUIT;
            }
            step_done(c);
        }
        if (c->file_steps > 1) {
            step_start(c, @"Copying \"%@\" to a staging file", c->file_name);
        } else {
            step_start(c, @"Copying \"%@\"", c->file_name);
        }
    } else if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        off_t copied = 0;
        copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied);
        c->file_bytes = copied;
        if (c->file_total > 0) step_progress(c, (double)copied / (double)c->file_total);
    } else if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH) {
        /* A clone writes nothing, so count the file's size rather than
         * what copyfile reported moving: the user's bytes arrived either
         * way, and that is the rate they care about. */
        c->bytes_done += c->file_total;
        c->file_bytes  = 0;
        step_done(c);  /* the copy step; a clone finishes it without any data */

        NSString *verified = @"";
        if (c->hash_validate && c->is_regular) {
            uint8_t copy_digest[FILE_SHA256_LEN];
            step_start(c, @"Hashing the staged copy of \"%@\"", c->file_name);
            if (!step_sha256(dst, @"copy", copy_digest, c)) {
                if (c->err == 0) c->err = EIO;
                return COPYFILE_QUIT;
            }
            step_done(c);

            step_start(c, @"Comparing the hashes of \"%@\"", c->file_name);
            BOOL matched = memcmp(c->src_digest, copy_digest, FILE_SHA256_LEN) == 0;
            step_done(c);

            /* The last step is what the comparison decided. On a mismatch
             * copy_tree deletes the staged item on its way out, so the
             * step is logged but never finished: the job stops here. */
            if (!matched) {
                step_start(c, @"Hash check failed — deleting the staged file");
                log_line(c, @"✗ Hash check FAILED for \"%@\": source %@, copy %@",
                         c->file_name, digest_hex(c->src_digest, FILE_SHA256_LEN),
                         digest_hex(copy_digest, FILE_SHA256_LEN));
                c->hash_failed = YES;
                return COPYFILE_QUIT;
            }
            step_start(c, @"Hash check passed — renaming the staged file");
            step_done(c);
            verified = [NSString stringWithFormat:@" (SHA-256 match: %@)",
                        digest_hex(copy_digest, FILE_SHA256_LEN)];
        } else if (c->is_regular) {
            /* Without hashing, the file's second step is the rename that
             * puts it under its real name. The rename itself — like the
             * one the last step above stands for — is the enclosing item's
             * single commit_item rename, microseconds away and, for a
             * tree, only after its last file, so the step is accounted
             * here, where this file's own work ends. */
            step_start(c, @"Renaming the staged copy of \"%@\" into place", c->file_name);
            step_done(c);
        }
        log_line(c, @"✓ %@ of \"%@\" successful%@", c->is_cut ? @"Move" : @"Copy",
                 c->file_name, verified);
    }
    return COPYFILE_CONTINUE;
}

/*
 * copy_tree — copies src (file, directory tree, or symlink) to dst, which
 * must not exist. Uses copyfile(3) so APFS clones are used where possible and
 * xattrs, ACLs, Finder info, flags and timestamps are preserved; symlinks are
 * copied as links. Hash validation, if on, happens file by file as the copy
 * goes (copy_status_cb). A partial dst is removed on failure.
 *
 * Inputs:
 *   src — source URL
 *   dst — destination URL (must not exist)
 *   c   — copy context (progress, cancel flag, hash validation)
 *
 * Output: nil on success; NSUserCancelledError on cancel; otherwise an error.
 */
static NSError *
copy_tree(NSURL *src, NSURL *dst, copy_ctx_t *c)
{
    copyfile_state_t state = copyfile_state_alloc();
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (const void *)&copy_status_cb);
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, c);

    c->err         = 0;
    c->hash_failed = NO;
    int rc = copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation,
                      state,
                      COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE
                      | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC);
    int saved_errno = errno;
    copyfile_state_free(state);

    if (rc == 0) return nil;

    remove_logged(dst, @"the partial copy", c);
    if (c->cancel && atomic_load(c->cancel)) {
        return [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSUserCancelledError userInfo:nil];
    }
    if (c->hash_failed) {
        return described_error([NSString stringWithFormat:
            @"SHA-256 validation failed for \"%@\". Nothing was replaced and "
             "the source was kept.", src.lastPathComponent]);
    }
    return posix_error(c->err ? c->err : saved_errno, src);
}

/*
 * match_hidden_flag — gives url the hidden flag (UF_HIDDEN) state want.
 * Items pass through hidden dot-names while staged or set aside, and iCloud
 * Drive (and other File Provider folders) marks a dot-named item hidden
 * once it notices it — a flag that survives the rename back to a normal
 * name, so it has to be cleared again here.
 *
 * Inputs:
 *   url  — item to fix (not followed if a symbolic link)
 *   want — YES if it should be hidden
 */
static void
match_hidden_flag(NSURL *url, BOOL want)
{
    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) != 0) return;
    if (((st.st_flags & UF_HIDDEN) != 0) == want) return;
    u_int flags = want ? (st.st_flags | UF_HIDDEN) : (st.st_flags & ~UF_HIDDEN);
    lchflags(url.fileSystemRepresentation, flags);
}

/*
 * misplaced_error — the error for a rollback rename that failed, leaving an
 * item under a hidden name; it names that path so the item can be found.
 *
 * Inputs:
 *   name   — the item's real name
 *   hidden — where it is now
 *   code   — errno of the failed rename
 *
 * Output: NSError with a user-facing description.
 */
static NSError *
misplaced_error(NSString *name, NSURL *hidden, int code)
{
    return described_error([NSString stringWithFormat:
        @"\"%@\" could not be put back (%s) and is now at \"%@\".",
        name, strerror(code), hidden.path]);
}

/*
 * commit_item — renames a fully staged item onto dst.
 *
 * Without replace, dst must not exist (RENAME_EXCL). With replace, the
 * existing dst is first renamed aside, the staged item renamed into place,
 * and only then is the old item deleted; if the second rename fails the old
 * item is put back. The existing dst is therefore never lost on failure.
 *
 * copyfile copies the lock flags, and a locked item cannot be renamed, so
 * a locked staged item is unlocked for the rename and locked again in place.
 *
 * Renames and deletions that worked are bookkeeping, so they are not
 * logged; a rollback and a failed cleanup are. The item put in place, and
 * an existing item put back after a failure, get the hidden flag state they
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

    struct stat st;
    u_int lock = (lstat(staged_p, &st) == 0) ? (st.st_flags & LOCK_FLAGS) : 0;
    if (lock && lchflags(staged_p, st.st_flags & ~lock) != 0) {
        return posix_error(errno, staged);
    }

    NSURL *old = nil;
    BOOL old_hidden = NO;
    if (replace && item_exists(dst)) {
        struct stat old_st;
        old_hidden = lstat(dst_p, &old_st) == 0 && (old_st.st_flags & UF_HIDDEN);
        old = sibling_temp_url(dst, @"old");
        if (rename(dst_p, old.fileSystemRepresentation) != 0) {
            return posix_error(errno, dst);
        }
    }

    if (renamex_np(staged_p, dst_p, RENAME_EXCL) != 0) {
        int saved_errno = errno;
        if (old) {
            if (rename(old.fileSystemRepresentation, dst_p) != 0) {
                int back_errno = errno;
                log_line(c, @"✗ Could not rename \"%@\" back to \"%@\"", old.path, dst.path);
                return misplaced_error(dst.lastPathComponent, old, back_errno);
            }
            log_line(c, @"The existing \"%@\" was put back unchanged", dst.path);
            match_hidden_flag(dst, old_hidden);
        }
        return posix_error(saved_errno, dst);
    }
    match_hidden_flag(dst, hidden);
    if (lock && (lstat(dst_p, &st) != 0 || lchflags(dst_p, st.st_flags | lock) != 0)) {
        log_line(c, @"✗ Could not lock \"%@\" again as its original is (%s)",
                 dst.path, strerror(errno));
    }

    /* The new item is in place; a failed cleanup only leaves a hidden
     * ".<name>.files-old-*" item behind, never data loss. */
    if (old) remove_logged(old, @"the replaced item", c);
    return nil;
}

/*
 * transfer_item — copies or moves one top-level item to dst.
 *
 * A move on the same volume is a single rename(2) — RENAME_EXCL, so it
 * cannot clobber anything — or, when replacing an existing dst, a rename
 * to a hidden staging name followed by commit_item. Otherwise the item is
 * copied under a hidden sibling name of dst (hash-verified as it goes, if
 * requested) and committed with commit_item only once it is complete, so
 * cancel, I/O errors and validation failures leave dst untouched; a move
 * across volumes then deletes the source. Staging costs one rename(2) in
 * the destination folder, so it is done whether or not hashes are checked.
 * Before any of this, iCloud
 * placeholders in src are downloaded (download_placeholders), unless the
 * move stays in iCloud Drive or the transfer is silent.
 *
 * Inputs:
 *   src     — source item URL
 *   dst     — final destination URL
 *   replace — YES to replace an existing dst (user chose Replace)
 *   is_cut  — YES = move (source removed on success)
 *   c       — copy context (progress, cancel flag, hash validation)
 *
 * Output: nil on success, NSError otherwise.
 */
static NSError *
transfer_item(NSURL *src, NSURL *dst, BOOL replace, BOOL is_cut, copy_ctx_t *c)
{
    NSURL *staged = sibling_temp_url(dst, @"tmp");
    struct stat st;
    BOOL have_st = lstat(src.fileSystemRepresentation, &st) == 0;
    BOOL hidden  = have_st && (st.st_flags & UF_HIDDEN);  /* the copy should match */

    /* A move that stays in iCloud Drive renames placeholders without
     * downloading them; anything else downloads them first, reported. A
     * silent transfer (no progress, no log) leaves that to the kernel. */
    BOOL stays_in_icloud = is_cut && [NSFileManager.defaultManager
        isUbiquitousItemAtURL:dst.URLByDeletingLastPathComponent];
    if ((c->progress || c->log) && !stays_in_icloud) {
        NSError *err = download_placeholders(src, c);
        if (err) return err;
    }

    if (is_cut) {
        BOOL direct = !replace || !item_exists(dst);
        NSURL *to   = direct ? dst : staged;
        /* The step is logged only once the rename has worked: until then
         * this could still turn out to be a copy across volumes, which
         * costs a step per file instead of this single one. */
        if (renamex_np(src.fileSystemRepresentation, to.fileSystemRepresentation,
                       RENAME_EXCL) == 0) {
            c->file_name  = src.lastPathComponent;
            c->file_steps = 1;
            c->file_step  = 0;
            step_start(c, @"Moving \"%@\"", c->file_name);

            if (!direct) {
                NSError *err = commit_item(staged, dst, replace, hidden, c);
                if (err) {
                    if (rename(staged.fileSystemRepresentation,
                               src.fileSystemRepresentation) != 0) {
                        return misplaced_error(src.lastPathComponent, staged, errno);
                    }
                    log_line(c, @"\"%@\" was put back unchanged", src.path);
                    match_hidden_flag(src, hidden);
                    return err;
                }
            }
            step_done(c);
            log_line(c, @"✓ Move of \"%@\" successful (renamed on the same volume, "
                        @"no data copied)", c->file_name);
            return nil;
        }
        if (errno != EXDEV) return posix_error(errno, src);
        log_line(c, @"\"%@\" is on another volume than its destination: copying it, "
                    @"then removing the original", src.lastPathComponent);
    }

    NSError *err = copy_tree(src, staged, c);
    if (err) return err;

    err = commit_item(staged, dst, replace, hidden, c);
    if (err) {
        remove_logged(staged, @"the staging item", c);
        return err;
    }

    if (is_cut) {
        if (![NSFileManager.defaultManager removeItemAtURL:src error:&err]) {
            return described_error([NSString stringWithFormat:
                @"\"%@\" was copied but the original could not be removed: %@",
                src.lastPathComponent, err.localizedDescription]);
        }
    }
    return nil;
}

/*
 * plan_steps — works out, before anything moves, how many steps each source
 * item will take, so progress can be reported against a known total (see
 * FileCopyProgressBlock in file_ops.h). Costs one fts walk per item
 * (files_folder_size), which is why a silent transfer — no progress block
 * and no log — is not planned at all.
 *
 * A move that stays on one volume is a single rename(2) however many files
 * it covers, so it counts as one file and one step. Anything else costs its
 * regular files — at least one, so an empty folder or a symbolic link still
 * has a step of its own — times the steps each file takes. An item whose
 * walk fails is counted as one file; the main loop snaps the count straight
 * at each item boundary, so a tree that has changed since cannot leave the
 * bars adrift.
 *
 * Inputs:
 *   srcs — source item URLs
 *   dest — destination directory URL
 *   c    — copy context; its files_total and steps_total are filled in
 *
 * Output: malloc'd array of srcs.count step counts, or NULL when there is
 *         nothing to report progress to. The caller frees it.
 */
static int64_t *
plan_steps(NSArray<NSURL *> *srcs, NSURL *dest, copy_ctx_t *c)
{
    if (!c->progress && !c->log) return NULL;

    int64_t *steps = calloc(srcs.count, sizeof *steps);
    if (!steps) return NULL;

    struct stat dest_st;
    BOOL have_dest = lstat(dest.fileSystemRepresentation, &dest_st) == 0;
    int  per_file  = c->hash_validate ? 5 : 2;

    for (NSUInteger i = 0; i < srcs.count; i++) {
        NSURL *src = srcs[i];
        struct stat src_st;
        BOOL rename_only = c->is_cut && have_dest
            && lstat(src.fileSystemRepresentation, &src_st) == 0
            && src_st.st_dev == dest_st.st_dev;

        int64_t files = 1;
        if (!rename_only) {
            int64_t counted = 0;
            if (files_folder_size(src.fileSystemRepresentation, &counted, c->cancel) >= 0
                && counted > 1) {
                files = counted;
            }
        }
        steps[i]        = rename_only ? 1 : files * per_file;
        c->files_total += files;
        c->steps_total += steps[i];
    }
    if (c->files_total < 1) c->files_total = 1;
    if (c->steps_total < 1) c->steps_total = 1;
    report(c);  /* the panel needs the file count to lay its bars out */
    return steps;
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
 *   completion    — called on main queue with the first error (nil on success)
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
   completion:(void (^)(NSError *))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        copy_ctx_t ctx = { .progress = progress, .log = log, .cancel = cancel_flag,
                           .is_cut = is_cut, .hash_validate = hash_validate,
                           .started = started };
        NSString *dest_path = real_path(dest);
        NSError *first_err  = nil;
        int64_t  errors     = 0;
        NSString *noun      = is_cut ? @"move" : @"copy";

        log_line(&ctx, @"Starting %@ job: %@ to \"%@\"%@", noun,
                 srcs.count == 1
                     ? [NSString stringWithFormat:@"\"%@\"", srcs.firstObject.lastPathComponent]
                     : [NSString stringWithFormat:@"%lu items", (unsigned long)srcs.count],
                 dest.lastPathComponent,
                 hash_validate ? @" (SHA-256 validation)" : @"");

        int64_t *item_steps = plan_steps(srcs, dest, &ctx);

        /* base is advanced in the loop's increment, so an item skipped with
         * `continue` still leaves the step count where the plan put it, and
         * steps_done is reset to it at the top of every item. */
        int64_t base = 0;
        for (NSUInteger i = 0; i < srcs.count;
             base += (item_steps ? item_steps[i] : 0), i++) {
            NSURL *src = srcs[i];
            ctx.steps_done = base;
            ctx.step_frac  = 0.0;

            if (cancel_flag && atomic_load(cancel_flag)) {
                first_err = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSUserCancelledError userInfo:nil];
                break;
            }

            /* The source's folder is canonicalised, not the source itself,
             * so a symbolic link is compared as the link, not its target. */
            NSString *src_dir  = real_path(src.URLByDeletingLastPathComponent);
            NSString *src_path = [src_dir stringByAppendingPathComponent:src.lastPathComponent];
            if ([dest_path isEqualToString:src_path] ||
                [dest_path hasPrefix:[src_path stringByAppendingString:@"/"]]) {
                first_err = described_error([NSString stringWithFormat:
                    @"\"%@\" can't be copied into itself.", src.lastPathComponent]);
                errors++;
                log_line(&ctx, @"✗ %@", first_err.localizedDescription);
                break;
            }

            NSURL *dst   = [dest URLByAppendingPathComponent:src.lastPathComponent];
            BOOL replace = NO;
            if ([dest_path isEqualToString:src_dir]) {
                if (is_cut) continue;              /* moving onto itself: no-op */
                dst = unique_dest_url(src.lastPathComponent, dest);
                log_line(&ctx, @"Duplicating \"%@\" in its own folder as \"%@\"",
                         src.lastPathComponent, dst.lastPathComponent);
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
                             src.lastPathComponent, dst.lastPathComponent);
                } else {
                    replace = YES;
                    log_line(&ctx, @"\"%@\" already exists: replacing it once the new "
                                   @"one is complete", dst.lastPathComponent);
                }
            }

            NSError *err = transfer_item(src, dst, replace, is_cut, &ctx);
            BOOL cancelled = err.code == NSUserCancelledError &&
                             [err.domain isEqualToString:NSCocoaErrorDomain];
            if (err && !first_err) first_err = err;
            if (cancelled) break;
            if (err) {
                errors++;
                log_line(&ctx, @"✗ %@", err.localizedDescription);
            }
        }

        BOOL cancelled = first_err.code == NSUserCancelledError &&
                         [first_err.domain isEqualToString:NSCocoaErrorDomain];
        if (!cancelled) {
            if (errors == 0) {  /* both bars end full */
                ctx.steps_done  = ctx.steps_total;
                ctx.file_steps  = 1;
                ctx.file_step   = 1;
                ctx.step_frac   = 0.0;
                ctx.downloading = NO;
                report(&ctx);
            }
            log_line(&ctx, @"%@ job completed %@ in %@", noun.capitalizedString,
                     errors == 0 ? @"successfully"
                                 : [NSString stringWithFormat:@"with %lld error%s",
                                    (long long)errors, errors == 1 ? "" : "s"],
                     files_format_duration(CFAbsoluteTimeGetCurrent() - started));
        }
        free(item_steps);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(first_err);
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
 * empty_trash: — remove_tree on every item in the Trash folders
 * (files_trash_urls), off the main queue.
 * Inputs/output are documented in file_ops.h.
 */
+ (void)
empty_trash:(void (^)(NSArray<NSURL *> *failed, NSArray<NSString *> *reasons))completion
{
    NSArray<NSURL *> *trashes = files_trash_urls();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *>    *failed   = [NSMutableArray array];
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        NSMutableArray<NSURL *>    *items    = [NSMutableArray array];
        for (NSURL *trash in trashes) {
            NSError *list_err = nil;
            NSArray<NSURL *> *found = [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:trash includingPropertiesForKeys:nil
                                 options:0 error:&list_err];
            if (found) {
                [items addObjectsFromArray:found];
                continue;
            }
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

/*
 * files_folder_size — fts walk summing regular files' sizes.
 * Inputs/output are documented in file_ops.h.
 */
int64_t
files_folder_size(const char *path, int64_t *files, const atomic_int *cancel)
{
    char *const roots[] = { (char *)path, NULL };
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) return -1;

    int64_t total = 0;
    int64_t count = 0;
    FTSENT *e;
    while ((e = fts_read(fts)) != NULL) {
        if (cancel && atomic_load(cancel)) {
            fts_close(fts);
            return -1;
        }
        if (e->fts_level == FTS_ROOTLEVEL &&
            (e->fts_info == FTS_NS || e->fts_info == FTS_ERR || e->fts_info == FTS_DNR)) {
            fts_close(fts);     /* the item itself is missing or unreadable */
            return -1;
        }
        if (e->fts_info == FTS_F) {
            total += e->fts_statp->st_size;
            count++;
        }
    }
    fts_close(fts);
    if (files) *files = count;
    return total;
}

