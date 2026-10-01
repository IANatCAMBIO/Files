#import "main_window.h"
#import "bookmarks_bar.h"
#import "browser_view.h"
#import "info_panel.h"
#import "info_sidebar.h"
#import "util.h"
#import "volume_manager.h"

/* Toolbar item identifiers */
static NSString * const tb_back          = @"files.back";
static NSString * const tb_forward       = @"files.forward";
static NSString * const tb_up            = @"files.up";
static NSString * const tb_reload        = @"files.reload";
static NSString * const tb_hidden_files  = @"files.hidden-files";
static NSString * const tb_path          = @"files.path";
static NSString * const tb_search        = @"files.search";
static NSString * const tb_open_terminal = @"files.open-terminal";
static NSString * const tb_dual_pane     = @"files.dual-pane";
static NSString * const tb_sidebar       = @"files.sidebar";
static NSString * const tb_new_item      = @"files.new-item";

static const CGFloat bookmarks_bar_h = 28.0;
static const CGFloat status_h        = 20.0;
static const CGFloat sidebar_w       = 180.0;  /* initial info sidebar width */
static const CGFloat sidebar_min_w   = 140.0;
static const CGFloat browser_min_w   = 400.0;
static const CGFloat search_w        = 220.0;  /* toolbar search field */
static const CGFloat address_min_w   = 200.0;  /* narrowest the address bar gets */

/* How long a transient status message stays before the item count returns. */
static const double  transient_status_sec = 4.0;

/* Retry interval for a pending unmount: starts short, backs off to the max. */
static const double  pending_retry_min_sec = 2.0;
static const double  pending_retry_max_sec = 10.0;

/* Most open items listed in the "unmount pending" sheet. */
static const NSUInteger pending_list_max = 10;

/* KVO context for the window's firstResponder (dual-pane focus tracking). */
static void *first_responder_ctx = &first_responder_ctx;

@interface FilesMainWindow () <NSToolbarDelegate, NSToolbarItemValidation>

/* Toolbar views; address_width is the address bar's width (fit_address_bar). */
@property (nonatomic, strong) NSTextField        *address_bar;
@property (nonatomic, strong) NSLayoutConstraint *address_width;
@property (nonatomic, weak)   NSToolbarItem      *address_item;
/* Measured by fit_address_bar when every toolbar item was last laid out:
 * the row of items, its leading margin, the padding around the address
 * bar, and the other items' total width (search field at full width). */
@property (nonatomic, weak)   NSView             *toolbar_row;
@property (nonatomic, assign) CGFloat             toolbar_margin;
@property (nonatomic, assign) CGFloat             toolbar_pad;
@property (nonatomic, assign) CGFloat             toolbar_others_w;

/* Layout */
@property (nonatomic, weak)   NSSearchField         *search_field;  /* toolbar search field */
@property (nonatomic, strong) FilesBookmarksBar     *bookmarks_bar;
@property (nonatomic, strong) NSView                *browser_area; /* everything below the bar */
@property (nonatomic, strong) NSSplitView           *pane_split;   /* holds 1 or 2 panes */
@property (nonatomic, strong) NSSplitViewController *content_split_vc;
@property (nonatomic, strong) NSSplitViewItem       *sidebar_item;
@property (nonatomic, strong) FilesInfoSidebar      *info_sidebar;

/* Panes: one browser each; in dual-pane mode the inactive one is dimmed. */
@property (nonatomic, strong) FilesBrowserView *primary_browser;
@property (nonatomic, strong) FilesBrowserView *secondary_browser; /* nil = single-pane */
@property (nonatomic)         NSInteger         active_pane_index; /* 0 or 1 */

/* Status bar (full-width, below the split) and the floating action button,
 * which is Empty Trash in the Trash and Unmount at an unmountable volume's
 * root (see update_floating_button). */
@property (nonatomic, strong) NSTextField *status_label;
@property (nonatomic, strong) NSButton    *floating_btn;
@property (nonatomic, assign) NSUInteger   transient_status_id;  /* 0 = none showing */

/* Paths of volumes waiting for their open files to close before unmounting. */
@property (nonatomic, strong) NSMutableSet<NSString *> *pending_unmounts;

/* NSUserDefaultsDidChangeNotification observer (main queue). */
@property (nonatomic, strong) id defaults_observer;

@end

@implementation FilesMainWindow

/*
 * init_with_url: — builds the window, toolbar, layout and primary browser
 * pane, then shows url. The window frame is restored from the previous
 * session when one was saved; otherwise the window is centered.
 *
 * Inputs:
 *   url — folder to show first
 *
 * Output: self or nil.
 */
- (instancetype)
init_with_url:(NSURL *)url
{
    NSWindowStyleMask style =
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 940, 620)
                                                styleMask:style
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title        = @"Files";
    win.minSize      = NSMakeSize(700, 450);
    win.toolbarStyle = NSWindowToolbarStyleExpanded;  /* titlebar above toolbar */
    if (![win setFrameUsingName:@"FilesMainWindow"]) [win center];
    win.frameAutosaveName = @"FilesMainWindow";

    self = [super initWithWindow:win];
    if (!self) return nil;

    [self build_toolbar];
    [self build_layout];
    [self.window addObserver:self forKeyPath:@"firstResponder"
                     options:0 context:first_responder_ctx];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(volumes_changed:)
                                               name:FilesVolumesChangedNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(window_will_close:)
                                               name:NSWindowWillCloseNotification
                                             object:self.window];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(fit_address_bar)
                                               name:NSWindowDidResizeNotification
                                             object:self.window];
    /* Defaults can change on any thread; the search field is only touched
     * on the main queue. */
    __weak FilesMainWindow *ws = self;
    self.defaults_observer = [NSNotificationCenter.defaultCenter
        addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) {
        [ws update_search_placeholder];
        [ws apply_bookmarks_bar_pref];
    }];
    [self apply_bookmarks_bar_pref];

    self.bookmarks_bar.selection_handler = ^(NSURL *url) {
        [[ws active_browser] navigate_to:url];
    };
    [self.primary_browser navigate_to:url];

    /* Deferred so it runs after the window's initial first-responder pass
     * and once the toolbar has been laid out. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self fit_address_bar];
        [self.window makeFirstResponder:self.address_bar];
    });
    return self;
}

/*
 * window_will_close: — stops each browser's folder watcher and Spotlight
 * search and clears the info sidebar's Quick Look request as the window
 * closes, so a Files kept running with no windows holds none of them.
 *
 * Inputs:
 *   note — NSWindowWillCloseNotification for this window (unused)
 */
