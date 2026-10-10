#import <Cocoa/Cocoa.h>

/*
 * FilesToolPanel — a small floating tool window for asking the user
 * something, in the style of the Tasks reminders window: a utility-titlebar
 * panel with a solid blue hero strip (icon, bold title, subtitle) at the
 * top, the caller's controls below it, and a button bar at the bottom
 * (Cancel / primary-action by default). It is not modal: it floats above ordinary
 * windows until the user clicks a button, presses Return (primary) or
 * Escape (Cancel), or closes it. All methods must be called on the main
 * thread.
 */
@interface FilesToolPanel : NSObject

/*
 * panel_with_title:hero_title:subtitle:symbol:content:primary_title:primary_handler: —
 * builds a panel; show_over: displays it. It keeps itself alive while it is
 * on screen.
 *
 * Inputs:
 *   window_title    — title bar text
 *   hero_title      — bold line in the hero strip
 *   subtitle        — second line in the hero strip; shows problems too
 *   symbol          — SF Symbols name for the hero icon; may be nil
 *   content         — the controls, sized by their own fittingSize
 *                     (fixed widths and heights); not retained after close
 *   primary_title   — label of the default button, e.g. @"Create"
 *   primary_handler — called when the primary button is clicked; returns
 *                     nil to accept (the panel closes) or a one-line
 *                     problem to show in the hero strip (it stays open)
 *
 * Output: the panel.
 */
+ (instancetype)panel_with_title:(NSString *)window_title
                      hero_title:(NSString *)hero_title
                        subtitle:(NSString *)subtitle
                          symbol:(NSString *)symbol
                         content:(NSView *)content
                   primary_title:(NSString *)primary_title
                 primary_handler:(NSString *(^)(void))primary_handler;

/*
 * show_message:message:symbol:buttons:over:handler: — shows a message in a
 * tool panel and returns at once: the replacement for a native alert.
 * Wherever a native dialog would appear, Files uses this.
 *
 * Inputs:
 *   title   — headline, in the hero strip
 *   message — wrapped body text (long text scrolls); may be empty
 *   symbol  — SF Symbols name for the hero icon, e.g.
 *             @"exclamationmark.triangle.fill"; may be nil
 *   buttons — button labels, at least one: [0] is the default (Return) and
 *             sits rightmost, the last of several answers Escape
 *   parent  — window to centre over; nil = the screen
 *   handler — called once on the main thread with the index of the clicked
 *             button, or -1 if the panel was closed without one; may be nil
 */
+ (void)show_message:(NSString *)title
             message:(NSString *)message
              symbol:(NSString *)symbol
             buttons:(NSArray<NSString *> *)buttons
                over:(NSWindow *)parent
             handler:(void (^)(NSInteger index))handler;

/*
 * show_over: — centres the panel over parent (the screen if nil), brings it
 * forward and makes it key.
 *
 * Inputs:
 *   parent — window to centre over; may be nil
 */
- (void)show_over:(NSWindow *)parent;

/*
 * window — the underlying panel, e.g. to set the first responder.
 *
 * Output: the NSPanel.
 */
- (NSPanel *)window;

@end
