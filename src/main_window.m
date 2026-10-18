#import "main_window.h"
#import "tool_panel.h"
#import "bookmarks_bar.h"
#import "browser_view.h"
#import "info_panel.h"
#import "info_sidebar.h"
#import "util.h"
#import "volume_manager.h"

/* Toolbar item identifiers */
static NSString * const tb_back_forward  = @"files.back-forward";
static NSString * const tb_up            = @"files.up";
static NSString * const tb_reload        = @"files.reload";
static NSString * const tb_hidden_files  = @"files.hidden-files";
static NSString * const tb_search        = @"files.search";
static NSString * const tb_open_terminal = @"files.open-terminal";
static NSString * const tb_dual_pane     = @"files.dual-pane";
static NSString * const tb_sidebar       = @"files.sidebar";
static NSString * const tb_new_item      = @"files.new-item";

static const CGFloat bookmarks_bar_h = 28.0;
static const CGFloat status_h        = 20.0;
static const CGFloat address_h       = 30.0;   /* address bar strip under the toolbar */
static const CGFloat sidebar_w       = 180.0;  /* initial info sidebar width */
static const CGFloat sidebar_min_w   = 140.0;
static const CGFloat browser_min_w   = 400.0;
static const CGFloat search_w        = 220.0;  /* toolbar search field */

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

/* Layout */
@property (nonatomic, strong) NSTextField           *address_bar;  /* full-width, under the toolbar */
@property (nonatomic, strong) NSButton              *bookmark_star; /* right of it: ★ / ☆ (update_bookmark_star) */
@property (nonatomic, weak)   NSSearchField         *search_field;  /* toolbar search field */
@property (nonatomic, strong) FilesBookmarksBar     *bookmarks_bar;
@property (nonatomic, strong) NSView                *browser_area; /* everything below the bar */
@property (nonatomic, strong) NSSplitViewController *pane_split_vc;  /* holds 1 or 2 panes */
@property (nonatomic, strong) NSSplitViewItem       *secondary_item; /* second pane's item; nil = single-pane */
@property (nonatomic, strong) NSSplitViewController *content_split_vc;
@property (nonatomic, strong) NSSplitViewItem       *sidebar_item;
@property (nonatomic, strong) FilesInfoSidebar      *info_sidebar;

/* Panes: one browser each; in dual-pane mode the inactive one is dimmed. */
@property (nonatomic, strong) FilesBrowserView *primary_browser;
@property (nonatomic, strong) FilesBrowserView *secondary_browser; /* nil = single-pane */
@property (nonatomic)         NSInteger         active_pane_index; /* 0 or 1 */
@property (nonatomic)         BOOL              panes_animating;   /* second pane sliding in or out */

/* Status bar (full-width, below the split) and the floating action button,
 * which is Empty Trash in the Trash and Unmount at an unmountable volume's
 * root (see update_floating_button). */
@property (nonatomic, strong) NSTextField *status_label;
/* Left of the status bar: spins while the active pane's folder is
 * loading (FilesBrowserView loading). */
@property (nonatomic, strong) NSProgressIndicator *loading_spinner;
/* Right of the status bar: free and total space of the active pane's
 * volume (refresh_disk_space). */
