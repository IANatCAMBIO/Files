/*
 * sync_domain_test — checks that files_sync_root places a path in the right
 * File Provider sync domain, the decision the copy engine rests on when it
 * refuses to treat a move into iCloud Drive, Google Drive or an SSH mount
 * as a same-volume rename. Pure path logic, so no provider has to be
 * mounted and nothing is written. Run with `make test`; prints one line per
 * check and exits non-zero on failure.
 */
#import <Cocoa/Cocoa.h>
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
 * root_of — files_sync_root for a path, as a string for comparison.
 *
 * Inputs:
 *   path — absolute path to classify
 *
 * Output: the domain root's path, or nil if the path is in no domain.
 */
static NSString *
root_of(NSString *path)
{
    return files_sync_root([NSURL fileURLWithPath:path]).URLByStandardizingPath.path;
}

int
main(void)
{
    @autoreleasepool {
        NSString *home  = files_home_url().URLByStandardizingPath.path;
        NSString *cloud = files_cloud_storage_url().URLByStandardizingPath.path;

        check([cloud isEqualToString:[home stringByAppendingPathComponent:
                                      @"Library/CloudStorage"]],
              @"cloud storage folder is ~/Library/CloudStorage");

        /* Ordinary local paths are in no domain. */
        check(root_of(@"/Users") == nil, @"/Users is in no sync domain");
        check(root_of([home stringByAppendingPathComponent:@"Music/song.mp3"]) == nil,
              @"a file in ~/Music is in no sync domain");
        check(files_sync_root(nil) == nil, @"a nil URL is in no sync domain");

        /* ~/Library/CloudStorage itself is the container, not a domain. */
        check(root_of(cloud) == nil, @"the CloudStorage folder itself is no domain");

        /* Each account folder under it is one domain, and everything
         * inside it belongs to that one. */
        NSString *acct = [cloud stringByAppendingPathComponent:@"Mountaineer-ian@burton"];
        check([root_of(acct) isEqualToString:acct],
              @"an account folder is its own domain root");
        check([root_of([acct stringByAppendingPathComponent:@"Music from Mac/a.mp3"])
                  isEqualToString:acct],
              @"a file inside an account folder maps to that account's root");
        check([root_of([acct stringByAppendingPathComponent:@"a/b/c/d/e.txt"])
                  isEqualToString:acct],
              @"a deeply nested file maps to the account's root");

        /* Two accounts are two domains: a move between them is a real
         * transfer between servers, not a rename. */
        NSString *other = [cloud stringByAppendingPathComponent:@"MountGoogle-Work"];
        check(![root_of([other stringByAppendingPathComponent:@"x.txt"])
                   isEqualToString:acct],
              @"two account folders are two different domains");

        /* Components are matched whole, so a sibling whose name merely
         * starts with the container's path is not inside it. */
        check(root_of([cloud stringByAppendingString:@"Extra/x.txt"]) == nil,
              @"a path that only shares a name prefix is outside the container");

        /* Relative traversal is resolved before the comparison. */
        check([root_of([acct stringByAppendingPathComponent:@"sub/../kept.txt"])
                  isEqualToString:acct],
              @"\"..\" is resolved before the domain is decided");
        check(root_of([acct stringByAppendingPathComponent:@"../.."]) == nil,
              @"\"..\" out of the container leaves the domain");

        /* iCloud Drive is one domain in its entirety, when it is set up. */
        NSURL *icloud = files_icloud_drive_url();
        if (icloud) {
            NSString *ic = icloud.URLByStandardizingPath.path;
            check([root_of(ic) isEqualToString:ic], @"iCloud Drive is its own domain root");
            check([root_of([ic stringByAppendingPathComponent:@"Docs/notes.txt"])
                      isEqualToString:ic],
                  @"a file in iCloud Drive maps to the iCloud Drive root");
            check(![root_of([ic stringByAppendingPathComponent:@"x"]) isEqualToString:acct],
                  @"iCloud Drive and an SSH account are different domains");
        } else {
            printf("ok   iCloud Drive is not set up on this Mac; its checks are skipped\n");
        }

        /* The display name is what the log and the Finder show. */
        check([files_display_name([NSURL fileURLWithPath:acct])
                  isEqualToString:@"Mountaineer-ian@burton"],
              @"an account folder's display name is its own name");

        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
