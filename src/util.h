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
extern NSString * const files_pref_simple_copies;   /* copy/move without the progress panel (default on) */
extern NSString * const files_pref_archive_reveal;  /* Archive Utility reveals results in Finder */
extern NSString * const files_pref_default_viewer;  /* Files replaces Finder as file viewer (default on) */

/*
 * files_register_defaults — registers the default value of every preference
 * whose default is not NO (currently: Simple Copies and Files as the
 * default file viewer on). A value the user
 * has set is never overridden. Call once at launch, before anything reads
 * preferences.
 */
void files_register_defaults(void);

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
 * files_sync_prefs — makes preferences in another app's (or the global)
 * domain hold the given values, using the `defaults` tool (which, unlike
 * CFPreferences, reaches a sandboxed app's container; that needs Full Disk
 * Access). Reads the domain once (`defaults export`) and writes or deletes
 * only the keys that differ, so the common case costs one process and no
 * writes. Blocks; call off the main thread.
 *
 * Values are "wrapped": @[value] means the key should hold value (any
 * property-list object), @[] means the key should be absent. The same form
 * is reported in previous, so passing previous back as values undoes the
 * change.
 *
 * Inputs:
 *   domain   — preferences domain, e.g. @"com.apple.archiveutility" or
 *              @"NSGlobalDomain"
 *   values   — key → wrapped wanted value
 *   previous — if non-nil, receives key → wrapped prior value for every key
 *              that was written or deleted
 *
 * Output: YES if every key now has its wanted value; NO if the domain could
 *         not be read or a write failed (typically: no Full Disk Access).
 */
BOOL files_sync_prefs(NSString *domain, NSDictionary<NSString *, NSArray *> *values,
                      NSMutableDictionary<NSString *, NSArray *> *previous);

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
