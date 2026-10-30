#import <Cocoa/Cocoa.h>

/*
 * FilesBrowserView — NSView subclass containing the file-list table, the
 * folder watcher (FSEvents), Spotlight search, and the back/forward history.
 * It has no status bar of its own; it reports status text through
 * status_text_handler. All methods must be called on the main thread.
 */
/*
 * files_column_sorts — whether the file list can be sorted by a column,
 * i.e. whether it has a value of its own to compare. Permissions and
 * Comment do not, so their headers do nothing when clicked.
 *
 * Inputs:
 *   col_id — column identifier
 *
 * Output: YES if clicking that column's header sorts the list.
 */
BOOL files_column_sorts(NSString *col_id);

/*
 * files_sort_columns — the file-list columns a default sort order can name,
 * in header order. Those are the sortable columns (files_column_sorts)
 * bar Git, which is left out because it exists only inside a repository.
 * Preferences builds its Default sort menu from this, so the choices and
 * the sorting cannot disagree.
 *
 * Output: array of @[title, column identifier] pairs, never empty.
 */
NSArray<NSArray<NSString *> *> *files_sort_columns(void);

/*
 * files_sort_default_column — the column a new file list sorts by
 * (files_pref_sort_column), worded as a column identifier. This is where
 * the shipped default lives, so files_pref_sort_column registers none.
 *
 * Output: an identifier from files_sort_columns(); Date Modified when the
 *         preference is unset or names no column that can be a default
 *         (an older or hand-edited defaults value), so a stale setting
 *         cannot leave lists sorted by something no header shows an arrow
 *         for. Date Modified rather than Date Created because the Date
 *         Created column is hidden by default.
 */
NSString *files_sort_default_column(void);

/*
 * files_sort_order_titles — the two directions a column sorts in, worded
 * for what that column holds ("Newest first" rather than "Descending"),
 * for the Default sort menu.
 *
 * Inputs:
 *   col_id — column identifier, normally from files_sort_columns()
 *
 * Output: @[ascending title, descending title]; the A → Z pair for an
 *         identifier that is not a column of its own.
 */
NSArray<NSString *> *files_sort_order_titles(NSString *col_id);

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
 * loading_handler — called whenever loading changes.
 */
@property (nonatomic, copy) void (^loading_handler)(void);

/*
 * open_window_handler — called to show a folder in a new window (used for
 * the volume of a newly mounted disk image and the folder an archive was
 * extracted to). If nil, the folder is shown in
 * this browser instead.
 */
@property (nonatomic, copy) void (^open_window_handler)(NSURL *url);

/*
 * bookmark_handler — called with a folder the user chose to bookmark
 * (context menu ▸ Add to Bookmarks).
 */
@property (nonatomic, copy) void (^bookmark_handler)(NSURL *url);

/*
 * split_pane_handler — called with a folder the user chose to open in the
 * other pane (context menu ▸ Open in Split Pane). If nil, the item is hidden.
 */
@property (nonatomic, copy) void (^split_pane_handler)(NSURL *url);

/*
 * status_text — the text last passed to status_text_handler (item count,
 * selection, listing error or progress message); nil before the first.
 */
@property (nonatomic, copy, readonly) NSString *status_text;

/*
 * loading — YES while a navigation check or folder listing has been
 * running for longer than a moment (slow or unresponsive volumes, e.g. File Provider mounts); NO
 * once it lands, is superseded or the browser shuts down.
 */
@property (nonatomic, assign, readonly) BOOL loading;

/*
 * The clip view showing the rows: the file list's visible area, which ends
 * where the scrollers begin. For anchoring overlays to the list.
 */
@property (nonatomic, readonly) NSView *list_view;

/*
 * list_insets — how far the scrollers, when shown as legacy bars that sit
 * over the clip view's edge, cut into the right and bottom of list_view;
 * zero for an edge with no bar (hidden, or overlay scrollers).
 */
@property (nonatomic, readonly) NSEdgeInsets list_insets;

/*
 * list_layout_handler — called when a scroller is shown or hidden, i.e.
 * when list_insets changes.
 */
@property (nonatomic, copy) void (^list_layout_handler)(void);

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
 * open_window_handler; an archive (.zip, .tar, .tar.gz, .tgz) is extracted
 * next to itself and the new folder shown the same way; any other item is
 * opened with its default application. Symbolic links are followed to their target first.
 * Asynchronous: the item is examined on a background queue, and a folder
 * is shown only if no newer navigate_to: was called meanwhile.
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
 * set_search_filter: — triggers a Spotlight search for names containing
 * text, within the current directory (and its subfolders) or, with
 * files_pref_search_this_mac on, the whole Mac. Pass nil or empty string
 * to cancel and restore the directory listing.
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
 * refresh — Reload: re-lists the current folder and, with Show Folder
 * Sizes on, counts its folders' sizes again (a listing refresh keeps the
 * totals already counted).
 */
- (void)refresh;

/*
 * shut_down — stops the folder watcher, any Spotlight search and
 * preference observing, for a browser whose window is closing. The
 * browser shows nothing new afterwards.
 */
- (void)shut_down;

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
- (IBAction)paste_into:(id)sender;
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
