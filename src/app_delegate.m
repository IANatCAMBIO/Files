#import "app_delegate.h"
#import "main_window.h"
#import "browser_pane.h"
#import "volume_manager.h"
#import "mounts_panel.h"
#import "util.h"

@interface FilesAppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSMutableArray<FilesMainWindow *> *windows;  /* open browser windows */
@end

@implementation FilesAppDelegate

/*
 * applicationDidFinishLaunching: — creates the menu bar and main window.
 *
 * Inputs:
 *   n — NSApplicationDidFinishLaunchingNotification (unused)
 */
- (void)
applicationDidFinishLaunching:(NSNotification *)n
{
    [self build_menu_bar];
    self.windows = [NSMutableArray array];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(window_will_close:)
                                               name:NSWindowWillCloseNotification
                                             object:nil];
    [self open_window_at:files_home_url()];
    [NSApp activate];
}

/* ── Windows ─────────────────────────────────────────────────────────────── */

/*
 * open_window_at: — opens a new browser window showing url, cascaded down
 * and right from the frontmost browser window (the first window uses the
 * saved frame). Used at launch, by File ▸ New Window, and when a window
 * asks for one (a newly mounted disk image).
 *
 * Inputs:
 *   url — folder to show
 */
- (void)
open_window_at:(NSURL *)url
{
    FilesMainWindow *front = [self front_window];
    FilesMainWindow *w     = [[FilesMainWindow alloc] init_with_url:url];
    if (front) {
        NSRect f = front.window.frame;
        [w.window setFrameTopLeftPoint:NSMakePoint(NSMinX(f) + 24.0, NSMaxY(f) - 24.0)];
    }
    __weak FilesAppDelegate *ws = self;
    w.new_window_handler = ^(NSURL *u) { [ws open_window_at:u]; };
    [self.windows addObject:w];
    [w showWindow:nil];
}

/*
 * new_window_action: — File ▸ New Window (⌘N): opens a browser window on the
 * home folder, like Finder's default new window.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
new_window_action:(id)sender
{
    [self open_window_at:files_home_url()];
}

/*
 * front_window — the browser window menu commands should act on: the main
 * window if it is a browser window, otherwise the most recently opened one.
 *
 * Output: FilesMainWindow, or nil if none is open.
 */
- (FilesMainWindow *)
front_window
{
    id wc = NSApp.mainWindow.windowController;
    return [self.windows containsObject:wc] ? wc : self.windows.lastObject;
}

/*
 * window_will_close: — releases a browser window's controller when its
 * window closes (other windows, e.g. panels, are ignored).
 *
 * Inputs:
 *   note — NSWindowWillCloseNotification; object is the closing window
 */
- (void)
window_will_close:(NSNotification *)note
{
    id wc = ((NSWindow *)note.object).windowController;
    if ([self.windows containsObject:wc]) [self.windows removeObject:wc];
}

/*
 * applicationShouldTerminateAfterLastWindowClosed: — returns YES so the app
 * quits when its only window is closed.
 *
 * Inputs:
 *   app — NSApplication (unused)
 *
 * Output: YES
 */
- (BOOL)
applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

/* ── Menu bar ────────────────────────────────────────────────────────────── */

/*
 * make_item:action:key:mod: — convenience factory for NSMenuItems.
 *
 * Inputs:
 *   title  — menu item title
 *   action — selector to send (targets first responder)
 *   key    — key equivalent character
 *   mod    — extra modifier flags; 0 for Cmd-only
 *
 * Output: configured NSMenuItem.
 */
static NSMenuItem *
make_item(NSString *title, SEL action, NSString *key, NSEventModifierFlags mod)
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:key];
    item.keyEquivalentModifierMask = NSEventModifierFlagCommand | mod;
    return item;
}

/*
 * make_pref_item — a View-menu checkbox item bound to a BOOL preference:
 * checked to match the current value, toggled by toggle_pref:.
 *
 * Inputs:
 *   title  — menu item title
 *   key    — NSUserDefaults key (a files_pref_* constant from util.h)
 *   target — object implementing toggle_pref:
 *
 * Output: configured NSMenuItem.
 */
static NSMenuItem *
make_pref_item(NSString *title, NSString *key, id target)
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(toggle_pref:)
                                           keyEquivalent:@""];
    item.target            = target;
    item.representedObject = key;
    item.state = [NSUserDefaults.standardUserDefaults boolForKey:key]
                 ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

