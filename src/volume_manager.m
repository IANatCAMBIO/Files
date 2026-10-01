#import "volume_manager.h"
#import "util.h"

NSString * const FilesVolumesChangedNotification = @"FilesVolumesChangedNotification";

/*
 * volume_keys — the resource keys mounted_volumes prefetches and the other
 * methods read, defined once.
 *
 * Output: NSArray of NSURLResourceKey, never nil.
 */
static NSArray<NSURLResourceKey> *
volume_keys(void)
{
    static NSArray<NSURLResourceKey> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[NSURLVolumeLocalizedNameKey,
                 NSURLVolumeIsRootFileSystemKey,
                 NSURLVolumeIsInternalKey,
                 NSURLVolumeIsLocalKey,
                 NSURLVolumeIsEjectableKey,
                 NSURLVolumeIsRemovableKey];
    });
    return keys;
}

/*
 * process_name — a user-facing name for pid: the app's localized name for
 * GUI apps, otherwise the command name lsof reported.
 *
 * Inputs:
 *   pid     — process id
 *   command — lsof's command name (fallback)
 *
 * Output: display name.
 */
static NSString *
process_name(pid_t pid, NSString *command)
{
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app.localizedName ?: command ?: [NSString stringWithFormat:@"pid %d", pid];
}

/*
 * list_open_files — runs `lsof -Fpctn +f -- <volume>` (every open file,
 * folder or working directory on that file system; FILES_TOOL_TIMEOUT, as
 * lsof itself can stall on a hung mount) and turns its field output into
 * de-duplicated, sorted descriptions. lsof exits 1 when it finds nothing,
 * so its output is used whatever the exit status. Blocks; call off the
 * main thread.
 *
 * Inputs:
 *   volume — volume root URL
 *
 * Output: array of descriptions (possibly empty).
 */
static NSArray<NSString *> *
list_open_files(NSURL *volume)
{
    NSData *data = nil;
    files_run_tool(@"/usr/sbin/lsof", @[@"-Fpctn", @"+f", @"--", volume.path],
                   FILES_TOOL_TIMEOUT, &data);
    if (!data) return @[];

    NSString *root = volume.path;
    NSMutableOrderedSet<NSString *> *items = [NSMutableOrderedSet orderedSet];
    pid_t pid = 0;
    NSString *command = nil, *type = nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length < 2) continue;
        NSString *value = [line substringFromIndex:1];
        switch ([line characterAtIndex:0]) {
        case 'p': pid = (pid_t)value.intValue; command = nil; break;
        case 'c': command = value; break;
        case 't': type = value; break;
        case 'n': {
            NSString *rel = [value hasPrefix:[root stringByAppendingString:@"/"]]
                ? [value substringFromIndex:root.length + 1] : value.lastPathComponent;
            if ([type isEqualToString:@"DIR"]) rel = [rel stringByAppendingString:@" (folder)"];
            [items addObject:[NSString stringWithFormat:@"%@ — %@", rel, process_name(pid, command)]];
            break;
        }
        }
    }
    return [items.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

/* How long to wait for DiskImageMounter to mount an image it was handed. */
static const int64_t interactive_mount_timeout_sec = 120;

/*
 * first_mount_point — the first mount point among an hdiutil plist's
 * system-entities.
 *
 * Inputs:
 *   image_info — one image's dictionary (attach output, or an entry of
 *                `hdiutil info`'s images)
 *
 * Output: volume root URL, or nil if none of its entities is mounted.
 */
static NSURL *
first_mount_point(NSDictionary *image_info)
{
    for (NSDictionary *entity in image_info[@"system-entities"]) {
        NSString *mount_point = entity[@"mount-point"];
        if (mount_point.length) return [NSURL fileURLWithPath:mount_point isDirectory:YES];
    }
    return nil;
}

/*
 * hdiutil_plist — runs hdiutil with args and parses its -plist output.
 *
 * Inputs:
 *   args    — hdiutil arguments, including -plist
 *   timeout — seconds to allow; 0 for no limit (attach may verify a large
 *             image for minutes)
 *
 * Output: the parsed dictionary, or nil if hdiutil failed.
 */
static NSDictionary *
hdiutil_plist(NSArray<NSString *> *args, double timeout)
{
    NSData *data = nil;
    if (!files_run_tool(@"/usr/bin/hdiutil", args, timeout, &data)) return nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0
                                                                     format:NULL error:nil];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

/*
 * attach_disk_image — runs `hdiutil attach -plist -noautoopen` on image with
 * stdin at /dev/null (so password or license prompts fail instead of
 * hanging) and returns the first mount point in its plist output. Blocks;
 * call off the main thread.
 *
 * Inputs:
 *   image — disk image file URL
 *
 * Output: mounted volume root URL, or nil if hdiutil could not mount it.
 */
static NSURL *
attach_disk_image(NSURL *image)
{
    return first_mount_point(hdiutil_plist(@[@"attach", @"-plist", @"-noautoopen", image.path], 0));
}

/*
 * attached_volume — the volume of image if it is already attached, from
 * `hdiutil info` (which changes nothing, unlike attach). Blocks; call off
 * the main thread.
 *
 * Inputs:
 *   image — disk image file URL
 *
 * Output: mounted volume root URL, or nil if the image is not mounted.
 */
static NSURL *
attached_volume(NSURL *image)
{
    NSString *want = image.URLByResolvingSymlinksInPath.path;
    NSDictionary *info = hdiutil_plist(@[@"info", @"-plist"], FILES_TOOL_TIMEOUT);
    for (NSDictionary *img in info[@"images"]) {
        NSString *path = img[@"image-path"];
        if (!path || ![[NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path
                          isEqualToString:want]) continue;
        /* An image can be attached more than once, not every time mounted. */
        NSURL *volume = first_mount_point(img);
        if (volume) return volume;
    }
    return nil;
}

@implementation FilesVolumeManager

/*
 * shared — returns the singleton, creating it on first call.
 *
 * Output: FilesVolumeManager singleton, never nil.
 */
+ (instancetype)
shared
{
    static FilesVolumeManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FilesVolumeManager alloc] init_internal];
    });
    return instance;
}

