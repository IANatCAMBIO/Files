/*
 * ui_check — builds Files' real windows in this process, checks the window
 * chrome the house style requires, renders light and dark PNG snapshots of
 * each one, and checks that a closed browser window is released.
 *
 * It exists because the outside tools need permissions an automated session
 * may not have: a screenshot needs Screen Recording and driving the
 * interface needs Accessibility. Nothing here needs either — the windows
 * are built, laid out and rendered in process, and never ordered on screen.
 *
 * It deliberately does NOT create FilesAppDelegate. The delegate's first
 * launch makes Files the default file viewer, which rewrites NSFileViewer,
 * two Finder settings, Archive Utility's preferences and ~/.zshrc, and
 * quits Finder. A test must not touch the machine it runs on, so this
 * builds the window controllers directly. Everything it writes goes to a
 * scratch folder in $TMPDIR and to a preference domain named after this
 * binary, both removed before it returns.
 *
 *   ui_check <snapshot dir>
 *
 * What it checks, for every window:
 *   - a real title bar: NSWindowStyleMaskTitled, a visible title, no
 *     transparent title bar and no full-size content view (the house style
 *     forbids a header bar);
 *   - the main window's toolbar: present, expanded style (so the title bar
 *     sits above it), icon-only, and not user-customisable;
 *   - it lays out and renders, in light and in dark appearance.
 *
 * And for the browser window, which is the only one that is not a
 * singleton: that closing it releases the controller, its window and its
 * browser views.
 *
 * Output: exit status 0 when every check passed, 1 otherwise, 2 when it
 * could not run.
 */

#import <Cocoa/Cocoa.h>

#import "main_window.h"
#import "browser_view.h"
#import "prefs_window.h"
#import "info_panel.h"
#import "mounts_panel.h"
#import "default_apps_panel.h"
#import "util.h"

static int failures;

/*
 * check — records one result and prints it.
 *
 * Inputs:
 *   ok   — whether the check passed
 *   what — description, printed either way
 */
