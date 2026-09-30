#import "app_delegate.h"
#import "main_window.h"
#import "browser_pane.h"
#import "volume_manager.h"
#import "mounts_panel.h"
#import "default_viewer.h"
#import "prefs_window.h"
#import "util.h"
#import <ServiceManagement/ServiceManagement.h>

@interface FilesAppDelegate () <NSMenuDelegate, NSMenuItemValidation>
@property (nonatomic, strong) NSMutableArray<FilesMainWindow *> *windows;  /* open browser windows */
@property (nonatomic, strong) NSNumber *archive_reveal_attempted;  /* value tried this session */
@property (nonatomic, strong) NSNumber *keep_running_applied;      /* login item state applied */
@property (nonatomic, assign) BOOL launched;  /* applicationDidFinishLaunching: has run */
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
 * applicationDidFinishLaunching: — creates the menu bar, starts following
 * preference changes, and opens a home-folder window unless the launch
 * already opened one (to reveal files) or Files was started at login to
 * keep running in the background (files_pref_keep_running). The first
 * window runs the launch checks (run_checks); a login launch makes only
 * the silent part of them (sync_integrations), leaving the Full Disk
 * Access prompt for the first window.
 *
 * Inputs:
 *   n — NSApplicationDidFinishLaunchingNotification (unused)
 */
- (void)
applicationDidFinishLaunching:(NSNotification *)n
{
    [self build_menu_bar];

    /* Preferences can change on any thread (default_viewer writes its
     * records on a queue); act on them on the main queue. */
    __weak FilesAppDelegate *ws = self;
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        [ws prefs_changed];
    }];

    self.launched = YES;
    if (self.windows.count > 0) {
        [self run_checks];
    } else if ([self launched_at_login] &&
               [NSUserDefaults.standardUserDefaults boolForKey:files_pref_keep_running]) {
        [self sync_integrations];
        return;
    } else {
        [self open_window_at:files_home_url()];
    }
    [NSApp activate];
}

/*
 * launched_at_login — whether this launch is the login item starting Files
 * (the open-application event carries keyAELaunchedAsLogInItem). Only
 * meaningful during applicationDidFinishLaunching:.
 *
 * Output: YES for a login launch.
 */
- (BOOL)
launched_at_login
{
    NSAppleEventDescriptor *ev = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
    return ev.eventID == kAEOpenApplication &&
           [ev paramDescriptorForKeyword:keyAEPropData].enumCodeValue == keyAELaunchedAsLogInItem;
}

/*
 * run_checks — the checks made whenever Files gets its first window: at
 * launch, and, while it keeps running with no windows, each time it is
 * used again (so they are not limited to once per login). Asks for Full
 * Disk Access if it is missing, then sync_integrations.
 */
- (void)
run_checks
{
    if (!files_has_full_disk_access()) {
        [self prompt_full_disk_access:
            @"Files is a file manager and needs Full Disk Access to show and manage "
             "all of your files (for example the Trash, Mail and Messages data, and "
             "other apps' containers)."];
    }
    [self sync_integrations];
}

/*
 * sync_integrations — silently brings the settings Files manages outside
 * itself in line with its preferences, re-reading each one: Archive
 * Utility (sync_archive_utility_reporting:), Finder / default file viewer
 * (files_default_viewer_sync; the first launch takes over from Finder, as
 * files_pref_default_viewer is on by default, and later ones repair or
 * keep restored), and the login item (sync_keep_running_reporting:).
 */
- (void)
sync_integrations
{
    self.archive_reveal_attempted = nil;
    self.keep_running_applied     = nil;
    [self sync_archive_utility_reporting:NO];
    files_default_viewer_sync(nil);
    [self sync_keep_running_reporting:NO];
}

/*
 * prefs_changed — NSUserDefaultsDidChangeNotification handler (main queue):
 * applies preferences that act outside Files, reporting failure (the
 * preference just changed, most likely from a menu or Preferences). Each
 * is a no-op unless its preference changed since it was last applied.
 */
