#import <Cocoa/Cocoa.h>
#import "file_ops.h"

/*
 * FilesCopyProgress — manages a progress panel for file copies.
 *
 * Use begin_copy:to:is_cut:hash_validate:completion: to start a copy. The
 * panel appears immediately so Cancel is available from the start. It shows
 * the current file, a live speed graph and a collapsible transfer log; the
 * total size is not known in advance, so there is no percentage or ETA.
 * After the copy finishes the panel shows the result and elapsed time and
 * stays open with a "Close" button (a cancelled copy closes it instead).
 */
@interface FilesCopyProgress : NSWindowController

/*
 * begin_copy:to:is_cut:hash_validate:completion: — start copying srcs into dest.
 *
 * Inputs:
 *   srcs          — source file/directory URLs; if empty, completion(nil) is
 *                   called immediately and no panel is shown
 *   dest          — destination directory URL
 *   is_cut        — YES = move (delete source after successful copy)
 *   hash_validate — YES = SHA-256 compare source and destination per file
 *   completion    — called on main queue after the panel shows its final
 *                   state; err is nil on full success
 */
+ (void)begin_copy:(NSArray<NSURL *> *)srcs
                to:(NSURL *)dest
            is_cut:(BOOL)is_cut
     hash_validate:(BOOL)hash_validate
        completion:(void (^)(NSError *err))completion;

@end
