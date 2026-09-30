#import "app_delegate.h"
#import "main_window.h"
#import "browser_pane.h"
#import "volume_manager.h"
#import "mounts_panel.h"
#import "default_viewer.h"
#import "util.h"

@interface FilesAppDelegate () <NSMenuDelegate, NSMenuItemValidation>
@property (nonatomic, strong) NSMutableArray<FilesMainWindow *> *windows;  /* open browser windows */
@property (nonatomic, strong) NSNumber *archive_reveal_attempted;  /* value tried this session */
@end

/* Archive Utility's preferences domain and the "reveal in Finder after
 * archiving / expanding" keys View ▸ Show Finder After Archive Operations
 * controls. */
static NSString * const archive_utility_domain = @"com.apple.archiveutility";

@implementation FilesAppDelegate

/*
 * applicationWillFinishLaunching: — registers preference defaults and
 * prepares window tracking. Runs before application:openURLs:, which a
 * launch to reveal files delivers ahead of applicationDidFinishLaunching:.
 *
 * Inputs:
 *   n — NSApplicationWillFinishLaunchingNotification (unused)
 */
- (void)
applicationWillFinishLaunching:(NSNotification *)n
{
    files_register_defaults();
    self.windows = [NSMutableArray array];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(window_will_close:)
                                               name:NSWindowWillCloseNotification
                                             object:nil];
}

/*
 * applicationDidFinishLaunching: — creates the menu bar and, unless the
 * launch already opened one (to reveal files), a home-folder window; then
 * checks Full Disk Access and brings the settings Files manages in other
 * apps (Archive Utility, Finder / default file viewer) in line with its
 * preferences.
 *
 * Inputs:
 *   n — NSApplicationDidFinishLaunchingNotification (unused)
 */
- (void)
applicationDidFinishLaunching:(NSNotification *)n
{
    [self build_menu_bar];
    if (self.windows.count == 0) [self open_window_at:files_home_url()];
    [NSApp activate];

    if (!files_has_full_disk_access()) {
        [self prompt_full_disk_access:
            @"Files is a file manager and needs Full Disk Access to show and manage "
             "all of your files (for example the Trash, Mail and Messages data, and "
             "other apps' containers)."];
    }

    /* Keep Archive Utility in step with files_pref_archive_reveal, now and
     * whenever it changes (View ▸ Show Finder After Archive Operations). */
    [self sync_archive_utility_reporting:NO];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sync_archive_utility)
                                               name:NSUserDefaultsDidChangeNotification
                                             object:nil];

    /* First launch takes over from Finder (files_pref_default_viewer is on
     * by default); later launches re-check and repair those settings, or,
     * after File ▸ Restore Finder…, make sure they stay restored. */
    files_default_viewer_sync(nil);
}

/*
 * sync_archive_utility — NSUserDefaultsDidChangeNotification handler: applies
 * files_pref_archive_reveal to Archive Utility, reporting failure (the
 * preference just changed, most likely from the View menu).
 */
- (void)
sync_archive_utility
{
    [self sync_archive_utility_reporting:YES];
}

/*
 * sync_archive_utility_reporting: — makes Archive Utility's
 * dearchive-reveal-after and archive-reveal-after equal
 * files_pref_archive_reveal (off by default), so the View menu item always
 * describes what Archive Utility will actually do. Runs at every launch —
 * including the first, which applies the default — and whenever the
 * preference changes. files_sync_bool_prefs reads Archive Utility's real
 * values and writes only what differs (missing keys included), on a serial
 * background queue; nothing is cached, so values changed or reset
 * elsewhere are corrected at the next launch. This needs Full Disk Access
 * (Archive Utility is sandboxed), which the launch check prompts for.
 *
 * Each value is attempted at most once per session, so the frequent
 * defaults notifications never re-run (or re-alert) it.
 *
 * Inputs:
 *   report — YES to prompt for Full Disk Access if it fails (the user
 *            toggled the option); NO at launch, where the Full Disk Access
 *            check has already prompted
 */
