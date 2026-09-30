#import <Cocoa/Cocoa.h>

@class FilesBrowserPane;

/*
 * FilesMainWindow — NSWindowController that owns the main application window:
 * toolbar, bookmarks bar, one or two browser panes, the collapsible info
 * sidebar and the status bar. It sits in the responder chain behind the
 * panes and implements the Go-menu, toolbar and view-preference actions,
 * which apply to the active pane (or to every pane for preferences).
 */
@interface FilesMainWindow : NSWindowController

/*
 * init — creates the window, toolbar, bookmarks bar, and primary browser pane.
 *
 * Output: self or nil on failure.
 */
- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithWindow:(NSWindow *)window NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/*
 * active_pane — returns the currently active browser pane.
 *
 * Output: FilesBrowserPane (never nil).
 */
- (FilesBrowserPane *)active_pane;

@end
