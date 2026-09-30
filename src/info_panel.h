#import <Cocoa/Cocoa.h>

/*
 * FilesInfoPanel — "Get Info" panel showing file attributes for a given URL.
 * Singleton-style: show_for_url: reuses the same window.
 */
@interface FilesInfoPanel : NSWindowController

/*
 * shared — returns the process-wide singleton panel.
 */
+ (instancetype)shared;

/*
 * show_for_url: — populates the panel with attributes for url and makes it
 * visible. Safe to call when panel is already visible; updates content in place.
 *
 * Inputs:
 *   url — file or directory URL to inspect
 */
- (void)show_for_url:(NSURL *)url;

@end
