#import "util.h"
#import "shared_ui.h"
#import "shared_tool_panel.h"
#import "git_info.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/attr.h>
#include <errno.h>

NSString * const files_pref_show_hidden     = @"files.show_hidden_files";
NSString * const files_pref_auto_fit        = @"files.auto_fit_columns";
NSString * const files_pref_hash_validation = @"files.copy.hash_validation";
NSString * const files_pref_show_hashes     = @"files.show_hashes";
NSString * const files_pref_large_rows      = @"files.large_rows";
NSString * const files_pref_simple_copies   = @"files.simple_copies";
NSString * const files_pref_default_viewer  = @"files.default_viewer";
NSString * const files_pref_keep_running    = @"files.keep_running";
NSString * const files_pref_hidden_columns  = @"files.hidden_columns";
NSString * const files_pref_search_this_mac = @"files.search_this_mac";
NSString * const files_pref_show_bookmarks  = @"files.show_bookmarks";
NSString * const files_pref_folder_sizes         = @"files.folder_sizes";
NSString * const files_pref_show_used_space      = @"files.show_used_space";
NSString * const files_pref_human_readable_sizes = @"files.human_readable_sizes";
NSString * const files_pref_full_path_title      = @"files.full_path_title";
NSString * const files_pref_hide_system_mounts   = @"files.mounts.hide_system";
NSString * const files_pref_sort_column          = @"files.sort_column";
NSString * const files_pref_sort_ascending       = @"files.sort_ascending";
NSString * const files_pref_folders_first        = @"files.folders_first";

/*
 * files_register_defaults — registers non-NO preference defaults.
 * Inputs/output are documented in util.h.
 */
void
files_register_defaults(void)
{
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        files_pref_auto_fit:               @YES,
        files_pref_default_viewer:         @YES,
        files_pref_show_bookmarks:         @YES,
        files_pref_human_readable_sizes:   @YES,
        files_pref_full_path_title:        @YES,
        files_pref_hidden_columns:         @[@"perms", @"created", @"comment"],
        files_pref_hide_system_mounts:     @YES,
        files_pref_folders_first:          @YES,
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
 * files_icloud_drive_url — iCloud Drive folder if it exists.
 * Inputs/output are documented in util.h.
 */
NSURL *
files_icloud_drive_url(void)
{
    NSURL *url = [files_home_url() URLByAppendingPathComponent:
                  @"Library/Mobile Documents/com~apple~CloudDocs" isDirectory:YES];
    return [url checkResourceIsReachableAndReturnError:nil] ? url : nil;
}

/*
 * files_trash_urls — ~/.Trash plus the iCloud Trash when it exists.
 * Inputs/output are documented in util.h.
 */
NSArray<NSURL *> *
files_trash_urls(void)
{
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithObject:files_directory_url(NSTrashDirectory)];
    NSURL *icloud = [files_home_url() URLByAppendingPathComponent:@"Library/Mobile Documents/.Trash"
                                                      isDirectory:YES];
    if ([icloud checkResourceIsReachableAndReturnError:nil]) [urls addObject:icloud];
    return urls;
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
 * icon_cache — the icon cache files_icon_for_url fills and
 * files_set_custom_icon empties when an item's icon changes under it. One
 * cache for the process, bounded and evictable under memory pressure so it
 * cannot grow without limit; NSCache is thread-safe, as the file lists
 * reading it from their background queues need.
 *
 * Output: the shared cache (never nil).
 */
static NSCache<NSString *, NSImage *> *
icon_cache(void)
{
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 4096;
    });
    return cache;
}

/* kHasCustomIcon: the bit of an item's Finder flags that says its icon is
 * its own. Carbon's Finder.h, which this app does not link, names it. */
static const uint16_t finder_flag_custom_icon = 0x0400;

/*
 * files_has_custom_icon — the kHasCustomIcon bit of the item's Finder
 * info. Inputs/output are documented in util.h.
 */
