#import "main_window.h"
#import "bookmarks_bar.h"
#import "browser_pane.h"
#import "browser_view.h"
#import "info_panel.h"
#import "info_sidebar.h"

/* Toolbar item identifiers */
static NSString * const kToolbarBack         = @"files.back";
static NSString * const kToolbarForward      = @"files.forward";
static NSString * const kToolbarUp           = @"files.up";
static NSString * const kToolbarReload       = @"files.reload";
static NSString * const kToolbarHiddenFiles  = @"files.hidden-files";
static NSString * const kToolbarPath         = @"files.path";
static NSString * const kToolbarSearch       = @"files.search";
static NSString * const kToolbarOpenTerminal = @"files.open-terminal";
static NSString * const kToolbarDualPane     = @"files.dual-pane";
static NSString * const kToolbarSidebar      = @"files.sidebar";

static const CGFloat kBookmarksBarH = 28.0;
static const CGFloat kSidebarW      = 180.0;
static const CGFloat kStatusH       = 20.0;

@interface FilesMainWindow ()
    <NSToolbarDelegate, NSSplitViewDelegate>

/* Toolbar controls */
@property (nonatomic, strong) NSButton      *back_button;
@property (nonatomic, strong) NSButton      *forward_button;
@property (nonatomic, strong) NSButton      *up_button;
@property (nonatomic, strong) NSTextField   *address_bar;
@property (nonatomic, strong) NSSearchField *search_field;
@property (nonatomic, strong) NSButton      *dual_pane_btn;

/* Layout */
@property (nonatomic, strong) NSView            *browser_container; /* holds pane(s) */
@property (nonatomic, strong) FilesBookmarksBar *bookmarks_bar;

/* Panes */
@property (nonatomic, strong) FilesBrowserPane *primary_pane;
@property (nonatomic, strong) FilesBrowserPane *secondary_pane;    /* nil = single-pane */
@property (nonatomic, strong) NSSplitView      *pane_split;        /* permanent; secondary_pane nil = single-pane */
@property (nonatomic)         NSInteger         active_pane_index; /* 0 or 1 */
@property (nonatomic)         BOOL              observing_responder;

/* Sidebar */
@property (nonatomic, strong) NSSplitView      *content_split;
@property (nonatomic, strong) FilesInfoSidebar *info_sidebar;

/* Status bar (full-width, below split) */
@property (nonatomic, strong) NSTextField *status_label;
@property (nonatomic, strong) NSButton    *status_trash_btn;

@end

@implementation FilesMainWindow {
    /* YES while the sidebar collapse setPosition: call is in flight.
     * Keeps shouldHideDividerAtIndex: returning NO so the divider is still
     * "live" and setPosition: is not a no-op. */
    BOOL _collapsing_sidebar;

    /* YES between entry and the next run-loop iteration after toggle_dual_pane:
     * completes.  NSButtonTypePushOnPushOff fires the action more than once per
     * physical click (once on mouse-down, once on mouse-up) via the AppKit
     * tracking loop; the async clear blocks both re-entrant and sequential
     * double-fires. */
    BOOL _in_toggle_dual;
}

- (instancetype)initWithCoder:(NSCoder *)c { (void)c; return [self init]; }

/*
 * init — builds window, toolbar, split view, sidebar, and primary browser pane.
 *
 * Output: self or nil.
 */
- (instancetype)
init
{
    NSRect frame = NSMakeRect(0, 0, 940, 620);
    NSWindowStyleMask style =
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    win.title             = @"Files";
    win.minSize           = NSMakeSize(700, 450);
    win.restorable        = YES;
    win.frameAutosaveName = @"FilesMainWindow";
    /* Separate titlebar above the toolbar (traditional appearance). */
    if (@available(macOS 11.0, *)) {
        win.toolbarStyle = NSWindowToolbarStyleExpanded;
    }
    [win center];

    self = [super initWithWindow:win];
    if (!self) return nil;

    [self build_toolbar];
    [self build_layout];
    [self wire_up];

    return self;
}

/* ── Layout ──────────────────────────────────────────────────────────────── */

/*
 * build_toolbar — creates and attaches the NSToolbar.
 */
- (void)
build_toolbar
{
    NSToolbar *tb    = [[NSToolbar alloc] initWithIdentifier:@"files.toolbar"];
    tb.delegate      = self;
    tb.allowsUserCustomization = NO;
    tb.displayMode   = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = tb;
}

/*
 * build_layout — creates the bookmarks bar and an autoresizing 'area' view
 * below it. Inside area, an NSSplitView holds the browser_container (left)
 * and info_sidebar (right). The sidebar is collapsed after the first layout
 * pass so the browser fills the full width on launch.
 */
