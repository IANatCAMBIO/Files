#import "main_window.h"
#import "bookmarks_bar.h"
#import "browser_pane.h"
#import "browser_view.h"
#import "info_panel.h"
#import "info_sidebar.h"
#import "util.h"

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

static const CGFloat bookmarks_bar_h = 28.0;
static const CGFloat status_h        = 20.0;
static const CGFloat sidebar_w       = 180.0;  /* initial info sidebar width */
static const CGFloat sidebar_min_w   = 140.0;
static const CGFloat browser_min_w   = 400.0;

/* KVO context for the window's firstResponder (dual-pane focus tracking). */
static void *first_responder_ctx = &first_responder_ctx;

@interface FilesMainWindow () <NSToolbarDelegate, NSToolbarItemValidation>

/* Toolbar views */
@property (nonatomic, strong) NSTextField *address_bar;

/* Layout */
@property (nonatomic, strong) FilesBookmarksBar     *bookmarks_bar;
@property (nonatomic, strong) NSSplitView           *pane_split;   /* holds 1 or 2 panes */
@property (nonatomic, strong) NSSplitViewController *content_split_vc;
@property (nonatomic, strong) NSSplitViewItem       *sidebar_item;
@property (nonatomic, strong) FilesInfoSidebar      *info_sidebar;

/* Panes */
@property (nonatomic, strong) FilesBrowserPane *primary_pane;
@property (nonatomic, strong) FilesBrowserPane *secondary_pane;    /* nil = single-pane */
@property (nonatomic)         NSInteger         active_pane_index; /* 0 or 1 */

/* Status bar (full-width, below the split) and floating Empty Trash button */
@property (nonatomic, strong) NSTextField *status_label;
@property (nonatomic, strong) NSButton    *empty_trash_btn;

@end

@implementation FilesMainWindow

/*
 * init — builds the window, toolbar, layout and primary browser pane, then
 * shows the home folder. The window frame is restored from the previous
 * session when one was saved; otherwise the window is centered.
 *
 * Output: self or nil.
 */
- (instancetype)
init
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

    __weak FilesMainWindow *ws = self;
    self.bookmarks_bar.selection_handler = ^(NSURL *url) {
        [[ws active_browser] navigate_to:url];
    };
    [self.primary_pane.browser navigate_to:files_home_url()];

    /* Deferred so it runs after the window's initial first-responder pass. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeFirstResponder:self.address_bar];
    });
    return self;
}

/*
 * dealloc — removes the firstResponder observer added in init.
 */
- (void)
dealloc
{
    [self.window removeObserver:self forKeyPath:@"firstResponder" context:first_responder_ctx];
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

    self.primary_pane = [[FilesBrowserPane alloc] init_with_frame:self.pane_split.bounds];
    [self.pane_split addSubview:self.primary_pane];
    [self wire_pane:self.primary_pane];

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

    /* Floating Empty Trash button — icon-only, lower-right, over the browser. */
    static const CGFloat fab_size   = 36.0;
    static const CGFloat fab_margin = 14.0;
    NSImage *fab_icon = [[NSImage imageNamed:NSImageNameTrashEmpty] copy];
    fab_icon.size = NSMakeSize(20.0, 20.0);
    self.empty_trash_btn = [[NSButton alloc]
        initWithFrame:NSMakeRect(w - fab_size - fab_margin, status_h + 1.0 + fab_margin,
                                 fab_size, fab_size)];
    self.empty_trash_btn.image            = fab_icon;
    self.empty_trash_btn.imageScaling     = NSImageScaleProportionallyDown;
    self.empty_trash_btn.bezelStyle       = NSBezelStyleRegularSquare;
    self.empty_trash_btn.buttonType       = NSButtonTypeMomentaryLight;
    self.empty_trash_btn.target           = self;
    self.empty_trash_btn.action           = @selector(empty_trash_action:);
    self.empty_trash_btn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.empty_trash_btn.hidden           = YES;
    self.empty_trash_btn.toolTip          = @"Empty Trash";
    [area addSubview:self.empty_trash_btn positioned:NSWindowAbove relativeTo:nil];
}