BOOL
files_has_custom_icon(NSURL *url)
{
    if (!url.isFileURL) return NO;

    /* ATTR_CMN_FNDRINFO rather than a getxattr of com.apple.FinderInfo,
     * which is the same 32 bytes by another road: measured over a folder
     * of 10,000 files, 21 ms against 99 ms, because getattrlist reads the
     * attribute the file system keeps rather than going through the
     * extended-attribute interface over it. (Finder does better still by
     * asking for these flags as part of the directory enumeration itself,
     * with getattrlistbulk: ~12 ms for the whole listing. That would mean
     * replacing the NSFileManager enumeration in list_folder.)
     *
     * The flags are the 16-bit big-endian field at offset 8 of both
     * shapes of Finder info — FileInfo for a file, FolderInfo for a
     * folder. A file system that keeps no Finder info returns less than
     * it was asked for, and cannot hold a custom icon either, so a short
     * answer means NO. */
    struct attrlist al = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr  = ATTR_CMN_FNDRINFO,
    };
    struct {
        uint32_t length;
        uint8_t  finder_info[32];
    } __attribute__((aligned(4), packed)) attrs;

    if (getattrlist(url.fileSystemRepresentation, &al, &attrs, sizeof attrs,
                    FSOPT_NOFOLLOW) != 0 || attrs.length < sizeof attrs) {
        return NO;
    }
    uint16_t flags = (uint16_t)((attrs.finder_info[8] << 8) | attrs.finder_info[9]);
    return (flags & finder_flag_custom_icon) != 0;
}

/*
 * icon_of_item — the icon itself, read from the volume: the type's icon
 * where a type is given, otherwise the item's own, git-badged for the top
 * folder of a working tree. No cache of its own; its callers decide what
 * is worth keeping.
 *
 * Inputs:
 *   path — the item's path (read only when type is nil)
 *   type — the type whose icon to use, or nil for the item's own
 *   size — edge length in points
 *
 * Output: NSImage of size x size (never nil).
 */
static NSImage *
icon_of_item(NSString *path, UTType *type, CGFloat size)
{
    NSImage *icon;
    if (type) {
        icon = [[NSWorkspace.sharedWorkspace iconForContentType:type] copy];
        icon.size = NSMakeSize(size, size);
    } else {
        icon = [NSWorkspace.sharedWorkspace iconForFile:path];
        icon.size = NSMakeSize(size, size);
        NSURL *url = [NSURL fileURLWithPath:path];
        if (files_is_git_repo(url)) icon = files_git_badged_icon(icon);
    }
    return icon;
}

/*
 * files_icon_cached — the shared cache in front of icon_of_item: one
 * entry per type for the files that share their type's icon, one per path
 * for the items that do not.
 * Inputs/output are documented in util.h.
 */
NSImage *
files_icon_cached(NSString *path, UTType *type, CGFloat size)
{
    NSCache<NSString *, NSImage *> *cache = icon_cache();
    NSString *key = [NSString stringWithFormat:@"%g:%@", size,
                        type ? type.identifier : path];
    NSImage *icon = [cache objectForKey:key];
    if (!icon) {
        icon = icon_of_item(path, type, size);
        [cache setObject:icon forKey:key];
    }
    return icon;
}

/*
 * files_icon_for_url — reads from the item what a file list is told with
 * its listing (the type, and whether the item has an icon of its own),
 * then hands over to files_icon_cached.
 * Inputs/output are documented in util.h.
 */
NSImage *
files_icon_for_url(NSURL *url, CGFloat size, BOOL cached)
{
    if (!cached) {
        return icon_of_item(url.path, nil, size);
    }

    NSNumber *is_dir = nil;
    NSString *uti    = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
    /* A plain file shares its type's icon unless it carries one of its
     * own, which nothing but a read of the item itself can tell. */
    BOOL by_type = !is_dir.boolValue && uti.length > 0 && !files_has_custom_icon(url);
    return files_icon_cached(url.path, by_type ? [UTType typeWithIdentifier:uti] : nil,
                             size);
}

/*
 * files_set_custom_icon — stores an item's own icon, or clears it.
 * Inputs/output are documented in util.h.
 */