- (void)
build_layout
{
    NSView *content = self.window.contentView;
    CGFloat w = content.bounds.size.width;
    CGFloat h = content.bounds.size.height;

    /* Bookmarks bar — 28pt at the very top of the content view. */
    self.bookmarks_bar = [[FilesBookmarksBar alloc]
        init_with_frame:NSMakeRect(0, h - kBookmarksBarH, w, kBookmarksBarH)];
    self.bookmarks_bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.bookmarks_bar];

    /* 'area' fills the content view below the bookmarks bar using only
     * autoresizing — the content view's child list stays frame-based only. */
    NSView *area = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, w, h - kBookmarksBarH)];
    area.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:area];

    /* Full-width status bar at the very bottom of area. */
    NSView *status_container = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, w, kStatusH)];
    status_container.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [area addSubview:status_container];

    /* Floating Empty Trash button — icon-only circle, lower-right of area.
     * Added to area (not status_container) so it overlays the browser. */

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

    /* 1pt separator above the status bar. */
    NSBox *status_sep = [[NSBox alloc]
        initWithFrame:NSMakeRect(0, kStatusH, w, 1)];
    status_sep.boxType          = NSBoxSeparator;
    status_sep.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [area addSubview:status_sep];

    /* NSSplitView sits above the status bar. Left subview = browser, right = sidebar. */
    CGFloat split_h = area.bounds.size.height - kStatusH - 1.0;
    self.content_split = [[NSSplitView alloc]
        initWithFrame:NSMakeRect(0, kStatusH + 1.0, w, split_h)];
    self.content_split.vertical     = YES;
    self.content_split.dividerStyle = NSSplitViewDividerStyleThin;
    self.content_split.delegate     = self;
    self.content_split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [area addSubview:self.content_split];

    /* Left: browser container. */
    CGFloat browser_w = area.bounds.size.width - kSidebarW;
    self.browser_container = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, browser_w, split_h)];
    self.browser_container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.browser_container.wantsLayer       = YES;
    [self.content_split addSubview:self.browser_container];

    /* pane_split permanently owns the browser panes.  In single-pane mode it
     * holds only primary_pane (which fills the full width); in dual-pane mode
     * secondary_pane is added alongside it.  Keeping primary_pane inside
     * pane_split for its entire lifetime avoids CA-layer reparenting issues. */
    self.pane_split = [[NSSplitView alloc]
        initWithFrame:self.browser_container.bounds];
    self.pane_split.vertical     = YES;
    self.pane_split.dividerStyle = NSSplitViewDividerStyleThin;
    self.pane_split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.browser_container addSubview:self.pane_split];

    self.primary_pane = [[FilesBrowserPane alloc]
        init_with_frame:self.pane_split.bounds];
    self.primary_pane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.pane_split addSubview:self.primary_pane];

    /* Right: info sidebar. Given its real initial width so build_views can
     * position its subviews correctly. */
    self.info_sidebar = [[FilesInfoSidebar alloc]
        initWithFrame:NSMakeRect(0, 0, kSidebarW, split_h)];
    [self.content_split addSubview:self.info_sidebar];

    /* Floating Empty Trash button — icon-only, lower-right, overlays the browser. */
    static const CGFloat kFABSize   = 36.0;
    static const CGFloat kFABMargin = 14.0; /* distance from right/bottom edges of area */
    NSImage *fab_icon = [NSImage imageNamed:NSImageNameTrashEmpty];
    fab_icon = [fab_icon copy];
    fab_icon.size = NSMakeSize(20.0, 20.0);
    self.status_trash_btn = [[NSButton alloc]
        initWithFrame:NSMakeRect(w - kFABSize - kFABMargin,
                                 kStatusH + 1.0 + kFABMargin,
                                 kFABSize, kFABSize)];
    self.status_trash_btn.image         = fab_icon;
    self.status_trash_btn.imageScaling  = NSImageScaleProportionallyDown;
    self.status_trash_btn.bezelStyle    = NSBezelStyleRegularSquare;
    self.status_trash_btn.buttonType    = NSButtonTypeMomentaryLight;
    self.status_trash_btn.target        = self;
    self.status_trash_btn.action        = @selector(empty_trash_action:);
    self.status_trash_btn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.status_trash_btn.hidden        = YES;
    self.status_trash_btn.toolTip       = @"Empty Trash";
    [area addSubview:self.status_trash_btn positioned:NSWindowAbove relativeTo:nil];

    /* Collapse the sidebar after the first layout pass so the browser fills
     * the full width on launch. Cannot hide synchronously — NSSplitView has
     * not yet measured its subviews at this point. */
    dispatch_async(dispatch_get_main_queue(), ^{
        _collapsing_sidebar = YES;
        [self.content_split setPosition:self.content_split.bounds.size.width
                       ofDividerAtIndex:0];
        self.info_sidebar.hidden = YES;
        _collapsing_sidebar = NO;
    });
}

