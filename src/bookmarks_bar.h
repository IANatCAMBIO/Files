#import <Cocoa/Cocoa.h>

/*
 * FilesBookmarksBar — a 28pt horizontal strip of recessed buttons for quick
 * directory navigation. Defaults to Home, Desktop, Downloads, Documents,
 * Applications and Trash. User-added bookmarks are persisted in
 * NSUserDefaults.
 */
@interface FilesBookmarksBar : NSView

/*
 * selection_handler — called when the user clicks a bookmark.
 * Receives the URL of the selected directory.
 */
@property (nonatomic, copy) void (^selection_handler)(NSURL *url);

/*
 * init_with_frame: — designated initialiser; loads saved (or default)
 * bookmarks and builds the button layout.
 *
 * Inputs:
 *   frame — initial frame (height should be 28)
 *
 * Output: configured FilesBookmarksBar, or nil on failure.
 */
- (instancetype)init_with_frame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/*
 * add_bookmark: — appends url to the bar and persists it. Silently ignored
 * if the URL is already present.
 *
 * Inputs:
 *   url — file-system directory URL to bookmark
 */
- (void)add_bookmark:(NSURL *)url;

/*
 * update_trash_icon — re-checks ~/.Trash and switches the bookmark icon
 * between NSImageNameTrashEmpty and NSImageNameTrashFull to reflect the
 * current state. Safe to call at any time; does nothing if the Trash
 * bookmark is not present.
 */
- (void)update_trash_icon;

@end