- (void)
window_will_close:(NSNotification *)note
{
    for (FilesBrowserView *b in [self all_browsers]) [b shut_down];
    [self.info_sidebar clear];
}

/*
 * dealloc — removes the observers added in init_with_url:.
 */
- (void)
dealloc
{
    [self.window removeObserver:self forKeyPath:@"firstResponder" context:first_responder_ctx];
    [NSNotificationCenter.defaultCenter removeObserver:self.defaults_observer];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/* ── Layout ──────────────────────────────────────────────────────────────── */

/*
 * build_toolbar — creates and attaches the NSToolbar (items come from the
 * NSToolbarDelegate methods below).
 */
- (void)
build_toolbar
{
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"files.toolbar"];
    tb.delegate                = self;
    tb.allowsUserCustomization = NO;
    tb.displayMode             = NSToolbarDisplayModeIconOnly;
    self.window.toolbar        = tb;
}

/*
 * build_layout — bookmarks bar on top; below it the status bar and an
 * NSSplitViewController whose left item holds the browser pane(s) and whose
 * right item is the collapsible info sidebar (collapsed at launch). The
 * split view controller manages collapsing, minimum widths and the divider.
 */
- (void)
build_layout
{
    NSView *content = self.window.contentView;
    CGFloat w = content.bounds.size.width;
    CGFloat h = content.bounds.size.height;

    self.bookmarks_bar = [[FilesBookmarksBar alloc]
        init_with_frame:NSMakeRect(0, h - bookmarks_bar_h, w, bookmarks_bar_h)];
    self.bookmarks_bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.bookmarks_bar];

    NSView *area = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h - bookmarks_bar_h)];
    area.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:area];
    self.browser_area = area;

    /* Status bar and its separator at the bottom of area. */
    NSView *status_container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, status_h)];
    status_container.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [area addSubview:status_container];

    self.status_label = [NSTextField labelWithString:@""];
    self.status_label.translatesAutoresizingMaskIntoConstraints = NO;
    self.status_label.alignment = NSTextAlignmentCenter;
    self.status_label.font      = [NSFont systemFontOfSize:11.0];
    self.status_label.textColor = NSColor.secondaryLabelColor;
    [status_container addSubview:self.status_label];
    [NSLayoutConstraint activateConstraints:@[
        [self.status_label.centerYAnchor  constraintEqualToAnchor:status_container.centerYAnchor],
        [self.status_label.leadingAnchor  constraintEqualToAnchor:status_container.leadingAnchor],
        [self.status_label.trailingAnchor constraintEqualToAnchor:status_container.trailingAnchor
                                                         constant:-8.0],
    ]];

    NSBox *status_sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, status_h, w, 1)];
    status_sep.boxType          = NSBoxSeparator;
    status_sep.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [area addSubview:status_sep];

    /* Browser side: pane_split permanently owns the pane(s); single-pane mode
     * is pane_split with one child, so primary_pane is never reparented. */
    CGFloat split_h = area.bounds.size.height - status_h - 1.0;
    NSView *browser_container = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, w, split_h)];
    browser_container.wantsLayer = YES;

    self.pane_split = [[NSSplitView alloc] initWithFrame:browser_container.bounds];
    self.pane_split.vertical         = YES;
    self.pane_split.dividerStyle     = NSSplitViewDividerStyleThin;
    self.pane_split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [browser_container addSubview:self.pane_split];

    self.primary_browser = [self new_browser_with_frame:self.pane_split.bounds];
    [self.pane_split addSubview:self.primary_browser];

    /* Sidebar side. */
    self.info_sidebar = [[FilesInfoSidebar alloc]
        initWithFrame:NSMakeRect(0, 0, sidebar_w, split_h)];

    NSViewController *browser_vc = [[NSViewController alloc] init];
    browser_vc.view = browser_container;
    NSViewController *sidebar_vc = [[NSViewController alloc] init];
    sidebar_vc.view = self.info_sidebar;

    NSSplitViewItem *browser_item = [NSSplitViewItem splitViewItemWithViewController:browser_vc];
    browser_item.minimumThickness = browser_min_w;

    self.sidebar_item = [NSSplitViewItem splitViewItemWithViewController:sidebar_vc];
    self.sidebar_item.canCollapse      = YES;
    self.sidebar_item.minimumThickness = sidebar_min_w;
    /* Higher holding priority: window resizes go to the browser, not the sidebar. */
    self.sidebar_item.holdingPriority  = NSLayoutPriorityDefaultLow + 1;
    self.sidebar_item.collapsed        = YES;

    self.content_split_vc = [[NSSplitViewController alloc] init];
    self.content_split_vc.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    [self.content_split_vc addSplitViewItem:browser_item];
    [self.content_split_vc addSplitViewItem:self.sidebar_item];

    NSView *split_view = self.content_split_vc.view;
    split_view.frame            = NSMakeRect(0, status_h + 1.0, w, split_h);
    split_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [area addSubview:split_view];

    /* Floating action button — icon-only, lower-right, over the browser.
     * Its image, action and tooltip are set by update_floating_button. */
    static const CGFloat fab_size   = 36.0;
    static const CGFloat fab_margin = 14.0;
    self.floating_btn = [[NSButton alloc]
        initWithFrame:NSMakeRect(w - fab_size - fab_margin, status_h + 1.0 + fab_margin,
                                 fab_size, fab_size)];
    self.floating_btn.imageScaling     = NSImageScaleProportionallyDown;
    self.floating_btn.bezelStyle       = NSBezelStyleRegularSquare;
    self.floating_btn.buttonType       = NSButtonTypeMomentaryLight;
    self.floating_btn.target           = self;
    self.floating_btn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.floating_btn.hidden           = YES;
    [area addSubview:self.floating_btn positioned:NSWindowAbove relativeTo:nil];
}