/* ── Pane access ─────────────────────────────────────────────────────────── */

/*
 * active_pane — returns the currently active browser pane.
 *
 * Output: FilesBrowserPane (never nil).
 */
- (FilesBrowserPane *)
active_pane
{
    if (self.active_pane_index == 1 && self.secondary_pane) {
        return self.secondary_pane;
    }
    return self.primary_pane;
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

/* ── Wiring ──────────────────────────────────────────────────────────────── */

/*
 * wire_up — connects panes, toolbar controls, and info handler.
 */
- (void)
wire_up
{
    __weak FilesMainWindow *ws = self;

    /* Wire primary pane */
    self.primary_pane.navigation_handler = ^(NSURL *url) {
        FilesMainWindow *s = ws;
        if (!s || s.active_pane_index != 0) return;
        [s update_toolbar_for_url:url];
        [s.bookmarks_bar update_trash_icon];
    };
    self.primary_pane.info_handler = ^(NSArray<NSURL *> *urls) {
        if (urls.firstObject) [FilesInfoPanel.shared show_for_url:urls.firstObject];
    };

    /* Bookmarks bar navigates the active pane */
    self.bookmarks_bar.selection_handler = ^(NSURL *url) {
        [[ws active_pane] navigate_to:url];
    };

    /* Sidebar selection tracking for primary pane. */
    [self wire_sidebar_for_pane:self.primary_pane];
    [self wire_status_for_pane:self.primary_pane];

    /* Navigate home on launch */
    [self.primary_pane navigate_to:[NSURL fileURLWithPath:NSHomeDirectory()]];

    /* Defer focus so it runs after window-state restoration overrides initialFirstResponder. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeFirstResponder:self.address_bar];
    });
}

/*
 * update_toolbar_for_url: — refreshes toolbar controls after a navigation event.
 *
 * Inputs:
 *   url — new current directory URL
 */
- (void)
update_toolbar_for_url:(NSURL *)url
{
    self.address_bar.stringValue = url.path ?: @"";
    self.window.title            = url.lastPathComponent ?: @"Files";
    self.back_button.enabled    = [[self active_browser] can_go_back];
    self.forward_button.enabled = [[self active_browser] can_go_forward];

    /* Disable Up at filesystem root (path == "/"). */
    if (self.up_button) {
        NSString *parent = url.path.stringByDeletingLastPathComponent;
        self.up_button.enabled = (parent.length > 0 &&
                                  ![parent isEqualToString:url.path]);
    }
}

/* ── Dual pane ───────────────────────────────────────────────────────────── */

/*
 * toggle_dual_pane: — switch between single-pane and dual-pane mode.
 *
 * Inputs:
 *   sender — menu item or toolbar button (unused)
 */
- (IBAction)
toggle_dual_pane:(id)sender
{
    if (_in_toggle_dual) return;
    _in_toggle_dual = YES;
    __weak FilesMainWindow *ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FilesMainWindow *s = ws;
        if (s) s->_in_toggle_dual = NO;
    });

    if (self.secondary_pane) {
        /* Collapse to single pane.  primary_pane stays inside pane_split —
         * we only remove secondary_pane so the split has one child and
         * primary fills the full width.  No CA-layer reparenting. */
        if (self.observing_responder) {
            [self.window removeObserver:self forKeyPath:@"firstResponder"];
            self.observing_responder = NO;
        }

        [self.secondary_pane removeFromSuperview];
        self.secondary_pane = nil;

        self.primary_pane.show_accent_border = NO;
        self.primary_pane.is_active          = YES;
        self.active_pane_index               = 0;

        [self update_toolbar_for_url:[self.primary_pane current_url]];
        [self.window makeFirstResponder:self.primary_pane.browser];

    } else {
        /* Expand to dual pane.  Add secondary_pane to the permanent
         * pane_split; primary_pane does not move. */
        CGFloat split_w = self.pane_split.bounds.size.width;
        CGFloat split_h = self.pane_split.bounds.size.height;

        self.active_pane_index               = 0;
        self.primary_pane.show_accent_border = YES;
        self.primary_pane.is_active          = YES;

        self.secondary_pane = [[FilesBrowserPane alloc]
            init_with_frame:NSMakeRect(0, 0, split_w / 2, split_h)];
        self.secondary_pane.autoresizingMask   = NSViewWidthSizable | NSViewHeightSizable;
        self.secondary_pane.show_accent_border = YES;
        self.secondary_pane.is_active          = NO;

        self.secondary_pane.navigation_handler = ^(NSURL *url) {
            FilesMainWindow *s = ws;
            if (!s || s.active_pane_index != 1) return;
            [s update_toolbar_for_url:url];
        };
        self.secondary_pane.info_handler = ^(NSArray<NSURL *> *urls) {
            if (urls.firstObject) [FilesInfoPanel.shared show_for_url:urls.firstObject];
        };

        [self wire_sidebar_for_pane:self.secondary_pane];
        [self wire_status_for_pane:self.secondary_pane];
        [self.secondary_pane navigate_to:self.primary_pane.current_url];

        [self.pane_split addSubview:self.secondary_pane];
        [self.pane_split setPosition:split_w / 2 ofDividerAtIndex:0];

        if (!self.observing_responder) {
            [self.window addObserver:self
                          forKeyPath:@"firstResponder"
                             options:0
                             context:NULL];
            self.observing_responder = YES;
        }
    }

    self.dual_pane_btn.state = self.secondary_pane
        ? NSControlStateValueOn : NSControlStateValueOff;
}

