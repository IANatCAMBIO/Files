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
 * each file finishes. All byte counts are in bytes.
 *
 * Parameters:
 *   current_file — filename (last path component) of the file being copied
 *   file_done    — bytes copied so far for the current file
 *   file_total   — total bytes in the current file
 *   total_done   — bytes copied across all files in this operation
 */
typedef void (^FileCopyProgressBlock)(NSString *current_file,
                                       int64_t   file_done,
                                       int64_t   file_total,
                                       int64_t   total_done);

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
 * run_copy_srcs:to:is_cut:hash_validate:conflict:cancel_flag:progress:completion: —
 * core copy engine; takes source URLs directly (not from pasteboard).
 *
 * Runs on a background queue; calls completion on the main queue.
 * Uses copyfile(3) (APFS clones, full metadata, symlinks kept as links) and
 * rename(2) for same-volume moves. Each item is staged under a hidden name
 * and renamed into place only when complete, so cancel, errors and failed
 * validation never damage an existing destination or delete the source.
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
 *   completion    — called on main queue with error and hash_results dict
 */
+ (void)run_copy_srcs:(NSArray<NSURL *> *)srcs
                   to:(NSURL *)dest
               is_cut:(BOOL)is_cut
        hash_validate:(BOOL)hash_validate
             conflict:(FilesConflictBlock)conflict
          cancel_flag:(atomic_int *)cancel_flag
             progress:(FileCopyProgressBlock)progress
           completion:(void (^)(NSError *err,
                                NSDictionary<NSURL *, NSNumber *> *hash_results))completion;

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

@end
