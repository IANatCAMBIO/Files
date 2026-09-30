#import "util.h"

NSString * const files_pref_show_hidden     = @"files.show_hidden_files";
NSString * const files_pref_auto_fit        = @"files.auto_fit_columns";
NSString * const files_pref_hash_validation = @"files.copy.hash_validation";
NSString * const files_pref_show_hashes     = @"files.show_hashes";
NSString * const files_pref_large_rows      = @"files.large_rows";
NSString * const files_pref_simple_copies   = @"files.simple_copies";

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
