#import "util.h"
#include <fcntl.h>
#include <unistd.h>

NSString * const files_pref_show_hidden     = @"files.show_hidden_files";
NSString * const files_pref_auto_fit        = @"files.auto_fit_columns";
NSString * const files_pref_hash_validation = @"files.copy.hash_validation";
NSString * const files_pref_show_hashes     = @"files.show_hashes";
NSString * const files_pref_large_rows      = @"files.large_rows";
NSString * const files_pref_simple_copies   = @"files.simple_copies";
NSString * const files_pref_archive_reveal  = @"files.archive_reveal";

/*
 * files_register_defaults — registers non-NO preference defaults.
 * Inputs/output are documented in util.h.
 */
void
files_register_defaults(void)
{
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        files_pref_simple_copies: @YES,
    }];
}

/*
 * files_directory_url — standard user folder URL (Applications: local domain).
 * Inputs/output are documented in util.h.
 */
NSURL *
files_directory_url(NSSearchPathDirectory dir)
{
    NSSearchPathDomainMask domain = (dir == NSApplicationDirectory)
                                    ? NSLocalDomainMask : NSUserDomainMask;
    return [NSFileManager.defaultManager URLsForDirectory:dir inDomains:domain].firstObject;
}

/*
 * files_home_url — current user's home folder URL.
 * Inputs/output are documented in util.h.
 */
NSURL *
files_home_url(void)
{
    return NSFileManager.defaultManager.homeDirectoryForCurrentUser;
}

/*
 * files_same_path — path equality after standardizing both URLs.
 * Inputs/output are documented in util.h.
 */
BOOL
files_same_path(NSURL *a, NSURL *b)
{
    if (!a || !b) return NO;
    return [a.URLByStandardizingPath.path isEqualToString:b.URLByStandardizingPath.path];
}

/*
 * files_has_full_disk_access — tries to open the TCC database read-only.
 * Inputs/output are documented in util.h.
 */
BOOL
files_has_full_disk_access(void)
{
    NSString *db = [NSHomeDirectory() stringByAppendingPathComponent:
                    @"Library/Application Support/com.apple.TCC/TCC.db"];
    int fd = open(db.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

/*
 * run_defaults — runs /usr/bin/defaults with args, optionally capturing
 * stdout.
 *
 * Inputs:
 *   args — arguments after "defaults"
 *   out  — receives stdout if non-NULL
 *
 * Output: YES if it ran and exited 0.
 */
static BOOL
run_defaults(NSArray<NSString *> *args, NSData **out)
{
    NSTask *task        = [[NSTask alloc] init];
    task.executableURL  = [NSURL fileURLWithPath:@"/usr/bin/defaults"];
    task.arguments      = args;
    task.standardError  = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe        = [NSPipe pipe];
    task.standardOutput = pipe;
    if (![task launchAndReturnError:nil]) return NO;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (out) *out = data;
    return task.terminationStatus == 0;
}

/*
 * files_sync_bool_prefs — read once, write only differences.
 * Inputs/output are documented in util.h.
 */
BOOL
files_sync_bool_prefs(NSString *domain, NSArray<NSString *> *keys, BOOL value)
{
    NSData *data = nil;
    if (!run_defaults(@[@"export", domain, @"-"], &data)) return NO;
    NSDictionary *current = [NSPropertyListSerialization propertyListWithData:data
                                                                      options:0
                                                                       format:NULL
                                                                        error:nil];
    if (![current isKindOfClass:NSDictionary.class]) return NO;

    BOOL ok = YES;
    for (NSString *key in keys) {
        id have = current[key];
        if ([have isKindOfClass:NSNumber.class] && [have boolValue] == value) continue;
        ok = run_defaults(@[@"write", domain, key, @"-bool", value ? @"true" : @"false"], NULL) && ok;
    }
    return ok;
}

/*
 * files_format_bytes — Finder-style byte count via one shared formatter.
 * Inputs/output are documented in util.h.
 */
NSString *
files_format_bytes(int64_t bytes)
{
    static NSByteCountFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSByteCountFormatter alloc] init];
        fmt.countStyle = NSByteCountFormatterCountStyleFile;
    });
    return [fmt stringFromByteCount:bytes];
}

/*
 * files_format_rate — byte count plus "/s".
 * Inputs/output are documented in util.h.
 */
NSString *
files_format_rate(double bytes_per_sec)
{
    int64_t bps = bytes_per_sec > 0 ? (int64_t)bytes_per_sec : 0;
    return [files_format_bytes(bps) stringByAppendingString:@"/s"];
}

/*
 * files_format_date — date via one of two shared formatters.
 * Inputs/output are documented in util.h.
 */
NSString *
files_format_date(NSDate *date, NSDateFormatterStyle date_style)
{
    static NSDateFormatter *short_fmt, *medium_fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        short_fmt  = [[NSDateFormatter alloc] init];
        short_fmt.dateStyle  = NSDateFormatterShortStyle;
        short_fmt.timeStyle  = NSDateFormatterShortStyle;
        medium_fmt = [[NSDateFormatter alloc] init];
        medium_fmt.dateStyle = NSDateFormatterMediumStyle;
        medium_fmt.timeStyle = NSDateFormatterShortStyle;
    });
    if (!date) return @"—";
    NSDateFormatter *fmt = (date_style == NSDateFormatterShortStyle) ? short_fmt : medium_fmt;
    return [fmt stringFromDate:date];
}

/*
 * files_show_error — error alert as a sheet (or app-modal if no window).
 * Inputs/output are documented in util.h.
 */
void
files_show_error(NSString *title, NSError *err, NSWindow *window)
{
    NSAlert *alert        = [[NSAlert alloc] init];
    alert.messageText     = title;
    alert.informativeText = err.localizedDescription ?: @"Unknown error";
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        [alert runModal];
    }
}