- (void)
sync_archive_utility_reporting:(BOOL)report
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("files.archive_utility", DISPATCH_QUEUE_SERIAL);
    });

    BOOL want = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_archive_reveal];
    if (self.archive_reveal_attempted && self.archive_reveal_attempted.boolValue == want) return;
    self.archive_reveal_attempted = @(want);

    dispatch_async(queue, ^{
        BOOL ok = files_sync_prefs(archive_utility_domain,
                                   @{ @"dearchive-reveal-after": @[@(want)],
                                      @"archive-reveal-after":   @[@(want)] },
                                   nil);
        if (ok || !report) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self prompt_full_disk_access:
                @"Files could not change Archive Utility's setting. Changing another "
                 "app's settings requires Full Disk Access."];
        });
    });
}

/*
 * prompt_full_disk_access: — explains why Full Disk Access is needed and how
 * to grant it, as a sheet on the front window. "Open System Settings" opens
 * Privacy & Security ▸ Full Disk Access directly.
 *
 * Inputs:
 *   reason — first paragraph: why access is needed right now
 */
- (void)
prompt_full_disk_access:(NSString *)reason
{
    NSString *app_path = NSBundle.mainBundle.bundlePath;
    NSAlert *alert     = [[NSAlert alloc] init];
    alert.messageText  = @"Files needs Full Disk Access";
    alert.informativeText = [NSString stringWithFormat:
        @"%@\n\nTo grant it:\n"
         "1. Click Open System Settings (Privacy & Security ▸ Full Disk Access).\n"
         "2. Turn on Files, or click + and add:\n    %@\n"
         "3. When asked, choose Quit & Reopen.", reason, app_path];
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Not Now"];
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
    };
    NSWindow *win = [self front_window].window;
    if (win) {
        [alert beginSheetModalForWindow:win completionHandler:handle];
    } else {
        handle([alert runModal]);
    }
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
 *
 * Output: the new window's controller.
 */
- (FilesMainWindow *)
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
    return w;
}

/*
 * window_for_folder: — the browser window to show folder in: one whose
 * active pane already shows it, else a new window on it.
 *
 * Inputs:
 *   folder — folder URL
 *
 * Output: window controller, brought to the front.
 */
- (FilesMainWindow *)
window_for_folder:(NSURL *)folder
{
    for (FilesMainWindow *w in self.windows) {
        if (files_same_path([w active_pane].browser.current_url, folder)) {
            [w showWindow:nil];
            return w;
        }
    }
    return [self open_window_at:folder];
}

/*
 * application:openURLs: — handles "open documents" requests from other
 * apps. As the default file viewer (NSFileViewer) Files receives "Show in
 * Finder" / "Reveal in Finder" this way, with the items themselves as the
 * URLs; `open -a files <path>` arrives the same way. A reveal of a folder
 * is indistinguishable from an open, so folders are shown (their contents);
 * files and packages (apps, bundles) are selected in their parent folder,
 * one window per parent.
 *
 * Inputs:
 *   app  — NSApplication (unused)
 *   urls — file URLs to show
 */