/* ── Panes ───────────────────────────────────────────────────────────────── */

/*
 * active_pane — returns the currently active browser pane.
 *
 * Output: FilesBrowserPane (never nil).
 */
- (FilesBrowserPane *)
active_pane
{
    return (self.active_pane_index == 1 && self.secondary_pane)
        ? self.secondary_pane : self.primary_pane;
}

/*
 * active_browser — returns the FilesBrowserView of the active pane.
 *
 * Output: FilesBrowserView (never nil).
 */
- (FilesBrowserView *)
active_browser
{
    return [self active_pane].browser;
}

/*
 * all_browsers — the browser of every open pane.
 *
 * Output: array of one or two FilesBrowserView.
 */
- (NSArray<FilesBrowserView *> *)
all_browsers
{
    return self.secondary_pane
        ? @[self.primary_pane.browser, self.secondary_pane.browser]
        : @[self.primary_pane.browser];
}

/*
 * wire_pane: — connects a pane's browser callbacks to the window. Every
 * callback records per-pane state, but only the active pane updates the
 * shared toolbar, status bar, Empty Trash button and info sidebar.
 *
 * Inputs:
 *   pane — pane to wire
 */
- (void)
wire_pane:(FilesBrowserPane *)pane
{
    __weak FilesMainWindow  *ws = self;
    __weak FilesBrowserPane *wp = pane;
    FilesBrowserView *b = pane.browser;

    b.navigation_handler = ^(NSURL *url) {
        FilesMainWindow *s = ws;
        if (!s || [s active_pane] != wp) return;
        [s update_toolbar_for_url:url];
        [s.bookmarks_bar update_trash_icon];
    };
    b.info_handler = ^(NSArray<NSURL *> *urls) {
        [FilesInfoPanel.shared show_for_url:urls.firstObject];
    };
    b.sidebar_handler = ^(NSArray<NSURL *> *urls) {
        FilesMainWindow *s = ws;
        if (s && [s active_pane] == wp) [s refresh_sidebar_for_active_pane];
    };
    b.status_text_handler = ^(NSString *text) {
        FilesMainWindow *s = ws;
        FilesBrowserPane *p = wp;
        if (!s || !p) return;
        p.status_text = text;
        /* Listings of the Trash are the signal that its contents changed. */
        if (p.showing_trash) [s.bookmarks_bar update_trash_icon];
        if ([s active_pane] == p) s.status_label.stringValue = text ?: @"";
    };
    b.trash_visible_handler = ^(BOOL show) {
        FilesMainWindow *s = ws;
        FilesBrowserPane *p = wp;
        if (!s || !p) return;
        p.showing_trash = show;
        if ([s active_pane] == p) s.empty_trash_btn.hidden = !show;
    };
}

/*
 * set_active_pane: — makes pane index idx active and refreshes everything
 * that follows the active pane: dimming, toolbar, status bar, Empty Trash
 * button and info sidebar.
 *
 * Inputs:
 *   idx — 0 (primary) or 1 (secondary)
 */
