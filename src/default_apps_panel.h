#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/*
 * default_apps_panel — the window behind Files ▸ Set Default Apps…: every
 * file type this Mac knows about, with its icon, its filename extensions,
 * its kind and the application macOS opens it with, and a chooser that
 * points a type at a different application.
 *
 * macOS keeps the default application per *content type* (a UTI such as
 * public.jpeg), not per extension, and one type usually carries several
 * extensions (public.jpeg is .jpeg, .jpg and .jpe). So the list holds one
 * row per type, listing every extension it covers, and changing a row's
 * application changes what opens all of them — which is what the user
 * asked for ("all files of that extension") and the only thing
 * LaunchServices can actually do. The Type column names the type so the
 * reason two extensions move together is visible.
 *
 * Changes go through NSWorkspace, so they are the same system-wide
 * defaults Finder's "Open with ▸ Change All…" sets: they outlive Files
 * and apply to every app that opens a document.
 */

/*
 * files_default_app_types — every file type this Mac can name an
 * application for. The applications installed on it and macOS itself
 * (CoreTypes.bundle) say in their Info.plists which types and extensions
 * they have to do with; each extension found is then resolved back, as a
 * plain file and as a package, to the type a file carrying it really
 * gets, and those are the types listed.
 *
 * Resolving rather than listing the declarations is what keeps the list
 * honest: a declaration two applications both make for .ada yields one
 * type a .ada file can be, not two, and a type that only ever appears on a
 * package (.rtfd, .workflow) is found, which its extension alone would
 * not have given.
 *
 * An extension that no declaration names resolves to a dynamic type (a
 * "dyn." identifier, with no localized description). Those are kept:
 * LaunchServices records a default application against them too.
 *
 * Reads a few hundred Info.plists, so it takes a few hundred
 * milliseconds: call it on a background queue, never on the main thread.
 *
 * Output: the types, each identifier appearing once, in no useful order.
 */
NSArray<UTType *> *files_default_app_types(void);

/*
 * files_default_apps_panel — ordinary window (not a utility panel: a list
 * to read and work in beside a browser window, as All Mounts is) listing
 * the file types from files_default_app_types with their default
 * applications. Double-clicking a row, pressing Return on it or clicking
 * Change… opens the chooser.
 */
@interface files_default_apps_panel : NSWindowController

/*
 * shared — the process-wide singleton.
 *
 * Output: the panel, never nil.
 */
+ (instancetype)shared;

/*
 * show_panel — brings the window forward and reloads the list, so it
 * always shows the defaults as they are now (another app, or Finder, may
 * have changed one since it was last open).
 */
- (void)show_panel;

/*
 * show_panel_for_type: — shows the window with one type selected and
 * scrolled into view: Get Info's "change" link beside Opens with arrives
 * here with the type of the item it is showing.
 *
 * Any filter typed in the search field is cleared first, so a row cannot
 * be hidden by one, and the rest of the list stays around the selected
 * row rather than being narrowed to it.
 *
 * A type the scan did not list — a file whose extension nothing installed
 * declares a type for — is added for this window rather than silently
 * selecting nothing, so the link always lands somewhere.
 *
 * Inputs:
 *   type — the content type to select; nil only shows the window
 */
- (void)show_panel_for_type:(UTType *)type;

@end
