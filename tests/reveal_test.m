/*
 * reveal_test — checks how a reveal ("Show in Finder" from another app, a
 * freshly created item) finds the rows it has to select: files_paths_named
 * matches the requested names against the listing's own URLs, so the paths
 * it returns are the ones the file list selects by, even when the folder
 * was reached through a symbolic link. Run with `make test`; prints one
 * line per check and exits non-zero on failure.
 */
#import <Cocoa/Cocoa.h>
#import "browser_view.h"

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
 * listing — a folder listing to match against, as the file manager hands
 * one back: every item under the folder's own path.
 *
 * Inputs:
 *   dir   — folder path
 *   names — file names within it
 *
 * Output: file URLs, one per name.
 */
static NSArray<NSURL *> *
listing(NSString *dir, NSArray<NSString *> *names)
{
    NSMutableArray<NSURL *> *items = [NSMutableArray array];
    for (NSString *name in names) {
        [items addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]]];
    }
    return items;
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
        NSArray<NSURL *> *items = listing(@"/private/tmp/reveal",
                                          @[@"one.txt", @"two.txt", @"three.txt"]);

        NSSet<NSString *> *one = files_paths_named(items, [NSSet setWithObject:@"two.txt"]);
        check([one isEqualToSet:[NSSet setWithObject:@"/private/tmp/reveal/two.txt"]],
              @"a requested name gives that item's own path");

        NSSet<NSString *> *two = files_paths_named(items, ([NSSet setWithObjects:@"one.txt",
                                                            @"three.txt", nil]));
        check(two.count == 2 && [two containsObject:@"/private/tmp/reveal/one.txt"] &&
              [two containsObject:@"/private/tmp/reveal/three.txt"],
              @"several names give several paths");

        /* The reveal asks by name only, so it still finds the item when the
         * folder was reached through a symbolic link (/tmp) and the listing
         * came back resolved (/private/tmp). Building the path from the
         * folder the user navigated to would match nothing here. */
        NSString *navigated = @"/tmp/reveal/two.txt";
        check(![[files_paths_named(items, [NSSet setWithObject:@"two.txt"]) anyObject]
                isEqualToString:navigated],
              @"the resolved path is returned, not the one navigated to");
        check(files_paths_named(listing(@"/tmp/reveal", @[@"two.txt"]),
                                [NSSet setWithObject:@"two.txt"]).count == 1,
              @"a listing that is not resolved is matched just the same");

        check(files_paths_named(items, [NSSet setWithObject:@"gone.txt"]).count == 0,
              @"an item that is no longer there selects nothing");
        check(files_paths_named(items, nil).count == 0,
              @"no names select nothing");
        check(files_paths_named(@[], [NSSet setWithObject:@"one.txt"]).count == 0,
              @"an empty folder selects nothing");

        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