- (void)
set_active_pane:(NSInteger)idx
{
    self.active_pane_index        = idx;
    self.primary_pane.is_active   = (idx == 0);
    self.secondary_pane.is_active = (idx == 1);

    FilesBrowserPane *p = [self active_pane];
    [self update_toolbar_for_url:p.browser.current_url];
    self.status_label.stringValue = p.status_text ?: @"";
    self.empty_trash_btn.hidden   = !p.showing_trash;
    [self refresh_sidebar_for_active_pane];
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
    if (self.secondary_pane) {
        [self.secondary_pane removeFromSuperview];
        self.secondary_pane = nil;
        self.primary_pane.in_dual_mode = NO;
        [self set_active_pane:0];
        [self.window makeFirstResponder:self.primary_pane.browser];
    } else {
        CGFloat split_w = self.pane_split.bounds.size.width;
        self.secondary_pane = [[FilesBrowserPane alloc]
            init_with_frame:NSMakeRect(0, 0, split_w / 2, self.pane_split.bounds.size.height)];
        self.secondary_pane.in_dual_mode = YES;
        self.primary_pane.in_dual_mode   = YES;
        [self wire_pane:self.secondary_pane];
        [self.pane_split addSubview:self.secondary_pane];
        [self.pane_split setPosition:split_w / 2 ofDividerAtIndex:0];
        [self set_active_pane:0];
        [self.secondary_pane.browser navigate_to:self.primary_pane.browser.current_url];
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
    if (self.secondary_pane && event.keyCode == 48 /* Tab */ &&
        !(event.modifierFlags & NSEventModifierFlagCommand)) {
        FilesBrowserPane *other = (self.active_pane_index == 0)
            ? self.secondary_pane : self.primary_pane;
        [self.window makeFirstResponder:other.browser];
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
    if (!self.secondary_pane) return;

    NSResponder *r = self.window.firstResponder;
    for (NSView *v = [r isKindOfClass:NSView.class] ? (NSView *)r : nil; v; v = v.superview) {
        NSInteger idx = (v == self.primary_pane) ? 0 : (v == self.secondary_pane) ? 1 : -1;
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
    return @[tb_back, tb_forward, tb_up, tb_reload,
             NSToolbarFlexibleSpaceItemIdentifier,
             tb_path,
             NSToolbarFlexibleSpaceItemIdentifier,
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

    if ([identifier isEqualToString:tb_search]) {
        NSSearchToolbarItem *item = [[NSSearchToolbarItem alloc] initWithItemIdentifier:identifier];
        item.searchField.target            = self;
        item.searchField.action            = @selector(search_changed:);
        item.searchField.placeholderString = @"Search";
        item.label                         = @"Search";
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
        NSLayoutConstraint *pref = [self.address_bar.widthAnchor constraintEqualToConstant:400];
        pref.priority = NSLayoutPriorityDefaultLow;
        [NSLayoutConstraint activateConstraints:@[
            [self.address_bar.widthAnchor constraintGreaterThanOrEqualToConstant:200],
            [self.address_bar.widthAnchor constraintLessThanOrEqualToConstant:800],
            pref,
        ]];
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.view  = self.address_bar;
        item.label = @"Path";
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
        item.image = [NSImage imageWithSystemSymbolName:self.secondary_pane
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
 * reload_action: — re-reads the active pane's folder.
 *
 * Inputs:
 *   sender — toolbar item (unused)
 */
- (IBAction)
reload_action:(id)sender
{
    [[self active_browser] reload_directory];
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
 * is only visible while that browser shows the Trash).
 *
 * Inputs:
 *   sender — the floating Empty Trash button
 */
- (IBAction)
empty_trash_action:(id)sender
{
    [[self active_browser] empty_trash_action:sender];
}

/* ── View preferences (apply to every pane) ──────────────────────────────── */

/*
 * toggle_hidden_files_action: — flips files_pref_show_hidden and reloads
 * every pane.
 *
 * Inputs:
 *   sender — toolbar item (unused)
 */
- (IBAction)
toggle_hidden_files_action:(id)sender
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setBool:![ud boolForKey:files_pref_show_hidden] forKey:files_pref_show_hidden];
    for (FilesBrowserView *b in [self all_browsers]) [b reload_directory];
    [self.window.toolbar validateVisibleItems];
}

/*
 * auto_fit_columns_action: — toggles files_pref_auto_fit; when turned on,
 * fits the columns of every pane immediately.
 *
 * Inputs:
 *   sender — View menu item (unused)
 */
- (IBAction)
auto_fit_columns_action:(id)sender
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL now_on = ![ud boolForKey:files_pref_auto_fit];
    [ud setBool:now_on forKey:files_pref_auto_fit];
    if (now_on) {
        for (FilesBrowserView *b in [self all_browsers]) [b apply_auto_fit];
    }
}

/*
 * validateMenuItem: — sets the Auto-Fit Columns and Dual Pane checkmarks and
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
    if (action == @selector(auto_fit_columns_action:)) {
        item.state = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_auto_fit]
            ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(toggle_dual_pane:)) {
        item.state = self.secondary_pane ? NSControlStateValueOn : NSControlStateValueOff;
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
