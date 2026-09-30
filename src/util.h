#import <Cocoa/Cocoa.h>

/*
 * util — small helpers shared across the app so each exists exactly once:
 * user-defaults keys, well-known folder URLs, size/date formatting, and
 * error alerts.
 */

/* ── NSUserDefaults keys (BOOL preferences) ─────────────────────────────── */

extern NSString * const files_pref_show_hidden;     /* list dotfiles/hidden items */
extern NSString * const files_pref_auto_fit;        /* auto-fit table columns */
extern NSString * const files_pref_hash_validation; /* SHA-256 verify copies */
extern NSString * const files_pref_show_hashes;     /* hashes in Get Info */
extern NSString * const files_pref_large_rows;      /* double-height file rows */
extern NSString * const files_pref_simple_copies;   /* copy/move without the progress panel */
extern NSString * const files_pref_archive_reveal;  /* Archive Utility reveals results in Finder */

/*
 * files_directory_url — returns the current user's URL for a standard folder
 * (NSDesktopDirectory, NSDownloadsDirectory, NSDocumentDirectory,
 * NSTrashDirectory, NSApplicationDirectory with the local domain, …).
 *
 * Inputs:
 *   dir — NSSearchPathDirectory constant
 *
 * Output: folder URL, or nil if the system does not define one.
 */
NSURL *files_directory_url(NSSearchPathDirectory dir);

/*
 * files_home_url — returns the current user's home folder URL.
 *
 * Output: home directory URL (never nil).
 */
NSURL *files_home_url(void);

/*
 * files_same_path — YES if a and b name the same file-system path, ignoring
 * differences NSURL -isEqual: is sensitive to (trailing slash, "..", base URL).
 *
 * Inputs:
 *   a, b — file URLs; either may be nil
 *
 * Output: YES if both are non-nil and their standardized paths match.
 */
BOOL files_same_path(NSURL *a, NSURL *b);

/*
 * files_has_full_disk_access — whether this process has Full Disk Access.
 * macOS has no API for this; the reliable check is whether the user's TCC
 * database (~/Library/Application Support/com.apple.TCC/TCC.db), which only
 * Full Disk Access processes may read, can be opened.
 *
 * Output: YES if Full Disk Access is granted.
 */
BOOL files_has_full_disk_access(void);

/*
 * files_format_bytes — formats a byte count the way Finder does
 * (NSByteCountFormatter, file style, base 1000). Thread-safe.
 *
 * Inputs:
 *   bytes — byte count
 *
 * Output: string such as "12.3 MB".
 */
NSString *files_format_bytes(int64_t bytes);

/*
 * files_format_rate — formats a transfer rate as files_format_bytes + "/s".
 *
 * Inputs:
 *   bytes_per_sec — rate; negative values are treated as 0
 *
 * Output: string such as "85.2 MB/s".
 */
NSString *files_format_rate(double bytes_per_sec);

/*
 * files_format_date — formats a date with a cached NSDateFormatter using
 * date_style for the date part and a short time. Thread-safe.
 *
 * Inputs:
 *   date       — date to format; nil yields "—"
 *   date_style — NSDateFormatterShortStyle or NSDateFormatterMediumStyle
 *                (any other value is treated as medium)
 *
 * Output: formatted string.
 */
NSString *files_format_date(NSDate *date, NSDateFormatterStyle date_style);

/*
 * files_show_error — shows an error alert: as a sheet on window when given,
 * otherwise app-modal. Must be called on the main thread.
 *
 * Inputs:
 *   title  — alert headline, e.g. @"Could not create folder"
 *   err    — error whose localizedDescription becomes the body; may be nil
 *   window — window to attach the sheet to; nil = app-modal alert
 */
void files_show_error(NSString *title, NSError *err, NSWindow *window);