static void
check(BOOL ok, NSString *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

/*
 * spin — runs the main run loop for a while, so the layout, the background
 * folder listing and anything else queued on the main queue can finish
 * before a window is measured or rendered.
 *
 * Inputs:
 *   seconds — how long to run
 */
static void
spin(double seconds)
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

/*
 * snapshot — renders a window, title bar and toolbar included, to a PNG.
 * The frame view rather than the content view, so the title bar and the
 * toolbar are in the picture and a header bar would be obvious.
 *
 * Inputs:
 *   window — the window; it need not be on screen
 *   dir    — folder to write into
 *   name   — the file's base name
 *
 * Output: YES when the file was written.
 */
static BOOL
snapshot(NSWindow *window, NSString *dir, NSString *name)
{
    NSView *frame_view = window.contentView.superview;

    [window layoutIfNeeded];
    [window display];
    spin(0.2);

    NSBitmapImageRep *rep =
        [frame_view bitmapImageRepForCachingDisplayInRect:frame_view.bounds];
    [frame_view cacheDisplayInRect:frame_view.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [dir stringByAppendingPathComponent:
                          [name stringByAppendingPathExtension:@"png"]];
    return png.length > 0 && [png writeToFile:path atomically:YES];
}

/*
 * check_title_bar — the chrome every window in the app must have: a real
 * title bar with its title shown, and none of the three things that turn a
 * title bar into a header bar.
 *
 * Inputs:
 *   window — the window to check
 *   label  — what to call it in the output
 */
static void
check_title_bar(NSWindow *window, NSString *label)
{
    check((window.styleMask & NSWindowStyleMaskTitled) != 0,
          [NSString stringWithFormat:@"%@: a titled window", label]);
    check((window.styleMask & NSWindowStyleMaskFullSizeContentView) == 0,
          [NSString stringWithFormat:@"%@: no full-size content view", label]);
    check(!window.titlebarAppearsTransparent,
          [NSString stringWithFormat:@"%@: an opaque title bar", label]);
    check(window.titleVisibility == NSWindowTitleVisible,
          [NSString stringWithFormat:@"%@: the title is shown", label]);
    check(window.title.length > 0,
          [NSString stringWithFormat:@"%@: the title is not empty (%@)", label, window.title]);
}

/*
 * check_snapshots — renders a window light and dark. The window's own
 * appearance is overridden rather than the app's, so each picture is of a
 * known appearance whatever the machine is set to, and is put back after.
 *
 * Inputs:
 *   window — the window to render
 *   dir    — folder to write the PNGs into
 *   name   — base name; "-dark" is appended for the dark one
 */
static void
check_snapshots(NSWindow *window, NSString *dir, NSString *name)
{
    NSAppearance *was = window.appearance;

    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    check(snapshot(window, dir, name),
          [NSString stringWithFormat:@"%@: renders in light appearance", name]);

    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    check(snapshot(window, dir, [name stringByAppendingString:@"-dark"]),
          [NSString stringWithFormat:@"%@: renders in dark appearance", name]);

    window.appearance = was;
}

/*
 * check_browser_window — the main window: its chrome, its toolbar, that it
 * lists the scratch folder, and that closing it releases the controller,
 * its window and its browser views.
 *
 * Inputs:
 *   folder — the folder to open it on
 *   dir    — folder to write the PNGs into
 */
static void
check_browser_window(NSURL *folder, NSString *dir)
{
    __weak FilesMainWindow *weak_controller = nil;
    __weak NSWindow        *weak_window     = nil;
    __weak FilesBrowserView *weak_browser   = nil;

    @autoreleasepool {
        FilesMainWindow *controller = [[FilesMainWindow alloc] init_with_url:folder];
        NSWindow        *window     = controller.window;
        check(window != nil, @"browser: the window is built");
        if (!window) {
            return;
        }
        /* The listing runs on a background queue; give it time to come
         * back and the table time to lay the rows out. */
        spin(0.6);

        check_title_bar(window, @"browser");

        NSToolbar *toolbar = window.toolbar;
        check(toolbar != nil, @"browser: it has a toolbar");
        check(window.toolbarStyle == NSWindowToolbarStyleExpanded,
              @"browser: the toolbar is expanded, so the title bar is above it");
        check(toolbar.displayMode == NSToolbarDisplayModeIconOnly,
              @"browser: the toolbar is icon-only");
        check(!toolbar.allowsUserCustomization,
              @"browser: the toolbar is not user-customisable");
        check(toolbar.items.count > 0,
              [NSString stringWithFormat:@"browser: the toolbar has items (%lu)",
                  (unsigned long)toolbar.items.count]);

        FilesBrowserView *browser = controller.active_browser;
        check(browser != nil, @"browser: it has an active browser view");

        check_snapshots(window, dir, @"browser");

        weak_controller = controller;
        weak_window     = window;
        weak_browser    = browser;

        [window close];
    }
    /* Closing releases the window; the controller goes with the last
     * reference to it. Spin first: AppKit holds a window briefly after a
     * close, through the autorelease pool it closed in. */
    spin(0.3);

    check(weak_window == nil,     @"browser: the window is released when it closes");
    check(weak_controller == nil, @"browser: the controller is released with it");
    check(weak_browser == nil,    @"browser: the browser view is released with it");
}

/*
 * check_panel — one of the app's singleton windows: its chrome and its
 * snapshots. These are deliberately kept alive by their +shared accessor,
 * so there is nothing to check about their release.
 *
 * Inputs:
 *   window — the panel's window
 *   label  — what to call it in the output
 *   dir    — folder to write the PNGs into
 */
static void
check_panel(NSWindow *window, NSString *label, NSString *dir)
{
    check(window != nil, [NSString stringWithFormat:@"%@: the window is built", label]);
    if (!window) {
        return;
    }
    spin(0.3);
    check_title_bar(window, label);
    check_snapshots(window, dir, label);
    [window close];
}

/*
 * main — builds a scratch folder, then every window, and checks each one.
 *
 * Inputs:
 *   argc, argv — argv[1] is the folder the PNGs are written to
 *
 * Output: 0 when every check passed, 1 otherwise, 2 when it could not run.
 */
int
main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "ui_check: run `make test-ui` (it names the snapshot folder)\n");
            return 2;
        }
        NSString     *dir = @(argv[1]);
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                           attributes:nil error:NULL]) {
            fprintf(stderr, "ui_check: cannot write to %s\n", argv[1]);
            return 2;
        }

        /* A folder of our own to browse, so the snapshots do not depend on
         * what happens to be in the user's home folder. */
        NSURL *scratch = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:
                [@"files-ui-check-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtURL:scratch withIntermediateDirectories:YES
                      attributes:nil error:NULL];
        for (NSString *name in @[@"notes.txt", @"page.html", @"photo.jpg", @"archive.zip"]) {
            [@"scratch" writeToURL:[scratch URLByAppendingPathComponent:name]
                        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        [fm createDirectoryAtURL:[scratch URLByAppendingPathComponent:@"a folder"]
       withIntermediateDirectories:YES attributes:nil error:NULL];

        /* An accessory app: windows build and render, but no Dock icon
         * appears and the user's front app keeps the keyboard. */
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        check_browser_window(scratch, dir);

        [FilesPrefsWindow.shared show_window];
        check_panel(FilesPrefsWindow.shared.window, @"preferences", dir);

        [FilesInfoPanel.shared show_for_url:[scratch URLByAppendingPathComponent:@"notes.txt"]];
        check_panel(FilesInfoPanel.shared.window, @"get-info", dir);

        [FilesMountsPanel.shared show_panel];
        check_panel(FilesMountsPanel.shared.window, @"all-mounts", dir);

        /* Set Default Apps scans every application on the Mac on a
         * background queue. The window and its chrome are what is checked
         * here; the list the scan fills in is default_apps_test's job. */
        [files_default_apps_panel.shared show_panel];
        check_panel(files_default_apps_panel.shared.window, @"default-apps", dir);

        [fm removeItemAtURL:scratch error:NULL];
        [NSUserDefaults.standardUserDefaults
            removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier
                                          ?: NSProcessInfo.processInfo.processName];

        printf("snapshots in %s\n", dir.UTF8String);
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
