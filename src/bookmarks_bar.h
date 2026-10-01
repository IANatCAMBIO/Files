#import <Cocoa/Cocoa.h>

/*
 * FilesBookmarksBar — a 28pt horizontal strip of recessed buttons for quick
 * directory navigation. Defaults to Home, Desktop, Downloads, Documents,
 * Applications and Trash. User-added bookmarks are persisted in
 * NSUserDefaults and shared by every window's bar. Trash is always present
 * as the last bookmark and cannot be removed; its icon shows whether the
 * Trash is empty, following one app-wide watcher.
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
 * add_bookmark: — adds url to the bar just before Trash (which is always
 * the last bookmark) and persists it. Silently ignored if the URL is
 * already present.
 *
 * Inputs:
 *   url — file-system directory URL to bookmark
 */
- (void)add_bookmark:(NSURL *)url;

@end
