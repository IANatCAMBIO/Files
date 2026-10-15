#import "app_delegate.h"
#import "tool_panel.h"
#import "main_window.h"
#import "browser_view.h"
#import "volume_manager.h"
#import "mounts_panel.h"
#import "default_viewer.h"
#import "prefs_window.h"
#import "bookmarks_bar.h"
#import "util.h"
#import <ServiceManagement/ServiceManagement.h>

@interface FilesAppDelegate () <NSMenuDelegate, NSMenuItemValidation>
@property (nonatomic, strong) NSMutableArray<FilesMainWindow *> *windows;  /* open browser windows */
@property (nonatomic, strong) NSNumber *keep_running_applied;      /* login item state applied */
@property (nonatomic, assign) BOOL launched;  /* applicationDidFinishLaunching: has run */
@property (nonatomic, assign) BOOL synced;    /* sync_integrations has run */
@property (nonatomic, assign) BOOL fda_asked; /* the launch Full Disk Access prompt was shown */
@property (nonatomic, strong) NSMenu    *go_menu;           /* its Bookmarks section is rebuilt on open */
@property (nonatomic, assign) NSInteger  go_fixed_count;    /* items above the Bookmarks section */
@end

@implementation FilesAppDelegate

/*
 * applicationWillFinishLaunching: — registers preference defaults,
 * prepares window tracking and sets the running app's icon. Runs before
 * application:openURLs:, which a launch to reveal files delivers ahead of
 * applicationDidFinishLaunching:.
 *
 * The icon: macOS 26 draws a bundle icon that is not its rounded-square
 * shape on a grey rounded-square backdrop. The running app's icon (the
 * Dock tile while Files runs) is set to folder.png itself; the
 * About panel is handed it explicitly (show_about:),
 * since it would add the backdrop to the app icon themselves. Finder,
 * and the Dock while Files is not running, use the bundle icon and keep
 * the backdrop; only redrawn artwork avoids that.
 *
 * Inputs:
 *   n — NSApplicationWillFinishLaunchingNotification (unused)
 */
