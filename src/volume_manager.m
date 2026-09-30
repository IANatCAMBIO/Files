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

@end