/*
 * toggle_pref: — flips the BOOL preference named by the menu item's
 * representedObject and updates its checkmark. Code that depends on a
 * preference reads it when needed (copies) or observes it (Large Rows).
 *
 * Inputs:
 *   sender — menu item made by make_pref_item
 */
- (void)
toggle_pref:(NSMenuItem *)sender
{
    NSString *key = sender.representedObject;
    BOOL next = ![NSUserDefaults.standardUserDefaults boolForKey:key];
    [NSUserDefaults.standardUserDefaults setBool:next forKey:key];
    sender.state = next ? NSControlStateValueOn : NSControlStateValueOff;
}

/* ── Devices menu ────────────────────────────────────────────────────────── */

/*
 * menuNeedsUpdate: — NSMenuDelegate; repopulates the Devices menu from the
 * mounted volumes each time it opens, so it never needs mount observers.
 * Each volume item navigates the front window's active pane; a separator
 * and "All Mounts…" follow.
 *
 * Inputs:
 *   menu — the Devices menu
 */
- (void)
menuNeedsUpdate:(NSMenu *)menu
{
    [menu removeAllItems];

    FilesVolumeManager *vm = FilesVolumeManager.shared;
    for (NSURL *vol in vm.mounted_volumes) {
        NSString *name  = [vm display_name_for_volume:vol];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name
                                                      action:@selector(device_menu_item_clicked:)
                                               keyEquivalent:@""];
        item.target           = self;
        item.representedObject = vol;

        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:vol.path];
        icon.size     = NSMakeSize(16, 16);
        item.image    = icon;

        [menu addItem:item];
    }

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *all = [[NSMenuItem alloc] initWithTitle:@"All Mounts…"
                                                 action:@selector(show_all_mounts:)
                                          keyEquivalent:@""];
    all.target = self;
    [menu addItem:all];
}

/*
 * device_menu_item_clicked: — navigates the front window's active pane to the
 * volume URL stored in the menu item's representedObject.
 *
 * Inputs:
 *   sender — NSMenuItem with representedObject = volume NSURL
 */
- (void)
device_menu_item_clicked:(NSMenuItem *)sender
{
    NSURL *vol = sender.representedObject;
    if (!vol) return;
    [[[self front_window] active_pane].browser navigate_to:vol];
}

/*
 * show_all_mounts: — opens the All Mounts utility panel.
 *
 * Inputs:
 *   sender — "All Mounts…" menu item
 */
- (void)
show_all_mounts:(id)sender
{
    [FilesMountsPanel.shared show_panel];
}

/*
 * build_menu_bar — constructs the application's entire menu bar programmatically.
 */
