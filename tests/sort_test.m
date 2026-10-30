/*
 * sort_test — checks the default sort order (Preferences ▸ View ▸ Default
 * sort): which columns can be sorted by at all, which of them a default
 * order may name, the direction wording, and that a missing, stale or
 * misspelled preference still resolves to a column the list really sorts
 * by. Run with `make test`; prints one line per check and exits non-zero
 * on failure.
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
 * column_offered — whether files_sort_columns() offers a column.
 *
 * Inputs:
 *   col_id — column identifier
 *
 * Output: YES if the Default sort menu can name it.
 */
static BOOL
column_offered(NSString *col_id)
{
    for (NSArray<NSString *> *column in files_sort_columns()) {
        if ([column[1] isEqualToString:col_id]) return YES;
    }
    return NO;
}

int
main(void)
{
    @autoreleasepool {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        files_register_defaults();

        /* Every offered column has a title and an identifier, and nothing
         * is offered twice. */
        NSArray<NSArray<NSString *> *> *columns = files_sort_columns();
        check(columns.count > 0, @"Default sort offers at least one column");
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        BOOL well_formed = YES;
        for (NSArray<NSString *> *column in columns) {
            if (column.count != 2 || column[0].length == 0 || column[1].length == 0) well_formed = NO;
            if (column.count == 2) [seen addObject:column[1]];
        }
        check(well_formed, @"every offered column is a title and an identifier");
        check(seen.count == columns.count, @"no column is offered twice");

        /* A header click sorts by every column with a value of its own,
         * and by nothing else. */
        check(files_column_sorts(@"name") && files_column_sorts(@"size") &&
              files_column_sorts(@"kind") && files_column_sorts(@"modified") &&
              files_column_sorts(@"created") && files_column_sorts(@"git"),
              @"Name, Size, Kind, both dates and Git sort on a header click");
        check(!files_column_sorts(@"perms") && !files_column_sorts(@"comment"),
              @"Permissions and Comment do not sort at all");
        check(!files_column_sorts(@"gone") && !files_column_sorts(@""),
              @"an identifier that is not a column does not sort");

        /* A default order may name the sortable columns bar Git. */
        check(column_offered(@"name") && column_offered(@"size") &&
              column_offered(@"kind") && column_offered(@"modified") &&
              column_offered(@"created"),
              @"Name, Size, Kind and both dates are offered as defaults");
        check(!column_offered(@"perms") && !column_offered(@"comment") &&
              !column_offered(@"git"),
              @"Permissions, Comment and Git are not offered as defaults");

        /* The direction wording follows what the column holds. */
        check([files_sort_order_titles(@"created") isEqualToArray:@[@"Oldest first", @"Newest first"]],
              @"dates read oldest/newest first");
        check([files_sort_order_titles(@"modified") isEqualToArray:
               files_sort_order_titles(@"created")],
              @"both date columns read the same");
        check([files_sort_order_titles(@"size") isEqualToArray:@[@"Smallest first", @"Largest first"]],
              @"sizes read smallest/largest first");
        check(files_sort_order_titles(@"name").count == 2 &&
              files_sort_order_titles(@"perms").count == 2,
              @"a column with no wording of its own still has two directions");

        /* The shipped default: Date Modified, newest first — Date Created
         * would be right too, but its column is hidden by default. */
        [ud removeObjectForKey:files_pref_sort_column];
        [ud removeObjectForKey:files_pref_sort_ascending];
        check([files_sort_default_column() isEqualToString:@"modified"],
              @"Files sorts by Date Modified until the preference is set");
        check(![ud boolForKey:files_pref_sort_ascending],
              @"and newest first");
        check([ud boolForKey:files_pref_folders_first],
              @"folders come before files until the preference is set");

        /* What a stale or hand-edited preference resolves to: never a
         * column no header shows an arrow for. */
        [ud setObject:@"created" forKey:files_pref_sort_column];
        check([files_sort_default_column() isEqualToString:@"created"],
              @"a column that is offered is used");
        for (NSString *stale in @[@"perms", @"comment", @"git", @"gone", @""]) {
            [ud setObject:stale forKey:files_pref_sort_column];
            check([files_sort_default_column() isEqualToString:@"modified"],
                  ([NSString stringWithFormat:@"\"%@\" falls back to Date Modified", stale]));
        }

        [ud removePersistentDomainForName:NSProcessInfo.processInfo.processName];

        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