/* ── Open in Terminal ────────────────────────────────────────────────────── */

/*
 * open_terminal_clicked: — open Terminal.app at the active pane's directory.
 *
 * Inputs:
 *   sender — toolbar button or menu item (unused)
 */
- (IBAction)
open_terminal_clicked:(id)sender
{
    NSString *path = [self active_pane].current_url.path ?: NSHomeDirectory();
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-a", @"Terminal", path];
    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) NSLog(@"open_terminal_clicked: %@", err.localizedDescription);
}

/* ── Tab key: switch active pane ─────────────────────────────────────────── */

/*
 * keyDown: — intercepts Tab when dual-pane is active to switch focus.
 *
 * Inputs:
 *   event — key event
 */
- (void)
keyDown:(NSEvent *)event
{
    if (self.secondary_pane &&
        event.keyCode == 48 /* Tab */ &&
        !(event.modifierFlags & NSEventModifierFlagCommand))
    {
        self.active_pane_index = (self.active_pane_index == 0) ? 1 : 0;
        self.primary_pane.is_active   = (self.active_pane_index == 0);
        self.secondary_pane.is_active = (self.active_pane_index == 1);
        [[self active_pane].browser becomeFirstResponder];
        [self update_toolbar_for_url:[self active_pane].current_url];
        return;
    }
    [super keyDown:event];
}

/* ── NSToolbarDelegate ───────────────────────────────────────────────────── */

- (NSArray<NSToolbarItemIdentifier> *)
toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
    return @[kToolbarBack, kToolbarForward, kToolbarUp, kToolbarReload,
             NSToolbarFlexibleSpaceItemIdentifier,
             kToolbarPath,
             NSToolbarFlexibleSpaceItemIdentifier,
             kToolbarSearch, kToolbarHiddenFiles, kToolbarOpenTerminal,
             kToolbarDualPane, kToolbarSidebar];
}

- (NSArray<NSToolbarItemIdentifier> *)
toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    /* Navigation cluster: ‹ › ↑ ↺  —  [address bar]  —  [search] 👁 >_ ⊟ ▣ */
    return @[kToolbarBack, kToolbarForward, kToolbarUp, kToolbarReload,
             NSToolbarFlexibleSpaceItemIdentifier,
             kToolbarPath,
             NSToolbarFlexibleSpaceItemIdentifier,
             kToolbarSearch, kToolbarHiddenFiles, kToolbarOpenTerminal,
             kToolbarDualPane, kToolbarSidebar];
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
 * Output: configured NSToolbarItem.
 */