/*
 * apply_bookmarks_bar_pref — shows or hides the bookmarks bar to match
 * files_pref_show_bookmarks (View ▸ Show Bookmarks Bar); when hidden, the
 * browser area takes its height. Cheap when nothing changed, so it runs on
 * every defaults change.
 */
- (void)
apply_bookmarks_bar_pref
{
    BOOL show = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_bookmarks];
    if (self.bookmarks_bar.hidden == !show) return;
    self.bookmarks_bar.hidden = !show;
    NSRect bounds = self.window.contentView.bounds;
    self.browser_area.frame = NSMakeRect(0, 0, NSWidth(bounds),
                                         NSHeight(bounds) - (show ? bookmarks_bar_h : 0.0));
}

/* ── Panes ───────────────────────────────────────────────────────────────── */

/*
 * active_browser — returns the browser of the active pane.
 *
 * Output: FilesBrowserView (never nil).
 */
- (FilesBrowserView *)
active_browser
{
    return (self.active_pane_index == 1 && self.secondary_browser)
        ? self.secondary_browser : self.primary_browser;
}

/*
 * all_browsers — the browser of every open pane.
 *
 * Output: array of one or two FilesBrowserView.
 */
- (NSArray<FilesBrowserView *> *)
all_browsers
{
    return self.secondary_browser
        ? @[self.primary_browser, self.secondary_browser]
        : @[self.primary_browser];
}

/*
 * new_browser_with_frame: — creates a pane's browser and connects its
 * callbacks to the window. Callbacks from either pane are accepted, but
 * only the active pane updates the shared toolbar, status bar, floating
 * button and info sidebar.
 *
 * Inputs:
 *   frame — initial frame
 *
 * Output: new FilesBrowserView, sized with the split view.
 */
- (FilesBrowserView *)
new_browser_with_frame:(NSRect)frame
{
    FilesBrowserView *b = [[FilesBrowserView alloc] init_with_frame:frame];
    b.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak FilesMainWindow  *ws = self;
    __weak FilesBrowserView *wb = b;
    b.navigation_handler = ^(NSURL *url) {
        FilesMainWindow *s = ws;
        if (!s || [s active_browser] != wb) return;
        [s update_toolbar_for_url:url];
        [s update_floating_button];
    };
    b.open_window_handler = ^(NSURL *url) {
        FilesMainWindow *s = ws;
        if (s.new_window_handler) s.new_window_handler(url);
    };
    b.bookmark_handler = ^(NSURL *url) {
        [ws.bookmarks_bar add_bookmark:url];
    };
    b.info_handler = ^(NSArray<NSURL *> *urls) {
        [FilesInfoPanel.shared show_for_url:urls.firstObject];
    };
    b.sidebar_handler = ^(NSArray<NSURL *> *urls) {
        FilesMainWindow *s = ws;
        if (s && [s active_browser] == wb) [s refresh_sidebar_for_active_pane];
    };
    b.status_text_handler = ^(NSString *text) {
        FilesMainWindow *s = ws;
        if (s && [s active_browser] == wb) [s show_pane_status];
    };
    return b;
}

/*
 * unmountable_volume_root — url itself if it is the root of a volume the
 * user may unmount (FilesVolumeManager can_unmount_volume: — anything but
 * the boot volume and fixed internal disks).
 *
 * Inputs:
 *   url — folder being shown
 *
 * Output: the volume root URL, or nil.
 */
static NSURL *
unmountable_volume_root(NSURL *url)
{
    NSURL *volume = nil;
    [url getResourceValue:&volume forKey:NSURLVolumeURLKey error:nil];
    if (!files_same_path(volume, url)) return nil;
    return [FilesVolumeManager.shared can_unmount_volume:volume] ? volume : nil;
}

/*
 * update_floating_button — shows the floating button for the active pane:
 * Empty Trash while it shows the Trash, Unmount "<name>" while it shows the
 * root of an unmountable volume, hidden otherwise.
 */
- (void)
update_floating_button
{
    NSURL    *url    = [self active_browser].current_url;
    NSURL    *volume = nil;
    NSButton *btn    = self.floating_btn;
    NSImage  *icon;
    if (files_same_path(url, files_directory_url(NSTrashDirectory))) {
        icon        = [[NSImage imageNamed:NSImageNameTrashEmpty] copy];
        icon.size   = NSMakeSize(20.0, 20.0);
        btn.action  = @selector(empty_trash_action:);
        btn.toolTip = @"Empty Trash";
    } else if ((volume = unmountable_volume_root(url))) {
        NSString *name = [FilesVolumeManager.shared display_name_for_volume:volume];
        btn.toolTip = [NSString stringWithFormat:@"Unmount \"%@\"", name];
        icon        = [[NSImage imageWithSystemSymbolName:@"eject" accessibilityDescription:btn.toolTip]
                          imageWithSymbolConfiguration:
                              [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                              weight:NSFontWeightRegular]];
        btn.action  = @selector(unmount_action:);
    } else {
        btn.hidden = YES;
        return;
    }
    btn.image   = icon;
    btn.enabled = YES;
    btn.hidden  = NO;
}

/*
 * set_active_pane: — makes pane index idx active and refreshes everything
 * that follows the active pane: dimming, toolbar, status bar, floating
 * button and info sidebar.
 *
 * Inputs:
 *   idx — 0 (primary) or 1 (secondary)
 */