- (void)
build_menu_bar
{
    NSMenu *bar = [[NSMenu alloc] init];

    /* ── App menu ── */
    NSMenuItem *app_mi = [[NSMenuItem alloc] init];
    NSMenu *app_menu   = [[NSMenu alloc] initWithTitle:@"Files"];
    [app_menu addItemWithTitle:@"About Files"
                        action:@selector(orderFrontStandardAboutPanel:)
                 keyEquivalent:@""];
    [app_menu addItem:NSMenuItem.separatorItem];
    [app_menu addItem:make_item(@"Quit Files", @selector(terminate:), @"q", 0)];
    app_mi.submenu = app_menu;
    [bar addItem:app_mi];

    /* ── File menu ── */
    NSMenuItem *file_mi = [[NSMenuItem alloc] init];
    NSMenu *file_menu   = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *new_window = make_item(@"New Window", @selector(new_window_action:), @"n", 0);
    new_window.target = self;
    [file_menu addItem:new_window];
    [file_menu addItem:make_item(@"New Folder",
                                 @selector(new_folder_action:),
                                 @"n", NSEventModifierFlagShift)];
    [file_menu addItem:make_item(@"New File",
                                 @selector(new_file_action:),
                                 @"n", NSEventModifierFlagOption)];
    [file_menu addItem:make_item(@"Get Info",
                                 @selector(get_info_action:),
                                 @"i", 0)];
    [file_menu addItem:make_item(@"Add to Bookmarks",
                                 @selector(add_bookmark_action:),
                                 @"d", 0)];
    [file_menu addItem:make_item(@"Open in Terminal",
                                 @selector(open_terminal_action:),
                                 @"t", NSEventModifierFlagShift)];
    [file_menu addItem:NSMenuItem.separatorItem];
    [file_menu addItem:make_item(@"Close Window",
                                 @selector(performClose:),
                                 @"w", 0)];
    file_mi.submenu = file_menu;
    [bar addItem:file_mi];

    /* ── Edit menu ── */
    NSMenuItem *edit_mi = [[NSMenuItem alloc] init];
    NSMenu *edit_menu   = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit_menu addItem:make_item(@"Undo",       @selector(undo:),   @"z", 0)];
    [edit_menu addItem:make_item(@"Redo",       @selector(redo:),   @"z",
                                 NSEventModifierFlagShift)];
    [edit_menu addItem:NSMenuItem.separatorItem];
    [edit_menu addItem:make_item(@"Cut",        @selector(cut:),    @"x", 0)];
    [edit_menu addItem:make_item(@"Copy",       @selector(copy:),   @"c", 0)];
    [edit_menu addItem:make_item(@"Paste",      @selector(paste:),  @"v", 0)];
    [edit_menu addItem:make_item(@"Select All", @selector(selectAll:), @"a", 0)];
    [edit_menu addItem:NSMenuItem.separatorItem];
    [edit_menu addItem:make_item(@"Move to Trash",
                                 @selector(move_to_trash_action:), @"\x08", 0)];
    edit_mi.submenu = edit_menu;
    [bar addItem:edit_mi];

    /* ── View menu ── */
    NSMenuItem *view_mi = [[NSMenuItem alloc] init];
    NSMenu *view_menu   = [[NSMenu alloc] initWithTitle:@"View"];
    [view_menu addItemWithTitle:@"Show Toolbar"
                         action:@selector(toggleToolbarShown:)
                  keyEquivalent:@""];
    [view_menu addItem:NSMenuItem.separatorItem];
    [view_menu addItem:make_item(@"Dual Pane",
                                 @selector(toggle_dual_pane:),
                                 @"2", NSEventModifierFlagShift)];
    [view_menu addItem:make_item(@"Auto-Fit Columns",
                                 @selector(auto_fit_columns_action:),
                                 @"", 0)];
    [view_menu addItem:make_pref_item(@"Large Rows", files_pref_large_rows, self)];
    [view_menu addItem:NSMenuItem.separatorItem];
    [view_menu addItem:make_pref_item(@"Simple Copies", files_pref_simple_copies, self)];
    [view_menu addItem:make_pref_item(@"Validate Copies with SHA-256",
                                      files_pref_hash_validation, self)];
    view_mi.submenu = view_menu;
    [bar addItem:view_mi];

    /* ── Go menu ── */
    NSMenuItem *go_mi = [[NSMenuItem alloc] init];
    NSMenu *go_menu   = [[NSMenu alloc] initWithTitle:@"Go"];
    [go_menu addItem:make_item(@"Back",
                               @selector(go_back_action:),      @"[", 0)];
    [go_menu addItem:make_item(@"Forward",
                               @selector(go_forward_action:),   @"]", 0)];
    [go_menu addItem:NSMenuItem.separatorItem];
    [go_menu addItem:make_item(@"Home",
                               @selector(go_home_action:),      @"h", NSEventModifierFlagShift)];
    [go_menu addItem:make_item(@"Desktop",
                               @selector(go_desktop_action:),   @"d", NSEventModifierFlagShift)];
    [go_menu addItem:make_item(@"Downloads",
                               @selector(go_downloads_action:), @"l", NSEventModifierFlagShift)];
    [go_menu addItem:make_item(@"Documents",
                               @selector(go_documents_action:), @"o", NSEventModifierFlagShift)];
    go_mi.submenu = go_menu;
    [bar addItem:go_mi];

    /* ── Devices menu ── */
    NSMenuItem *dev_mi = [[NSMenuItem alloc] init];
    NSMenu *devices_menu  = [[NSMenu alloc] initWithTitle:@"Devices"];
    devices_menu.delegate = self;  /* rebuilt on open: menuNeedsUpdate: */
    dev_mi.submenu        = devices_menu;
    [bar addItem:dev_mi];

    NSApp.mainMenu = bar;
}

@end
