#import <Cocoa/Cocoa.h>
#import "app_delegate.h"

/*
 * main — application entry point.
 *
 * Inputs:
 *   argc — argument count
 *   argv — argument vector
 *
 * Output: never returns normally; exits via NSApp.terminate.
 */
int
main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app         = [NSApplication sharedApplication];
        FilesAppDelegate *delegate = [[FilesAppDelegate alloc] init];
        app.delegate               = delegate;
        [app run];
    }
    return 0;
}