- (void)
application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls
{
    NSMutableDictionary<NSURL *, NSMutableArray<NSString *> *> *reveal =
        [NSMutableDictionary dictionary];
    for (NSURL *url in urls) {
        if (!url.isFileURL) continue;
        NSNumber *is_dir = nil, *is_pkg = nil;
        NSURL *target = url.URLByResolvingSymlinksInPath;
        [target getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        [target getResourceValue:&is_pkg forKey:NSURLIsPackageKey error:nil];
        if (is_dir.boolValue && !is_pkg.boolValue) {
            [self window_for_folder:target];
            continue;
        }
        NSURL *parent = url.URLByDeletingLastPathComponent.URLByStandardizingPath;
        if (!reveal[parent]) reveal[parent] = [NSMutableArray array];
        [reveal[parent] addObject:url.lastPathComponent];
    }
    for (NSURL *parent in reveal) {
        [[[self window_for_folder:parent] active_pane].browser reveal_items:reveal[parent]];
    }
    [NSApp activate];
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
 * make_pref_item — a View-menu checkbox item bound to a BOOL preference,
 * toggled by toggle_pref:; validateMenuItem: sets its checkmark each time
 * the menu opens, so changes made elsewhere show too.
 *
 * Inputs:
 *   title  — menu item title
 *   key    — NSUserDefaults key (a files_pref_* constant from util.h)
 *   target — object implementing toggle_pref: and validateMenuItem:
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
    return item;
}

/*
 * toggle_pref: — flips the BOOL preference named by the menu item's
 * representedObject. Code that depends on a preference reads it when
 * needed (copies) or observes it (Large Rows).
 *
 * Inputs:
 *   sender — menu item made by make_pref_item
 */
- (void)
toggle_pref:(NSMenuItem *)sender
{
    NSString *key = sender.representedObject;
    [NSUserDefaults.standardUserDefaults setBool:![NSUserDefaults.standardUserDefaults boolForKey:key]
                                          forKey:key];
}

/*
 * validateMenuItem: — NSMenuItemValidation for the delegate's own items:
 * checkmarks of preference items, and the default-viewer item's title,
 * which names what choosing it will do.
 *
 * Inputs:
 *   item — menu item about to be shown
 *
 * Output: YES (every item the delegate handles is always available).
 */
- (BOOL)
validateMenuItem:(NSMenuItem *)item
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (item.action == @selector(toggle_pref:)) {
        item.state = [defaults boolForKey:item.representedObject]
                     ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (item.action == @selector(default_viewer_action:)) {
        item.title = [defaults boolForKey:files_pref_default_viewer]
                     ? @"Restore Finder as Default File Viewer…"
                     : @"Make Files the Default File Viewer";
    }
    return YES;
}

/*
 * default_viewer_action: — File ▸ Restore Finder as Default File Viewer…
 * (while Files is the default) or Make Files the Default File Viewer.
 * Restoring asks for confirmation, then turns files_pref_default_viewer
 * off, which writes back every setting Files replaced, and turns View ▸
 * Show Finder After Archive Operations on (Archive Utility's own
 * default). Making Files the default reverses both. The outcome is
 * reported in an alert: after a restore, Files can be uninstalled.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
default_viewer_action:(id)sender
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL restore = [defaults boolForKey:files_pref_default_viewer];
    NSWindow *win = [self front_window].window;

    void (^apply)(void) = ^{
        [defaults setBool:!restore forKey:files_pref_default_viewer];
        [defaults setBool:restore forKey:files_pref_archive_reveal];
        files_default_viewer_sync(^(BOOL ok) {
            NSAlert *done = [[NSAlert alloc] init];
            if (!ok) {
                done.messageText     = restore ? @"Some settings could not be restored"
                                               : @"Some settings could not be changed";
                done.informativeText = @"Files will try again the next time it opens.";
            } else if (restore) {
                done.messageText     = @"Finder is the default file viewer again";
                done.informativeText = @"Every setting Files changed has been put back. "
                                        "You can now quit and uninstall Files; folders "
                                        "open in Finder again after you log out and back in.";
            } else {
                done.messageText     = @"Files is the default file viewer";
                done.informativeText = @"\"Show in Finder\" requests from other apps now open "
                                        "in Files. Folders opened from other apps open in "
                                        "Files after you log out and back in.";
            }
            if (win) {
                [done beginSheetModalForWindow:win completionHandler:nil];
            } else {
                [done runModal];
            }
        });
    };
    if (!restore) {
        apply();
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"Restore Finder as the default file viewer?";
    alert.informativeText = @"\"Show in Finder\" requests and opened folders will go to Finder "
                             "again, and the settings Files changed (desktop icons, Finder's "
                             "Quit menu item, Archive Utility revealing its results) go back "
                             "to what they were before Files. Do this before uninstalling "
                             "Files.";
    [alert addButtonWithTitle:@"Restore Finder"];
    [alert addButtonWithTitle:@"Cancel"];
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) apply();
    };
    if (win) {
        [alert beginSheetModalForWindow:win completionHandler:handle];
    } else {
        handle([alert runModal]);
    }
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
    NSMenuItem *viewer = make_item(@"Restore Finder as Default File Viewer…",
                                   @selector(default_viewer_action:), @"", 0);
    viewer.target = self;  /* title set by validateMenuItem: */
    [file_menu addItem:viewer];
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
    [edit_menu addItem:make_item(@"Find…", @selector(find_action:), @"f", 0)];
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
    [view_menu addItem:make_pref_item(@"Show Finder After Archive Operations",
                                      files_pref_archive_reveal, self)];
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
