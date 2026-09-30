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
 * new_window_handler — asked to open url in a new window (e.g. a freshly
 * mounted disk image's volume). Set by the app delegate, which owns windows.
 */
@property (nonatomic, copy) void (^new_window_handler)(NSURL *url);

/*
 * init_with_url: — creates the window, toolbar, bookmarks bar, and primary
 * browser pane, showing url.
 *
 * Inputs:
 *   url — folder to show first
 *
 * Output: self or nil on failure.
 */
- (instancetype)init_with_url:(NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWindow:(NSWindow *)window NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/*
 * active_pane — returns the currently active browser pane.
 *
 * Output: FilesBrowserPane (never nil).
 */
- (FilesBrowserPane *)active_pane;

@end
