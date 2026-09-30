#import <Cocoa/Cocoa.h>

/* ── Data model ──────────────────────────────────────────────────────── */

/*
 * FilesSidebarItem — one entry in the sidebar (a favourite or a volume).
 */
@interface FilesSidebarItem : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSURL    *url;
@property (nonatomic, assign) BOOL      is_volume;
@property (nonatomic, assign) BOOL      can_eject;
@end

/*
 * FilesSidebarSection — a collapsible group header (Favorites / Devices).
 */
@interface FilesSidebarSection : NSObject
@property (nonatomic, strong) NSString                        *title;
@property (nonatomic, strong) NSMutableArray<FilesSidebarItem *> *items;
@end

/* ── FilesSidebar ────────────────────────────────────────────────────── */

/*
 * FilesSidebar — manages an NSOutlineView used as the places sidebar.
 * The caller creates and owns the NSOutlineView; this object sets itself as
 * its data source and delegate.
 */
@interface FilesSidebar : NSObject

/*
 * outline_view — the outline view this object manages. Set before calling
 * setup.
 */
@property (nonatomic, weak) NSOutlineView *outline_view;

/*
 * selection_handler — called on the main queue when the user clicks an item.
 * Receives the item's URL.
 */
@property (nonatomic, copy) void (^selection_handler)(NSURL *url);

/*
 * setup — populates favourites, loads volumes, registers for volume-change
 * notifications, and reloads the outline view. Must be called after
 * outline_view is set.
 */
- (void)setup;

/*
 * reload_volumes — refreshes the Devices section from FilesVolumeManager.
 */
- (void)reload_volumes;

/*
 * select_url: — highlights the sidebar row matching url, if any.
 *
 * Inputs:
 *   url — URL to select
 */
- (void)select_url:(NSURL *)url;

@end