@property (nonatomic, strong) NSTextField *space_label;
@property (nonatomic, assign) NSUInteger   space_generation;
@property (nonatomic, assign) BOOL         space_refresh_scheduled;
@property (nonatomic, strong) NSButton    *floating_btn;
@property (nonatomic, copy)   NSArray<NSLayoutConstraint *> *fab_anchors; /* its current pin */
@property (nonatomic, assign) NSUInteger   fab_generation;  /* drops superseded volume checks */
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
                                           selector:@selector(update_bookmark_star)
                                               name:files_bookmarks_changed_note
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(window_will_close:)
                                               name:NSWindowWillCloseNotification
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
        [ws refresh_disk_space];
        [ws update_title];
    }];
    [self apply_bookmarks_bar_pref];

    self.bookmarks_bar.selection_handler = ^(NSURL *url) {
        [[ws active_browser] navigate_to:url];
    };
    [self.primary_browser navigate_to:url];

    /* Deferred so it runs after the window's initial first-responder pass. */
    dispatch_async(dispatch_get_main_queue(), ^{
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
 * build_layout — the full-width address bar on top, the bookmarks bar
 * under it; below them the status bar and an NSSplitViewController whose
 * left item holds the browser pane(s) and whose right item is the
 * collapsible info sidebar (collapsed at launch). The split view controller
 * manages collapsing, minimum widths and the divider.
 */
- (void)
build_layout
{
    NSView *content = self.window.contentView;
    CGFloat w = content.bounds.size.width;
    CGFloat h = content.bounds.size.height;

    /* Address bar: the window's full width, under the toolbar, with the
     * bookmark star at its right and a separator along the bottom edge:
     * the divider above the list when the bookmarks bar is hidden. */
    NSView *address_container = [[NSView alloc]
        initWithFrame:NSMakeRect(0, h - address_h, w, address_h)];
    address_container.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:address_container];

    self.address_bar = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.address_bar.translatesAutoresizingMaskIntoConstraints = NO;
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
    [address_container addSubview:self.address_bar];

    NSButton *star = [NSButton buttonWithTitle:@"☆" target:self
                                        action:@selector(toggle_bookmark_action:)];
    star.translatesAutoresizingMaskIntoConstraints = NO;
    star.bordered = NO;   /* a bare glyph, no button background */
    star.font     = [NSFont systemFontOfSize:14.0];
    [address_container addSubview:star];
    self.bookmark_star = star;

    [NSLayoutConstraint activateConstraints:@[
        [self.address_bar.leadingAnchor  constraintEqualToAnchor:address_container.leadingAnchor
                                                        constant:8.0],
        [self.address_bar.trailingAnchor constraintEqualToAnchor:star.leadingAnchor
                                                        constant:-4.0],
        /* Centred in the strip above the separator. The 1 pt separator
         * takes the bottom of the container, and the rounded bezel's
         * alignment rect sits about half a point below its drawn edge:
         * measured together they left the field 1 pt low. */
        [self.address_bar.centerYAnchor  constraintEqualToAnchor:address_container.centerYAnchor
                                                        constant:-1.0],
        [star.trailingAnchor constraintEqualToAnchor:address_container.trailingAnchor
                                            constant:-8.0],
        [star.centerYAnchor  constraintEqualToAnchor:self.address_bar.centerYAnchor],
        [star.widthAnchor    constraintEqualToConstant:26.0],
    ]];

    NSBox *address_sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, w, 1)];
    address_sep.boxType          = NSBoxSeparator;
    address_sep.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [address_container addSubview:address_sep];

    CGFloat below_address = h - address_h;
    self.bookmarks_bar = [[FilesBookmarksBar alloc]
        init_with_frame:NSMakeRect(0, below_address - bookmarks_bar_h, w, bookmarks_bar_h)];
    self.bookmarks_bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.bookmarks_bar];

    NSView *area = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, w, below_address - bookmarks_bar_h)];
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
    self.space_label = [NSTextField labelWithString:@""];
    self.space_label.translatesAutoresizingMaskIntoConstraints = NO;
    self.space_label.alignment = NSTextAlignmentRight;
    self.space_label.font      = [NSFont systemFontOfSize:11.0];
    self.space_label.textColor = NSColor.secondaryLabelColor;
    [self.space_label setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.space_label setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [status_container addSubview:self.space_label];
    self.loading_spinner = [[NSProgressIndicator alloc] init];
    self.loading_spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loading_spinner.style                = NSProgressIndicatorStyleSpinning;
    self.loading_spinner.controlSize          = NSControlSizeSmall;
    self.loading_spinner.indeterminate        = YES;
    self.loading_spinner.displayedWhenStopped = NO;
    [status_container addSubview:self.loading_spinner];

    /* The item count stays centred in the bar; it gives way (truncating)
     * before it would run into the disk space on the right. */
    NSLayoutConstraint *centred = [self.status_label.centerXAnchor
                                      constraintEqualToAnchor:status_container.centerXAnchor];
    centred.priority = NSLayoutPriorityDefaultHigh;
    self.status_label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.status_label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [self.status_label.centerYAnchor  constraintEqualToAnchor:status_container.centerYAnchor],
        centred,
        [self.status_label.leadingAnchor  constraintGreaterThanOrEqualToAnchor:self.loading_spinner.trailingAnchor
                                                                      constant:8.0],
        [self.status_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.space_label.leadingAnchor
                                                                   constant:-8.0],
        [self.loading_spinner.centerYAnchor constraintEqualToAnchor:status_container.centerYAnchor],
        [self.loading_spinner.leadingAnchor constraintEqualToAnchor:status_container.leadingAnchor
                                                           constant:8.0],
        [self.loading_spinner.widthAnchor   constraintEqualToConstant:14.0],
        [self.loading_spinner.heightAnchor  constraintEqualToConstant:14.0],
        [self.space_label.centerYAnchor   constraintEqualToAnchor:status_container.centerYAnchor],
        [self.space_label.trailingAnchor  constraintEqualToAnchor:status_container.trailingAnchor
                                                         constant:-8.0],
    ]];

    NSBox *status_sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, status_h, w, 1)];
    status_sep.boxType          = NSBoxSeparator;
    status_sep.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [area addSubview:status_sep];

    /* Browser side: pane_split_vc permanently owns the pane(s); single-pane
     * mode is pane_split_vc with one item, so primary_pane is never
     * reparented. A split view controller, like the info sidebar's, so the
     * second pane slides in and out with the same animation. */
    CGFloat split_h = area.bounds.size.height - status_h - 1.0;
    NSView *browser_container = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, w, split_h)];
    browser_container.wantsLayer = YES;

    self.pane_split_vc = [[NSSplitViewController alloc] init];
    self.pane_split_vc.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    NSView *panes = self.pane_split_vc.view;
    panes.frame            = browser_container.bounds;
    panes.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [browser_container addSubview:panes];

    self.primary_browser = [self new_browser_with_frame:browser_container.bounds];
    [self.pane_split_vc addSplitViewItem:[self pane_item:self.primary_browser]];

    /* Sidebar side. */
    self.info_sidebar = [[FilesInfoSidebar alloc]
        initWithFrame:NSMakeRect(0, 0, sidebar_w, split_h)];

    NSViewController *browser_vc = [[NSViewController alloc] init];
    browser_vc.view = browser_container;
    [browser_vc addChildViewController:self.pane_split_vc];
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

    /* Floating action button — icon-only, lower-right, over the file list.
     * It lives in browser_container, not area, so it stays clear of the info
     * sidebar. Its image, action and tooltip are set by update_floating_button. */
    static const CGFloat fab_size = 36.0;
    self.floating_btn = [[NSButton alloc]
        initWithFrame:NSMakeRect(0, 0, fab_size, fab_size)];
    self.floating_btn.imageScaling     = NSImageScaleProportionallyDown;
    self.floating_btn.bezelStyle       = NSBezelStyleRegularSquare;
    self.floating_btn.buttonType       = NSButtonTypeMomentaryLight;
    self.floating_btn.target           = self;
    self.floating_btn.hidden           = YES;
    [browser_container addSubview:self.floating_btn positioned:NSWindowAbove relativeTo:nil];
    /* Positioned by constraints (anchor_floating_button), not a frame: the
     * container's real width is set later by the split view. */
    self.floating_btn.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.floating_btn.widthAnchor  constraintEqualToConstant:fab_size],
        [self.floating_btn.heightAnchor constraintEqualToConstant:fab_size],
    ]];
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
                                         NSHeight(bounds) - address_h
                                         - (show ? bookmarks_bar_h : 0.0));
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
    b.split_pane_handler = ^(NSURL *url) {
        [ws open_in_split_pane:url from:wb];
    };
    b.info_handler = ^(NSArray<NSURL *> *urls) {
        [FilesInfoPanel.shared show_for_url:urls.firstObject];
    };
    b.sidebar_handler = ^(NSArray<NSURL *> *urls) {
        FilesMainWindow *s = ws;
        if (s && [s active_browser] == wb) [s refresh_sidebar_for_active_pane];
    };
    b.list_layout_handler = ^{
        FilesMainWindow *s = ws;
        if (s && [s active_browser] == wb) [s anchor_floating_button];
    };
    b.status_text_handler = ^(NSString *text) {
        FilesMainWindow *s = ws;
        if (s && [s active_browser] == wb) [s show_pane_status];
    };
    b.loading_handler = ^{
        FilesMainWindow *s = ws;
        if (s && [s active_browser] == wb) [s show_pane_loading];
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
 * anchor_floating_button — pins the floating button fab_margin (visible
 * gap) from the lower-right corner of the active pane's file list: the visible
 * rows, ending where the scrollers begin, not the pane or window edge. Replaces the previous pin, so it follows the active
 * pane.
 */
- (void)
anchor_floating_button
{
    static const CGFloat fab_margin = 15.0;
    NSView *list = [self active_browser].list_view;
    NSButton *btn = self.floating_btn;
    if (!list.window || list.window != btn.window) return;
    if (self.fab_anchors) [NSLayoutConstraint deactivateConstraints:self.fab_anchors];
    NSEdgeInsets bars  = [self active_browser].list_insets;
    self.fab_anchors = @[
        [btn.trailingAnchor constraintEqualToAnchor:list.trailingAnchor
                                           constant:-(fab_margin + bars.right)],
        [btn.bottomAnchor   constraintEqualToAnchor:list.bottomAnchor
                                           constant:-(fab_margin + bars.bottom)],
    ];
    [NSLayoutConstraint activateConstraints:self.fab_anchors];
}

/*
 * update_floating_button — shows the floating button for the active pane:
 * Empty Trash while it shows the Trash, Unmount "<name>" while it shows the
 * root of an unmountable volume, hidden otherwise. The volume is checked
 * on a background queue (a slow volume would otherwise block the UI), so
 * the Unmount button appears once that check is in.
 */
- (void)
update_floating_button
{
    [self anchor_floating_button];
    NSURL    *url = [self active_browser].current_url;
    NSButton *btn = self.floating_btn;
    NSUInteger generation = ++self.fab_generation;
    btn.hidden = YES;
    if (!url) return;
    if (files_same_path(url, files_directory_url(NSTrashDirectory))) {
        NSImage *icon = [[NSImage imageNamed:NSImageNameTrashEmpty] copy];
        icon.size   = NSMakeSize(20.0, 20.0);
        btn.action  = @selector(empty_trash_action:);
        btn.toolTip = @"Empty Trash";
        btn.image   = icon;
        btn.enabled = YES;
        btn.hidden  = NO;
        return;
    }

    __weak FilesMainWindow *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *volume  = unmountable_volume_root(url);
        NSString *name = volume ? [FilesVolumeManager.shared display_name_for_volume:volume] : nil;
        if (!volume) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesMainWindow *s = ws;
            if (!s || generation != s.fab_generation) return;
            NSButton *b = s.floating_btn;
            b.toolTip = [NSString stringWithFormat:@"Unmount \"%@\"", name];
            b.image   = [[NSImage imageWithSystemSymbolName:@"eject" accessibilityDescription:b.toolTip]
                            imageWithSymbolConfiguration:
                                [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                                weight:NSFontWeightRegular]];
            b.action  = @selector(unmount_action:);
            b.enabled = YES;
            b.hidden  = NO;
        });
    });
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
    [self show_pane_loading];
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
    [self refresh_disk_space];
    if (self.transient_status_id) return;
    self.status_label.stringValue = [self active_browser].status_text ?: @"";
}

