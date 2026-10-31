#import <Cocoa/Cocoa.h>
#include <stdatomic.h>
#include <stdint.h>

/*
 * FilesFileOps — stateless utility class for clipboard-based file operations.
 * All methods are class methods; this class is never instantiated.
 */
@interface FilesFileOps : NSObject

/*
 * copy_urls:is_cut: — writes file URLs to the general pasteboard.
 *
 * Inputs:
 *   urls   — file URLs to copy or cut
 *   is_cut — YES if this is a cut operation (files will be moved on paste)
 */
+ (void)copy_urls:(NSArray<NSURL *> *)urls is_cut:(BOOL)is_cut;

/*
 * pasteboard_has_files — returns YES if the general pasteboard contains file URLs.
 */
+ (BOOL)pasteboard_has_files;

/*
 * transfer_urls:to:is_cut:completion: — copies or moves srcs into dest.
 * Normally shows the progress panel (step status line, progress bars,
 * transfer log, conflict prompts, cancel). With files_pref_simple_copies
 * on, runs silently instead: no panel, no step counting, name clashes
 * resolved as Keep Both, errors still reported through completion.
 * Honours files_pref_hash_validation either way (util.h).
 *
 * Inputs:
 *   srcs       — source file/directory URLs
 *   dest       — destination directory URL
 *   is_cut     — YES = move instead of copy
 *   completion — called on main queue; error is nil on success
 */
+ (void)transfer_urls:(NSArray<NSURL *> *)srcs
                   to:(NSURL *)dest
               is_cut:(BOOL)is_cut
           completion:(void (^)(NSError *))completion;

/*
 * paste_to_directory:completion: — moves or copies pasteboard files to dest.
 * Delegates to transfer_urls:to:is_cut:completion:.
 *
 * Inputs:
 *   dest       — destination directory URL
 *   completion — called on main queue; error is nil on success
 */
+ (void)paste_to_directory:(NSURL *)dest completion:(void (^)(NSError *))completion;

/*
 * FileCopyProgressBlock — progress callback for copies and moves.
 *
 * Progress is counted in steps, not bytes, because the byte totals of a
 * transfer say little about how much of it is left: hashing a file costs
 * about as much as copying it, and a same-volume move or an APFS clone
 * moves no data at all. Every regular file costs five steps with hash
 * validation on — hash the source, copy it into a staging file, hash the
 * staged copy, compare the two, then rename the staged file into place or
 * delete it — and two steps without: copy it into a staging file, then
 * rename it into place. A move that stays on one volume is a single
 * rename(2), so it is one step however many files it covers.
 *
 * Called on the background copy queue once the job's steps have been
 * counted (so the first call reports the file count with no progress), as
 * each step starts, and as the step in progress advances: after every 1 MB
 * of data copied and about ten times a second while an iCloud placeholder
 * is downloaded.
 *
 * Parameters:
 *   files_total — regular files the job will touch; counts a same-volume
 *                 move as the one rename it is. Never 0.
 *   file_frac   — 0..1 through the current file's own steps
 *   job_frac    — 0..1 through the whole job's steps
 *   rate        — bytes a second the job has averaged so far: every byte
 *                 of every file copied, counted once whether it was
 *                 written out or cloned, over the time since the job
 *                 started. Hashing moves no bytes but does take time, so a
 *                 validated copy averages well under the volume's own
 *                 speed. 0 when there is nothing to measure — before the
 *                 first file lands, and throughout a same-volume move,
 *                 which copies nothing.
 */
typedef void (^FileCopyProgressBlock)(int64_t files_total,
                                      double  file_frac,
                                      double  job_frac,
                                      double  rate);

/*
 * FileCopyLogBlock — transfer-log callback for copies and moves.
 *
 * Called on the background copy queue with the lines the progress panel
 * shows: it puts each one in the transfer log and the latest one in its
 * status line, so the two always agree. In order, for a job:
 *
 *   - one "Starting copy job: …" / "Starting move job: …" line;
 *   - per file, one line as each of its steps begins, numbered "[2/5]"
 *     with hash validation on and "[1/2]" without (a single-step file is
 *     not numbered), plus
 *     a "✓ Copy of "name" successful" line carrying the verified SHA-256;
 *   - one "Copy job completed …" line with the error count and elapsed time.
 *
 * Anything that needs the user's attention is logged as well, on its own
 * line and marked "✗" if it failed: conflict decisions, iCloud downloads,
 * hash mismatches and I/O errors. Routine bookkeeping — the staging item's
 * hidden name, each rename and each cleanup deletion — is not logged.
 *
 * Parameters:
 *   line — log text, without timestamp or trailing newline
 */
typedef void (^FileCopyLogBlock)(NSString *line);

/*
 * FilesConflictResolution — outcome of a per-item conflict prompt.
 * Overwrite replaces the existing file or folder only after the new item has
 * been fully copied (and verified, if requested).
 */
typedef NS_ENUM(NSInteger, FilesConflictResolution) {
    FilesConflictCancel    = 0,
    FilesConflictKeepBoth  = 1,
    FilesConflictOverwrite = 2,
};

/*
 * FilesConflictBlock — called on the background copy queue when a destination
 * file or folder already exists. Must block until the user responds; return
 * the chosen resolution.
 *
 * Parameters:
 *   src — source item URL
 *   dst — conflicting destination item URL
 */
typedef FilesConflictResolution (^FilesConflictBlock)(NSURL *src, NSURL *dst);

