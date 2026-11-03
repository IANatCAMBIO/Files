/*
 * listing_test — checks that the batched listing (files_list_items, which
 * reads a folder with getattrlistbulk) tells the file list exactly what
 * Foundation's own prefetched resource values would have told it, for
 * every awkward kind of item a folder can hold: packages, application
 * bundles, symbolic links, dot files, hidden-flagged files, items with no
 * extension, items with an icon of their own. Every difference here would
 * be a wrong row in the window. Run with `make test`; prints one line per
 * check and exits non-zero on failure.
 */
#import <Cocoa/Cocoa.h>
#import "dir_listing.h"
#import "util.h"
#include <sys/stat.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/param.h>

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
 * same — compares two values that may each be nil.
 *
 * Inputs:
 *   a, b — values to compare
 *
 * Output: YES if both are nil or they are equal.
 */
static BOOL
same(id a, id b)
{
    return (a == nil && b == nil) || [a isEqual:b];
}

/*
 * compare_item — checks one record against the resource values Foundation
 * reports for the same item, field by field.
 *
 * Inputs:
 *   item — the record the batched listing produced
 */
static void
compare_item(files_item *item)
{
    NSURL *url = [NSURL fileURLWithPath:item.path];
    NSDictionary<NSURLResourceKey, id> *v = [url resourceValuesForKeys:@[
        NSURLNameKey, NSURLFileSizeKey, NSURLIsDirectoryKey, NSURLIsPackageKey,
        NSURLIsApplicationKey, NSURLIsSymbolicLinkKey, NSURLTypeIdentifierKey,
        NSURLLocalizedTypeDescriptionKey, NSURLContentModificationDateKey,
        NSURLCreationDateKey, NSURLIsHiddenKey, NSURLIsVolumeKey] error:nil];

    NSString *n = item.name;

    /* A volume root is the one item whose name the listing does not take
     * from Foundation. Foundation answers with the mounted volume's name
     * ("Macintosh HD" for /.nofollow, where the startup volume appears a
     * second time); the file list shows the name the folder actually
     * holds, because that is the name in the path, and a dot-prefixed one
     * stays hidden with it. Everything else about the item — its dates,
     * mode, type and kind — still has to agree, which is what the firmlink
     * and mount-point re-read is for. */
    BOOL is_volume = [v[NSURLIsVolumeKey] boolValue];
    if (is_volume) {
        check([item.name isEqualToString:url.lastPathComponent],
              [NSString stringWithFormat:@"%@: a volume keeps the folder's own name "
                                          "(Foundation says %@)", n, v[NSURLNameKey]]);
    } else {
        check(same(item.name, v[NSURLNameKey]),
              [NSString stringWithFormat:@"%@: name", n]);
    }
    /* Hidden by a dot in the name the folder holds, or by the item's own
     * flag (/dev carries UF_HIDDEN without a dot). */
    check(item.is_hidden == ([item.name hasPrefix:@"."] ||
                             [v[NSURLIsHiddenKey] boolValue]),
          [NSString stringWithFormat:@"%@: is hidden", n]);
    check(item.is_dir == [v[NSURLIsDirectoryKey] boolValue],
          [NSString stringWithFormat:@"%@: is a directory", n]);
    check(item.is_symlink == [v[NSURLIsSymbolicLinkKey] boolValue],
          [NSString stringWithFormat:@"%@: is a symbolic link", n]);
    check(item.is_package == [v[NSURLIsPackageKey] boolValue],
          [NSString stringWithFormat:@"%@: is a package", n]);
    check(item.is_application == [v[NSURLIsApplicationKey] boolValue],
          [NSString stringWithFormat:@"%@: is an application", n]);
    check(same(item.type.identifier, v[NSURLTypeIdentifierKey]),
          [NSString stringWithFormat:@"%@: type (%@ / %@)", n,
              item.type.identifier, v[NSURLTypeIdentifierKey]]);
    check(same(item.kind, v[NSURLLocalizedTypeDescriptionKey]),
          [NSString stringWithFormat:@"%@: kind (%@ / %@)", n,
              item.kind, v[NSURLLocalizedTypeDescriptionKey]]);

    /* Size: Foundation reports none for a directory, and so does the
     * record, as -1. */
    NSNumber *size = v[NSURLFileSizeKey];
    check(size ? (item.size == size.longLongValue) : (item.size == -1),
          [NSString stringWithFormat:@"%@: size (%lld / %@)", n, item.size, size]);

    /* Dates to the second: the records keep whole seconds, which is all
     * the list's date formatters show. */
    NSDate *mod = v[NSURLContentModificationDateKey];
    NSDate *cre = v[NSURLCreationDateKey];
    check(fabs(item.modified.timeIntervalSince1970 - mod.timeIntervalSince1970) < 1.0,
          [NSString stringWithFormat:@"%@: modified", n]);
    check(fabs(item.created.timeIntervalSince1970 - cre.timeIntervalSince1970) < 1.0,
          [NSString stringWithFormat:@"%@: created", n]);

    /* Mode, against the system call the Permissions column would need. */
    struct stat st;
    lstat(item.path.fileSystemRepresentation, &st);
    check(item.mode == st.st_mode,
          [NSString stringWithFormat:@"%@: mode (0%o / 0%o)", n, item.mode, st.st_mode]);

    check(item.has_custom_icon == files_has_custom_icon(url),
          [NSString stringWithFormat:@"%@: has an icon of its own", n]);
}

