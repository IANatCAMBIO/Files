#import <Cocoa/Cocoa.h>
#import "browser_view.h"

/*
 * FilesBrowserPane — one browser pane: wraps a FilesBrowserView and holds
 * the per-pane state the window shows for whichever pane is active. In
 * dual-pane mode the inactive pane is dimmed.
 */
@interface FilesBrowserPane : NSView

/* The underlying file-list browser. */
@property (nonatomic, readonly) FilesBrowserView *browser;

/*
 * is_active — YES when this is the pane toolbar and menu actions target.
 * Does NOT transfer first responder — the caller must do that.
 */
@property (nonatomic) BOOL is_active;

/*
 * in_dual_mode — YES while two panes are shown; the pane is then dimmed
 * whenever it is not active. Default NO.
 */
@property (nonatomic) BOOL in_dual_mode;

/* Last status-bar text reported by the browser (shown when active). */
@property (nonatomic, copy) NSString *status_text;

/* YES while the browser shows the Trash (floating Empty Trash button). */
@property (nonatomic) BOOL showing_trash;

/* The volume whose root the browser shows, if that volume can be unmounted
 * (floating Unmount button); nil otherwise. */
@property (nonatomic, strong) NSURL *unmountable_volume;

/*
 * init_with_frame: — designated initialiser; fills the pane with a browser.
 *
 * Inputs:
 *   frame — initial frame
 *
 * Output: configured pane, or nil on failure.
 */
- (instancetype)init_with_frame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end