- (void)
applicationWillFinishLaunching:(NSNotification *)n
{
    files_register_defaults();
    if (files_app_icon()) NSApp.applicationIconImage = files_app_icon();
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
 * window runs the launch checks (run_checks_soon); a login launch makes only
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
    BOOL at_login = [self launched_at_login];
    NSLog(@"[launch] %@", at_login ? @"started as a login item" : @"started normally");
    if (self.windows.count > 0) {
        [self run_checks_soon];
    } else if (at_login &&
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
 * run_checks_soon — the checks made whenever Files gets its first window:
 * at launch, and, while it keeps running with no windows, each time it is
 * used again (so they are not limited to once per login). Run on the next
 * pass of the main run loop, so the window draws first. Asks for Full
 * Disk Access if it is missing — once per run of Files, so declining is
 * not met with the same prompt on every reopen — then sync_integrations.
 */
- (void)
run_checks_soon
{
    dispatch_async(dispatch_get_main_queue(), ^{ [self run_checks]; });
}

/*
 * run_checks — the body of run_checks_soon.
 */
- (void)
run_checks
{
    if (!self.fda_asked && !files_has_full_disk_access()) {
        self.fda_asked = YES;
        [self prompt_full_disk_access:
            @"Files is a file manager and needs Full Disk Access to show and manage "
             "all of your files (for example the Trash, Mail and Messages data, and "
             "other apps' containers)."];
    }
    [self sync_integrations];
}

/*
 * sync_integrations — silently brings the settings Files manages outside
 * itself in line with its preferences, re-reading each one: Finder /
 * default file viewer and Archive Utility (files_default_viewer_sync; the
 * first launch takes over from Finder, as files_pref_default_viewer is on
 * by default, and later ones repair or keep restored), and the login item
 * (sync_keep_running_reporting:).
 */
- (void)
sync_integrations
{
    self.keep_running_applied = nil;
    files_default_viewer_sync(nil);
    [self sync_keep_running_reporting:NO];
    self.synced = YES;
}

/*
 * prefs_changed — NSUserDefaultsDidChangeNotification handler (main queue):
 * applies preferences that act outside Files, reporting failure (the
 * preference just changed, most likely from a menu or Preferences). Each
 * is a no-op unless its preference changed since it was last applied.
 * Does nothing before the first sync_integrations, which applies them all
 * silently: the defaults written while the first window is built (its
 * frame, the first bookmark list) are not preference changes.
 */
- (void)
prefs_changed
{
    if (!self.synced) return;
    [self sync_keep_running_reporting:YES];
}

/*
 * sync_keep_running_reporting: — registers Files as a login item
 * (SMAppService main app) while files_pref_keep_running is on, and
 * unregisters it when off, on files_background_queue() (SMAppService asks
 * a system daemon and blocks); any alert is shown on the main queue. Runs
 * with sync_integrations and whenever the preference changes; each value
 * is applied at most once until sync_integrations re-checks, so frequent
 * defaults notifications cost nothing. Staying open after the last window
 * closes follows the
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

    dispatch_async(files_background_queue(), ^{
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
                dispatch_async(dispatch_get_main_queue(), ^{
                    files_show_error(@"Files could not add itself to your login items", err,
                                     [self front_window].window);
                });
            }
            return;
        }
        if (svc.status != SMAppServiceStatusRequiresApproval || !report) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [self ask_login_item_approval]; });
    });
}

/*
 * ask_login_item_approval — explains that the login item is turned off in
 * System Settings and offers to open Login Items there.
 */
- (void)
ask_login_item_approval
{
    [FilesToolPanel show_message:@"Allow Files to open at login"
                         message:@"Files is turned off in Login Items. Turn it on in System "
                                  "Settings ▸ General ▸ Login Items so Files starts at login."
                          symbol:@"power"
                         buttons:@[@"Open Login Items Settings", @"Not Now"]
                            over:[self front_window].window
                         handler:^(NSInteger index) {
        if (index == 0) [SMAppService openSystemSettingsLoginItems];
    }];
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
    NSString *message = [NSString stringWithFormat:
        @"%@\n\nTo grant it:\n"
         "1. Click Open System Settings (Privacy & Security ▸ Full Disk Access).\n"
         "2. Turn on Files, or click + and add:\n    %@\n"
         "3. When asked, choose Quit & Reopen.", reason, app_path];
    [FilesToolPanel show_message:@"Files needs Full Disk Access"
                         message:message
                          symbol:@"lock.shield"
                         buttons:@[@"Open System Settings", @"Not Now"]
                            over:[self front_window].window
                         handler:^(NSInteger index) {
        if (index != 0) return;
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
    }];
}

/* ── Windows ─────────────────────────────────────────────────────────────── */

/*
 * open_window_at: — opens a new browser window showing url, cascaded down
 * and right from the frontmost browser window (the first window uses the
 * saved frame). Used at launch, by File ▸ New Window, when a window asks
 * for one (a newly mounted disk image), and when Files, kept running with
 * no windows, is used again. Opening the first window after launch with
 * none open runs run_checks_soon.
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
    if (first && self.launched) [self run_checks_soon];
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
        if (files_same_path([w active_browser].current_url, folder)) {
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
        [[[self window_for_folder:parent] active_browser] reveal_items:reveal[parent]];
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

/* Links in the About panel's credits: the author's site and the license
 * (BSD 3-Clause, as for Tasks). */
static NSString * const about_site_url    = @"https://camb.io";
static NSString * const about_license_url = @"https://opensource.org/license/bsd-3-clause";

/*
 * about_credits — the About panel's credits: "camb.io · BSD License",
 * centred in the small system font, each name a link.
 *
 * Output: attributed string for NSAboutPanelOptionCredits.
 */
static NSAttributedString *
about_credits(void)
{
    NSMutableParagraphStyle *centred = [[NSMutableParagraphStyle alloc] init];
    centred.alignment = NSTextAlignmentCenter;
    NSDictionary *plain = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName:  centred,
    };
    NSArray<NSArray<NSString *> *> *links = @[
        @[@"camb.io",     about_site_url],
        @[@"BSD License", about_license_url],
    ];

    NSMutableAttributedString *credits = [[NSMutableAttributedString alloc] init];
    for (NSArray<NSString *> *link in links) {
        if (credits.length > 0) {
            [credits appendAttributedString:
                [[NSAttributedString alloc] initWithString:@"  ·  " attributes:plain]];
        }
        NSMutableDictionary *attrs = [plain mutableCopy];
        attrs[NSLinkAttributeName] = [NSURL URLWithString:link[1]];
        [credits appendAttributedString:
            [[NSAttributedString alloc] initWithString:link[0] attributes:attrs]];
    }
    return credits;
}

/*
 * show_about: — Files ▸ About Files: the standard About panel. Its version
 * line reads "Version <VERSION> (built <date>)": the version comes from
 * Info.plist and the build date from its FilesBuildDate key (UTC, ISO
 * 8601), both written by the Makefile; without a readable build date the
 * line is just the version. The copyright line is Info.plist's
 * NSHumanReadableCopyright, and the credits link to camb.io and the
 * license (about_credits). The icon is files_app_icon(), passed explicitly
 * so the panel does not put it on the grey backdrop.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
show_about:(id)sender
{
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[NSAboutPanelOptionCredits] = about_credits();
    if (files_app_icon()) options[NSAboutPanelOptionApplicationIcon] = files_app_icon();

    NSString *stamp = NSBundle.mainBundle.infoDictionary[@"FilesBuildDate"];
    NSDate *built   = stamp ? [[[NSISO8601DateFormatter alloc] init] dateFromString:stamp] : nil;
    if (built) {
        options[NSAboutPanelOptionApplicationVersion] =
            [@"built " stringByAppendingString:files_format_date(built, NSDateFormatterMediumStyle)];
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

/* ── Go and Mounts menus ─────────────────────────────────────────────────── */

/*
 * add_location_item:url:name:icon: — appends a menu item that navigates the
 * front window's active pane to url (location_menu_item_clicked:).
 *
 * Inputs:
 *   menu — the menu to add to
 *   url  — folder the item goes to
 *   name — item title
 *   icon — item image, or nil for url's Workspace icon at 16 points
 */
- (void)
add_location_item:(NSMenu *)menu url:(NSURL *)url name:(NSString *)name icon:(NSImage *)icon
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name
                                                  action:@selector(location_menu_item_clicked:)
                                           keyEquivalent:@""];
    item.target            = self;
    item.representedObject = url;
    if (!icon) {
        icon      = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size = NSMakeSize(16, 16);
    }
    item.image = icon;

    [menu addItem:item];
}