BOOL
files_set_custom_icon(NSURL *url, NSImage *icon, NSError **err)
{
    if (!url.isFileURL) {
        if (err) {
            *err = [NSError errorWithDomain:NSCocoaErrorDomain
                                       code:NSFileNoSuchFileError
                                   userInfo:nil];
        }
        return NO;
    }

    if ([NSWorkspace.sharedWorkspace setIcon:icon forFile:url.path options:0]) {
        /* The cache keys folders and packages by path, so the entry for
         * this item (and any the write touched) is now wrong. */
        [icon_cache() removeAllObjects];
        return YES;
    }

    /* setIcon:forFile: reports a failure as a plain NO with nothing to say
     * about it. What it comes down to in practice is permission — a
     * read-only item, or a volume mounted read-only — so the error says so
     * where the item cannot be written, and stays unspecific where it can. */
    if (err) {
        BOOL writable = [NSFileManager.defaultManager isWritableFileAtPath:url.path];
        *err = [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:writable ? NSFileWriteUnknownError
                                                 : NSFileWriteNoPermissionError
                               userInfo:@{NSFilePathErrorKey: url.path}];
    }
    return NO;
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
 * files_run_tool — runs a command-line tool and waits for it, up to timeout.
 * Inputs/output are documented in util.h.
 */
BOOL
files_run_tool(NSString *tool, NSArray<NSString *> *args, double timeout, NSData **out)
{
    NSTask *task        = [[NSTask alloc] init];
    task.executableURL  = [NSURL fileURLWithPath:tool];
    task.arguments      = args;
    task.standardInput  = NSFileHandle.fileHandleWithNullDevice;
    task.standardError  = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe        = [NSPipe pipe];
    task.standardOutput = pipe;
    if (![task launchAndReturnError:nil]) return NO;
    if (timeout > 0) {
        /* Terminating the tool closes its end of the pipe, ending the read. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (task.running) [task terminate];
        });
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (out) *out = data;
    return task.terminationStatus == 0;
}

/*
 * files_background_queue — one serial utility-QoS queue, made once.
 * Inputs/output are documented in util.h.
 */
dispatch_queue_t
files_background_queue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("files.background",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static NSString * const defaults_tool = @"/usr/bin/defaults";

/*
 * cf_app — the CFPreferences application ID for a domain name.
 *
 * Inputs:
 *   domain — preferences domain; @"NSGlobalDomain" for the global one
 *
 * Output: kCFPreferencesAnyApplication or the domain itself.
 */
static CFStringRef
cf_app(NSString *domain)
{
    return [domain isEqualToString:@"NSGlobalDomain"]
           ? kCFPreferencesAnyApplication : (__bridge CFStringRef)domain;
}

/*
 * is_container_domain — whether a domain belongs to a sandboxed app, whose
 * settings live in its container and are reached through the defaults
 * tool. Only a container known to be absent means an ordinary domain:
 * without Full Disk Access the check itself can be refused (EPERM), and a
 * sandboxed app's settings must not be written beside its container.
 *
 * Inputs:
 *   domain — preferences domain
 *
 * Output: YES unless ~/Library/Containers/<domain> is known not to exist.
 */
static BOOL
is_container_domain(NSString *domain)
{
    NSString *container = [NSString stringWithFormat:@"%@/Library/Containers/%@",
                           NSHomeDirectory(), domain];
    struct stat st;
    return !(lstat(container.fileSystemRepresentation, &st) != 0 && errno == ENOENT);
}

/*
 * files_read_prefs — current values, CFPreferences or `defaults export`.
 * Inputs/output are documented in util.h.
 */
NSDictionary<NSString *, NSArray *> *
files_read_prefs(NSString *domain, NSArray<NSString *> *keys)
{
    NSMutableDictionary<NSString *, NSArray *> *found = [NSMutableDictionary dictionary];
    if (!is_container_domain(domain)) {
        for (NSString *key in keys) {
            id have = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key,
                                        cf_app(domain), kCFPreferencesCurrentUser,
                                        kCFPreferencesAnyHost));
            found[key] = have ? @[have] : @[];
        }
        return found;
    }

    NSData *data = nil;
    if (!files_run_tool(defaults_tool, @[@"export", domain, @"-"], FILES_TOOL_TIMEOUT, &data)) {
        return nil;
    }
    NSDictionary *current = [NSPropertyListSerialization propertyListWithData:data
                                                                      options:0
                                                                       format:NULL
                                                                        error:nil];
    if (![current isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in keys) {
        found[key] = current[key] ? @[current[key]] : @[];
    }
    return found;
}

/*
 * files_sync_prefs — read once (files_read_prefs), write only differences:
 * CFPreferences, or the defaults tool for a sandboxed app's container.
 * Inputs/output are documented in util.h.
 */
BOOL
files_sync_prefs(NSString *domain, NSDictionary<NSString *, NSArray *> *values,
                 NSMutableDictionary<NSString *, NSArray *> *previous)
{
    NSDictionary<NSString *, NSArray *> *current = files_read_prefs(domain, values.allKeys);
    if (!current) return NO;
    BOOL cf = !is_container_domain(domain);

    NSMutableDictionary<NSString *, NSArray *> *changed = [NSMutableDictionary dictionary];
    BOOL ok = YES;
    for (NSString *key in values) {
        id want = values[key].firstObject;  /* nil: remove the key */
        id have = current[key].firstObject;
        if (want ? [have isEqual:want] : have == nil) continue;

        BOOL wrote = YES;
        if (cf) {
            CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)want,
                                  cf_app(domain), kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost);
        } else if (want) {
            /* `defaults write` parses a value starting with "<" as a property
             * list, so any type (string, bool, number, …) round-trips. */
            NSData *xml = [NSPropertyListSerialization dataWithPropertyList:want
                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                    options:0
                                                                      error:nil];
            NSString *plist = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding]
                                  : nil;
            wrote = plist && files_run_tool(defaults_tool, @[@"write", domain, key, plist],
                                              FILES_TOOL_TIMEOUT, NULL);
        } else {
            wrote = files_run_tool(defaults_tool, @[@"delete", domain, key],
                                   FILES_TOOL_TIMEOUT, NULL);
        }
        if (wrote) changed[key] = current[key];
        ok = wrote && ok;
    }
    /* CFPreferences changes are kept only once synchronized. */
    if (cf && changed.count > 0 &&
        !CFPreferencesSynchronize(cf_app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
        return NO;
    }
    [previous addEntriesFromDictionary:changed];
    return ok;
}

/*
 * files_kind_text — "Application Container" for app bundles, else the
 * localized type description. Inputs/output are documented in util.h.
 */
NSString *
files_kind_text(NSURL *url)
{
    NSDictionary<NSURLResourceKey, id> *res =
        [url resourceValuesForKeys:@[NSURLContentTypeKey, NSURLLocalizedTypeDescriptionKey]
                             error:nil];
    if ([res[NSURLContentTypeKey] conformsToType:UTTypeApplicationBundle]) {
        return @"Application Container";
    }
    return res[NSURLLocalizedTypeDescriptionKey] ?: @"—";
}

/*
 * files_opens_with_text — the default app's name for a file, from
 * NSWorkspace. Inputs/output are documented in util.h.
 */
NSString *
files_opens_with_text(NSURL *url)
{
    NSDictionary<NSURLResourceKey, id> *res =
        [url resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsPackageKey, NSURLContentTypeKey]
                             error:nil];
    BOOL folder = [res[NSURLIsDirectoryKey] boolValue] && ![res[NSURLIsPackageKey] boolValue];
    if (folder || [res[NSURLContentTypeKey] conformsToType:UTTypeApplicationBundle]) return @"—";

    return files_app_display_name([NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url]);
}

