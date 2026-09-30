#import <Cocoa/Cocoa.h>

/*
 * FilesMountsPanel — utility panel listing all currently mounted filesystems.
 * Shows device name, mount point, filesystem type, mount options, and an eject
 * button for removable volumes. Uses getmntinfo(3) for the raw mount table and
 * FilesVolumeManager for eject support.
 */
@interface FilesMountsPanel : NSWindowController

/*
 * shared — returns the process-wide singleton instance.
 *
 * Output: FilesMountsPanel singleton.
 */
+ (instancetype)shared;

/*
 * show_panel — brings the mounts panel to the front, refreshing the list.
 */
- (void)show_panel;

@end