- (void)
set_active_pane:(NSInteger)idx
{
    self.active_pane_index = idx;
    BOOL dual = self.secondary_browser != nil;
    self.primary_browser.alphaValue   = (dual && idx != 0) ? 0.45 : 1.0;
    self.secondary_browser.alphaValue = (idx != 1) ? 0.45 : 1.0;

    [self update_toolbar_for_url:[self active_browser].current_url];
    [self show_pane_status];
    [self update_floating_button];
    [self refresh_sidebar_for_active_pane];
}

/*
 * show_pane_status — puts the active pane's item count in the status bar,
 * unless a transient message is currently being shown.
 */
- (void)
show_pane_status
{
    if (self.transient_status_id) return;
    self.status_label.stringValue = [self active_browser].status_text ?: @"";
}

/*
 * show_transient_status: — shows msg in the status bar for
 * transient_status_sec, then restores the active pane's item count. Item
 * counts reported meanwhile are recorded and shown once it expires.
 *
 * Inputs:
 *   msg — message to show
 */
- (void)
show_transient_status:(NSString *)msg
{
    NSUInteger msg_id = ++self.transient_status_id;
    self.status_label.stringValue = msg;
    __weak FilesMainWindow *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(transient_status_sec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilesMainWindow *s = ws;
        if (!s || s.transient_status_id != msg_id) return;  /* superseded */
        s.transient_status_id = 0;
        [s show_pane_status];
    });
}

/*
 * update_toolbar_for_url: — refreshes the address bar, window title and
 * toolbar item enablement after a navigation.
 *
 * Inputs:
 *   url — directory now shown by the active pane
 */
- (void)
update_toolbar_for_url:(NSURL *)url
{
    self.address_bar.stringValue = url.path ?: @"";
    self.window.title            = url.lastPathComponent ?: @"Files";
    [self.window.toolbar validateVisibleItems];
}

/*
 * fit_address_bar — makes the address bar fill the toolbar between the +
 * button and the search field. The toolbar sizes a view item to its
 * fitting width and puts any room left over after its last item, so this
 * sets the address bar to the toolbar's width less its margins and the
 * other items (never below address_min_w). The toolbar's row of items, its
 * margin and the other items' width are measured whenever every item is
 * laid out with the search field at full width; the last measurement is
 * used while some are squeezed or in the overflow menu — the address bar
 * included, as when the window has just been made narrower. Runs whenever
 * the window is resized, and once after the first layout.
 */
- (void)
fit_address_bar
{
    NSView *viewer = self.address_bar.superview;   /* the item's viewer */
    NSView *row    = viewer.superview;             /* the toolbar's row of items */
    if (row) {
        [row layoutSubtreeIfNeeded];
        CGFloat pad   = NSWidth(viewer.frame) - NSWidth(self.address_bar.frame);
        CGFloat start = CGFLOAT_MAX, end = 0, next_w = 0, next_x = CGFLOAT_MAX;
        for (NSView *v in row.subviews) {
            start = MIN(start, NSMinX(v.frame));
            end   = MAX(end, NSMaxX(v.frame));
            if (NSMinX(v.frame) >= NSMaxX(viewer.frame) && NSMinX(v.frame) < next_x) {
                next_x = NSMinX(v.frame);   /* the search item comes next */
                next_w = NSWidth(v.frame);
            }
        }
        if (row.subviews.count == self.window.toolbar.items.count && next_w >= search_w + pad) {
            self.toolbar_row      = row;
            self.toolbar_margin   = start;
            self.toolbar_pad      = pad;
            self.toolbar_others_w = (end - start) - NSWidth(viewer.frame);
        }
    }
    if (!self.toolbar_row) return;   /* never measured: keep address_min_w */

    CGFloat want = MAX(address_min_w,
                       floor(NSWidth(self.toolbar_row.bounds) - 2.0 * self.toolbar_margin
                             - self.toolbar_others_w - self.toolbar_pad));
    if (fabs(want - self.address_width.constant) < 1.0) return;
    self.address_width.constant = want;
    /* The toolbar measures an item's view when it is set, and keeps that
     * size until the window is resized again; setting it anew makes the new
     * width count now (otherwise a narrower window could leave items in the
     * overflow menu). */
    self.address_item.view = self.address_bar;
}

/* ── Dual pane ───────────────────────────────────────────────────────────── */

/*
 * toggle_dual_pane: — switches between single-pane and dual-pane mode. The
 * second pane opens on the same folder as the first.
 *
 * Inputs:
 *   sender — menu item or toolbar item (unused)
 */
- (IBAction)
toggle_dual_pane:(id)sender
{
    if (self.secondary_browser) {
        [self.secondary_browser shut_down];
        [self.secondary_browser removeFromSuperview];
        self.secondary_browser = nil;
        [self set_active_pane:0];
        [self.window makeFirstResponder:self.primary_browser];
    } else {
        CGFloat split_w = self.pane_split.bounds.size.width;
        self.secondary_browser = [self new_browser_with_frame:
            NSMakeRect(0, 0, split_w / 2, self.pane_split.bounds.size.height)];
        [self.pane_split addSubview:self.secondary_browser];
        [self.pane_split setPosition:split_w / 2 ofDividerAtIndex:0];
        [self set_active_pane:0];
        [self.secondary_browser navigate_to:self.primary_browser.current_url];
    }
    [self.window.toolbar validateVisibleItems];
}

/*
 * keyDown: — Tab (without ⌘) in dual-pane mode moves focus to the other
 * pane; the firstResponder observer then makes it active.
 *
 * Inputs:
 *   event — key event; anything else goes to super
 */
- (void)
keyDown:(NSEvent *)event
{
    if (self.secondary_browser && event.keyCode == 48 /* Tab */ &&
        !(event.modifierFlags & NSEventModifierFlagCommand)) {
        FilesBrowserView *other = (self.active_pane_index == 0)
            ? self.secondary_browser : self.primary_browser;
        [self.window makeFirstResponder:other];
        return;
    }
    [super keyDown:event];
}