/*
 * files_app_display_name — an application bundle's localized name without
 * ".app". Inputs/output are documented in util.h.
 */
NSString *
files_app_display_name(NSURL *app)
{
    if (!app) return @"None";
    NSString *name = nil;
    [app getResourceValue:&name forKey:NSURLLocalizedNameKey error:nil];
    name = name ?: app.lastPathComponent;
    return [name.pathExtension isEqualToString:@"app"] ? name.stringByDeletingPathExtension : name;
}

/*
 * files_get_finder_comment — reads the Spotlight/Finder comment on a file.
 * Inputs/output are documented in util.h.
 */
NSString *
files_get_finder_comment(NSURL *url)
{
    const char *path = url.fileSystemRepresentation;
    if (!path) return nil;
    ssize_t sz = getxattr(path, "com.apple.metadata:kMDItemFinderComment",
                          NULL, 0, 0, XATTR_NOFOLLOW);
    if (sz <= 0) return nil;
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)sz];
    if (getxattr(path, "com.apple.metadata:kMDItemFinderComment",
                 buf.mutableBytes, (size_t)sz, 0, XATTR_NOFOLLOW) != sz) return nil;
    id obj = [NSPropertyListSerialization propertyListWithData:buf
                                                       options:0
                                                        format:nil
                                                         error:nil];
    if (![obj isKindOfClass:NSString.class]) return nil;
    NSString *s = obj;
    return s.length > 0 ? s : nil;
}

/*
 * files_set_finder_comment — writes or removes the Spotlight/Finder comment.
 * Inputs/output are documented in util.h.
 */