/*
 * show_pane_loading — spins the status bar spinner while the active
 * pane's folder is loading and hides it otherwise.
 */
- (void)
show_pane_loading
{
    if ([self active_browser].loading) {
        [self.loading_spinner startAnimation:nil];
    } else {
        [self.loading_spinner stopAnimation:nil];
    }
}

/*
 * refresh_disk_space — shows "10.4 GB (of 200 GB) free" — or, with
 * files_pref_show_used_space (View ▸ Show Used Disk Space), "189.6 GB (of
 * 200 GB) used", i.e. total less free — for the volume of the active
 * pane's folder at the right of the status bar. Free space is
 * the space available for important use (it counts purgeable space, as
 * Finder does), else the plain available capacity. The volume is asked on
 * a background queue — an unresponsive network volume must not stall the
 * window — at most every 0.3 s however often the status changes (every
 * listing and selection change asks), and a newer request supersedes an
 * older answer still on its way. Empty if the volume does not say. Also
 * runs on every preference change, so the toggle shows at once.
 */
- (void)
refresh_disk_space
{
    if (self.space_refresh_scheduled) return;
    self.space_refresh_scheduled = YES;
    __weak FilesMainWindow *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilesMainWindow *s = ws;
        if (!s) return;
        s.space_refresh_scheduled = NO;
        NSString *path = [s active_browser].current_url.path;
        if (!path) return;
        NSUInteger generation = ++s.space_generation;
        BOOL used = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_used_space];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            /* A new URL each time: resource values are cached per URL. */
            NSDictionary<NSURLResourceKey, id> *v =
                [[NSURL fileURLWithPath:path] resourceValuesForKeys:@[
                    NSURLVolumeAvailableCapacityForImportantUsageKey,
                    NSURLVolumeAvailableCapacityKey,
                    NSURLVolumeTotalCapacityKey,
                ] error:nil];
            NSNumber *free  = v[NSURLVolumeAvailableCapacityForImportantUsageKey]
                              ?: v[NSURLVolumeAvailableCapacityKey];
            NSNumber *total = v[NSURLVolumeTotalCapacityKey];
            NSString *text  = @"";
            if (free && total.longLongValue > 0) {
                int64_t shown = used ? MAX(total.longLongValue - free.longLongValue, 0)
                                     : free.longLongValue;
                text = [NSString stringWithFormat:@"%@ (of %@) %@", files_format_bytes(shown),
                        files_format_bytes(total.longLongValue), used ? @"used" : @"free"];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesMainWindow *m = ws;
                if (m && generation == m.space_generation) m.space_label.stringValue = text;
            });
        });
    });
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
 * update_title — titles the window after the active pane's folder: its
 * name, or its full path when files_pref_full_path_title is on ("Files"
 * before any folder is shown). Runs after a navigation and on every
 * defaults change.
 */
