#import "browser_pane.h"

@implementation FilesBrowserPane

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

    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return self;
}

/*
 * update_dim — full opacity when active or in single-pane mode; dimmed when
 * inactive in dual-pane mode.
 */
- (void)
update_dim
{
    _browser.alphaValue = (_in_dual_mode && !_is_active) ? 0.45 : 1.0;
}

/*
 * setIs_active: — is_active setter; updates dimming.
 *
 * Inputs:
 *   active — YES to mark as the active pane
 */
- (void)
setIs_active:(BOOL)active
{
    _is_active = active;
    [self update_dim];
}

/*
 * setIn_dual_mode: — in_dual_mode setter; updates dimming.
 *
 * Inputs:
 *   dual — YES when two panes are shown
 */
- (void)
setIn_dual_mode:(BOOL)dual
{
    _in_dual_mode = dual;
    [self update_dim];
}

@end
