#import <Cocoa/Cocoa.h>

/*
 * FilesBrowserView — NSView subclass containing the file-list table, status
 * bar, FSEvents watcher, and back/forward navigation stack.
 */
@interface FilesBrowserView : NSView

/*
 * navigation_handler — called on main queue after any navigation event.
 * Receives the new current URL. Use it to update toolbar controls.
 */
@property (nonatomic, copy) void (^navigation_handler)(NSURL *url);

/*
 * info_handler — called when the user requests Get Info on selected files.
 * Receives an array of selected URLs.
 */
@property (nonatomic, copy) void (^info_handler)(NSArray<NSURL *> *urls);

/*
 * sidebar_handler — called on the main queue whenever the table selection
 * changes. Receives the current selected URLs (empty array = nothing selected).
 */
@property (nonatomic, copy) void (^sidebar_handler)(NSArray<NSURL *> *urls);

/*
 * status_text_handler — called whenever the status bar text changes.
 * Receives the formatted item-count string.
 */
@property (nonatomic, copy) void (^status_text_handler)(NSString *text);

/*
 * trash_visible_handler — called when navigating to or away from ~/.Trash.
 * Receives YES when the Empty Trash button should be shown.
 */
@property (nonatomic, copy) void (^trash_visible_handler)(BOOL show);

/*
 * init_with_frame: — designated initialiser; builds subviews and sets up the
 * table.
 *
 * Inputs:
 *   frame — initial frame
 *
 * Output: configured FilesBrowserView, or nil on failure.
 */
- (instancetype)init_with_frame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;

/*
 * navigate_to: — navigates to url, pushing the previous location onto the
 * back stack and clearing the forward stack.
 *
 * Inputs:
 *   url — target directory URL
 */
- (void)navigate_to:(NSURL *)url;

/*
 * go_back — navigates to the previous location, if any.
 */
- (void)go_back;

/*
 * go_forward — navigates to the next location in the forward stack, if any.
 */
- (void)go_forward;

/*
 * can_go_back — returns YES if a back navigation target exists.
 */
- (BOOL)can_go_back;

/*
 * can_go_forward — returns YES if a forward navigation target exists.
 */
- (BOOL)can_go_forward;

/*
 * current_url — returns the URL of the directory currently displayed.
 *
 * Output: NSURL, or nil if no directory loaded.
 */
- (NSURL *)current_url;

/*
 * selected_urls — returns the URLs of all currently selected rows.
 *
 * Output: NSArray<NSURL *>, empty if nothing selected.
 */
- (NSArray<NSURL *> *)selected_urls;

/*
 * set_search_filter: — triggers a Spotlight search for text within the current
 * directory. Pass nil or empty string to cancel and restore the directory listing.
 *
 * Inputs:
 *   text — search string; nil/empty restores normal listing
 */
- (void)set_search_filter:(NSString *)text;

/*
 * reload_directory — re-reads the current directory and refreshes the table.
 * Safe to call from any context that holds a reference to this view.
 */
- (void)reload_directory;

/*
 * begin_spotlight_search:scope: — starts an NSMetadataQuery Spotlight search
 * for filenames containing query within scope directory and its subdirectories.
 *
 * Inputs:
 *   query — search string (matched against kMDItemDisplayName, case-insensitive)
 *   scope — directory URL to scope the search to
 */
- (void)begin_spotlight_search:(NSString *)query scope:(NSURL *)scope;

/*
 * end_spotlight_search — stops any active Spotlight search and restores the
 * directory listing for the current directory.
 */
- (void)end_spotlight_search;

/*
 * Action methods wired to the menu / responder chain.
 */
- (IBAction)copy_action:(id)sender;
- (IBAction)cut_action:(id)sender;
- (IBAction)paste_action:(id)sender;
- (IBAction)move_to_trash_action:(id)sender;
- (IBAction)new_folder_action:(id)sender;
- (IBAction)get_info_action:(id)sender;
- (IBAction)select_all_action:(id)sender;
- (IBAction)go_back_action:(id)sender;
- (IBAction)go_forward_action:(id)sender;
- (IBAction)go_home_action:(id)sender;
- (IBAction)go_desktop_action:(id)sender;
- (IBAction)go_downloads_action:(id)sender;
- (IBAction)go_documents_action:(id)sender;

/*
 * toggle_hidden_files_action: — toggles "files.show_hidden_files" in
 * NSUserDefaults and reloads the current directory.
 */
- (IBAction)toggle_hidden_files_action:(id)sender;

/*
 * empty_trash_action: — confirms and permanently deletes all items in ~/.Trash.
 */
- (IBAction)empty_trash_action:(id)sender;

/*
 * apply_auto_fit — resizes every column to fit its widest content.
 * Called by FilesMainWindow when the Auto-Fit Columns toggle is turned on.
 */
- (void)apply_auto_fit;

@end