- (NSToolbarItem *)
toolbar:(NSToolbar *)toolbar
itemForItemIdentifier:(NSString *)identifier
willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];

    if ([identifier isEqualToString:kToolbarBack]) {
        self.back_button = [NSButton buttonWithTitle:@"‹"
                                              target:self
                                              action:@selector(back_clicked:)];
        if (@available(macOS 11.0, *)) {
            self.back_button.image =
                [NSImage imageWithSystemSymbolName:@"chevron.left"
                          accessibilityDescription:@"Back"];
        }
        self.back_button.bezelStyle = NSBezelStyleTexturedRounded;
        self.back_button.enabled    = NO;
        item.view    = self.back_button;
        item.label   = @"Back";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarForward]) {
        self.forward_button = [NSButton buttonWithTitle:@"›"
                                                 target:self
                                                 action:@selector(forward_clicked:)];
        if (@available(macOS 11.0, *)) {
            self.forward_button.image =
                [NSImage imageWithSystemSymbolName:@"chevron.right"
                          accessibilityDescription:@"Forward"];
        }
        self.forward_button.bezelStyle = NSBezelStyleTexturedRounded;
        self.forward_button.enabled    = NO;
        item.view    = self.forward_button;
        item.label   = @"Forward";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarPath]) {
        self.address_bar = [[NSTextField alloc]
            initWithFrame:NSMakeRect(0, 0, 400, 22)];
        self.address_bar.placeholderString  = @"Path";
        self.address_bar.bezelStyle         = NSTextFieldRoundedBezel;
        self.address_bar.font               = [NSFont monospacedSystemFontOfSize:12.0
                                                                          weight:NSFontWeightRegular];
        self.address_bar.target             = self;
        self.address_bar.action             = @selector(address_bar_action:);
        self.address_bar.focusRingType      = NSFocusRingTypeNone;
        item.view    = self.address_bar;
        item.label   = @"Path";
        item.minSize = NSMakeSize(200, 26);
        item.maxSize = NSMakeSize(800, 26);

    } else if ([identifier isEqualToString:kToolbarUp]) {
        self.up_button = [NSButton buttonWithTitle:@"↑"
                                            target:self
                                            action:@selector(go_up_clicked:)];
        if (@available(macOS 11.0, *)) {
            self.up_button.image =
                [NSImage imageWithSystemSymbolName:@"arrow.up"
                          accessibilityDescription:@"Up"];
        }
        self.up_button.bezelStyle = NSBezelStyleTexturedRounded;
        self.up_button.enabled    = NO;
        self.up_button.toolTip    = @"Go Up";
        item.view    = self.up_button;
        item.label   = @"Up";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarSearch]) {
        self.search_field = [[NSSearchField alloc]
            initWithFrame:NSMakeRect(0, 0, 117, 22)];
        self.search_field.target              = self;
        self.search_field.action              = @selector(search_changed:);
        self.search_field.placeholderString   = @"Search";
        item.view    = self.search_field;
        item.label   = @"Search";
        item.minSize = NSMakeSize(65, 26);
        item.maxSize = NSMakeSize(169, 26);

    } else if ([identifier isEqualToString:kToolbarReload]) {
        NSButton *reload_btn = [NSButton buttonWithTitle:@"↻"
                                                  target:self
                                                  action:@selector(reload_clicked:)];
        if (@available(macOS 11.0, *)) {
            reload_btn.image =
                [NSImage imageWithSystemSymbolName:@"arrow.clockwise"
                          accessibilityDescription:@"Reload"];
        }
        reload_btn.bezelStyle = NSBezelStyleTexturedRounded;
        reload_btn.toolTip    = @"Reload";
        item.view    = reload_btn;
        item.label   = @"Reload";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarHiddenFiles]) {
        BOOL showing = [NSUserDefaults.standardUserDefaults
                            boolForKey:@"files.show_hidden_files"];
        NSButton *eye_btn = [NSButton buttonWithTitle:@"👁"
                                               target:nil
                                               action:@selector(toggle_hidden_files_action:)];
        if (@available(macOS 11.0, *)) {
            NSString *sym = showing ? @"eye" : @"eye.slash";
            eye_btn.image = [NSImage imageWithSystemSymbolName:sym
                                        accessibilityDescription:@"Show Hidden Files"];
        }
        [eye_btn setButtonType:NSButtonTypePushOnPushOff];
        eye_btn.bezelStyle = NSBezelStyleTexturedRounded;
        eye_btn.state      = showing ? NSControlStateValueOn : NSControlStateValueOff;
        eye_btn.toolTip    = @"Show Hidden Files";
        item.view    = eye_btn;
        item.label   = @"Hidden";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarOpenTerminal]) {
        NSButton *term_btn = [NSButton buttonWithTitle:@">_"
                                                target:self
                                                action:@selector(open_terminal_clicked:)];
        if (@available(macOS 12.0, *)) {
            NSImage *img = [NSImage imageWithSystemSymbolName:@"terminal"
                                      accessibilityDescription:@"Open in Terminal"];
            if (img) term_btn.image = img;
        }
        term_btn.bezelStyle = NSBezelStyleTexturedRounded;
        term_btn.toolTip    = @"Open in Terminal";
        item.view    = term_btn;
        item.label   = @"Terminal";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarDualPane]) {
        self.dual_pane_btn = [NSButton buttonWithTitle:@"[][]"
                                                target:self
                                                action:@selector(toggle_dual_pane:)];
        if (@available(macOS 11.0, *)) {
            self.dual_pane_btn.image =
                [NSImage imageWithSystemSymbolName:@"rectangle.split.2x1"
                          accessibilityDescription:@"Dual Pane"];
        }
        [self.dual_pane_btn setButtonType:NSButtonTypePushOnPushOff];
        self.dual_pane_btn.bezelStyle = NSBezelStyleTexturedRounded;
        self.dual_pane_btn.state      = self.secondary_pane
            ? NSControlStateValueOn : NSControlStateValueOff;
        self.dual_pane_btn.toolTip    = @"Dual Pane";
        item.view    = self.dual_pane_btn;
        item.label   = @"Dual Pane";
        item.minSize = item.maxSize = NSMakeSize(36, 26);

    } else if ([identifier isEqualToString:kToolbarSidebar]) {
        NSButton *sidebar_btn = [NSButton buttonWithTitle:@"▣"
                                                   target:self
                                                   action:@selector(toggle_sidebar_action:)];
        if (@available(macOS 11.0, *)) {
            sidebar_btn.image = [NSImage imageWithSystemSymbolName:@"sidebar.right"
                                          accessibilityDescription:@"Toggle Info Sidebar"];
        }
        [sidebar_btn setButtonType:NSButtonTypePushOnPushOff];
        sidebar_btn.bezelStyle = NSBezelStyleTexturedRounded;
        sidebar_btn.toolTip    = @"Toggle Info Sidebar";
        item.view    = sidebar_btn;
        item.label   = @"Sidebar";
        item.minSize = item.maxSize = NSMakeSize(36, 26);
    }

    return item;
}

