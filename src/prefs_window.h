#import <Cocoa/Cocoa.h>

/*
 * prefs_window — the Preferences tool window (Files ▸ Preferences…, ⌘,).
 *
 * View: the View menu's preferences, as checkboxes.
 * Integration: the default file browser (Files or Finder;
 * files_default_viewer_choose), "Keep Files running for faster startup"
 * (files_pref_keep_running; FilesAppDelegate applies it) and Show Finder
 * After Archive Operations (from the View menu's list, since it changes
 * Archive Utility's settings).
 *
 * Controls write NSUserDefaults and redraw from them whenever any
 * preference changes, so the window, the menus and the app never disagree.
 */

/*
 * files_view_pref_groups — the View menu's preference checkboxes, in the
 * groups the menu separates them into. The View menu and Preferences are
 * both built from this list (Preferences shows Show Finder After Archive
 * Operations under Integration).
 *
 * Output: array of groups; each group is an array of @[title, key] pairs,
 *         key being a files_pref_* constant.
 */
NSArray<NSArray<NSArray<NSString *> *> *> *files_view_pref_groups(void);

@interface FilesPrefsWindow : NSWindowController

/*
 * shared — returns the process-wide singleton, creating it on first call.
 *
 * Output: FilesPrefsWindow singleton, never nil.
 */
+ (instancetype)shared;

/*
 * show_window — refreshes the controls and brings the window to the front.
 */
- (void)show_window;

@end