/*
 * observeValueForKeyPath:ofObject:change:context: — when the window's first
 * responder moves into a pane (dual-pane mode), makes that pane active so
 * toolbar and menu actions target the pane the user last touched.
 *
 * Inputs:
 *   keyPath, object, change — KVO arguments
 *   context                 — first_responder_ctx for our observation
 */
- (void)
observeValueForKeyPath:(NSString *)keyPath
              ofObject:(id)object
                change:(NSDictionary *)change
               context:(void *)context
{
    if (context != first_responder_ctx) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (!self.secondary_browser) return;

    NSResponder *r = self.window.firstResponder;
    for (NSView *v = [r isKindOfClass:NSView.class] ? (NSView *)r : nil; v; v = v.superview) {
        NSInteger idx = (v == self.primary_browser) ? 0 : (v == self.secondary_browser) ? 1 : -1;
        if (idx < 0) continue;
        if (idx != self.active_pane_index) [self set_active_pane:idx];
        return;
    }
}

/* ── NSToolbarDelegate ───────────────────────────────────────────────────── */

/*
 * toolbar_identifiers — the toolbar's items, left to right.
 *
 * Output: array of item identifiers.
 */
static NSArray<NSToolbarItemIdentifier> *
toolbar_identifiers(void)
{
    return @[tb_back, tb_forward, tb_up, tb_reload, tb_new_item,
             tb_path,
             tb_search, tb_hidden_files, tb_open_terminal,
             tb_dual_pane, tb_sidebar];
}

/*
 * toolbarAllowedItemIdentifiers: — every item the toolbar may show.
 *
 * Inputs:
 *   toolbar — the toolbar (unused)
 *
 * Output: toolbar_identifiers().
 */
- (NSArray<NSToolbarItemIdentifier> *)
toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
    return toolbar_identifiers();
}

/*
 * toolbarDefaultItemIdentifiers: — the items shown (customization is off).
 *
 * Inputs:
 *   toolbar — the toolbar (unused)
 *
 * Output: toolbar_identifiers().
 */
- (NSArray<NSToolbarItemIdentifier> *)
toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    return toolbar_identifiers();
}

/*
 * button_item — a standard image toolbar item targeting self. Standard
 * items get an overflow-menu representation and validation for free.
 *
 * Inputs:
 *   ident  — item identifier
 *   label  — label / tooltip text
 *   symbol — SF Symbol name
 *   action — selector sent to self
 *   target — action target
 *
 * Output: configured NSToolbarItem.
 */
static NSToolbarItem *
button_item(NSToolbarItemIdentifier ident, NSString *label, NSString *symbol,
            SEL action, id target)
{
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.label    = label;
    item.toolTip  = label;
    item.image    = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    item.action   = action;
    item.target   = target;
    item.bordered = YES;
    return item;
}

/*
 * toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar: — factory for each
 * toolbar item.
 *
 * Inputs:
 *   toolbar    — the requesting toolbar
 *   identifier — item identifier string
 *   flag       — YES if actually being inserted
 *
 * Output: configured NSToolbarItem, or nil for an unknown identifier.
 */
- (NSToolbarItem *)
toolbar:(NSToolbar *)toolbar
itemForItemIdentifier:(NSString *)identifier
willBeInsertedIntoToolbar:(BOOL)flag
{
    if ([identifier isEqualToString:tb_back])
        return button_item(identifier, @"Back", @"chevron.left", @selector(go_back_action:), self);
    if ([identifier isEqualToString:tb_forward])
        return button_item(identifier, @"Forward", @"chevron.right", @selector(go_forward_action:), self);
    if ([identifier isEqualToString:tb_up])
        return button_item(identifier, @"Up", @"arrow.up", @selector(go_up_action:), self);
    if ([identifier isEqualToString:tb_reload])
        return button_item(identifier, @"Reload", @"arrow.clockwise", @selector(reload_action:), self);
    if ([identifier isEqualToString:tb_hidden_files])
        return button_item(identifier, @"Show Hidden Files", @"eye.slash",
                           @selector(toggle_hidden_files_action:), self);
    if ([identifier isEqualToString:tb_open_terminal])
        return button_item(identifier, @"Open in Terminal", @"terminal",
                           @selector(open_terminal_action:), self);
    if ([identifier isEqualToString:tb_dual_pane])
        return button_item(identifier, @"Dual Pane", @"rectangle.split.2x1",
                           @selector(toggle_dual_pane:), self);
    if ([identifier isEqualToString:tb_sidebar])
        return button_item(identifier, @"Info Sidebar", @"sidebar.right",
                           @selector(toggle_sidebar_action:), self);

    if ([identifier isEqualToString:tb_new_item]) {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"New"];
        NSMenuItem *folder = [menu addItemWithTitle:@"New Folder"
                                             action:@selector(new_folder_action:) keyEquivalent:@""];
        NSMenuItem *file   = [menu addItemWithTitle:@"New File"
                                             action:@selector(new_file_action:) keyEquivalent:@""];
        folder.target = self;
        file.target   = self;
        NSMenuToolbarItem *item = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
        item.menu    = menu;
        item.label   = @"New";
        item.toolTip = @"New Folder or File";
        item.image   = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New"];
        return item;
    }
    if ([identifier isEqualToString:tb_search]) {
        NSSearchToolbarItem *item = [[NSSearchToolbarItem alloc] initWithItemIdentifier:identifier];
        /* A fixed width, so the address bar gets the toolbar's spare room. */
        item.preferredWidthForSearchField = search_w;
        [item.searchField.widthAnchor constraintLessThanOrEqualToConstant:search_w].active = YES;
        item.searchField.target            = self;
        item.searchField.action            = @selector(search_changed:);
        item.label                         = @"Search";

        /* The magnifying glass offers where to search. */
        NSMenu *scope = [[NSMenu alloc] initWithTitle:@"Search"];
        NSString * const titles[] = { @"This Folder", @"This Mac" };
        for (NSInteger tag = 0; tag < 2; tag++) {
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:titles[tag]
                                                        action:@selector(set_search_scope:)
                                                 keyEquivalent:@""];
            mi.target = self;
            mi.tag    = tag;
            [scope addItem:mi];
        }
        ((NSSearchFieldCell *)item.searchField.cell).searchMenuTemplate = scope;
        self.search_field = item.searchField;
        [self update_search_placeholder];
        return item;
    }

    if ([identifier isEqualToString:tb_path]) {
        self.address_bar = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 400, 22)];
        self.address_bar.placeholderString = @"Path";
        self.address_bar.bezelStyle        = NSTextFieldRoundedBezel;
        self.address_bar.font              = [NSFont monospacedSystemFontOfSize:12.0
                                                                         weight:NSFontWeightRegular];
        self.address_bar.target            = self;
        self.address_bar.action            = @selector(address_bar_action:);
        self.address_bar.focusRingType     = NSFocusRingTypeNone;
        /* One line, the end of the path kept in view when it is too long. */
        self.address_bar.usesSingleLineMode = YES;
        self.address_bar.cell.wraps         = NO;
        self.address_bar.cell.scrollable    = YES;
        self.address_bar.lineBreakMode      = NSLineBreakByTruncatingHead;
        /* The toolbar lays an item out at its view's fitting width and
         * leaves any spare room after the last item, so fit_address_bar
         * sets this width to fill it. */
        self.address_width = [self.address_bar.widthAnchor
                                 constraintEqualToConstant:address_min_w];
        self.address_width.priority = NSLayoutPriorityDefaultLow;
        [NSLayoutConstraint activateConstraints:@[
            [self.address_bar.widthAnchor constraintGreaterThanOrEqualToConstant:address_min_w],
            self.address_width,
        ]];
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.view  = self.address_bar;
        item.label = @"Path";
        self.address_item = item;
        return item;
    }
    return nil;
}

