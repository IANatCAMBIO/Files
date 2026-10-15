#import <Cocoa/Cocoa.h>

/*
 * FilesBookmarksBar — a 28pt horizontal strip of recessed buttons for quick
 * directory navigation. Defaults to Home, Desktop, Downloads, Documents,
 * Applications and Trash. User-added bookmarks are persisted in
 * NSUserDefaults and shared by every window's bar; dragging a bookmark
 * along the bar reorders it. Trash is always present as the last bookmark
 * and cannot be removed or moved; its icon shows whether the Trash is
 * empty, following one app-wide watcher.
 */
/*
 * files_bookmarks_changed_note — posted (main queue) by a bar after it
 * saves the bookmark list (added, removed or reordered); object is the bar
 * that saved. Every other bar reloads the list on it.
 */
extern NSString * const files_bookmarks_changed_note;

/*
 * files_bookmark_urls — the bookmarks, in bar order (Trash last): the saved
 * list, or the defaults when none is saved yet.
 *
 * Output: array of directory URLs.
 */
NSArray<NSURL *> *files_bookmark_urls(void);

/*
 * files_is_bookmark — whether url is one of the bookmarks.
 *
 * Inputs:
 *   url — a directory URL
 *
 * Output: YES if it is bookmarked (Trash always is).
 */
BOOL files_is_bookmark(NSURL *url);

/*
 * files_bookmark_name — the title a bookmark is shown with: "Home",
 * "Trash", or the folder's localized name.
 *
 * Inputs:
 *   url — a bookmark's URL
 *
 * Output: display name.
 */
NSString *files_bookmark_name(NSURL *url);

/*
 * files_bookmark_icon — a bookmark's icon; Trash's shows whether the Trash
 * is empty, as the app-wide Trash watcher last saw it.
 *
 * Inputs:
 *   url  — a bookmark's URL
 *   size — icon edge in points
 *
 * Output: icon image.
 */
NSImage *files_bookmark_icon(NSURL *url, CGFloat size);

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

/*
 * remove_bookmark: — removes url from the bar and persists the list.
 * Ignored for Trash, which cannot be removed, and for a URL that is not
 * bookmarked.
 *
 * Inputs:
 *   url — directory URL to remove
 */
- (void)remove_bookmark:(NSURL *)url;

@end
