#import "util.h"
#import "git_info.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
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
 * files_icon_for_url — Workspace icon, git-badged for working trees. With
 * cached, plain files share one icon per type (keyed by UTI) so a folder
 * of 10,000 JPEGs costs one image, and folders and packages (which can
 * carry custom icons or be git working trees) are cached per path; the
 * cache is bounded and evictable under memory pressure. Without, the
 * item's own current icon is read and the cache is left alone.
 * Inputs/output are documented in util.h.
 */
NSImage *
files_icon_for_url(NSURL *url, CGFloat size, BOOL cached)
{
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 4096;
    });

    NSString *key = nil;
    UTType *type  = nil;
    if (cached) {
        NSNumber *is_dir = nil;
        NSString *uti    = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        [url getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
        BOOL by_type = !is_dir.boolValue && uti.length > 0;
        key  = [NSString stringWithFormat:@"%g:%@", size, by_type ? uti : url.path];
        type = by_type ? [UTType typeWithIdentifier:uti] : nil;
        NSImage *icon = [cache objectForKey:key];
        if (icon) return icon;
    }

    NSImage *icon;
    if (type) {
        icon = [[NSWorkspace.sharedWorkspace iconForContentType:type] copy];
        icon.size = NSMakeSize(size, size);
    } else {
        icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size = NSMakeSize(size, size);
        if (files_is_git_repo(url)) icon = files_git_badged_icon(icon);
    }
    if (key) [cache setObject:icon forKey:key];
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

    NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url];
    if (!app) return @"None";
    NSString *name = nil;
    [app getResourceValue:&name forKey:NSURLLocalizedNameKey error:nil];
    name = name ?: app.lastPathComponent;
    return [name.pathExtension isEqualToString:@"app"] ? name.stringByDeletingPathExtension : name;
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
    static NSByteCountFormatter *human_fmt;
    static NSNumberFormatter    *raw_fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        human_fmt = [[NSByteCountFormatter alloc] init];
        human_fmt.countStyle = NSByteCountFormatterCountStyleFile;
        raw_fmt = [[NSNumberFormatter alloc] init];
        raw_fmt.numberStyle = NSNumberFormatterDecimalStyle;
    });
    if ([NSUserDefaults.standardUserDefaults boolForKey:files_pref_human_readable_sizes])
        return [human_fmt stringFromByteCount:bytes];
    NSString *n = [raw_fmt stringFromNumber:@(bytes)];
    return bytes == 1 ? [n stringByAppendingString:@" byte"]
                      : [n stringByAppendingString:@" bytes"];
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
