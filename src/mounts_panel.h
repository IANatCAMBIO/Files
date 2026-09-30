#import <Cocoa/Cocoa.h>

/*
 * FilesMountsPanel — utility panel listing all currently mounted filesystems.
 * Shows device name, mount point, filesystem type, mount options, capacity,
 * free space, and whether the volume can be unmounted, with Unmount and
 * Refresh buttons. Uses getmntinfo(3) for the raw mount table and
 * FilesVolumeManager for volume details and unmounting.
 */
@interface FilesMountsPanel : NSWindowController

/*
 * shared — returns the process-wide singleton instance.
 *
 * Output: FilesMountsPanel singleton, never nil.
 */
+ (instancetype)shared;

/*
 * show_panel — reloads the mount list, sizes the window to fit it, and brings
 * the panel to the front.
 *
 * Output: none.
 */
- (void)show_panel;

@end