- (void)
update_title
{
    NSURL *url  = [self active_browser].current_url;
    BOOL   full = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_full_path_title];
    self.window.title = (full ? url.path : url.lastPathComponent) ?: @"Files";
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
    [self update_bookmark_star];
    [self update_title];
    [self.window.toolbar validateVisibleItems];
}

/* ── Dual pane ───────────────────────────────────────────────────────────── */

/*
 * pane_item: — a split view item for one browser pane of pane_split_vc.
 *
 * Inputs:
 *   browser — the pane's browser view
 *
 * Output: new split view item.
 */
- (NSSplitViewItem *)
pane_item:(FilesBrowserView *)browser
{
    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = browser;
    return [NSSplitViewItem splitViewItemWithViewController:vc];
}

/*
 * toggle_dual_pane: — switches between single-pane and dual-pane mode. The
 * second pane opens on the same folder as the first (open_secondary_pane_at:);
 * on close it slides back out to the right edge with the split view
 * collapse animation, then is removed. Ignored while a slide is under way.
 *
 * Inputs:
 *   sender — menu item or toolbar item (unused)
 */
- (IBAction)
toggle_dual_pane:(id)sender
{
    if (self.panes_animating) return;

    if (self.secondary_browser) {
        self.panes_animating = YES;
        __weak FilesMainWindow *ws = self;
        /* Single-pane from now on; the closing pane only slides out. */
        NSSplitViewItem *item = self.secondary_item;
        [self.secondary_browser shut_down];
        self.secondary_browser = nil;
        self.secondary_item    = nil;
        [self set_active_pane:0];
        [self.window makeFirstResponder:self.primary_browser];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            item.animator.collapsed = YES;
        } completionHandler:^{
            [ws.pane_split_vc removeSplitViewItem:item];
            ws.panes_animating = NO;
        }];
        [self.window.toolbar validateVisibleItems];
    } else {
        [self open_secondary_pane_at:self.primary_browser.current_url];
    }
}