BOOL
files_set_finder_comment(NSURL *url, NSString *comment)
{
    const char *path = url.fileSystemRepresentation;
    if (!path) return NO;
    if (comment.length == 0) {
        int r = removexattr(path, "com.apple.metadata:kMDItemFinderComment", XATTR_NOFOLLOW);
        return r == 0 || errno == ENOATTR;
    }
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:comment
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:nil];
    if (!plist) return NO;
    return setxattr(path, "com.apple.metadata:kMDItemFinderComment",
                    plist.bytes, plist.length, 0, XATTR_NOFOLLOW) == 0;
}

/*
 * human_bytes — the shared formatter for human-readable byte counts
 * ("12.3 MB"), used by files_format_bytes when the Sizes preference asks
 * for them and by files_format_rate always.
 *
 * Output: the shared formatter.
 */
static NSByteCountFormatter *
human_bytes(void)
{
    static NSByteCountFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSByteCountFormatter alloc] init];
        fmt.countStyle = NSByteCountFormatterCountStyleFile;
    });
    return fmt;
}

/*
 * files_format_bytes — formats a byte count according to the current
 * files_pref_human_readable_sizes setting. When on (the default), uses
 * NSByteCountFormatter (Finder-style: 1.2 MB, 345 KB …). When off, returns
 * the raw count with thousands separators ("1,234,567 bytes"). Thread-safe.
 */
NSString *
files_format_bytes(int64_t bytes)
{
    static NSNumberFormatter *raw_fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        raw_fmt = [[NSNumberFormatter alloc] init];
        raw_fmt.numberStyle = NSNumberFormatterDecimalStyle;
    });
    if ([NSUserDefaults.standardUserDefaults boolForKey:files_pref_human_readable_sizes])
        return [human_bytes() stringFromByteCount:bytes];
    NSString *n = [raw_fmt stringFromNumber:@(bytes)];
    return bytes == 1 ? [n stringByAppendingString:@" byte"]
                      : [n stringByAppendingString:@" bytes"];
}

/*
 * files_format_duration — seconds below the 90-second cut-off, minutes and
 * seconds above it.
 * Inputs/output are documented in util.h.
 */
NSString *
files_format_duration(double seconds)
{
    if (seconds < 0.0) seconds = 0.0;
    if (seconds <= 90.0) return [NSString stringWithFormat:@"%.1f seconds", seconds];

    int64_t whole = (int64_t)(seconds + 0.5);
    int64_t mins  = whole / 60;
    int64_t secs  = whole % 60;
    return [NSString stringWithFormat:@"%lld minute%s %lld second%s",
            mins, mins == 1 ? "" : "s", secs, secs == 1 ? "" : "s"];
}

/*
 * files_format_rate — human-readable byte count plus "/s".
 * Inputs/output are documented in util.h.
 */
NSString *
files_format_rate(double bytes_per_sec)
{
    int64_t bps = bytes_per_sec > 0 ? (int64_t)bytes_per_sec : 0;
    return [[human_bytes() stringFromByteCount:bps] stringByAppendingString:@"/s"];
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
 * files_table_column — one column of a list window's table.
 * Inputs/output are documented in util.h.
 */
NSTableColumn *
files_table_column(NSString *ident, NSString *title, CGFloat width, BOOL resizable)
{
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title          = title;
    col.width          = width;
    col.minWidth       = 40.0;
    col.resizingMask   = resizable ? NSTableColumnUserResizingMask
                                   : NSTableColumnNoResizing;
    return col;
}

/*
 * files_app_icon — app_icon.icns, loaded once.
 * Inputs/output are documented in util.h.
 */
NSImage *
files_app_icon(void)
{
    static NSImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        icon = [NSImage imageNamed:@"app_icon"];  /* Resources/app_icon.icns */
    });
    return icon;
}

/*
 * files_show_error — error in a tool panel.
 * Inputs/output are documented in util.h.
 */
void
files_show_error(NSString *title, NSError *err, NSWindow *window)
{
    shared_ui_notice(window, title, err.localizedDescription ?: @"Unknown error", nil);
}

@implementation FilesCancelToken {
    atomic_int _cancel;
}

/*
 * cancel_flag — the token's flag. Inputs/output are documented in util.h.
 */
- (const atomic_int *)
cancel_flag
{
    return &_cancel;
}

/*
 * cancel — sets the flag. Inputs/output are documented in util.h.
 */
- (void)
cancel
{
    atomic_store(&_cancel, 1);
}

@end
