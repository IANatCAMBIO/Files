#import <Cocoa/Cocoa.h>
#import "file_ops.h"

/*
 * FilesCopyProgress — manages a progress panel for file copies.
 *
 * Use begin_copy:to:is_cut:hash_validate:completion: to start a copy. The
 * panel appears immediately (indeterminate bar) so Cancel is available from
 * the start, including during the initial size pre-scan. After the copy
 * finishes the panel stays open and the button changes to "Close".
 */
@interface FilesCopyProgress : NSWindowController

/*
 * begin_copy:to:is_cut:hash_validate:completion: — start copying srcs into dest.
 *
 * Inputs:
 *   srcs          — source file/directory URLs (must not be empty)
 *   dest          — destination directory URL
 *   is_cut        — YES = move (delete source after successful copy)
 *   hash_validate — YES = SHA-256 compare source and destination per file
 *   completion    — called on main queue; err is nil on full success
 */
+ (void)begin_copy:(NSArray<NSURL *> *)srcs
                to:(NSURL *)dest
            is_cut:(BOOL)is_cut
     hash_validate:(BOOL)hash_validate
        completion:(void (^)(NSError *err))completion;

@end