/*
 * validateToolbarItem: — enables Back/Forward/Up only when they can act and
 * swaps the Hidden Files and Dual Pane images to reflect their state.
 *
 * Inputs:
 *   item — toolbar item being validated
 *
 * Output: YES if the item should be enabled.
 */
- (BOOL)
validateToolbarItem:(NSToolbarItem *)item
{
    FilesBrowserView *b = [self active_browser];
    SEL action = item.action;
    if (action == @selector(go_back_action:))    return [b can_go_back];
    if (action == @selector(go_forward_action:)) return [b can_go_forward];
    if (action == @selector(go_up_action:)) {
        NSString *path = b.current_url.path;
        return path.length > 0 && ![path isEqualToString:@"/"];
    }
    if (action == @selector(toggle_hidden_files_action:)) {
        BOOL on = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hidden];
        item.image = [NSImage imageWithSystemSymbolName:on ? @"eye" : @"eye.slash"
                               accessibilityDescription:item.label];
    } else if (action == @selector(toggle_dual_pane:)) {
        item.image = [NSImage imageWithSystemSymbolName:self.secondary_browser
                                                        ? @"rectangle.split.2x1.fill"
                                                        : @"rectangle.split.2x1"
                               accessibilityDescription:item.label];
    }
    return YES;
}

/* ── Navigation actions (toolbar and Go menu) ────────────────────────────── */

/*
 * go_back_action: — Back in the active pane.
 *
 * Inputs:
 *   sender — toolbar item or menu item (unused)
 */
- (IBAction)
go_back_action:(id)sender
{
    [[self active_browser] go_back];
}

/*
 * go_forward_action: — Forward in the active pane.
 *
 * Inputs:
 *   sender — toolbar item or menu item (unused)
 */
- (IBAction)
go_forward_action:(id)sender
{
    [[self active_browser] go_forward];
}

/*
 * go_up_action: — shows the parent of the active pane's folder.
 *
 * Inputs:
 *   sender — toolbar item (unused)
 */
- (IBAction)
go_up_action:(id)sender
{
    NSURL *cur = [self active_browser].current_url;
    if (cur && ![cur.path isEqualToString:@"/"]) {
        [[self active_browser] navigate_to:cur.URLByDeletingLastPathComponent];
    }
}

/*
 * go_home_action: — Go ▸ Home.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
go_home_action:(id)sender
{
    [[self active_browser] navigate_to:files_home_url()];
}

/*
 * go_desktop_action: — Go ▸ Desktop.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
go_desktop_action:(id)sender
{
    [[self active_browser] navigate_to:files_directory_url(NSDesktopDirectory)];
}

/*
 * go_downloads_action: — Go ▸ Downloads.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
go_downloads_action:(id)sender
{
    [[self active_browser] navigate_to:files_directory_url(NSDownloadsDirectory)];
}

/*
 * go_documents_action: — Go ▸ Documents.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
go_documents_action:(id)sender
{
    [[self active_browser] navigate_to:files_directory_url(NSDocumentDirectory)];
}

/*
 * go_trash_action: — Go ▸ Trash.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
go_trash_action:(id)sender
{
    [[self active_browser] navigate_to:files_directory_url(NSTrashDirectory)];
}

/*
 * new_folder_action: — New Folder in the active pane (reached from the menu
 * or toolbar even when a text field, not the browser, has focus).
 *
 * Inputs:
 *   sender — menu item or toolbar menu item (unused)
 */
- (IBAction)
new_folder_action:(id)sender
{
    [[self active_browser] new_folder_action:sender];
}

/*
 * new_file_action: — New File in the active pane (see new_folder_action:).
 *
 * Inputs:
 *   sender — menu item or toolbar menu item (unused)
 */
- (IBAction)
new_file_action:(id)sender
{
    [[self active_browser] new_file_action:sender];
}

/*
 * reload_action: — re-reads the active pane's folder (and recounts its
 * folder sizes, with Show Folder Sizes on).
 *
 * Inputs:
 *   sender — toolbar item (unused)
 */
