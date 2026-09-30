#import "volume_manager.h"

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

/* How long to wait for DiskImageMounter to mount an image it was handed. */
static const int64_t interactive_mount_timeout_sec = 120;

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
    NSTask *task       = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
    task.arguments     = @[@"attach", @"-plist", @"-noautoopen", image.path];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *out        = [NSPipe pipe];
    task.standardOutput = out;
    if (![task launchAndReturnError:nil]) return nil;

    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;

    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data
                                                                    options:0
                                                                     format:NULL
                                                                      error:nil];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    for (NSDictionary *entity in plist[@"system-entities"]) {
        NSString *mount_point = entity[@"mount-point"];
        if (mount_point.length) return [NSURL fileURLWithPath:mount_point isDirectory:YES];
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
 * then, each time a volume mounts, re-runs attach_disk_image — which for an
 * already-attached image just reports its volume without prompting — until
 * the image's volume appears or interactive_mount_timeout_sec passes.
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
        completion(volume, nil);
    };

    observer = [NSNotificationCenter.defaultCenter
        addObserverForName:FilesVolumesChangedNotification object:self
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSURL *volume = attach_disk_image(image);
            if (volume) dispatch_async(dispatch_get_main_queue(), ^{ finish(volume); });
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, interactive_mount_timeout_sec * (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ finish(nil); });
}

@end
