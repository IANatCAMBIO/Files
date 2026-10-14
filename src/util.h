#import <Cocoa/Cocoa.h>
#include <stdatomic.h>

/*
 * util — small helpers shared across the app so each exists exactly once:
 * user-defaults keys, well-known folder URLs, size/date formatting, and
 * error alerts.
 */

/* ── NSUserDefaults keys (BOOL preferences) ─────────────────────────────── */

extern NSString * const files_pref_show_hidden;     /* list dotfiles/hidden items */
extern NSString * const files_pref_auto_fit;        /* auto-fit table columns (default on) */
extern NSString * const files_pref_hash_validation; /* SHA-256 verify copies */
extern NSString * const files_pref_show_hashes;     /* hashes in Get Info (Preferences ▸ View) */
extern NSString * const files_pref_large_rows;      /* double-height file rows */
extern NSString * const files_pref_simple_copies;   /* copy/move without the progress panel */
extern NSString * const files_pref_default_viewer;  /* Files replaces Finder as file viewer (default on) */
extern NSString * const files_pref_keep_running;    /* stay running with no windows; open at login */
extern NSString * const files_pref_search_this_mac; /* search the whole Mac, not the current folder */
extern NSString * const files_pref_show_bookmarks;  /* bookmarks bar above the list (default on) */
extern NSString * const files_pref_folder_sizes;         /* Size column totals folders' contents */
extern NSString * const files_pref_show_used_space;      /* status bar shows used, not free, space */
extern NSString * const files_pref_human_readable_sizes; /* format sizes as KB/MB/… (default on) */
extern NSString * const files_pref_full_path_title;      /* window title shows the full path, not the folder name (default on) */

/* NSUserDefaults key (array of column identifiers): file-list columns the
 * user has hidden from the column-header menu. Absent = all shown. */
extern NSString * const files_pref_hidden_columns;

/*
 * files_register_defaults — registers the default value of every preference
 * whose default is not NO (currently: Auto-Fit Columns and Files as the
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
 * files_icloud_drive_url — the user's iCloud Drive folder
 * (~/Library/Mobile Documents/com~apple~CloudDocs).
 *
 * Output: folder URL, or nil if iCloud Drive is not set up on this Mac.
 */
NSURL *files_icloud_drive_url(void);

/*
 * files_trash_urls — the folders that together make up the user's Trash:
 * ~/.Trash, and ~/Library/Mobile Documents/.Trash where macOS puts items
 * deleted from iCloud-synced folders (e.g. a Desktop synced with iCloud).
 * Finder shows their union.
 *
 * Output: ~/.Trash first, then the iCloud Trash when it exists.
 */
NSArray<NSURL *> *files_trash_urls(void);

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
 * files_kind_text — the Kind Files' Info shows for an item: "Application
 * Container" for an application bundle (.app), which is a folder holding
 * the app, else the system's localized type description ("Folder", "PNG
 * image", …).
 *
 * Inputs:
 *   url — file URL of the item
 *
 * Output: kind text, or "—" if it cannot be determined.
 */
NSString *files_kind_text(NSURL *url);

/*
 * files_opens_with_text — the app that opens a file by default
 * (LaunchServices' choice, as a double-click in Files would use), for
 * Info. Folders and apps open themselves, so they have none; a package
 * that is a document (an .rtfd, a Keynote file) counts as a file.
 *
 * Inputs:
 *   url — file URL of the item
 *
 * Output: the app's name (e.g. "Preview"); "None" for a file no app is
 *         set to open; "—" for a folder or app.
 */
NSString *files_opens_with_text(NSURL *url);

/*
 * files_icon_for_url — the icon Files shows for an item at a given size:
 * the Workspace icon, with the git badge centered on it for the top folder
 * of a git working tree. Cached, it is cheap enough per table cell: one
 * icon per file type (custom icons on individual files are not shown) and
 * one per folder or package path. Uncached, it reads the item's own
 * current icon, custom icons included, for the one item Get Info or the
 * sidebar shows. Any thread: per-path icons read the volume, which can
 * stall on a slow one, so file lists read them on a background queue.
 *
 * Inputs:
 *   url    — file URL of the item (listing resource values used if prefetched)
 *   size   — edge length in points
 *   cached — YES for list rows and bookmarks, NO for a single inspected item
 *
 * Output: NSImage of size×size (never nil); do not modify it.
 */
NSImage *files_icon_for_url(NSURL *url, CGFloat size, BOOL cached);

/* Timeout for quick helper tools (git, defaults, lsof), in seconds. */
#define FILES_TOOL_TIMEOUT 15.0

