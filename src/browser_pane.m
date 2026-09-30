#import "browser_pane.h"

@implementation FilesBrowserPane {
    FilesBrowserView *_browser;
    BOOL              _is_active;
    BOOL              _show_accent_border;
}

@synthesize browser = _browser;

/*
 * init_with_frame: — fills the pane entirely with the browser view.
 *
 * Inputs:
 *   frame — initial frame for the whole pane
 *
 * Output: configured FilesBrowserPane, or nil on failure.
 */
- (instancetype)
init_with_frame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _browser = [[FilesBrowserView alloc] init_with_frame:
        NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    _browser.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_browser];

    /* Forward navigation and info events to our own handlers. */
    __weak FilesBrowserPane *weak_self = self;
    _browser.navigation_handler = ^(NSURL *url) {
        FilesBrowserPane *p = weak_self;
        if (!p) return;
        if (p.navigation_handler) p.navigation_handler(url);
    };
    _browser.info_handler = ^(NSArray<NSURL *> *urls) {
        FilesBrowserPane *p = weak_self;
        if (!p) return;
        if (p.info_handler) p.info_handler(urls);
    };

    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return self;
}

/*
 * update_dim — sets the browser view alpha: full when active or single-pane,
 * dimmed when inactive in dual-pane mode.
 */
- (void)
update_dim
{
    _browser.alphaValue = (_show_accent_border && !_is_active) ? 0.45 : 1.0;
}

/*
 * is_active setter — updates dim state.
 *
 * Inputs:
 *   active — YES to mark as active pane
 */
- (void)
setIs_active:(BOOL)active
{
    _is_active = active;
    [self update_dim];
}

- (BOOL)is_active { return _is_active; }

/*
 * show_accent_border setter — called when entering/leaving dual-pane mode.
 * Updates dim state for the new mode.
 *
 * Inputs:
 *   show — YES when dual-pane is active
 */
- (void)
setShow_accent_border:(BOOL)show
{
    _show_accent_border = show;
    [self update_dim];
}

- (BOOL)show_accent_border { return _show_accent_border; }

/*
 * navigate_to: — forward navigation to the underlying browser.
 *
 * Inputs:
 *   url — destination directory URL
 */
- (void)
navigate_to:(NSURL *)url
{
    [_browser navigate_to:url];
}

/*
 * current_url — returns the directory the browser is currently showing.
 *
 * Output: NSURL or nil.
 */
- (NSURL *)
current_url
{
    return _browser.current_url;
}

/*
 * selected_urls — returns the file URLs selected in the browser.
 *
 * Output: NSArray<NSURL *>.
 */
- (NSArray<NSURL *> *)
selected_urls
{
    return _browser.selected_urls;
}

@end
