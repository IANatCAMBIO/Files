/*
 * default_apps_test — checks the file-type list behind Files ▸ Set Default
 * Apps…: that the scan of this Mac's applications and of macOS's own type
 * declarations finds the common types, that every type it lists can be
 * named by an extension, that no type is listed twice, and that an
 * extension a declared type covers is never also listed under a dynamic
 * type of its own (the row model depends on it: one row per content type,
 * listing every extension that type covers). Also checks how an
 * application's name is written. Run with `make test`; prints one line per
 * check and exits non-zero on failure.
 *
 * Read-only: it reads Info.plists and the LaunchServices database and
 * changes no default.
 */
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "default_apps_panel.h"
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
 * type_for_identifier — the listed type with an identifier.
 *
 * Inputs:
 *   types      — the listed types
 *   identifier — the identifier to look for
 *
 * Output: the type, or nil if it is not listed.
 */
static UTType *
type_for_identifier(NSArray<UTType *> *types, NSString *identifier)
{
    for (UTType *type in types) {
        if ([type.identifier isEqualToString:identifier]) return type;
    }
    return nil;
}

int
main(void)
{
    @autoreleasepool {
        NSArray<UTType *> *types = files_default_app_types();

        /* The scan found something worth showing: every Mac declares
         * several hundred types in CoreTypes.bundle alone. */
        check(types.count > 200,
              ([NSString stringWithFormat:@"the scan lists %lu file types",
                (unsigned long)types.count]));

        /* Every row can be named by an extension, and no type twice. */
        NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
        NSMutableSet<NSString *> *duplicates  = [NSMutableSet set];
        NSUInteger extensionless = 0;
        for (UTType *type in types) {
            if (((NSArray *)type.tags[UTTagClassFilenameExtension]).count == 0) extensionless++;
            if ([identifiers containsObject:type.identifier]) {
                [duplicates addObject:type.identifier];
            }
            [identifiers addObject:type.identifier];
        }
        check(extensionless == 0, @"every listed type has a filename extension");
        check(duplicates.count == 0,
              ([NSString stringWithFormat:@"no type is listed twice (%@)",
                duplicates.count ? duplicates.anyObject : @"none"]));

        /* The types a user would look for first are there, with the
         * extensions that share them listed together — the reason a row is
         * a type and not an extension. */
        for (NSString *identifier in @[@"public.jpeg", @"public.plain-text", @"com.adobe.pdf",
                                       @"public.png", @"public.html"]) {
            check(type_for_identifier(types, identifier) != nil,
                  ([NSString stringWithFormat:@"%@ is listed", identifier]));
        }
        UTType *jpeg = type_for_identifier(types, @"public.jpeg");
        NSArray<NSString *> *jpeg_extensions = jpeg.tags[UTTagClassFilenameExtension];
        check([jpeg_extensions containsObject:@"jpg"] && [jpeg_extensions containsObject:@"jpeg"],
              @"public.jpeg's row covers both jpg and jpeg");

        /* Every listed type is one a real file can be: at least one of its
         * extensions resolves to it, as a plain file or as a package. A
         * type nothing resolves to would be a row whose default could be
         * set and never take effect. */
        NSMutableArray<NSString *> *unreachable = [NSMutableArray array];
        for (UTType *type in types) {
            BOOL reached = NO;
            for (NSString *extension in type.tags[UTTagClassFilenameExtension]) {
                UTType *plain   = [UTType typeWithFilenameExtension:extension];
                UTType *package = [UTType typeWithFilenameExtension:extension
                                                   conformingToType:UTTypePackage];
                if ([plain isEqual:type] || [package isEqual:type]) { reached = YES; break; }
            }
            if (!reached) [unreachable addObject:type.identifier];
        }
        check(unreachable.count == 0,
              ([NSString stringWithFormat:@"every listed type is one a file resolves to (%@)",
                unreachable.count ? unreachable.firstObject : @"none"]));

        /* Types that exist only on packages are found, which resolving an
         * extension as a plain file alone would have missed. */
        UTType *rtfd = [UTType typeWithFilenameExtension:@"rtfd" conformingToType:UTTypePackage];
        check(!rtfd.isDynamic && type_for_identifier(types, rtfd.identifier) != nil,
              ([NSString stringWithFormat:@"the package type for .rtfd (%@) is listed",
                rtfd.identifier]));

        /* A dynamic type stands in only for an extension no declared type
         * covers, so no extension is listed twice. */
        NSMutableDictionary<NSString *, UTType *> *owner = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *clashes = [NSMutableArray array];
        for (UTType *type in types) {
            for (NSString *extension in type.tags[UTTagClassFilenameExtension]) {
                NSString *key = extension.lowercaseString;
                UTType *seen  = owner[key];
                if (seen && (seen.isDynamic || type.isDynamic)) {
                    [clashes addObject:[NSString stringWithFormat:@".%@ (%@ and %@)",
                                        key, seen.identifier, type.identifier]];
                }
                if (!seen) owner[key] = type;
            }
        }
        check(clashes.count == 0,
              ([NSString stringWithFormat:@"no extension is listed under a dynamic type as well"
                " (%@)", clashes.count ? clashes.firstObject : @"none"]));

        /* An application is named without ".app", and a type nothing opens
         * reads "None" rather than an empty cell. */
        NSURL *finder = [NSURL fileURLWithPath:@"/System/Library/CoreServices/Finder.app"];
        check([files_app_display_name(finder) isEqualToString:@"Finder"],
              @"an application is named without \".app\"");
        check([files_app_display_name(nil) isEqualToString:@"None"],
              @"a type no application opens reads \"None\"");

        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
