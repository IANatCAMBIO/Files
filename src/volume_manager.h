#import <Cocoa/Cocoa.h>

/*
 * FilesVolumesChangedNotification — posted on main queue when volumes are
 * mounted or unmounted.
 */
extern NSString * const FilesVolumesChangedNotification;

/*
 * FilesVolumeManager — singleton that monitors mounted volumes and provides
 * eject support. Observes NSWorkspaceDidMountNotification and
 * NSWorkspaceDidUnmountNotification.
 */
@interface FilesVolumeManager : NSObject

/*
 * shared — returns the process-wide singleton instance.
 */
+ (instancetype)shared;

/*
 * mounted_volumes — returns the current list of user-visible mounted volumes.
 *
 * Output: NSArray<NSURL *> of volume root URLs, never nil.
 */
- (NSArray<NSURL *> *)mounted_volumes;

/*
 * display_name_for_volume: — returns the human-readable name for a volume.
 *
 * Inputs:
 *   url — volume root URL
 *
 * Output: display name string, or last path component on failure.
 */
- (NSString *)display_name_for_volume:(NSURL *)url;

/*
 * can_eject_volume: — returns YES if the volume at url can be ejected.
 *
 * Inputs:
 *   url — volume root URL
 */
- (BOOL)can_eject_volume:(NSURL *)url;

/*
 * eject_volume:completion: — ejects the volume at url on a background queue.
 *
 * Inputs:
 *   url        — volume root URL
 *   completion — called on main queue; error is nil on success
 */
- (void)eject_volume:(NSURL *)url completion:(void (^)(NSError *))completion;

@end