- (void)
prefs_changed
{
    [self sync_archive_utility_reporting:YES];
    [self sync_keep_running_reporting:YES];
}

/*
 * sync_keep_running_reporting: — registers Files as a login item
 * (SMAppService main app) while files_pref_keep_running is on, and
 * unregisters it when off. Runs with sync_integrations and whenever the
 * preference changes; each value is applied at most once until
 * sync_integrations re-checks, so frequent defaults notifications cost
 * nothing. Staying open after the last window closes follows the
 * preference directly (applicationShouldTerminateAfterLastWindowClosed:),
 * and Info.plist's NSSupportsAutomaticTermination = NO keeps macOS from
 * quitting Files while it has no windows.
 *
 * Inputs:
 *   report — YES to explain a failure, or that the login item needs
 *            approval in System Settings; NO to only log it
 */
- (void)
sync_keep_running_reporting:(BOOL)report
{
    BOOL want = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_keep_running];
    if (self.keep_running_applied && self.keep_running_applied.boolValue == want) return;
    self.keep_running_applied = @(want);

    SMAppService *svc  = SMAppService.mainAppService;
    SMAppServiceStatus st = svc.status;
    NSError *err = nil;
    if (!want) {
        if ((st == SMAppServiceStatusEnabled || st == SMAppServiceStatusRequiresApproval) &&
            ![svc unregisterAndReturnError:&err]) {
            NSLog(@"[keep_running] could not remove login item: %@", err);
        }
        return;
    }
    if (st == SMAppServiceStatusEnabled) return;
    if (st != SMAppServiceStatusRequiresApproval && ![svc registerAndReturnError:&err]) {
        NSLog(@"[keep_running] could not add login item: %@", err);
        if (report) {
            files_show_error(@"Files could not add itself to your login items", err,
                             NSApp.keyWindow);
        }
        return;
    }
    if (svc.status != SMAppServiceStatusRequiresApproval || !report) return;

    NSAlert *alert        = [[NSAlert alloc] init];
    alert.messageText     = @"Allow Files to open at login";
    alert.informativeText = @"Files is turned off in Login Items. Turn it on in System "
                             "Settings ▸ General ▸ Login Items so Files starts at login.";
    [alert addButtonWithTitle:@"Open Login Items Settings"];
    [alert addButtonWithTitle:@"Not Now"];
    files_present_alert(alert, NSApp.keyWindow, ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) [SMAppService openSystemSettingsLoginItems];
    });
}

/*
 * sync_archive_utility_reporting: — makes Archive Utility's
 * dearchive-reveal-after and archive-reveal-after equal
 * files_pref_archive_reveal (off by default), so the View menu item always
 * describes what Archive Utility will actually do. Runs with
 * sync_integrations — at every launch, including the first, which applies
 * the default — and whenever the preference changes. files_sync_prefs
 * reads Archive Utility's real values and writes only what differs
 * (missing keys included), on a serial background queue; nothing is
 * cached, so values changed or reset elsewhere are corrected at the next
 * sync_integrations. This needs Full Disk Access (Archive Utility is
 * sandboxed), which run_checks prompts for.
 *
 * Each value is attempted at most once until sync_integrations re-checks,
 * so the frequent defaults notifications never re-run (or re-alert) it.
 *
 * Inputs:
 *   report — YES to prompt for Full Disk Access if it fails (the user
 *            toggled the option); NO from sync_integrations, where
 *            run_checks has already prompted
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
    files_present_alert(alert, [self front_window].window, handle);
}

/* ── Windows ─────────────────────────────────────────────────────────────── */

