#import <Cocoa/Cocoa.h>

/*
 * FilesInfoSidebar — 220pt-wide right panel showing a Quick Look thumbnail
 * and file metadata for the active selection.  The thumbnail is served from
 * the system Quick Look cache; no file parsing is done by this class.
 */
@interface FilesInfoSidebar : NSView

/*
 * show_url: — display the thumbnail and metadata for a single file or folder.
 *
 * Inputs:
 *   url — item to inspect; must be a file-system URL
 */
- (void)show_url:(NSURL *)url;

/*
 * show_urls: — display aggregate info for a multi-item selection.
 * Shows an item count and the combined size of the selected files (folder
 * contents are not counted; the size is marked "excl. folders" when any
 * folder is selected, "—" if only folders are); no thumbnail.
 *
 * Inputs:
 *   urls — selected URLs (count > 1)
 */
- (void)show_urls:(NSArray<NSURL *> *)urls;

/*
 * clear — reset to empty state (no item selected, or sidebar collapsed).
 * Cancels any in-flight Quick Look request and drops the thumbnail image.
 */
- (void)clear;

@end
