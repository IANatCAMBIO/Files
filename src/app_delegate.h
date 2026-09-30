#import <Cocoa/Cocoa.h>

/*
 * FilesAppDelegate — NSApplicationDelegate that bootstraps the application,
 * builds the menu bar, and owns the browser windows (the first shows the
 * home folder; more open via File ▸ New Window, for newly mounted disk
 * images, and for "Show in Finder" requests while Files is the default
 * file viewer — see default_viewer.h).
 */
@interface FilesAppDelegate : NSObject <NSApplicationDelegate>
@end