/*
 * main — builds a folder of awkward items and compares every record.
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
                           [@"files-listing-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *d = root.path;

        void (^write_file)(NSString *, NSString *) = ^(NSString *name, NSString *text) {
            [text writeToFile:[d stringByAppendingPathComponent:name]
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
        };
        void (^make_dir)(NSString *) = ^(NSString *name) {
            [fm createDirectoryAtPath:[d stringByAppendingPathComponent:name]
          withIntermediateDirectories:YES attributes:nil error:nil];
        };

        write_file(@"doc.txt",      @"text");
        write_file(@"page.html",    @"<p>");
        write_file(@"second.txt",   @"more text");   /* shares doc.txt's group */
        write_file(@"noext",        @"no extension");
        write_file(@".dotfile",     @"hidden by name");
        /* Three extensionless files that resolve to three different types.
         * They share an empty extension, so a listing that groups items by
         * extension alone gives all three whichever type it read first —
         * the wrong Kind, the wrong Kind sort and the wrong icon for two of
         * them. "noext" above is a fourth; it resolves to public.data. */
        write_file(@"Makefile",     @"all:\n\techo hi\n");   /* public.make-source */
        write_file(@"LICENSE",      @"BSD 3-Clause\n");      /* public.plain-text */
        [[NSData dataWithBytes:"\x7f\x45\x4c\x46\x00\x01\x02\x03" length:8]
            writeToFile:[d stringByAppendingPathComponent:@"blob"] atomically:YES];
        write_file(@"UPPER.TXT",    @"extension case");
        write_file(@"spaced name.txt", @"spaces");
        write_file(@"ünïcode–ñ.txt", @"unicode");
        write_file(@"big.bin",      @"");
        write_file(@"flagged.txt",  @"hidden by flag");
        chflags([d stringByAppendingPathComponent:@"flagged.txt"].fileSystemRepresentation,
                UF_HIDDEN);
        write_file(@"locked.txt",   @"immutable");
        write_file(@"odd-perms.txt", @"perms");
        chmod([d stringByAppendingPathComponent:@"odd-perms.txt"].fileSystemRepresentation, 0741);

        make_dir(@"plain folder");
        make_dir(@".hidden folder");
        make_dir(@"note.rtfd");                       /* a package by extension */
        make_dir(@"Bundle.app/Contents/MacOS");       /* an application bundle */
        write_file(@"Bundle.app/Contents/Info.plist", @"<plist/>");
        make_dir(@"second.rtfd");                     /* shares note.rtfd's group */

        [fm createSymbolicLinkAtPath:[d stringByAppendingPathComponent:@"link to doc"]
                 withDestinationPath:[d stringByAppendingPathComponent:@"doc.txt"] error:nil];
        [fm createSymbolicLinkAtPath:[d stringByAppendingPathComponent:@"link to folder"]
                 withDestinationPath:[d stringByAppendingPathComponent:@"plain folder"] error:nil];
        [fm createSymbolicLinkAtPath:[d stringByAppendingPathComponent:@"broken link"]
                 withDestinationPath:[d stringByAppendingPathComponent:@"nothing here"] error:nil];

        /* Items with icons of their own: a file and a folder. */
        NSImage *art = [[NSImage alloc] initWithSize:NSMakeSize(64.0, 64.0)];
        [art lockFocus];
        [NSColor.systemOrangeColor setFill];
        NSRectFill(NSMakeRect(0.0, 0.0, 64.0, 64.0));
        [art unlockFocus];
        write_file(@"iconned.txt", @"has an icon");
        files_set_custom_icon([NSURL fileURLWithPath:
            [d stringByAppendingPathComponent:@"iconned.txt"]], art, NULL);
        make_dir(@"iconned folder");
        files_set_custom_icon([NSURL fileURLWithPath:
            [d stringByAppendingPathComponent:@"iconned folder"]], art, NULL);

        NSError *err = nil;
        NSArray<files_item *> *items = files_list_items(root, &err);
        check(items != nil, [NSString stringWithFormat:@"the folder lists (%@)", err]);

        /* Every name Foundation sees, the batched listing sees too. */
        NSArray<NSURL *> *expected =
            [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:@[] options:0 error:nil];
        NSMutableSet<NSString *> *want = [NSMutableSet set];
        for (NSURL *u in expected) [want addObject:u.lastPathComponent];
        NSMutableSet<NSString *> *got = [NSMutableSet set];
        for (files_item *it in items) [got addObject:it.name];
        /* The icon of a folder is a file inside it, not an entry here. */
        check([got isEqualToSet:want],
              [NSString stringWithFormat:@"the same %lu entries (missing %@, extra %@)",
                  (unsigned long)want.count,
                  [want.allObjects filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(id o, id _) {
                          return ![got containsObject:o]; }]],
                  [got.allObjects filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(id o, id _) {
                          return ![want containsObject:o]; }]]]);

        for (files_item *item in items) compare_item(item);

        /* The scattered-paths path (search results) must agree with the
         * folder pass item for item. */
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (files_item *it in items) [urls addObject:it.url];
        NSArray<files_item *> *scattered = files_items_at_urls(urls);
        check(scattered.count == items.count, @"one record per URL, read one at a time");
        BOOL agree = YES;
        for (NSUInteger i = 0; i < MIN(scattered.count, items.count); i++) {
            files_item *a = items[i], *b = scattered[i];
            if (!same(a.name, b.name) || a.is_dir != b.is_dir || a.size != b.size ||
                a.mode != b.mode || a.is_package != b.is_package ||
                a.is_hidden != b.is_hidden || a.has_custom_icon != b.has_custom_icon ||
                !same(a.type.identifier, b.type.identifier) || !same(a.kind, b.kind) ||
                fabs([a.modified timeIntervalSinceDate:b.modified]) >= 1.0 ||
                fabs([a.created timeIntervalSinceDate:b.created]) >= 1.0) {
                agree = NO;
                printf("     differs: %s\n", a.name.UTF8String);
            }
        }
        check(agree, @"reading one at a time gives the same answers");

        /* The startup volume's root, where the dates used to be wrong: its
         * firmlinked folders (Library, Users, Applications, private, opt,
         * Volumes, cores) and its mount points (/dev) are reported by
         * getattrlistbulk as the directory standing in the way rather than
         * the one it stands for, so each has to be read again by path.
         * Nothing but a real volume root exercises this, which is why the
         * check is made here rather than against the fixture. */
        NSURL *vol_root = [NSURL fileURLWithPath:@"/" isDirectory:YES];
        NSArray<files_item *> *root_items = files_list_items(vol_root, NULL);
        check(root_items.count > 0, @"the startup volume's root lists");
        for (files_item *item in root_items) compare_item(item);

        /* A folder that cannot be read fails rather than coming back empty. */
        NSURL *missing = [root URLByAppendingPathComponent:@"not here at all"];
        err = nil;
        check(files_list_items(missing, &err) == nil && err != nil,
              @"a folder that is not there reports an error");
        check(files_item_at_url(missing) == nil, @"and has no record of its own");

        [fm removeItemAtURL:root error:nil];
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
