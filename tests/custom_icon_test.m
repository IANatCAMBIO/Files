/*
 * custom_icon_test — exercises the custom-icon pair behind the icon well in
 * Get Info (files_set_custom_icon / files_has_custom_icon in util.m) against
 * real files in a scratch folder: an icon written and read back, reverted,
 * and the two shapes it takes on disk — a resource fork on a file, an
 * "Icon\r" file inside a folder. Run with `make test`; prints one line per
 * check and exits non-zero on failure.
 */
#import <Cocoa/Cocoa.h>
#import "util.h"
#include <sys/xattr.h>
#include <sys/stat.h>

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
 * test_icon — a plain coloured square to use as an icon.
 *
 * Output: a valid NSImage.
 */
static NSImage *
test_icon(void)
{
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(128.0, 128.0)];
    [img lockFocus];
    [NSColor.systemTealColor setFill];
    NSRectFill(NSMakeRect(0.0, 0.0, 128.0, 128.0));
    [img unlockFocus];
    return img;
}

/*
 * has_xattr — whether an item carries a named extended attribute.
 *
 * Inputs:
 *   url  — item to read
 *   name — attribute name
 *
 * Output: YES if the attribute is present.
 */
static BOOL
has_xattr(NSURL *url, const char *name)
{
    return getxattr(url.fileSystemRepresentation, name, NULL, 0, 0, XATTR_NOFOLLOW) >= 0;
}

/*
 * main — runs the checks.
 *
 * Output: 0 when every check passed, 1 otherwise.
 */
int
main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                       URLByAppendingPathComponent:
                           [@"files-icon-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];

        NSImage *icon = test_icon();

        /* A file: no icon of its own to start with, then one, then none. */
        NSURL *file = [root URLByAppendingPathComponent:@"note.txt"];
        [@"note" writeToURL:file atomically:NO encoding:NSUTF8StringEncoding error:nil];
        check(!files_has_custom_icon(file), @"a new file has no icon of its own");

        NSError *err = nil;
        check(files_set_custom_icon(file, icon, &err),
              [NSString stringWithFormat:@"a file takes a custom icon (%@)", err]);
        check(files_has_custom_icon(file), @"the file now reads as having its own icon");
        check(has_xattr(file, "com.apple.ResourceFork"),
              @"the icon is stored in the file's resource fork");

        check(files_set_custom_icon(file, nil, &err),
              [NSString stringWithFormat:@"the file's icon reverts (%@)", err]);
        check(!files_has_custom_icon(file), @"the reverted file has no icon of its own");

        /* A folder: the icon becomes a file inside it. */
        NSURL *dir = [root URLByAppendingPathComponent:@"folder"];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:NO attributes:nil error:nil];
        NSURL *icon_file = [dir URLByAppendingPathComponent:@"Icon\r"];
        check(!files_has_custom_icon(dir), @"a new folder has no icon of its own");

        check(files_set_custom_icon(dir, icon, &err),
              [NSString stringWithFormat:@"a folder takes a custom icon (%@)", err]);
        check(files_has_custom_icon(dir), @"the folder now reads as having its own icon");
        check([fm fileExistsAtPath:icon_file.path], @"the folder's icon is a file inside it");

        check(files_set_custom_icon(dir, nil, &err),
              [NSString stringWithFormat:@"the folder's icon reverts (%@)", err]);
        check(!files_has_custom_icon(dir), @"the reverted folder has no icon of its own");
        check(![fm fileExistsAtPath:icon_file.path], @"reverting removes that file");

        /* What the file lists draw: files of a type share one cached icon,
         * and a file with an icon of its own gets its own instead. */
        NSURL *one = [root URLByAppendingPathComponent:@"one.txt"];
        NSURL *two = [root URLByAppendingPathComponent:@"two.txt"];
        [@"one" writeToURL:one atomically:NO encoding:NSUTF8StringEncoding error:nil];
        [@"two" writeToURL:two atomically:NO encoding:NSUTF8StringEncoding error:nil];
        check(files_icon_for_url(one, 16.0, YES) == files_icon_for_url(two, 16.0, YES),
              @"two files of a type share one cached icon");

        files_set_custom_icon(one, icon, &err);
        check(files_icon_for_url(one, 16.0, YES) != files_icon_for_url(two, 16.0, YES),
              @"a file with its own icon no longer shares its type's");
        check(files_icon_for_url(two, 16.0, YES) ==
              files_icon_for_url([root URLByAppendingPathComponent:@"note.txt"], 16.0, YES),
              @"the files without one still share");

        files_set_custom_icon(one, nil, &err);
        check(files_icon_for_url(one, 16.0, YES) == files_icon_for_url(two, 16.0, YES),
              @"reverting puts the file back on its type's icon");

        /* A symbolic link is read as itself, not as what it points at —
         * the target's icon is the target's. */
        NSURL *linked = [root URLByAppendingPathComponent:@"linked.txt"];
        [@"linked" writeToURL:linked atomically:NO encoding:NSUTF8StringEncoding error:nil];
        files_set_custom_icon(linked, icon, &err);
        NSURL *link = [root URLByAppendingPathComponent:@"link.txt"];
        [fm createSymbolicLinkAtURL:link withDestinationURL:linked error:nil];
        check(files_has_custom_icon(linked), @"the link's target has its own icon");
        check(!files_has_custom_icon(link), @"the link itself does not");

        /* An item that cannot be written: refused, and said to be refused
         * for want of permission — the message the panel shows. */
        NSURL *read_only = [root URLByAppendingPathComponent:@"read-only.txt"];
        [@"ro" writeToURL:read_only atomically:NO encoding:NSUTF8StringEncoding error:nil];
        chmod(read_only.fileSystemRepresentation, 0444);
        err = nil;
        check(!files_set_custom_icon(read_only, icon, &err),
              @"a read-only file refuses a custom icon");
        check(err.code == NSFileWriteNoPermissionError,
              [NSString stringWithFormat:@"and says why (%@)", err.localizedDescription]);
        chmod(read_only.fileSystemRepresentation, 0644);

        /* Not a file at all. */
        err = nil;
        NSURL *remote = [NSURL URLWithString:@"https://example.com/icon.png"];
        check(!files_has_custom_icon(remote), @"a URL that is not a file has no custom icon");
        check(!files_set_custom_icon(remote, icon, &err) && err != nil,
              @"and cannot be given one");

        [fm removeItemAtURL:root error:nil];
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
