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
 * Normally shows the progress panel (conflict prompts, cancel, speed
 * graph). With files_pref_simple_copies on, runs silently instead: no
 * panel, name clashes resolved as Keep Both, errors still reported through
 * completion. Honours files_pref_hash_validation either way (util.h).
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
 * FileCopyProgressBlock — progress callback for copies.
 *
 * Called on the background copy queue when each file starts, after every
 * 1 MB of data copied (cloned files report no intermediate chunks), and when
 * each file finishes. While iCloud placeholders are downloaded before an
 * item is transferred, it is called about ten times a second with
 * downloading set: file_done and file_total then count the bytes of all of
 * that item's downloads, and current_file names one still downloading.
 * All byte counts are in bytes.
 *
 * Parameters:
 *   current_file — filename (last path component) of the file being copied
 *   file_done    — bytes copied so far for the current file
 *   file_total   — total bytes in the current file
 *   total_done   — bytes copied (and downloaded) across this operation
 *   downloading  — YES while downloading from iCloud, NO while copying
 */
typedef void (^FileCopyProgressBlock)(NSString *current_file,
                                       int64_t   file_done,
                                       int64_t   file_total,
                                       int64_t   total_done,
                                       BOOL      downloading);

/*
 * FileCopyLogBlock — transfer-log callback for copies and moves.
 *
 * Called on the background copy queue with one human-readable line per
 * step, naming files by their full paths as they are at that moment —
 * including the hidden staging item an item is copied into: each file
 * started and finished ("15,000 bytes of 15,000 bytes copied", noting
 * APFS clones), each SHA-256 being computed and then its digest, for the
 * source and the copy, and whether they match, conflict decisions, every
 * rename (staging item into place, an existing item set aside, a
 * same-volume move), every deletion (a replaced item, a staging item
 * after a failure, the original after a move across volumes) and iCloud
 * downloads (started, finished, or not startable).
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
 * Validation hashes each file as soon as it is copied, stopping at the
 * first mismatch; APFS clones are identical by construction and not hashed.
 * Copying a folder into itself is rejected; pasting into the source's own
 * folder duplicates on copy and is a no-op on cut.
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
 * Inputs:
 *   path   — folder (or package) to measure
 *   cancel — polled during the walk; non-zero stops it. May be NULL.
 *
 * Output: total bytes, or -1 if cancelled or the folder cannot be opened.
 */
int64_t files_folder_size(const char *path, const atomic_int *cancel);