/* ── Toolbar actions ─────────────────────────────────────────────────────── */

/*
 * back_clicked: — navigates the active pane back.
 *
 * Inputs:
 *   sender — back toolbar button
 */
- (void)
back_clicked:(id)sender
{
    [[self active_browser] go_back];
    self.back_button.enabled     = [[self active_browser] can_go_back];
    self.forward_button.enabled  = [[self active_browser] can_go_forward];
    self.address_bar.stringValue = [self active_browser].current_url.path ?: @"";
}

/*
 * forward_clicked: — navigates the active pane forward.
 *
 * Inputs:
 *   sender — forward toolbar button
 */
- (void)
forward_clicked:(id)sender
{
    [[self active_browser] go_forward];
    self.back_button.enabled     = [[self active_browser] can_go_back];
    self.forward_button.enabled  = [[self active_browser] can_go_forward];
    self.address_bar.stringValue = [self active_browser].current_url.path ?: @"";
}

/*
 * address_bar_action: — navigates to the path the user typed and pressed Enter.
 * Expands ~ and resolves relative paths against the current directory.
 * Reverts the field to the current path on failure.
 *
 * Inputs:
 *   sender — address bar NSTextField
 */
- (void)
address_bar_action:(NSTextField *)sender
{
    NSString *raw  = [sender.stringValue stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *path = raw.stringByExpandingTildeInPath;
    BOOL is_dir    = NO;

    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&is_dir]) {
        /* Path does not exist — revert and shake the field. */
        sender.stringValue = [self active_browser].current_url.path ?: @"";
        [sender.window makeFirstResponder:nil];
        return;
    }
    if (!is_dir) {
        /* It's a file — navigate to its parent directory. */
        path = path.stringByDeletingLastPathComponent;
    }
    [[self active_pane] navigate_to:[NSURL fileURLWithPath:path]];
    [sender.window makeFirstResponder:nil];
}

/*
 * go_up_clicked: — navigates the active pane to the parent directory.
 *
 * Inputs:
 *   sender — up toolbar button
 */
- (IBAction)
go_up_clicked:(id)sender
{
    NSURL *cur = [self active_pane].current_url;
    if (!cur) return;
    NSURL *parent = cur.URLByDeletingLastPathComponent;
    if (!parent || [parent.path isEqualToString:cur.path]) return;
    [[self active_pane] navigate_to:parent];
}

/*
 * reload_clicked: — reloads the active browser pane's directory listing.
 *
 * Inputs:
 *   sender — reload toolbar button
 */
- (IBAction)
reload_clicked:(id)sender
{
    [[self active_browser] reload_directory];
}

/*
 * add_bookmark_action: — adds the active pane's current directory to the
 * bookmarks bar.
 *
 * Inputs:
 *   sender — menu item or toolbar button
 */
- (IBAction)
add_bookmark_action:(id)sender
{
    NSURL *cur = [self active_pane].current_url;
    if (cur) {
        [self.bookmarks_bar add_bookmark:cur];
    }
}

/*
 * search_changed: — delegates to Spotlight search in the active browser.
 *
 * Inputs:
 *   sender — NSSearchField
 */
- (void)
search_changed:(NSSearchField *)sender
{
    [[self active_browser] set_search_filter:sender.stringValue];
}

/* ── First-responder observation (dual-pane active tracking) ─────────────── */

/*
 * observeValueForKeyPath:ofObject:change:context: — detects which pane a click
 * lands in by watching window.firstResponder; updates active_pane_index so every
 * toolbar action operates on the pane the user last touched.
 */
