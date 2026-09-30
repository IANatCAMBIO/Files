#import <Cocoa/Cocoa.h>
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
 * pasteboard_is_cut — returns YES if the pasteboard contents are from a cut.
 */
+ (BOOL)pasteboard_is_cut;

/*
 * urls_from_pasteboard — reads file URLs from the general pasteboard.
 *
 * Output: array of NSURL, or empty array if none.
 */
+ (NSArray<NSURL *> *)urls_from_pasteboard;

/*
 * paste_to_directory:completion: — moves or copies pasteboard files to dest.
 * Reads NSUserDefaults key "files.copy.hash_validation" for hash behaviour.
 * Shows a progress panel for transfers >= 10 MB.
 *
 * Inputs:
 *   dest       — destination directory URL
 *   completion — called on main queue; error is nil on success
 */
+ (void)paste_to_directory:(NSURL *)dest completion:(void (^)(NSError *))completion;

/*
 * FileCopyProgressBlock — progress callback for chunked copies.
 *
 * Called on the background copy queue after every 1 MB chunk.
 * All byte counts are in bytes.
 *
 * Parameters:
 *   current_file — filename (last path component) of the file being copied
 *   file_done    — bytes copied so far for the current file
 *   file_total   — total bytes in the current file
 *   total_done   — bytes copied across all files in this operation
 *   total_total  — total bytes across all files in this operation
 *   bps          — instantaneous bytes-per-second for this chunk
 */
typedef void (^FileCopyProgressBlock)(NSString *current_file,
                                       int64_t   file_done,
                                       int64_t   file_total,
                                       int64_t   total_done,
                                       int64_t   total_total,
                                       double    bps);

/*
 * paste_to_directory:progress:hash_validate:completion: — chunked copy with
 * byte-level progress reporting and optional SHA-256 validation.
 *
 * Inputs:
 *   dest          — destination directory URL
 *   progress      — called after each chunk on the copy queue; nil = disabled
 *   hash_validate — YES = SHA-256 compare src vs dst for each file
 *   completion    — called on main queue; hash_results maps dst URL -> @YES/@NO
 *                   (nil dict when hash_validate is NO)
 */
+ (void)paste_to_directory:(NSURL *)dest
                  progress:(FileCopyProgressBlock)progress
             hash_validate:(BOOL)hash_validate
                completion:(void (^)(NSError *err,
                                     NSDictionary<NSURL *, NSNumber *> *hash_results))completion;

/*
 * FilesConflictResolution — outcome of a per-file conflict prompt.
 */
typedef NS_ENUM(NSInteger, FilesConflictResolution) {
    FilesConflictCancel    = 0,
    FilesConflictKeepBoth  = 1,
    FilesConflictOverwrite = 2,
};

/*
 * FilesConflictBlock — called (from any thread) when a destination file already
 * exists. Must block until the user responds; return the chosen resolution.
 *
 * Parameters:
 *   src — source file URL
 *   dst — conflicting destination file URL
 */
typedef FilesConflictResolution (^FilesConflictBlock)(NSURL *src, NSURL *dst);

/*
 * run_copy_srcs:to:is_cut:hash_validate:conflict:cancel_flag:progress:completion: —
 * core copy engine; takes source URLs directly (not from pasteboard).
 *
 * Runs on a background queue; calls completion on the main queue.
 *
 * Inputs:
 *   srcs          — source file/directory URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = delete sources after successful copy
 *   hash_validate — YES = SHA-256 verify each file after copying
 *   conflict      — called when a destination file already exists; nil = keep both
 *   cancel_flag   — pointer to an int32_t; set to non-zero to abort; may be NULL
 *   progress      — chunk progress callback; may be nil
 *   completion    — called on main queue with error and hash_results dict
 */
+ (void)run_copy_srcs:(NSArray<NSURL *> *)srcs
                   to:(NSURL *)dest
               is_cut:(BOOL)is_cut
        hash_validate:(BOOL)hash_validate
             conflict:(FilesConflictBlock)conflict
          cancel_flag:(volatile int32_t *)cancel_flag
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
 * create_folder_in:name:completion: — creates a new directory.
 *
 * Inputs:
 *   parent     — parent directory URL
 *   name       — folder name; "untitled folder" if nil
 *   completion — called on main queue with new URL or error
 */
+ (void)create_folder_in:(NSURL *)parent
                    name:(NSString *)name
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