/*
 * init_internal — private initialiser; registers for workspace mount,
 * unmount and rename notifications.
 *
 * Output: self, or nil if [super init] fails.
 */
- (instancetype)
init_internal
{
    self = [super init];
    if (!self) {
        return nil;
    }
    NSNotificationCenter *ws_nc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceDidMountNotification,
                                      NSWorkspaceDidUnmountNotification,
                                      NSWorkspaceDidRenameVolumeNotification]) {
        [ws_nc addObserver:self
                  selector:@selector(volumes_changed:)
                      name:name
                    object:nil];
    }
    return self;
}

/*
 * volumes_changed: — workspace notification handler (already delivered on
 * the main thread); re-posts it as FilesVolumesChangedNotification.
 *
 * Inputs:
 *   note — workspace mount/unmount/rename notification (unused)
 *
 * Output: none.
 */
- (void)
volumes_changed:(NSNotification *)note
{
    [NSNotificationCenter.defaultCenter
        postNotificationName:FilesVolumesChangedNotification
                      object:self];
}

/*
 * cloud_storage_locations — iCloud Drive, then the visible folders in
 * ~/Library/CloudStorage.
 * Inputs/output are documented in volume_manager.h.
 */
- (NSArray<NSURL *> *)
cloud_storage_locations
{
    NSURL *root = [files_home_url() URLByAppendingPathComponent:@"Library/CloudStorage"
                                                    isDirectory:YES];
    NSArray<NSURL *> *items =
        [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
                                    includingPropertiesForKeys:@[NSURLIsDirectoryKey,
                                                                 NSURLLocalizedNameKey]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:nil];
    NSMutableArray<NSURL *> *dirs = [NSMutableArray array];
    for (NSURL *u in items) {
        NSNumber *is_dir = nil;
        [u getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) [dirs addObject:u];
    }
    [dirs sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];

    NSURL *icloud = files_icloud_drive_url();
    if (icloud) [dirs insertObject:icloud atIndex:0];
    return dirs;
}

/*
 * mounted_volumes — returns visible mounted volumes with volume_keys()
 * prefetched.
 *
 * Output: NSArray<NSURL *>, never nil.
 */
- (NSArray<NSURL *> *)
mounted_volumes
{
    NSArray<NSURL *> *vols =
        [NSFileManager.defaultManager
            mountedVolumeURLsIncludingResourceValuesForKeys:volume_keys()
            options:NSVolumeEnumerationSkipHiddenVolumes];
    return vols ?: @[];
}

