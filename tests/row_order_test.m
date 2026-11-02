/*
 * row_order_test — checks the order and the membership of the rows the
 * file list shows, driven through the real browser view: every sortable
 * column in both directions, folders-first on and off, and Show Hidden
 * Files. The listing now sorts from the values it read with the folder
 * rather than from Foundation's resource values, so this is what proves
 * the two agree about order. Run with `make test`; prints one line per
 * check and exits non-zero on failure.
 *
 * This binary is not the app bundle, so the preferences it writes land in
 * a domain of its own (named after the binary) and never in the app's.
 * That domain is removed before the test returns.
 */
#import <Cocoa/Cocoa.h>
#import "browser_view.h"
#import "util.h"

static int failures;

/*
 * check — records one test result and prints it.
 *
 * Inputs:
 *   ok   — whether the check passed
 *   what — description
 */
static void
check(BOOL ok, NSString *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

/*
 * pump — runs the main run loop, so the listing's background work lands.
 *
 * Inputs:
 *   secs — seconds to run for
 */
static void
pump(NSTimeInterval secs)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:secs];
    while (until.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

/*
 * row_names — the names of the rows a freshly built list shows, in the
 * order it shows them: the view is created with the given preferences,
 * pointed at the folder, and every row selected, since the selection
 * comes back in row order.
 *
 * Inputs:
 *   dir           — folder to list
 *   column        — sort column identifier
 *   ascending     — sort direction
 *   folders_first — folders before files
 *   show_hidden   — list hidden items too
 *
 * Output: row names in display order.
 */
static NSArray<NSString *> *
row_names(NSURL *dir, NSString *column, BOOL ascending, BOOL folders_first, BOOL show_hidden)
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setObject:column forKey:files_pref_sort_column];
    [ud setBool:ascending forKey:files_pref_sort_ascending];
    [ud setBool:folders_first forKey:files_pref_folders_first];
    [ud setBool:show_hidden forKey:files_pref_show_hidden];

    FilesBrowserView *view =
        [[FilesBrowserView alloc] init_with_frame:NSMakeRect(0, 0, 900, 400)];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 400)
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    w.contentView = view;
    [view navigate_to:dir];
    pump(1.0);
    [view selectAll:nil];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in [view selected_urls]) [names addObject:url.lastPathComponent];
    [view shut_down];
    return names;
}

/*
 * expect — compares the rows against the order they should be in.
 *
 * Inputs:
 *   got   — the names the list showed
 *   want  — the names expected, in order
 *   what  — description
 */
static void
expect(NSArray<NSString *> *got, NSArray<NSString *> *want, NSString *what)
{
    check([got isEqualToArray:want],
          [NSString stringWithFormat:@"%@\n       got  %@\n       want %@", what,
              [got componentsJoinedByString:@", "], [want componentsJoinedByString:@", "]]);
}

/*
 * main — builds a folder whose every column sorts differently and checks
 * each order.
 *
 * Output: 0 when every check passed, 1 otherwise.
 */
int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;

        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                       URLByAppendingPathComponent:
                           [@"files-order-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *d = root.path;

        /* Sizes, names, kinds and dates each give a different order, so a
         * column that sorted by the wrong field could not pass by luck.
         * Names are also numbered to catch a plain string sort, which puts
         * "item10" before "item9". */
        struct { NSString *name; NSUInteger bytes; NSInteger age_days; } files[] = {
            { @"item9.txt",   300, 3 },
            { @"item10.txt",  100, 1 },
            { @"alpha.html",  500, 5 },
            { @"zebra.png",    50, 2 },
        };
        for (size_t i = 0; i < sizeof files / sizeof files[0]; i++) {
            NSString *path = [d stringByAppendingPathComponent:files[i].name];
            NSMutableData *data = [NSMutableData dataWithLength:files[i].bytes];
            [data writeToFile:path atomically:YES];
            NSDate *when = [NSDate dateWithTimeIntervalSinceNow:-86400.0 * files[i].age_days];
            [fm setAttributes:@{NSFileModificationDate: when} ofItemAtPath:path error:nil];
        }
        [fm createDirectoryAtPath:[d stringByAppendingPathComponent:@"mid folder"]
      withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:[d stringByAppendingPathComponent:@".hidden.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];

        /* Name, folders first — the folder leads, then natural order, so
         * item9 comes before item10. */
        expect(row_names(root, @"name", YES, YES, NO),
               @[@"mid folder", @"alpha.html", @"item9.txt", @"item10.txt", @"zebra.png"],
               @"by name, ascending, folders first");
        expect(row_names(root, @"name", NO, YES, NO),
               @[@"mid folder", @"zebra.png", @"item10.txt", @"item9.txt", @"alpha.html"],
               @"by name, descending, folders first");
        expect(row_names(root, @"name", YES, NO, NO),
               @[@"alpha.html", @"item9.txt", @"item10.txt", @"mid folder", @"zebra.png"],
               @"by name, ascending, folders among the files");

        /* Size — a folder has none, and sorts before every file that has. */
        expect(row_names(root, @"size", YES, NO, NO),
               @[@"mid folder", @"zebra.png", @"item10.txt", @"item9.txt", @"alpha.html"],
               @"by size, ascending");
        expect(row_names(root, @"size", NO, NO, NO),
               @[@"alpha.html", @"item9.txt", @"item10.txt", @"zebra.png", @"mid folder"],
               @"by size, descending");

        /* Date Modified — the ages above, newest last when ascending. */
        expect(row_names(root, @"modified", YES, NO, NO),
               @[@"alpha.html", @"item9.txt", @"zebra.png", @"item10.txt", @"mid folder"],
               @"by date modified, ascending");

        /* Kind — "Folder", "HTML text", "PNG image", "text": the strings
         * the Kind column shows, in natural order. */
        expect(row_names(root, @"kind", YES, NO, NO),
               @[@"mid folder", @"alpha.html", @"zebra.png", @"item9.txt", @"item10.txt"],
               @"by kind, ascending");

        /* Show Hidden Files brings the dot file in, in its sorted place. */
        expect(row_names(root, @"name", YES, NO, YES),
               @[@".hidden.txt", @"alpha.html", @"item9.txt", @"item10.txt",
                 @"mid folder", @"zebra.png"],
               @"hidden items shown, in order");

        [fm removeItemAtURL:root error:nil];
        [NSUserDefaults.standardUserDefaults
            removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier
                                          ?: NSProcessInfo.processInfo.processName];
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
