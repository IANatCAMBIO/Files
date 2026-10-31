#import <Cocoa/Cocoa.h>
#import "file_ops.h"

/*
 * FilesCopyProgress — manages a progress panel for file copies and moves.
 *
 * Use begin_copy:to:is_cut:hash_validate:completion: to start a copy. The
 * panel appears immediately so Cancel is available from the start.
 *
 * It shows a status line, one text progress bar for the file being
 * transferred and, when the job covers more than one file, a second bar for
 * the job as a whole, over a collapsible transfer log. Progress is measured
 * in steps rather than bytes, because byte totals say little about how much
 * of a transfer is left: hashing a file costs about as much as copying it,
 * and a same-volume move or an APFS clone moves no data at all. The engine
 * counts the job's steps before anything moves; FileCopyProgressBlock in
 * file_ops.h describes them. The bar that stands for the job — the Total
 * bar, or the single bar of a one-file job — carries the rate the job has
 * averaged after its percentage, once there is enough of it to measure.
 *
 * Every line the engine logs goes into the transfer log and, as the latest
 * one, into the status line, so the two always agree. After the copy
 * finishes the panel's title says how it ended and it stays open with a
 * "Close" button (a cancelled copy closes it instead).
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