/*
 * display_name_for_volume: — returns the volume's localized (Finder) name.
 *
 * Inputs:
 *   url — volume root URL
 *
 * Output: display name string, or the last path component on failure.
 */
- (NSString *)
display_name_for_volume:(NSURL *)url
{
    NSString *name = nil;
    [url getResourceValue:&name forKey:NSURLVolumeLocalizedNameKey error:nil];
    return name ?: url.lastPathComponent;
}

/*
 * can_unmount_volume: — applies the rule documented in volume_manager.h:
 * not root, and (network or external or ejectable or removable).
 *
 * Inputs:
 *   url — volume root URL
 *
 * Output: YES if the volume may be unmounted, NO otherwise (including when
 *         its resource values cannot be read).
 */
- (BOOL)
can_unmount_volume:(NSURL *)url
{
    NSDictionary<NSURLResourceKey, id> *v = [url resourceValuesForKeys:volume_keys()
                                                                  error:nil];
    if (!v || [v[NSURLVolumeIsRootFileSystemKey] boolValue]) {
        return NO;
    }
    return ![v[NSURLVolumeIsLocalKey] boolValue]
        || ![v[NSURLVolumeIsInternalKey] boolValue]
        || [v[NSURLVolumeIsEjectableKey] boolValue]
        || [v[NSURLVolumeIsRemovableKey] boolValue];
}

/*
 * unmount_volume:completion: — unmounts only this volume via NSFileManager
 * (asynchronous, no thread blocked).
 *
 * Inputs:
 *   url        — volume root URL
 *   completion — called on the main thread with nil error on success; may be nil
 *
 * Output: none (result delivered through completion).
 */
- (void)
unmount_volume:(NSURL *)url
    completion:(void (^)(NSError *err))completion
{
    [NSFileManager.defaultManager
        unmountVolumeAtURL:url
                   options:0
         completionHandler:^(NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(err);
            }
        });
    }];
}

/*
 * open_files_on_volume:completion: — runs list_open_files in the background.
 *
 * Inputs:
 *   volume     — volume root URL
 *   completion — see volume_manager.h
 */
- (void)
open_files_on_volume:(NSURL *)volume
          completion:(void (^)(NSArray<NSString *> *items))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *items = list_open_files(volume);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
    });
}

/*
 * mount_disk_image:completion: — tries a non-interactive hdiutil attach;
 * on failure falls back to mount_interactively:completion:.
 *
 * Inputs:
 *   image      — disk image file URL
 *   completion — see volume_manager.h
 */
- (void)
mount_disk_image:(NSURL *)image
      completion:(void (^)(NSURL *volume, NSError *err))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *volume = attach_disk_image(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (volume) {
                completion(volume, nil);
            } else {
                [self mount_interactively:image completion:completion];
            }
        });
    });
}

/*
 * mount_interactively:completion: — opens image with the system's handler
 * (DiskImageMounter, which prompts for passwords and license agreements),
 * then, each time a volume mounts, asks `hdiutil info` whether the image
 * is now attached (attached_volume) until its volume appears or
 * interactive_mount_timeout_sec passes.
 *
 * Inputs:
 *   image      — disk image file URL
 *   completion — see volume_manager.h; called exactly once
 */
- (void)
mount_interactively:(NSURL *)image
         completion:(void (^)(NSURL *volume, NSError *err))completion
{
    if (![NSWorkspace.sharedWorkspace openURL:image]) {
        completion(nil, [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadUnknownError
                                        userInfo:@{NSFilePathErrorKey: image.path}]);
        return;
    }

    __block id  observer = nil;
    __block BOOL done    = NO;
    void (^finish)(NSURL *) = ^(NSURL *volume) {
        if (done) return;
        done = YES;
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        observer = nil;  /* the token's block retains finish, which retains observer */
        completion(volume, nil);
    };

    observer = [NSNotificationCenter.defaultCenter
        addObserverForName:FilesVolumesChangedNotification object:self
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSURL *volume = attached_volume(image);
            if (volume) dispatch_async(dispatch_get_main_queue(), ^{ finish(volume); });
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, interactive_mount_timeout_sec * (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ finish(nil); });
}

@end