/*
 * run_copy_srcs:to:is_cut:hash_validate:conflict:cancel_flag:progress:log:completion: —
 * core copy engine; takes source URLs directly (not from pasteboard).
 *
 * Runs on a background queue; calls completion on the main queue.
 * Uses copyfile(3) (APFS clones, full metadata, symlinks kept as links) and
 * rename(2) for same-volume moves. iCloud placeholders are downloaded first,
 * with progress, unless progress and log are both nil or a move stays in
 * iCloud Drive. Each copy is staged under a hidden name
 * and renamed into place only when complete, so cancel, errors and failed
 * validation never damage an existing destination or delete the source.
 * Validation hashes each file's source before copying it and its staged
 * copy straight after, stopping at the first mismatch; APFS clones are
 * hashed like any other copy.
 * Copying a folder into itself is rejected; pasting into the source's own
 * folder duplicates on copy and is a no-op on cut.
 *
 * Unless both progress and log are nil, the job's steps are counted before
 * any data moves (one walk of each source), so progress can be reported
 * against a known total; see FileCopyProgressBlock for the step model.
 *
 * Inputs:
 *   srcs          — source file/directory URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = move sources (deleted only after a successful commit)
 *   hash_validate — YES = SHA-256 verify each file before committing
 *   conflict      — called when a destination item already exists; nil = keep both
 *   cancel_flag   — set to non-zero (atomic_store) to abort; may be NULL
 *   progress      — progress callback; may be nil
 *   log           — transfer-log callback; may be nil
 *   completion    — called on main queue with the first error, nil on success
 */
+ (void)run_copy_srcs:(NSArray<NSURL *> *)srcs
                   to:(NSURL *)dest
               is_cut:(BOOL)is_cut
        hash_validate:(BOOL)hash_validate
             conflict:(FilesConflictBlock)conflict
          cancel_flag:(atomic_int *)cancel_flag
             progress:(FileCopyProgressBlock)progress
                  log:(FileCopyLogBlock)log
           completion:(void (^)(NSError *err))completion;

/*
 * move_to_trash:completion: — moves urls to the trash.
 *
 * Inputs:
 *   urls       — file URLs to trash
 *   completion — called on main queue; error is nil on success
 */
+ (void)move_to_trash:(NSArray<NSURL *> *)urls completion:(void (^)(NSError *))completion;

/*
 * create_item_in:name:folder:completion: — creates a new, empty folder or
 * file. If name is taken, " copy", " copy 2", … is appended (before any
 * extension). A file is created exclusively (O_EXCL), so an item that
 * appears concurrently is never overwritten.
 *
 * Inputs:
 *   parent     — parent directory URL
 *   name       — desired name, e.g. "untitled folder" or "untitled.txt"
 *   folder     — YES for a folder, NO for an empty file
 *   completion — called on main queue with the new URL, or nil and an error
 */
+ (void)create_item_in:(NSURL *)parent
                  name:(NSString *)name
                folder:(BOOL)folder
            completion:(void (^)(NSURL *, NSError *))completion;

/*
 * rename_url:to:completion: — renames a file or folder.
 *
 * Inputs:
 *   url        — current file URL
 *   new_name   — new filename (without path)
 *   completion — called on main queue with new URL or error
 */
+ (void)rename_url:(NSURL *)url
                to:(NSString *)new_name
        completion:(void (^)(NSURL *, NSError *))completion;

/*
 * empty_trash: — permanently deletes everything in the user's Trash
 * (~/.Trash and the iCloud Trash, dotfiles included) on a background queue. Like Finder, it
 * deletes locked items and folders the user cannot write to: each item's
 * tree is walked without following symbolic links, lock flags (uchg,
 * uappnd) are cleared and folders get owner rwx before their contents are
 * removed. Items it still cannot delete — typically ones owned by root or
 * another user — are left in place and reported.
 *
 * Inputs:
 *   completion — called on the main queue with the Trash items that could
 *                not be fully deleted and, parallel to them, one line each
 *                ("name — reason", naming the inner path when that is what
 *                failed); both empty if the Trash is now empty
 */
+ (void)empty_trash:(void (^)(NSArray<NSURL *> *failed,
                              NSArray<NSString *> *reasons))completion;

/*
 * empty_trash_with_finder: — asks Finder to empty the Trash (the AppleScript
 * `empty trash` command) for items Files itself may not delete: other
 * developers' apps, which macOS's App Management protection reserves for
 * Finder, and items owned by root, for which Finder asks for an
 * administrator's password. Commands run as root from Files cannot do
 * this: macOS attributes them to a system helper, which has neither App
 * Management nor access to the Trash. The first use makes macOS ask
 * whether Files may control Finder (NSAppleEventsUsageDescription).
 *
 * Inputs:
 *   completion — called on the main queue with nil when Finder finished,
 *                or a user-facing explanation of why it could not (Files
 *                not allowed to control Finder, password prompt
 *                cancelled, Finder's own error)
 */
+ (void)empty_trash_with_finder:(void (^)(NSString *error))completion;

@end

/*
 * files_folder_size — the total size of every file inside a folder, at
 * any depth: the sum of their sizes (st_size), as the Size column shows
 * for a file. Symbolic links are not followed and other volumes mounted
 * inside the folder are not entered. Items that cannot be read are
 * skipped. Blocks for as long as the walk takes; call off the main thread.
 *
 * A path that is itself a regular file is measured as one file, so the
 * copy engine can count the files in a source item without knowing first
 * whether it is a folder.
 *
 * Inputs:
 *   path   — folder, package or file to measure
 *   files  — receives the number of regular files counted; may be NULL.
 *            Left untouched when the walk fails.
 *   cancel — polled during the walk; non-zero stops it. May be NULL.
 *
 * Output: total bytes, or -1 if cancelled or the item cannot be opened.
 */
int64_t files_folder_size(const char *path, int64_t *files, const atomic_int *cancel);
