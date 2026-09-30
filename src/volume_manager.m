#import "volume_manager.h"

NSString * const FilesVolumesChangedNotification = @"FilesVolumesChangedNotification";

@implementation FilesVolumeManager

/*
 * shared — returns the singleton, creating it on first call.
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
 * init_internal — designated initialiser; registers workspace notifications.
 *
 * Output: self
 */
- (instancetype)
init_internal
{
    self = [super init];
    if (!self) {
        return nil;
    }
    NSNotificationCenter *ws_nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [ws_nc addObserver:self
              selector:@selector(volumes_changed:)
                  name:NSWorkspaceDidMountNotification
                object:nil];
    [ws_nc addObserver:self
              selector:@selector(volumes_changed:)
                  name:NSWorkspaceDidUnmountNotification
                object:nil];
    return self;
}

- (void)dealloc
{
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

/*
 * volumes_changed: — called when a volume is mounted or unmounted; posts
 * FilesVolumesChangedNotification on the main queue.
 *
 * Inputs:
 *   note — workspace notification (unused)
 */
- (void)
volumes_changed:(NSNotification *)note
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FilesVolumesChangedNotification
                          object:self];
    });
}

/*
 * mounted_volumes — returns visible mounted volumes.
 *
 * Output: NSArray<NSURL *>, never nil.
 */
- (NSArray<NSURL *> *)
mounted_volumes
{
    NSArray<NSURL *> *vols =
        [NSFileManager.defaultManager
            mountedVolumeURLsIncludingResourceValuesForKeys:@[]
            options:NSVolumeEnumerationSkipHiddenVolumes];
    return vols ?: @[];
}

/*
 * display_name_for_volume: — returns the volume's display name.
 *
 * Inputs:
 *   url — volume root URL
 *
 * Output: display name string.
 */
- (NSString *)
display_name_for_volume:(NSURL *)url
{
    NSString *name = nil;
    [url getResourceValue:&name forKey:NSURLVolumeNameKey error:nil];
    return name ?: url.lastPathComponent;
}

/*
 * can_eject_volume: — returns YES if volume is ejectable or removable.
 *
 * Inputs:
 *   url — volume root URL
 */
- (BOOL)
can_eject_volume:(NSURL *)url
{
    NSNumber *ejectable = nil;
    NSNumber *removable = nil;
    [url getResourceValue:&ejectable forKey:NSURLVolumeIsEjectableKey error:nil];
    [url getResourceValue:&removable forKey:NSURLVolumeIsRemovableKey error:nil];
    return ejectable.boolValue || removable.boolValue;
}

/*
 * eject_volume:completion: — ejects volume on background queue.
 *
 * Inputs:
 *   url        — volume root URL
 *   completion — called on main queue with nil error on success
 */
- (void)
eject_volume:(NSURL *)url
  completion:(void (^)(NSError *))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        BOOL ok = [NSWorkspace.sharedWorkspace unmountAndEjectDeviceAtURL:url
                                                                    error:&err];
        if (!ok && !err) {
            err = [NSError errorWithDomain:NSCocoaErrorDomain
                                      code:NSFileWriteUnknownError
                                  userInfo:@{NSLocalizedDescriptionKey: @"Eject failed"}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(ok ? nil : err);
            }
        });
    });
}

@end