- (void)
observeValueForKeyPath:(NSString *)keyPath
              ofObject:(id)object
                change:(NSDictionary *)change
               context:(void *)context
{
    if (![keyPath isEqualToString:@"firstResponder"] || !self.secondary_pane) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    NSResponder *r = self.window.firstResponder;
    NSView *v = [r isKindOfClass:NSView.class] ? (NSView *)r : nil;
    while (v) {
        if (v == (NSView *)self.primary_pane) {
            if (self.active_pane_index != 0) {
                self.active_pane_index        = 0;
                self.primary_pane.is_active   = YES;
                self.secondary_pane.is_active = NO;
                [self update_toolbar_for_url:self.primary_pane.current_url];
            }
            return;
        }
        if (v == (NSView *)self.secondary_pane) {
            if (self.active_pane_index != 1) {
                self.active_pane_index        = 1;
                self.primary_pane.is_active   = NO;
                self.secondary_pane.is_active = YES;
                [self update_toolbar_for_url:self.secondary_pane.current_url];
            }
            return;
        }
        v = v.superview;
    }
}

/* ── Info sidebar ────────────────────────────────────────────────────────── */

/*
 * toggle_sidebar_action: — shows or hides the info sidebar by collapsing or
 * expanding the NSSplitView's right subview.
 *
 * Inputs:
 *   sender — sidebar toolbar button (unused beyond triggering)
 */
- (IBAction)
toggle_sidebar_action:(id)sender
{
    if (self.info_sidebar.hidden) {
        /* Expand: set frames directly so the sidebar springs back to its last width. */
        CGFloat sv_w = self.content_split.bounds.size.width;
        CGFloat sv_h = self.content_split.bounds.size.height;
        CGFloat div  = self.content_split.dividerThickness;
        CGFloat sidebar_w = MIN(MAX(kSidebarW, 140.0), sv_w - div - 400.0);
        CGFloat browser_w = sv_w - div - sidebar_w;
        self.info_sidebar.hidden = NO;
        self.browser_container.frame = NSMakeRect(0, 0, browser_w, sv_h);
        self.info_sidebar.frame      = NSMakeRect(browser_w + div, 0, sidebar_w, sv_h);
        [self.content_split setNeedsDisplay:YES];
        [self refresh_sidebar_for_active_pane];
    } else {
        /* Collapse: keep divider alive during setPosition: so it is not a no-op. */
        _collapsing_sidebar = YES;
        [self.content_split setPosition:self.content_split.bounds.size.width
                       ofDividerAtIndex:0];
        self.info_sidebar.hidden = YES;
        _collapsing_sidebar = NO;
    }
}

/* ── NSSplitViewDelegate ─────────────────────────────────────────────────── */

/*
 * splitView:canCollapseSubview: — allows the sidebar to collapse to zero
 * width when hidden; the browser pane may not collapse.
 */
- (BOOL)
splitView:(NSSplitView *)sv canCollapseSubview:(NSView *)subview
{
    (void)sv;
    return subview == self.info_sidebar;
}

/*
 * splitView:shouldHideDividerAtIndex: — hides the 1pt divider line when the
 * sidebar is collapsed so no ghost line remains in the file list.
 */
- (BOOL)
splitView:(NSSplitView *)sv shouldHideDividerAtIndex:(NSInteger)idx
{
    (void)sv; (void)idx;
    /* Keep the divider "live" during the collapse setPosition: call so that
     * NSSplitView does not treat it as a no-op. */
    return self.info_sidebar.hidden && !_collapsing_sidebar;
}

/*
 * splitView:shouldAdjustSizeOfSubview: — only the browser pane grows with
 * the window; the sidebar stays at its current dragged width.
 */
- (BOOL)
splitView:(NSSplitView *)sv shouldAdjustSizeOfSubview:(NSView *)subview
{
    (void)sv;
    /* Sidebar resizes during collapse (so setPosition can move it to 0) and
     * when already hidden (so window resize keeps it at 0). When visible and
     * not in mid-collapse, it holds its dragged width. */
    if (subview == self.info_sidebar)
        return _collapsing_sidebar || self.info_sidebar.hidden;
    return YES;
}

/*
 * splitView:constrainMinCoordinate:ofSubviewAt: — keeps the browser at least
 * 400pt wide so the divider cannot be dragged too far right.
 */
- (CGFloat)
splitView:(NSSplitView *)sv
constrainMinCoordinate:(CGFloat)proposed
     ofSubviewAt:(NSInteger)idx
{
    (void)sv; (void)idx;
    return MAX(proposed, 400.0);
}