- (IBAction)
reload_action:(id)sender
{
    [[self active_browser] refresh];
}

/*
 * address_bar_action: — navigates to the path typed into the address bar.
 * Expands ~; resolves a relative path against the active pane's folder; for
 * a file, shows its parent folder. An unknown path reverts the field.
 *
 * Inputs:
 *   sender — address bar NSTextField
 */
- (void)
address_bar_action:(NSTextField *)sender
{
    FilesBrowserView *b = [self active_browser];
    NSString *raw  = [sender.stringValue stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *path = raw.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath && b.current_url) {
        path = [b.current_url.path stringByAppendingPathComponent:path];
    }

    BOOL is_dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&is_dir]) {
        sender.stringValue = b.current_url.path ?: @"";
    } else {
        if (!is_dir) path = path.stringByDeletingLastPathComponent;
        [b navigate_to:[NSURL fileURLWithPath:path].URLByStandardizingPath];
    }
    [sender.window makeFirstResponder:nil];
}

/*
 * find_action: — Edit ▸ Find (⌘F): moves focus to the toolbar search field,
 * showing the toolbar and expanding a collapsed search field first. A
 * custom selector (not performFindPanelAction:) so that a focused text
 * field such as the address bar cannot intercept it.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
find_action:(id)sender
{
    NSToolbar *tb = self.window.toolbar;
    tb.visible = YES;
    for (NSToolbarItem *item in tb.items) {
        if ([item isKindOfClass:NSSearchToolbarItem.class]) {
            [(NSSearchToolbarItem *)item beginSearchInteraction];
            return;
        }
    }
}

/*
 * update_search_placeholder — shows the search scope in the empty search
 * field: "Search This Folder" or "Search This Mac" (files_pref_search_this_mac).
 * Also run when preferences change, so every window stays in step.
 */
- (void)
update_search_placeholder
{
    BOOL mac = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_search_this_mac];
    self.search_field.placeholderString = mac ? @"Search This Mac" : @"Search This Folder";
}

/*
 * set_search_scope: — search menu ▸ This Folder (tag 0) or This Mac (tag 1):
 * saves the choice and re-runs the search in progress, if any.
 *
 * Inputs:
 *   sender — the chosen menu item
 */
- (void)
set_search_scope:(NSMenuItem *)sender
{
    [NSUserDefaults.standardUserDefaults setBool:(sender.tag == 1)
                                          forKey:files_pref_search_this_mac];
    [self update_search_placeholder];
    if (self.search_field.stringValue.length > 0) [self search_changed:self.search_field];
}

/*
 * search_changed: — runs (or clears) a Spotlight search in the active pane.
 *
 * Inputs:
 *   sender — the toolbar NSSearchField
 */
- (void)
search_changed:(NSSearchField *)sender
{
    [[self active_browser] set_search_filter:sender.stringValue];
}

/*
 * add_bookmark_action: — adds the active pane's folder to the bookmarks bar.
 *
 * Inputs:
 *   sender — menu item or the bookmarks bar's star button (unused)
 */
- (IBAction)
add_bookmark_action:(id)sender
{
    NSURL *cur = [self active_browser].current_url;
    if (cur) [self.bookmarks_bar add_bookmark:cur];
}

/*
 * open_terminal_action: — opens Terminal at the active pane's folder.
 *
 * Inputs:
 *   sender — toolbar item or menu item (unused)
 */
- (IBAction)
open_terminal_action:(id)sender
{
    NSWorkspace *ws = NSWorkspace.sharedWorkspace;
    NSURL *dir      = [self active_browser].current_url ?: files_home_url();
    NSURL *terminal = [ws URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"];
    __weak NSWindow *win = self.window;
    [ws openURLs:@[dir]
        withApplicationAtURL:terminal
               configuration:[NSWorkspaceOpenConfiguration configuration]
           completionHandler:^(NSRunningApplication *app, NSError *err) {
        if (!err) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            files_show_error(@"Could not open Terminal", err, win);
        });
    }];
}

/*
 * empty_trash_action: — forwards to the active browser (the floating button
 * shows Empty Trash only while that browser shows the Trash).
 *
 * Inputs:
 *   sender — the floating button
 */
- (IBAction)
empty_trash_action:(id)sender
{
    [[self active_browser] empty_trash_action:sender];
}

/*
 * unmount_action: — unmounts the volume whose root the active pane shows.
 * The button is disabled while the unmount runs. On success the status bar
 * says so for a few seconds and volumes_changed: moves every pane off the
 * vanished volume to /Volumes. If it fails because files on the volume are
 * open, a sheet lists them and says the unmount is pending (see
 * watch_pending_unmount:); any other failure shows an error sheet.
 *
 * Inputs:
 *   sender — the floating button
 */
- (IBAction)
unmount_action:(id)sender
{
    NSURL *volume = unmountable_volume_root([self active_browser].current_url);
    if (!volume) return;
    NSString *name = [FilesVolumeManager.shared display_name_for_volume:volume];
    self.floating_btn.enabled = NO;
    __weak FilesMainWindow *ws = self;
    [FilesVolumeManager.shared unmount_volume:volume completion:^(NSError *err) {
        FilesMainWindow *s = ws;
        if (!s) return;
        s.floating_btn.enabled = YES;
        if (!err) {
            [s show_transient_status:[NSString stringWithFormat:@"\"%@\" was unmounted.", name]];
            return;
        }
        [FilesVolumeManager.shared open_files_on_volume:volume completion:^(NSArray<NSString *> *items) {
            if (items.count == 0) {
                files_show_error([NSString stringWithFormat:@"Could not unmount \"%@\"", name],
                                 err, s.window);
                return;
            }
            [s show_pending_unmount:name items:items];
            [s watch_pending_unmount:volume name:name delay:pending_retry_min_sec];
        }];
    }];
}

