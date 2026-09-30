#import <Cocoa/Cocoa.h>

/*
 * FilesVolumesChangedNotification — posted on the main thread when a volume
 * is mounted, unmounted, or renamed.
 */
extern NSString * const FilesVolumesChangedNotification;

/*
 * FilesVolumeManager — singleton that monitors mounted volumes and provides
 * unmount support. Observes NSWorkspaceDidMountNotification,
 * NSWorkspaceDidUnmountNotification and NSWorkspaceDidRenameVolumeNotification.
 */
@interface FilesVolumeManager : NSObject

/*
 * init — unavailable; use +shared.
 */
- (instancetype)init NS_UNAVAILABLE;

/*
 * shared — returns the process-wide singleton instance, creating it on the
 * first call.
 *
 * Output: FilesVolumeManager singleton, never nil.
 */
+ (instancetype)shared;

/*
 * mounted_volumes — returns the current list of user-visible mounted volumes,
 * with the resource values used by display_name_for_volume: and
 * can_unmount_volume: prefetched.
 *
 * Output: NSArray<NSURL *> of volume root URLs, never nil.
 */
- (NSArray<NSURL *> *)mounted_volumes;

/*
 * display_name_for_volume: — returns the volume name as Finder shows it
 * (NSURLVolumeLocalizedNameKey).
 *
 * Inputs:
 *   url — volume root URL
 *
 * Output: display name string, or the last path component on failure.
 */
- (NSString *)display_name_for_volume:(NSURL *)url;

/*
 * can_unmount_volume: — decides whether the user may unmount a volume.
 * Rule: never the root (boot) file system; otherwise any network volume,
 * any external (non-internal) volume, and any ejectable or removable volume.
 * Fixed internal local volumes (e.g. system/data partitions) are refused.
 *
 * Inputs:
 *   url — volume root URL
 *
 * Output: YES if the volume may be unmounted, NO otherwise.
 */
- (BOOL)can_unmount_volume:(NSURL *)url;

/*
 * unmount_volume:completion: — asynchronously unmounts just this volume
 * (other partitions of the same physical disk stay mounted).
 *
 * Inputs:
 *   url        — volume root URL
 *   completion — called on the main thread; error is nil on success; may be nil
 */
- (void)unmount_volume:(NSURL *)url completion:(void (^)(NSError *err))completion;

@end
