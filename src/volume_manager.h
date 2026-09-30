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

/*
 * open_files_on_volume:completion: — lists what is keeping a volume busy:
 * files and folders on it that processes have open (via lsof; only the
 * current user's processes are visible). Runs in the background.
 *
 * Inputs:
 *   volume     — volume root URL
 *   completion — called on the main thread with one description per open
 *                item, e.g. "inner/a.txt — Preview" or "Projects (folder)
 *                — Terminal"; empty if nothing visible is open
 */
- (void)open_files_on_volume:(NSURL *)volume
                  completion:(void (^)(NSArray<NSString *> *items))completion;

/*
 * mount_disk_image:completion: — mounts a disk image (.dmg, .iso, …) and
 * reports the mounted volume. Runs `hdiutil attach` in the background
 * without a terminal, so it can never block on a prompt; an image that is
 * already attached just reports its existing volume. If hdiutil cannot
 * mount the image by itself (password-protected, license agreement), the
 * image is handed to the system's DiskImageMounter, which asks the user,
 * and the volume is reported once it appears (up to 2 minutes).
 *
 * Inputs:
 *   image      — disk image file URL
 *   completion — called once on the main thread with the volume root URL;
 *                or with an error if the image could not be opened at
 *                all; or with (nil, nil) if the user never finished
 *                mounting it (e.g. cancelled the password prompt)
 */
- (void)mount_disk_image:(NSURL *)image
              completion:(void (^)(NSURL *volume, NSError *err))completion;

@end
