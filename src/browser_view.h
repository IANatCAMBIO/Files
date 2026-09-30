#import <Cocoa/Cocoa.h>

/*
 * FilesBrowserView — NSView subclass containing the file-list table, the
 * folder watcher (FSEvents), Spotlight search, and the back/forward history.
 * It has no status bar of its own; it reports status text through
 * status_text_handler. All methods must be called on the main thread.
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
 * open_window_handler — called to show a folder in a new window (used for
 * the volume of a newly mounted disk image). If nil, the folder is shown in
 * this browser instead.
 */
@property (nonatomic, copy) void (^open_window_handler)(NSURL *url);

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
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/*
 * navigate_to: — shows url if it is a folder, pushing the previous location
 * onto the back stack (capped at 100 entries) and clearing the forward
 * stack. A disk image is mounted and its volume shown via
 * open_window_handler; any other item is opened with its default
 * application. Symbolic links are followed to their target first.
 *
 * Inputs:
 *   url — target URL
 */
- (void)navigate_to:(NSURL *)url;

/*
 * reveal_items: — selects the named items of the current folder once it has
 * been re-listed, scrolling the first into view (ends any Spotlight search).
 * Items that are hidden while hidden files are not shown stay unselected.
 *
 * Inputs:
 *   names — file names (last path components) within current_url
 */
- (void)reveal_items:(NSArray<NSString *> *)names;

/*
 * go_back — navigates to the previous location, if any.
 */
- (void)go_back;

/*
 * go_forward — navigates to the next location in the forward stack, if any.
 */
- (void)go_forward;

/*
 * can_go_back — whether a back navigation target exists.
 *
 * Output: YES if go_back would navigate.
 */
- (BOOL)can_go_back;

/*
 * can_go_forward — whether a forward navigation target exists.
 *
 * Output: YES if go_forward would navigate.
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
 * reload_directory — re-reads the current folder on a background queue and
 * refreshes the table when the listing arrives (selection kept by path).
 * No-op while Spotlight results are displayed.
 */
- (void)reload_directory;

/*
 * Action methods wired to the menu / responder chain (Go-menu and view
 * toggles live on FilesMainWindow so they work whatever has focus and apply
 * to the active or every pane). copy:, cut:, paste:
 * and selectAll: are the standard AppKit editing selectors, so when a text
 * field (address bar, search, inline rename) is first responder its field
 * editor handles them instead and they act on text, not files.
 */
- (IBAction)copy:(id)sender;
- (IBAction)cut:(id)sender;
- (IBAction)paste:(id)sender;
- (IBAction)move_to_trash_action:(id)sender;
- (IBAction)new_folder_action:(id)sender;
- (IBAction)new_file_action:(id)sender;
- (IBAction)get_info_action:(id)sender;
- (IBAction)selectAll:(id)sender;

/*
 * empty_trash_action: — confirms, then permanently deletes everything in the
 * Trash on a background queue.
 *
 * Inputs:
 *   sender — the Empty Trash button (unused)
 */
- (IBAction)empty_trash_action:(id)sender;

@end