/*
 * open_secondary_pane_at: — switches to dual-pane mode with the second pane
 * showing url. The pane slides in from the right edge with the split view
 * collapse animation the info sidebar uses: it is added collapsed at half
 * the width, then expanded. The primary pane stays active. Call only in
 * single-pane mode and when no slide is under way.
 *
 * Inputs:
 *   url — folder the second pane shows
 */
- (void)
open_secondary_pane_at:(NSURL *)url
{
    self.panes_animating = YES;
    __weak FilesMainWindow *ws = self;

    NSSize size = self.pane_split_vc.view.bounds.size;
    self.secondary_browser = [self new_browser_with_frame:
        NSMakeRect(0, 0, floor(size.width / 2), size.height)];
    NSSplitViewItem *item = [self pane_item:self.secondary_browser];
    item.canCollapse = YES;
    item.collapsed   = YES;
    [self.pane_split_vc addSplitViewItem:item];
    self.secondary_item = item;
    [self set_active_pane:0];
    [self.secondary_browser navigate_to:url];
    /* Expand on the next pass, once the item is laid out collapsed. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            item.animator.collapsed = NO;
        } completionHandler:^{
            ws.panes_animating = NO;
        }];
    });
    [self.window.toolbar validateVisibleItems];
}

/*
 * open_in_split_pane:from: — shows url in the pane other than source,
 * opening the second pane first in single-pane mode. Ignored while a pane
 * slide is under way.
 *
 * Inputs:
 *   url    — folder to show
 *   source — the pane whose context menu asked for it
 */
- (void)
open_in_split_pane:(NSURL *)url from:(FilesBrowserView *)source
{
    if (self.panes_animating) return;
    if (!self.secondary_browser) {
        [self open_secondary_pane_at:url];
    } else if (source == self.secondary_browser) {
        [self.primary_browser navigate_to:url];
    } else {
        [self.secondary_browser navigate_to:url];
    }
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
    return @[tb_back_forward, tb_up, tb_reload,
             NSToolbarSpaceItemIdentifier,
             tb_hidden_files, tb_open_terminal, tb_dual_pane, tb_sidebar,
             NSToolbarSpaceItemIdentifier,
             tb_new_item,
             NSToolbarFlexibleSpaceItemIdentifier,
             tb_search];
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
    if ([identifier isEqualToString:tb_back_forward]) {
        /* One segmented control, Back joined to Forward. Each subitem keeps
         * its own action, so validateToolbarItem: enables each segment and
         * the overflow menu runs the right one. */
        NSArray<NSString *> *labels = @[@"Back", @"Forward"];
        NSArray<NSImage *> *images = @[
            [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:labels[0]],
            [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:labels[1]],
        ];
        NSToolbarItemGroup *group =
            [NSToolbarItemGroup groupWithItemIdentifier:identifier
                                                 images:images
                                          selectionMode:NSToolbarItemGroupSelectionModeMomentary
                                                 labels:labels
                                                 target:self
                                                 action:@selector(back_forward_action:)];
        group.label = @"Back/Forward";
        const SEL actions[] = { @selector(go_back_action:), @selector(go_forward_action:) };
        for (NSUInteger i = 0; i < group.subitems.count; i++) {
            group.subitems[i].toolTip = labels[i];
            group.subitems[i].action  = actions[i];
            group.subitems[i].target  = self;
        }
        return group;
    }
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
        item.preferredWidthForSearchField = search_w;
        [item.searchField.widthAnchor constraintLessThanOrEqualToConstant:search_w].active = YES;
        item.searchField.target            = self;
        item.searchField.action            = @selector(search_changed:);
        /* No focus ring, like the address bar. */
        item.searchField.focusRingType     = NSFocusRingTypeNone;
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
 * back_forward_action: — the Back/Forward segmented item: runs the clicked
 * segment's action.
 *
 * Inputs:
 *   sender — the toolbar item group
 */
- (IBAction)
back_forward_action:(NSToolbarItemGroup *)sender
{
    if (sender.selectedIndex == 0) [self go_back_action:sender];
    else                           [self go_forward_action:sender];
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
 *   sender — menu item (unused)
 */
- (IBAction)
add_bookmark_action:(id)sender
{
    NSURL *cur = [self active_browser].current_url;
    if (cur) [self.bookmarks_bar add_bookmark:cur];
}

/*
 * toggle_bookmark_action: — the address bar's star: bookmarks the active
 * pane's folder, or removes its bookmark if it has one. The star follows
 * through files_bookmarks_changed_note.
 *
 * Inputs:
 *   sender — the star button (unused)
 */
- (IBAction)
toggle_bookmark_action:(id)sender
{
    NSURL *cur = [self active_browser].current_url;
    if (!cur) return;
    if (files_is_bookmark(cur)) {
        [self.bookmarks_bar remove_bookmark:cur];
    } else {
        [self.bookmarks_bar add_bookmark:cur];
    }
}

/*
 * update_bookmark_star — shows ★ when the active pane's folder is a
 * bookmark and ☆ when it is not, with a tooltip saying what a click does.
 * Disabled at Trash, which is always a bookmark and cannot be removed.
 * Runs after each navigation, pane switch and bookmark-list change.
 */
- (void)
update_bookmark_star
{
    NSURL *cur    = [self active_browser].current_url;
    BOOL   marked = cur && files_is_bookmark(cur);
    self.bookmark_star.title   = marked ? @"★" : @"☆";
    self.bookmark_star.toolTip = marked ? @"Remove Current Folder from Bookmarks"
                                        : @"Add Current Folder to Bookmarks";
    self.bookmark_star.enabled = cur && !files_same_path(cur, files_directory_url(NSTrashDirectory));
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
    [FilesToolPanel show_message:[NSString stringWithFormat:@"Unmounting \"%@\" is pending", name]
                         message:[NSString stringWithFormat:
                                     @"It will be unmounted automatically once these are closed:"
                                      "\n\n%@", [lines componentsJoinedByString:@"\n"]]
                          symbol:@"eject"
                         buttons:@[@"OK"]
                            over:self.window
                         handler:nil];
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
