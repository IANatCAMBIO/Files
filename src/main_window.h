#import <Cocoa/Cocoa.h>

@class FilesBrowserPane;

/*
 * FilesMainWindow — NSWindowController that owns the main application window.
 * Contains the toolbar, bookmarks bar, and one or two browser panes.
 */
@interface FilesMainWindow : NSWindowController

/*
 * init — creates the window, toolbar, bookmarks bar, and primary browser pane.
 *
 * Output: self or nil on failure.
 */
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/*
 * active_pane — returns the currently active browser pane.
 *
 * Output: FilesBrowserPane (never nil).
 */
- (FilesBrowserPane *)active_pane;

/*
 * toggle_dual_pane: — switches between single-pane and dual-pane layouts.
 *
 * Inputs:
 *   sender — menu item or toolbar button
 */
- (IBAction)toggle_dual_pane:(id)sender;

/*
 * open_terminal_clicked: — opens Terminal.app at the active pane's directory.
 *
 * Inputs:
 *   sender — toolbar button or menu item
 */
- (IBAction)open_terminal_clicked:(id)sender;

@end