/*
 * open_window_at: — opens a new browser window showing url, cascaded down
 * and right from the frontmost browser window (the first window uses the
 * saved frame). Used at launch, by File ▸ New Window, when a window asks
 * for one (a newly mounted disk image), and when Files, kept running with
 * no windows, is used again. Opening the first window after launch with
 * none open runs run_checks.
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
    BOOL first             = self.windows.count == 0;
    if (front) {
        NSRect f = front.window.frame;
        [w.window setFrameTopLeftPoint:NSMakePoint(NSMinX(f) + 24.0, NSMaxY(f) - 24.0)];
    }
    __weak FilesAppDelegate *ws = self;
    w.new_window_handler = ^(NSURL *u) { [ws open_window_at:u]; };
    [self.windows addObject:w];
    [w showWindow:nil];
    if (first && self.launched) [self run_checks];
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
 * applicationShouldTerminateAfterLastWindowClosed: — Files quits when its
 * last window closes, unless files_pref_keep_running keeps it running
 * (like Finder) so the next window opens without a launch.
 *
 * Inputs:
 *   app — NSApplication (unused)
 *
 * Output: NO while files_pref_keep_running is on, else YES.
 */
- (BOOL)
applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:files_pref_keep_running];
}

/*
 * applicationShouldHandleReopen:hasVisibleWindows: — clicking the Dock
 * icon (or opening the app again) with no browser window open opens one on
 * the home folder, as Finder does; otherwise AppKit's default handling
 * (e.g. un-minimizing a window) applies.
 *
 * Inputs:
 *   app     — NSApplication (unused)
 *   visible — whether any window is visible (unused: panels such as
 *             Preferences count, but are not browser windows)
 *
 * Output: NO if a window was opened here, else YES.
 */
- (BOOL)
applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{
    if (self.windows.count > 0) return YES;
    [self open_window_at:files_home_url()];
    return NO;
}

/*
 * show_about: — Files ▸ About Files: the standard About panel, whose
 * version line reads "Version <VERSION> (built <date>)". The version comes
 * from Info.plist; the build date from its FilesBuildDate key (UTC, ISO
 * 8601), both written by the Makefile. Without a readable build date the
 * line is just the version.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
show_about:(id)sender
{
    NSString *stamp = NSBundle.mainBundle.infoDictionary[@"FilesBuildDate"];
    NSDate *built   = stamp ? [[[NSISO8601DateFormatter alloc] init] dateFromString:stamp] : nil;
    NSDictionary *options = @{};
    if (built) {
        options = @{ NSAboutPanelOptionApplicationVersion:
                     [@"built " stringByAppendingString:
                         files_format_date(built, NSDateFormatterMediumStyle)] };
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

/*
 * show_preferences: — Files ▸ Preferences… (⌘,): shows the Preferences
 * window.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
show_preferences:(id)sender
{
    [FilesPrefsWindow.shared show_window];
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
 * needed (copies) or observes it (Large Rows, Auto-Fit Columns).
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
 * checkmarks of preference items, and the Preferences… title. AppKit
 * renames an app-menu "Preferences…" item with ⌘, to "Settings…" once the
 * app runs; setting the title here, as the menu opens, keeps "Preferences…".
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
    } else if (item.action == @selector(show_preferences:)) {
        item.title = @"Preferences…";
    }
    return YES;
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
    NSMenuItem *about = make_item(@"About Files", @selector(show_about:), @"", 0);
    about.target = self;
    [app_menu addItem:about];
    [app_menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *prefs = make_item(@"Preferences…", @selector(show_preferences:), @",", 0);
    prefs.target = self;  /* title kept by validateMenuItem: */
    [app_menu addItem:prefs];
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
    /* Preference items, in groups shared with Preferences ▸ View. */
    NSArray<NSArray<NSArray<NSString *> *> *> *groups = files_view_pref_groups();
    for (NSArray<NSArray<NSString *> *> *group in groups) {
        if (group != groups.firstObject) [view_menu addItem:NSMenuItem.separatorItem];
        for (NSArray<NSString *> *pref in group) {
            [view_menu addItem:make_pref_item(pref[0], pref[1], self)];
        }
    }
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
