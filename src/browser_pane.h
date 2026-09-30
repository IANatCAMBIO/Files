#import <Cocoa/Cocoa.h>
#import "browser_view.h"

/*
 * FilesBrowserPane — wraps a FilesBrowserView with an optional active-pane
 * border for dual-pane mode.
 */
@interface FilesBrowserPane : NSView

/* The underlying file-list browser. */
@property (nonatomic, readonly) FilesBrowserView *browser;

/*
 * is_active — YES when this pane has keyboard focus in dual-pane mode.
 * Only draws a border when show_accent_border is also YES.
 * Does NOT transfer first responder — the caller must do that.
 */
@property (nonatomic) BOOL is_active;

/*
 * show_accent_border — YES while dual-pane mode is active; causes a 2pt
 * accent-colour border to be drawn when is_active is also YES.
 * Default NO (no border in single-pane mode).
 */
@property (nonatomic) BOOL show_accent_border;

/*
 * navigation_handler — forwarded from the underlying FilesBrowserView.
 * Receives the new directory URL after every navigation event.
 */
@property (nonatomic, copy) void (^navigation_handler)(NSURL *url);

/*
 * info_handler — forwarded from the underlying FilesBrowserView.
 * Receives the selected URLs when the user requests Get Info.
 */
@property (nonatomic, copy) void (^info_handler)(NSArray<NSURL *> *urls);

/*
 * init_with_frame: — designated initialiser; builds subviews.
 *
 * Inputs:
 *   frame — initial frame
 *
 * Output: configured pane, or nil on failure.
 */
- (instancetype)init_with_frame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;

/*
 * navigate_to: — navigate the underlying browser to url.
 *
 * Inputs:
 *   url — destination directory URL
 */
- (void)navigate_to:(NSURL *)url;

/*
 * current_url — returns the URL currently displayed in this pane.
 *
 * Output: NSURL or nil.
 */
- (NSURL *)current_url;

/*
 * selected_urls — returns the selected file URLs in this pane.
 *
 * Output: NSArray<NSURL *>, may be empty.
 */
- (NSArray<NSURL *> *)selected_urls;

@end
