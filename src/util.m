#import "util.h"
#import "git_info.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fcntl.h>
#include <unistd.h>

NSString * const files_pref_show_hidden     = @"files.show_hidden_files";
NSString * const files_pref_auto_fit        = @"files.auto_fit_columns";
NSString * const files_pref_hash_validation = @"files.copy.hash_validation";
NSString * const files_pref_show_hashes     = @"files.show_hashes";
NSString * const files_pref_large_rows      = @"files.large_rows";
NSString * const files_pref_simple_copies   = @"files.simple_copies";
NSString * const files_pref_archive_reveal  = @"files.archive_reveal";
NSString * const files_pref_default_viewer  = @"files.default_viewer";
NSString * const files_pref_keep_running    = @"files.keep_running";
NSString * const files_pref_hidden_columns  = @"files.hidden_columns";
NSString * const files_pref_search_this_mac = @"files.search_this_mac";

/*
 * files_register_defaults — registers non-NO preference defaults.
 * Inputs/output are documented in util.h.
 */
void
files_register_defaults(void)
{
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        files_pref_auto_fit:       @YES,
        files_pref_default_viewer: @YES,
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
 * files_icon_for_url — Workspace icon, git-badged for working trees,
 * cached: plain files share one icon per type (keyed by UTI) so a folder
 * of 10,000 JPEGs costs one image; folders and packages can carry custom
 * icons (or be git working trees), so they are cached per path. The cache
 * is bounded and evictable under memory pressure.
 * Inputs/output are documented in util.h.
 */
NSImage *
files_icon_for_url(NSURL *url, CGFloat size)
{
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 4096;
    });

    NSNumber *is_dir = nil;
    NSString *uti    = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
    BOOL by_type = !is_dir.boolValue && uti.length > 0;
    NSString *key = [NSString stringWithFormat:@"%g:%@", size, by_type ? uti : url.path];

    NSImage *icon = [cache objectForKey:key];
    if (icon) return icon;
    UTType *type = by_type ? [UTType typeWithIdentifier:uti] : nil;
    if (type) {
        icon = [[NSWorkspace.sharedWorkspace iconForContentType:type] copy];
        icon.size = NSMakeSize(size, size);
    } else {
        icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size = NSMakeSize(size, size);
        if (files_is_git_repo(url)) icon = files_git_badged_icon(icon);
    }
    [cache setObject:icon forKey:key];
    return icon;
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
 * sync_prefs_cf — files_sync_prefs for a domain CFPreferences can reach:
 * reads each key from exactly that domain (current user, any host),
 * changes the ones that differ and synchronizes once.
 *
 * Inputs:
 *   domain   — preferences domain; @"NSGlobalDomain" for the global one
 *   values   — key → wrapped wanted value
 *   previous — if non-nil, receives key → wrapped prior value per change
 *
 * Output: YES if every key now has its wanted value.
 */
static BOOL
sync_prefs_cf(NSString *domain, NSDictionary<NSString *, NSArray *> *values,
              NSMutableDictionary<NSString *, NSArray *> *previous)
{
    CFStringRef app = [domain isEqualToString:@"NSGlobalDomain"]
                      ? kCFPreferencesAnyApplication : (__bridge CFStringRef)domain;
    NSMutableDictionary<NSString *, NSArray *> *changed = [NSMutableDictionary dictionary];
    for (NSString *key in values) {
        id want = values[key].firstObject;  /* nil: remove the key */
        id have = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, app,
                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        if (want ? [have isEqual:want] : have == nil) continue;
        CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)want, app,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        changed[key] = have ? @[have] : @[];
    }
    if (changed.count == 0) return YES;
    if (!CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
        return NO;
    }
    [previous addEntriesFromDictionary:changed];
    return YES;
}

/*
 * files_sync_prefs — read once, write only differences: CFPreferences, or
 * the defaults tool for a sandboxed app's container.
 * Inputs/output are documented in util.h.
 */
BOOL
files_sync_prefs(NSString *domain, NSDictionary<NSString *, NSArray *> *values,
                 NSMutableDictionary<NSString *, NSArray *> *previous)
{
    NSString *container = [NSString stringWithFormat:@"%@/Library/Containers/%@",
                           NSHomeDirectory(), domain];
    if (access(container.fileSystemRepresentation, F_OK) != 0) {
        return sync_prefs_cf(domain, values, previous);
    }

    NSData *data = nil;
    if (!files_run_tool(defaults_tool, @[@"export", domain, @"-"], FILES_TOOL_TIMEOUT, &data)) {
        return NO;
    }
    NSDictionary *current = [NSPropertyListSerialization propertyListWithData:data
                                                                      options:0
                                                                       format:NULL
                                                                        error:nil];
    if (![current isKindOfClass:NSDictionary.class]) return NO;

    BOOL ok = YES;
    for (NSString *key in values) {
        id want = values[key].firstObject;  /* nil: remove the key */
        id have = current[key];
        if (want ? [have isEqual:want] : have == nil) continue;

        BOOL wrote;
        if (want) {
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
        if (wrote && previous) previous[key] = have ? @[have] : @[];
        ok = wrote && ok;
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
 * files_app_icon — folder.png, loaded once.
 * Inputs/output are documented in util.h.
 */
NSImage *
files_app_icon(void)
{
    static NSImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        icon = [NSImage imageNamed:@"folder"];  /* Resources/folder.png */
    });
    return icon;
}

/*
 * files_new_alert — NSAlert with the plain app icon.
 * Inputs/output are documented in util.h.
 */
NSAlert *
files_new_alert(void)
{
    NSAlert *alert = [[NSAlert alloc] init];
    NSImage *icon  = files_app_icon();
    if (icon) alert.icon = icon;
    return alert;
}

/*
 * files_present_alert — alert as a sheet (or app-modal if no window).
 * Inputs/output are documented in util.h.
 */
void
files_present_alert(NSAlert *alert, NSWindow *window, void (^handler)(NSModalResponse resp))
{
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:handler];
    } else {
        NSModalResponse resp = [alert runModal];
        if (handler) handler(resp);
    }
}

/*
 * files_show_error — error alert as a sheet (or app-modal if no window).
 * Inputs/output are documented in util.h.
 */
void
files_show_error(NSString *title, NSError *err, NSWindow *window)
{
    NSAlert *alert        = files_new_alert();
    alert.messageText     = title;
    alert.informativeText = err.localizedDescription ?: @"Unknown error";
    files_present_alert(alert, window, nil);
}