/*
 * files_run_tool — runs a command-line tool with stdin and stderr at
 * /dev/null, optionally capturing stdout, and waits for it to exit, or
 * terminates it (SIGTERM) after timeout seconds — so a tool stuck on an
 * unresponsive network volume cannot block its caller for good. A process
 * in an uninterruptible kernel wait may still outlive the timeout.
 * Blocks; call off the main thread.
 *
 * Inputs:
 *   tool    — absolute path of the executable, e.g. @"/usr/bin/defaults"
 *   args    — arguments after the tool name
 *   timeout — seconds to allow (FILES_TOOL_TIMEOUT for quick tools); 0 for
 *             no limit
 *   out     — receives stdout if non-NULL, even when the exit status is
 *             not 0
 *
 * Output: YES if it ran and exited 0.
 */
BOOL files_run_tool(NSString *tool, NSArray<NSString *> *args, double timeout, NSData **out);

/*
 * files_background_queue — the serial, utility-priority queue for work
 * Files does in the background on its own initiative (keeping Archive
 * Utility, Finder and the login item in step with its preferences), so it
 * never competes with the UI or runs two such jobs at once.
 *
 * Output: the shared queue.
 */
dispatch_queue_t files_background_queue(void);

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
 * domain hold the given values. Ordinary domains are read and written
 * directly with CFPreferences; a sandboxed app's domain (one with a
 * folder in ~/Library/Containers) goes through the `defaults` tool, which,
 * unlike CFPreferences, reaches its container — that needs Full Disk
 * Access. Either way the domain is read once and only the keys that
 * differ are written or deleted, so the common case writes nothing.
 * Blocks; call off the main thread.
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
 * files_read_prefs — reads keys from another app's (or the global)
 * preferences domain the way files_sync_prefs does (CFPreferences, or
 * `defaults export` for a sandboxed app's container). Blocks; call off
 * the main thread.
 *
 * Inputs:
 *   domain — preferences domain, as for files_sync_prefs
 *   keys   — keys to read
 *
 * Output: key → wrapped current value (@[value], or @[] if absent) for
 *         every key; nil if the domain could not be read (typically: no
 *         Full Disk Access).
 */
NSDictionary<NSString *, NSArray *> *files_read_prefs(NSString *domain, NSArray<NSString *> *keys);


/*
 * files_get_finder_comment — reads the Spotlight/Finder comment on a file by
 * decoding the com.apple.metadata:kMDItemFinderComment xattr (a binary
 * property list). Thread-safe; blocks only for the xattr syscall.
 *
 * Inputs:
 *   url — file URL; may be nil
 *
 * Output: the comment string, or nil if none is set or the read fails.
 */
NSString *files_get_finder_comment(NSURL *url);

/*
 * files_set_finder_comment — writes or removes the Spotlight/Finder comment
 * on a file by setting or removing the com.apple.metadata:kMDItemFinderComment
 * xattr. An empty or nil comment removes the attribute. Thread-safe; blocks
 * only for the xattr syscall.
 *
 * Inputs:
 *   url     — file URL
 *   comment — new comment text, or nil / empty to clear
 *
 * Output: YES on success.
 */
BOOL files_set_finder_comment(NSURL *url, NSString *comment);

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
 * files_app_icon — Files' icon as drawn: folder.png from the app bundle.
 * macOS 26 shows a bundle icon that is not its rounded-square shape on a
 * grey rounded-square backdrop, in alerts and the About panel too; handing
 * them this image explicitly shows just the folder. Loaded once.
 *
 * Output: shared NSImage, or nil if folder.png is missing.
 */
NSImage *files_app_icon(void);

/*
 * files_show_error — shows an error in a tool panel (FilesToolPanel), centred
 * over window. Returns at once. Must be called on the main thread.
 *
 * Inputs:
 *   title  — headline, e.g. @"Could not create folder"
 *   err    — error whose localizedDescription becomes the body; may be nil
 *   window — window to centre over; nil = the screen
 */
void files_show_error(NSString *title, NSError *err, NSWindow *window);

/*
 * FilesCancelToken — an atomic cancel flag for one piece of background
 * work (a hash, a folder-size count). The work's block holds a strong
 * reference, so the flag stays valid for the whole job even after its
 * owner has moved on and dropped (or replaced) its own reference.
 */
@interface FilesCancelToken : NSObject

/*
 * cancel_flag — the flag for C code to poll (e.g. file_digests).
 *
 * Output: pointer valid while the token is alive; non-zero once cancelled.
 */
- (const atomic_int *)cancel_flag;

/*
 * cancel — asks the job to stop at its next check.
 */
- (void)cancel;

@end

