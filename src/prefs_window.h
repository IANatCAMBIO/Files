#import <Cocoa/Cocoa.h>

/*
 * prefs_window — the Preferences tool window (Files ▸ Preferences…, ⌘,).
 *
 * View: the order new file lists start in (files_pref_sort_column,
 * files_pref_sort_ascending; every browser follows it), the View menu's
 * first group of preferences, as checkboxes, and Show Hashes in Get Info
 * (files_pref_show_hashes; FilesInfoPanel follows it).
 * Move/Copy: the View menu's remaining preference groups, which govern
 * how transfers run (files_pref_simple_copies, files_pref_hash_validation).
 * Integration: the default file browser (its current choice and "Set
 * default file browser to Files" / "… to Finder" buttons, each opening a
 * change log; files_default_viewer_choose, which also sets whether Archive
 * Utility reveals its results in Finder) and "Keep Files running for
 * faster startup" (files_pref_keep_running; FilesAppDelegate applies it).
 *
 * Controls write NSUserDefaults and redraw from them whenever any
 * preference changes, so the window, the menus and the app never disagree.
 */

/*
 * files_view_pref_groups — the View menu's preference checkboxes, in the
 * groups the menu separates them into. The View menu and Preferences are
 * both built from this list.
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