/*
 * show_pending_unmount:items: — sheet telling the user the unmount is
 * pending and which open files (and the apps holding them) must be closed.
 *
 * Inputs:
 *   name  — volume display name
 *   items — open-file descriptions from open_files_on_volume:completion:
 */
- (void)
show_pending_unmount:(NSString *)name items:(NSArray<NSString *> *)items
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN(items.count, pending_list_max); i++) {
        [lines addObject:[@"• " stringByAppendingString:items[i]]];
    }
    if (items.count > pending_list_max) {
        [lines addObject:[NSString stringWithFormat:@"…and %lu more",
                          (unsigned long)(items.count - pending_list_max)]];
    }
    NSAlert *alert        = files_new_alert();
    alert.messageText     = [NSString stringWithFormat:@"Unmounting \"%@\" is pending", name];
    alert.informativeText = [NSString stringWithFormat:
        @"It will be unmounted automatically once these are closed:\n\n%@",
        [lines componentsJoinedByString:@"\n"]];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

/*
 * watch_pending_unmount:name:delay: — after delay, checks a pending volume:
 * if it is already gone (macOS completed the unmount itself), or a retried
 * unmount now succeeds, the status bar reports it; otherwise it checks
 * again, backing off to pending_retry_max_sec. A retry is a single cheap
 * unmount request, not a scan of open files. One watcher per volume;
 * stops if this window closes.
 *
 * Inputs:
 *   volume — volume root URL
 *   name   — its display name (for the status message)
 *   delay  — seconds until the next check
 */
- (void)
watch_pending_unmount:(NSURL *)volume name:(NSString *)name delay:(double)delay
{
    if (!self.pending_unmounts) self.pending_unmounts = [NSMutableSet set];
    if (delay == pending_retry_min_sec) {
        if ([self.pending_unmounts containsObject:volume.path]) return;  /* already watching */
        [self.pending_unmounts addObject:volume.path];
    }

    __weak FilesMainWindow *ws = self;
    void (^done)(void) = ^{
        FilesMainWindow *s = ws;
        [s.pending_unmounts removeObject:volume.path];
        [s show_transient_status:[NSString stringWithFormat:@"\"%@\" was unmounted.", name]];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilesMainWindow *s = ws;
        if (!s) return;
        if (![volume checkResourceIsReachableAndReturnError:nil]) {
            done();
            return;
        }
        [FilesVolumeManager.shared unmount_volume:volume completion:^(NSError *err) {
            if (!err) {
                done();
            } else {
                [ws watch_pending_unmount:volume name:name
                                    delay:MIN(delay * 2.0, pending_retry_max_sec)];
            }
        }];
    });
}

/*
 * volumes_changed: — after any mount, unmount or rename (from this app,
 * Finder, or elsewhere), moves each pane whose folder no longer exists —
 * e.g. it was on an unmounted volume — to /Volumes, where the remaining
 * volumes are listed.
 *
 * Inputs:
 *   note — FilesVolumesChangedNotification (unused)
 */
- (void)
volumes_changed:(NSNotification *)note
{
    for (FilesBrowserView *b in [self all_browsers]) {
        NSURL *url = b.current_url;
        if (url && ![url checkResourceIsReachableAndReturnError:nil]) {
            [b navigate_to:[NSURL fileURLWithPath:@"/Volumes" isDirectory:YES]];
        }
    }
}

/* ── View preferences (apply to every pane) ──────────────────────────────── */

/*
 * toggle_hidden_files_action: — flips files_pref_show_hidden; every pane
 * in every window applies it (FilesBrowserView apply_view_prefs).
 *
 * Inputs:
 *   sender — toolbar item (unused)
 */
- (IBAction)
toggle_hidden_files_action:(id)sender
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setBool:![ud boolForKey:files_pref_show_hidden] forKey:files_pref_show_hidden];
    [self.window.toolbar validateVisibleItems];
}

/*
 * validateMenuItem: — sets the Dual Pane and search-scope checkmarks and
 * enables Back/Forward only when possible.
 *
 * Inputs:
 *   item — the menu item being validated
 *
 * Output: YES if the item should be enabled.
 */
- (BOOL)
validateMenuItem:(NSMenuItem *)item
{
    SEL action = item.action;
    if (action == @selector(toggle_dual_pane:)) {
        item.state = self.secondary_browser ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(set_search_scope:)) {
        BOOL mac   = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_search_this_mac];
        item.state = (item.tag == 1) == mac ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(go_back_action:)) {
        return [[self active_browser] can_go_back];
    } else if (action == @selector(go_forward_action:)) {
        return [[self active_browser] can_go_forward];
    }
    return YES;
}

/* ── Info sidebar ────────────────────────────────────────────────────────── */

/*
 * toggle_sidebar_action: — shows or hides the info sidebar (animated). On
 * show it displays the active selection; on hide it releases the thumbnail
 * and cancels any pending Quick Look request.
 *
 * Inputs:
 *   sender — toolbar item (unused)
 */
- (IBAction)
toggle_sidebar_action:(id)sender
{
    BOOL show = self.sidebar_item.isCollapsed;
    self.sidebar_item.animator.collapsed = !show;
    if (show) {
        [self refresh_sidebar_for_active_pane];
    } else {
        [self.info_sidebar clear];
    }
}

/*
 * refresh_sidebar_for_active_pane — shows the active pane's selection in the
 * info sidebar (its folder when nothing is selected). No-op while collapsed.
 */
- (void)
refresh_sidebar_for_active_pane
{
    if (self.sidebar_item.isCollapsed) return;
    FilesBrowserView *b = [self active_browser];
    NSArray<NSURL *> *sel = b.selected_urls;
    if (sel.count > 1) {
        [self.info_sidebar show_urls:sel];
    } else if (sel.count == 1) {
        [self.info_sidebar show_url:sel.firstObject];
    } else if (b.current_url) {
        [self.info_sidebar show_url:b.current_url];
    } else {
        [self.info_sidebar clear];
    }
}

@end