/*
 * splitView:constrainMaxCoordinate:ofSubviewAt: — keeps the sidebar at least
 * 140pt wide so the divider cannot be dragged too far left.
 */
- (CGFloat)
splitView:(NSSplitView *)sv
constrainMaxCoordinate:(CGFloat)proposed
      ofSubviewAt:(NSInteger)idx
{
    (void)idx;
    /* During collapse, allow the divider to reach the far right edge. */
    if (_collapsing_sidebar || self.info_sidebar.hidden) return proposed;
    return MIN(proposed, sv.bounds.size.width - 140.0);
}

/*
 * refresh_sidebar_for_active_pane — pushes the active pane's current
 * selection (or the directory itself when nothing is selected) to the sidebar.
 */
- (void)
refresh_sidebar_for_active_pane
{
    if (self.info_sidebar.hidden) return;
    NSArray<NSURL *> *sel = [self active_pane].selected_urls;
    if (sel.count == 0) {
        NSURL *cur = [self active_pane].current_url;
        if (cur) [self.info_sidebar show_url:cur];
        else     [self.info_sidebar clear];
    } else if (sel.count == 1) {
        [self.info_sidebar show_url:sel.firstObject];
    } else {
        [self.info_sidebar show_urls:sel];
    }
}

/*
 * wire_status_for_pane: — attaches status_text_handler and trash_visible_handler
 * on the given pane's browser so they route to the full-width status bar.
 *
 * Inputs:
 *   pane — pane to wire
 */
- (void)
wire_status_for_pane:(FilesBrowserPane *)pane
{
    __weak FilesMainWindow *ws = self;
    pane.browser.status_text_handler = ^(NSString *text) {
        FilesMainWindow *s = ws;
        if (s) s.status_label.stringValue = text ?: @"";
    };
    pane.browser.trash_visible_handler = ^(BOOL show) {
        FilesMainWindow *s = ws;
        if (s) s.status_trash_btn.hidden = !show;
    };
}

/*
 * empty_trash_action: — forwards to the active browser's empty_trash_action:.
 *
 * Inputs:
 *   sender — toolbar button or menu item
 */
- (IBAction)
empty_trash_action:(id)sender
{
    [[self active_browser] empty_trash_action:sender];
    /* Delay slightly so the filesystem change completes before we re-check. */
    __weak FilesMainWindow *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ws.bookmarks_bar update_trash_icon];
    });
}

/*
 * wire_sidebar_for_pane: — attaches a sidebar_handler to the given pane's
 * browser so that selection changes update the sidebar.
 *
 * Inputs:
 *   pane — pane to wire
 */
- (void)
wire_sidebar_for_pane:(FilesBrowserPane *)pane
{
    __weak FilesMainWindow  *ws = self;
    __weak FilesBrowserPane *wp = pane;
    pane.browser.sidebar_handler = ^(NSArray<NSURL *> *urls) {
        FilesMainWindow  *s = ws;
        FilesBrowserPane *p = wp;
        if (!s || !p || s.info_sidebar.hidden) return;
        /* Only the active pane drives the sidebar. */
        if ([s active_pane] != p) return;
        if (urls.count == 0) {
            NSURL *cur = p.current_url;
            if (cur) [s.info_sidebar show_url:cur];
            else     [s.info_sidebar clear];
        } else if (urls.count == 1) {
            [s.info_sidebar show_url:urls.firstObject];
        } else {
            [s.info_sidebar show_urls:urls];
        }
    };
}

/* ── View menu actions ───────────────────────────────────────────────────── */

/*
 * auto_fit_columns_action: — toggles persistent column auto-fit.
 * Lives here rather than in FilesBrowserView so it is always reachable in the
 * responder chain regardless of which control has keyboard focus.
 *
 * Inputs:
 *   sender — View menu item (unused beyond triggering)
 */
- (IBAction)
auto_fit_columns_action:(id)sender
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL now_on = ![ud boolForKey:@"files.auto_fit_columns"];
    [ud setBool:now_on forKey:@"files.auto_fit_columns"];
    if (now_on) {
        [[self active_browser] apply_auto_fit];
    }
}

/*
 * validateMenuItem: — sets the Auto-Fit Columns checkmark.
 *
 * Inputs:
 *   item — the menu item being validated
 *
 * Output: YES (always enabled).
 */
- (BOOL)
validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(auto_fit_columns_action:)) {
        item.state = [NSUserDefaults.standardUserDefaults boolForKey:@"files.auto_fit_columns"]
            ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (item.action == @selector(toggle_dual_pane:)) {
        item.state = self.secondary_pane
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return YES;
}

- (void)
dealloc
{
    if (self.observing_responder) {
        [self.window removeObserver:self forKeyPath:@"firstResponder"];
    }
}

@end