/*
 * menuNeedsUpdate: — NSMenuDelegate; rebuilds the dynamic part of the Go
 * or Mounts menu each time it opens, so neither needs observers.
 *
 * Go: below its fixed items, a Bookmarks section listing every bookmark in
 * bar order.
 *
 * Mounts: the mounted volumes, then (after a separator) the cloud storage
 * locations — iCloud Drive and File Provider accounts such as Google
 * Drive — then "All Mounts…".
 *
 * Each location item navigates the front window's active pane.
 *
 * Inputs:
 *   menu — the Go or Mounts menu
 */
- (void)
menuNeedsUpdate:(NSMenu *)menu
{
    if (menu == self.go_menu) {
        while (menu.numberOfItems > self.go_fixed_count) {
            [menu removeItemAtIndex:menu.numberOfItems - 1];
        }
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Bookmarks"]];
        for (NSURL *url in files_bookmark_urls()) {
            [self add_location_item:menu url:url name:files_bookmark_name(url)
                               icon:files_bookmark_icon(url, 16)];
        }
        return;
    }

    [menu removeAllItems];

    FilesVolumeManager *vm = FilesVolumeManager.shared;
    for (NSURL *vol in vm.mounted_volumes) {
        [self add_location_item:menu url:vol name:[vm display_name_for_volume:vol] icon:nil];
    }

    NSArray<NSURL *> *clouds = vm.cloud_storage_locations;
    if (clouds.count > 0) [menu addItem:NSMenuItem.separatorItem];
    for (NSURL *cloud in clouds) {
        NSString *name = nil;
        [cloud getResourceValue:&name forKey:NSURLLocalizedNameKey error:nil];
        [self add_location_item:menu url:cloud name:name ?: cloud.lastPathComponent icon:nil];
    }

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *all = [[NSMenuItem alloc] initWithTitle:@"All Mounts…"
                                                 action:@selector(show_all_mounts:)
                                          keyEquivalent:@""];
    all.target = self;
    [menu addItem:all];
}

/*
 * location_menu_item_clicked: — navigates the front window's active pane
 * to the location stored in the menu item's representedObject, or opens a
 * window on it when none is open (Files kept running).
 *
 * Inputs:
 *   sender — NSMenuItem with representedObject = bookmark, volume or
 *            cloud folder URL
 */
- (void)
location_menu_item_clicked:(NSMenuItem *)sender
{
    NSURL *vol = sender.representedObject;
    if (!vol) return;
    FilesMainWindow *front = [self front_window];
    if (front) {
        [[front active_browser] navigate_to:vol];
    } else {
        [self open_window_at:vol];
    }
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
    [go_menu addItem:NSMenuItem.separatorItem];
    /* No shortcut: ⇧⌘T is File ▸ Open in Terminal. */
    [go_menu addItem:make_item(@"Trash",
                               @selector(go_trash_action:),     @"",  0)];
    go_menu.delegate    = self;  /* Bookmarks section: menuNeedsUpdate: */
    self.go_menu        = go_menu;
    self.go_fixed_count = go_menu.numberOfItems;
    go_mi.submenu = go_menu;
    [bar addItem:go_mi];

    /* ── Mounts menu ── */
    NSMenuItem *mounts_mi   = [[NSMenuItem alloc] init];
    NSMenu     *mounts_menu = [[NSMenu alloc] initWithTitle:@"Mounts"];
    mounts_menu.delegate    = self;  /* rebuilt on open: menuNeedsUpdate: */
    mounts_mi.submenu       = mounts_menu;
    [bar addItem:mounts_mi];

    NSApp.mainMenu = bar;
}

@end
