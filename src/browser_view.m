#import "browser_view.h"
#import "archive.h"
#import "file_ops.h"
#import "git_info.h"
#import "info_panel.h"
#import "util.h"
#import "volume_manager.h"
#import <CoreServices/CoreServices.h>
#import <Quartz/Quartz.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/stat.h>
#include <limits.h>
#include <stdlib.h>

/* Column identifiers */
static NSString * const col_name     = @"name";
static NSString * const col_size     = @"size";
static NSString * const col_kind     = @"kind";
static NSString * const col_perms    = @"perms";
static NSString * const col_modified = @"modified";
static NSString * const col_comment  = @"comment";
static NSString * const col_git      = @"git";   /* shown only inside a repo */

/*
 * column_spec_t — static description of one table column.
 */
typedef struct {
    NSString * __unsafe_unretained id;
    NSString * __unsafe_unretained title;   /* header title without sort arrow */
    CGFloat width;
    CGFloat min_width;
} column_spec_t;

static const column_spec_t column_specs[] = {
    { @"name",     @"Name",          260, 120 },
    { @"size",     @"Size",           80,  50 },
    { @"kind",     @"Kind",          120,  80 },
    { @"perms",    @"Permissions",    90,  70 },
    { @"modified", @"Date Modified", 160, 120 },
    { @"comment",  @"Comment",       200, 100 },
    { @"git",      @"Git",            60,  40 },
};
#define COLUMN_COUNT (sizeof(column_specs) / sizeof(column_specs[0]))

/* Row height and Name-column icon size; Large Rows (files_pref_large_rows)
 * doubles both. */
static const CGFloat row_height_normal = 20.0;
static const CGFloat icon_size_normal  = 16.0;

/* Most back/forward entries kept; older ones are dropped. */
#define HISTORY_LIMIT 100

/* Rows measured by auto-fit; beyond this the widest name is almost surely seen. */
#define AUTO_FIT_ROW_LIMIT 2000

/* Delay used to coalesce bursts of file-system events into one reload. */
#define WATCH_COALESCE_SEC 0.25

/*
 * listing_keys — resource keys prefetched for every listed item, so table
 * cells, sorting and filtering never touch the file system again.
 *
 * Output: array of NSURLResourceKey.
 */
static NSArray<NSURLResourceKey> *
listing_keys(void)
{
    return @[
        NSURLNameKey,
        NSURLFileSizeKey,
        NSURLIsDirectoryKey,
        NSURLIsPackageKey,
        NSURLIsApplicationKey,
        NSURLIsSymbolicLinkKey,
        NSURLTypeIdentifierKey,
        NSURLLocalizedTypeDescriptionKey,
        NSURLContentModificationDateKey,
        NSURLFileSecurityKey,
        NSURLIsHiddenKey,
    ];
}

/*
 * column_title — header title (without sort arrow) for a column identifier.
 *
 * Inputs:
 *   col_id — column identifier
 *
 * Output: title string, or @"" for an unknown identifier.
 */
static NSString *
column_title(NSString *col_id)
{
    for (size_t i = 0; i < COLUMN_COUNT; i++) {
        if ([column_specs[i].id isEqualToString:col_id]) return column_specs[i].title;
    }
    return @"";
}

/*
 * sort_resource_key — the prefetched resource key a column sorts by.
 *
 * Inputs:
 *   col_id — column identifier
 *
 * Output: NSURLResourceKey (name for unknown columns; the Git column sorts
 *         by name within tracked / untracked, see listing_rows).
 */
static NSURLResourceKey
sort_resource_key(NSString *col_id)
{
    if ([col_id isEqualToString:col_size])     return NSURLFileSizeKey;
    if ([col_id isEqualToString:col_kind])     return NSURLLocalizedTypeDescriptionKey;
    if ([col_id isEqualToString:col_modified]) return NSURLContentModificationDateKey;
    return NSURLNameKey;
}

/*
 * file_mode — POSIX mode (type + permission bits) from the prefetched
 * NSURLFileSecurityKey; equals lstat(2)'s st_mode without a system call.
 *
 * Inputs:
 *   url — file URL from a listing
 *
 * Output: mode, or 0 if unavailable.
 */
static mode_t
file_mode(NSURL *url)
{
    NSFileSecurity *sec = nil;
    [url getResourceValue:&sec forKey:NSURLFileSecurityKey error:nil];
    mode_t mode = 0;
    if (!sec || !CFFileSecurityGetMode((__bridge CFFileSecurityRef)sec, &mode)) return 0;
    return mode;
}

/*
 * perms_string_for_mode — formats a POSIX mode_t as the 10-char ls -l
 * string, with strmode(3).
 *
 * Inputs:
 *   mode — st_mode (type and permission bits)
 *
 * Output: e.g. "drwxr-xr-x".
 */
static NSString *
perms_string_for_mode(mode_t mode)
{
    char b[12];
    strmode(mode, b);
    b[10] = '\0';  /* drop the trailing space strmode leaves for ACL markers */
    return @(b);
}

/* Most Spotlight results shown; a broad search can match far more. */
#define SEARCH_RESULT_LIMIT 5000

/*
 * git_index_stamp — identifies the state of a git index file by its
 * modification time and size, which change whenever git rewrites it.
 *
 * Inputs:
 *   index — path of the index file, or nil
 *
 * Output: opaque stamp string, or nil if there is no readable index.
 */
static NSString *
git_index_stamp(NSString *index)
{
    struct stat st;
    if (!index || stat(index.fileSystemRepresentation, &st) != 0) return nil;
    return [NSString stringWithFormat:@"%ld.%09ld:%lld", (long)st.st_mtimespec.tv_sec,
            (long)st.st_mtimespec.tv_nsec, (long long)st.st_size];
}

/*
 * listing_rows — the rows to show for a set of items: hidden items dropped
 * (unless show_hidden), then sorted folders-first and by the sort column
 * using prefetched values (Finder-style natural order for names and
 * kinds). The Git column sorts tracked items first (ascending), then by
 * name. Pure and thread-safe, so listings are prepared off the main thread.
 *
 * Inputs:
 *   items       — listed URLs with listing_keys() prefetched
 *   sort_key    — column identifier to sort by
 *   ascending   — sort direction
 *   tracked     — git-tracked names (used only when sorting by Git); may be nil
 *   sizes       — folder sizes by path (Show Folder Sizes), used when
 *                 sorting by Size; may be nil
 *   show_hidden — YES to keep items whose NSURLIsHiddenKey is set
 *
 * Output: new sorted, filtered array.
 */
static NSArray<NSURL *> *
listing_rows(NSArray<NSURL *> *items, NSString *sort_key, BOOL ascending,
             NSSet<NSString *> *tracked, NSDictionary<NSString *, NSNumber *> *sizes,
             BOOL show_hidden)
{
    NSMutableArray<NSURL *> *rows = [NSMutableArray arrayWithCapacity:items.count];
    for (NSURL *url in items) {
        if (!show_hidden) {
            NSNumber *hidden = nil;
            [url getResourceValue:&hidden forKey:NSURLIsHiddenKey error:nil];
            if (hidden.boolValue) continue;
        }
        [rows addObject:url];
    }

    NSURLResourceKey key = sort_resource_key(sort_key);
    if (![sort_key isEqualToString:col_git]) tracked = nil;
    [rows sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *a_dir = nil, *b_dir = nil;
        [a getResourceValue:&a_dir forKey:NSURLIsDirectoryKey error:nil];
        [b getResourceValue:&b_dir forKey:NSURLIsDirectoryKey error:nil];
        if (a_dir.boolValue != b_dir.boolValue) {
            return a_dir.boolValue ? NSOrderedAscending : NSOrderedDescending;
        }
        if (tracked) {
            BOOL a_git = [tracked containsObject:a.lastPathComponent];
            BOOL b_git = [tracked containsObject:b.lastPathComponent];
            if (a_git != b_git) {
                return (a_git == ascending) ? NSOrderedAscending : NSOrderedDescending;
            }
        }

        id av = nil, bv = nil;
        [a getResourceValue:&av forKey:key error:nil];
        [b getResourceValue:&bv forKey:key error:nil];
        if (sizes && key == NSURLFileSizeKey) {  /* folders have no file size */
            if (!av) av = sizes[a.path];
            if (!bv) bv = sizes[b.path];
        }

        NSComparisonResult cmp;
        if (!av || !bv) {
            cmp = (av == bv) ? NSOrderedSame : (av ? NSOrderedDescending : NSOrderedAscending);
        } else if ([av isKindOfClass:NSString.class]) {
            cmp = [(NSString *)av localizedStandardCompare:bv];
        } else {
            cmp = [av compare:bv];
        }
        return ascending ? cmp : (NSComparisonResult)(-cmp);
    }];
    return rows;
}

/* ── FilesBrowserView ────────────────────────────────────────────────── */

@interface FilesBrowserView () <NSTableViewDataSource,
                                NSTableViewDelegate,
                                NSTextFieldDelegate,
                                NSMenuDelegate,
                                QLPreviewPanelDataSource,
                                QLPreviewPanelDelegate>

@property (nonatomic, strong) NSTableView             *table;
@property (nonatomic, strong) NSScrollView            *scroll;
@property (nonatomic, strong) NSMutableArray<NSURL *> *back_stack;
@property (nonatomic, strong) NSMutableArray<NSURL *> *forward_stack;
@property (nonatomic, strong) NSURL                   *current_dir;
/* Everything listed (or found), unfiltered, and the rows shown from it. */
@property (nonatomic, copy)   NSArray<NSURL *>        *all_items;
@property (nonatomic, copy)   NSArray<NSURL *>        *filtered_items;

/* Folder watcher: stream plus the resolved path events are compared with. */
@property (nonatomic, assign) FSEventStreamRef         fs_stream;
@property (nonatomic, copy)   NSString                *watched_path;
/* The index of the git repo the folder is in, also watched so badges
 * follow add/rm/commit; nil outside a repo. */
@property (nonatomic, copy)   NSString                *watched_git_index;
/* The Quick Look panel while this browser controls it (Space); nil otherwise. */
@property (nonatomic, strong) QLPreviewPanel          *preview_panel;
/* Names in the listing that git tracks (the Git column); nil outside a
 * repo and for Spotlight results, which hides the column. */
@property (nonatomic, copy, readonly) NSSet<NSString *> *git_tracked; /* set_git_tracked: */
@property (nonatomic, assign) BOOL                     reload_scheduled;
/* What git last reported (git_cache_tracked) and for which folder and
 * index state, so reloads that leave the index alone do not run git
 * again. Only a successful git run sets them. */
@property (nonatomic, copy)   NSString                *git_cache_dir;
@property (nonatomic, copy)   NSString                *git_cache_stamp;
@property (nonatomic, copy)   NSSet<NSString *>       *git_cache_tracked;
/* Show Folder Sizes: totals by path for the folder shown (cleared on
 * navigation and Reload), folders being counted, the token that cancels
 * their counts, the serial queue they run on, and whether a refresh of
 * the Size column is already scheduled. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *folder_sizes;
@property (nonatomic, strong) NSMutableSet<NSString *> *sizes_pending;
@property (nonatomic, strong) FilesCancelToken        *size_token;
@property (nonatomic, strong) dispatch_queue_t         size_queue;
@property (nonatomic, assign) BOOL                     size_refresh_scheduled;

/* Set by shut_down: nothing is listed or watched afterwards. */
@property (nonatomic, assign) BOOL                     is_shut_down;

/* Counters that discard results a newer listing or search has superseded. */
@property (nonatomic, assign) NSUInteger               list_generation;
@property (nonatomic, assign) NSUInteger               search_generation;
@property (nonatomic, assign) BOOL                     auto_fit_pending;

/* Why the folder could not be listed (shown as the status); nil normally. */
@property (nonatomic, copy)   NSString                *listing_error;
/* Total Spotlight matches when more than SEARCH_RESULT_LIMIT; 0 otherwise. */
@property (nonatomic, assign) NSUInteger               search_overflow;

/* Names to select when the next listing lands (reveal_items:, a new or
 * renamed item), replacing the kept selection; nil normally. With
 * pending_rename, the item selected that way is then renamed in place. */
@property (nonatomic, copy)   NSSet<NSString *>       *pending_names;
@property (nonatomic, assign) BOOL                     pending_rename;

/* Inline rename: the Name cell's own text field while it is being edited,
 * the item being renamed, and whether a listing reload was postponed so
 * it would not destroy the cell mid-edit. */
@property (nonatomic, weak)   NSTextField             *rename_field;
@property (nonatomic, strong) NSURL                   *rename_url;
@property (nonatomic, assign) BOOL                     reload_deferred;

/* Sort key and ascending flag */
@property (nonatomic, copy)   NSString                *sort_key;
@property (nonatomic, assign) BOOL                     sort_ascending;

/* Spotlight search state */
@property (nonatomic, strong) NSMetadataQuery         *search_query;
@property (nonatomic, assign) BOOL                     search_active;

/* Mirror files_pref_large_rows, files_pref_auto_fit and
 * files_pref_show_hidden as currently applied to the table. */
@property (nonatomic, assign) BOOL                     large_rows;
@property (nonatomic, assign) BOOL                     auto_fit;
@property (nonatomic, assign) BOOL                     show_hidden;
@property (nonatomic, assign) BOOL                     show_folder_sizes;
@property (nonatomic, assign) BOOL                     human_readable_sizes;

/* NSUserDefaultsDidChangeNotification observer (main queue). */
@property (nonatomic, strong) id                       defaults_observer;

@property (nonatomic, copy, readwrite) NSString       *status_text;

- (void)schedule_reload;

@end

/*
 * fs_event_callback — FSEventStream callback (main queue). The stream
 * reports folders, not files: a change to any item in a folder names the
 * folder (with a trailing slash). Schedules one coalesced reload if an
 * event names the watched folder, its parent (the folder itself was
 * renamed: kFSEventStreamCreateFlagWatchRoot), or the git index's folder,
 * or if the folder was deleted or events were dropped; events from deeper
 * in the tree are ignored.
 *
 * Inputs:
 *   client_info — the FilesBrowserView (unretained; the view stops the
 *                 stream before it is deallocated)
 *   num_events  — number of entries in event_paths / event_flags
 *   event_paths — CFArray of CFString paths (kFSEventStreamCreateFlagUseCFTypes)
 *   event_flags — per-event flags
 */
static void
fs_event_callback(ConstFSEventStreamRef stream, void *client_info,
                  size_t num_events, void *event_paths,
                  const FSEventStreamEventFlags *event_flags,
                  const FSEventStreamEventId *event_ids)
{
    FilesBrowserView *view = (__bridge FilesBrowserView *)client_info;
    NSArray<NSString *> *paths = (__bridge NSArray<NSString *> *)event_paths;
    NSString *watched = view.watched_path;
    NSString *git_dir = view.watched_git_index.stringByDeletingLastPathComponent;

    for (size_t i = 0; i < num_events; i++) {
        NSString *path = paths[i];
        if (path.length > 1 && [path hasSuffix:@"/"]) {
            path = [path substringToIndex:path.length - 1];
        }
        BOOL relevant =
            (event_flags[i] & (kFSEventStreamEventFlagMustScanSubDirs |
                               kFSEventStreamEventFlagRootChanged)) ||
            [path isEqualToString:watched] ||
            [path isEqualToString:watched.stringByDeletingLastPathComponent] ||
            (git_dir && [path isEqualToString:git_dir]);
        if (relevant) {
            [view schedule_reload];
            return;
        }
    }
}

/* ── FilesBrowserView ────────────────────────────────────────────────── */

@implementation FilesBrowserView

/*
 * init_with_frame: — builds all subviews.
 *
 * Inputs:
 *   frame — initial frame
 *
 * Output: self or nil.
 */
- (instancetype)
init_with_frame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.back_stack     = [NSMutableArray array];
    self.forward_stack  = [NSMutableArray array];
    self.all_items      = @[];
    self.filtered_items = @[];
    self.sort_key       = col_name;
    self.sort_ascending = YES;
    self.show_hidden    = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hidden];
    self.folder_sizes   = [NSMutableDictionary dictionary];
    self.sizes_pending  = [NSMutableSet set];
    self.size_queue     = dispatch_queue_create("files.browser.folder_sizes",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));

    [self build_table];
    [self update_sort_indicators];
    [self apply_view_prefs];
    /* Every browser in every window follows the view preferences, wherever
     * they are changed. Defaults can change on any thread; the table is
     * only touched on the main queue. */
    __weak FilesBrowserView *ws = self;
    self.defaults_observer = [NSNotificationCenter.defaultCenter
        addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { [ws apply_view_prefs]; }];

    return self;
}

/*
 * build_table — creates the scroll view and NSTableView.
 */
- (void)
build_table
{
    self.table = [[NSTableView alloc] initWithFrame:self.bounds];
    self.table.style                              = NSTableViewStylePlain;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.allowsMultipleSelection            = YES;
    self.table.allowsEmptySelection               = YES;
    /* First column (Name) fills spare width; other columns are fixed.
     * When the window is narrower than the sum of minimum widths the
     * horizontal scrollbar appears. */
    self.table.columnAutoresizingStyle            = NSTableViewFirstColumnOnlyAutoresizingStyle;

    /* Columns — no sortDescriptorPrototype; clicks handled by didClickTableColumn: */
    for (size_t i = 0; i < COLUMN_COUNT; i++) {
        NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:column_specs[i].id];
        tc.title          = column_specs[i].title;
        tc.width          = column_specs[i].width;
        tc.minWidth       = column_specs[i].min_width;
        tc.resizingMask   = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
        [self.table addTableColumn:tc];
    }
    self.table.headerView.menu = [self build_header_menu];

    self.table.dataSource   = self;
    self.table.delegate     = self;
    self.table.target       = self;
    self.table.doubleAction = @selector(row_double_clicked:);

    /* Drag source: rows can be moved (the default) or, with ⌥, copied. */
    NSDragOperation drag_ops = NSDragOperationMove | NSDragOperationCopy;
    [self.table setDraggingSourceOperationMask:drag_ops forLocal:YES];
    [self.table setDraggingSourceOperationMask:drag_ops forLocal:NO];

    /* Drag destination: accept file URL drops from any source. */
    [self.table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    self.table.menu = [self build_context_menu];

    self.scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    self.scroll.documentView          = self.table;
    self.scroll.hasVerticalScroller   = YES;
    self.scroll.hasHorizontalScroller = YES;
    self.scroll.autohidesScrollers    = YES;
    self.scroll.autoresizingMask      = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:self.scroll];
}

/*
 * build_header_menu — the column headers' right-click menu: one checkbox
 * item per column, toggling it (toggle_column:); validateMenuItem: sets
 * the checkmarks. Name is always shown, so its item is checked and
 * disabled.
 *
 * Output: configured NSMenu.
 */
- (NSMenu *)
build_header_menu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    for (size_t i = 0; i < COLUMN_COUNT; i++) {
        NSString *title = [column_specs[i].id isEqualToString:col_git]
            ? @"Git (inside repositories)" : column_specs[i].title;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(toggle_column:)
                                               keyEquivalent:@""];
        item.target            = self;
        item.representedObject = column_specs[i].id;
        [menu addItem:item];
    }
    return menu;
}

/*
 * toggle_column: — shows or hides a column in every file list: adds or
 * removes its identifier in files_pref_hidden_columns, whose change every
 * browser applies (apply_view_prefs).
 *
 * Inputs:
 *   sender — header-menu item; representedObject = column identifier
 */
- (void)
toggle_column:(NSMenuItem *)sender
{
    NSString *col_id = sender.representedObject;
    if ([col_id isEqualToString:col_name]) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSString *> *hidden =
        [[ud stringArrayForKey:files_pref_hidden_columns] mutableCopy] ?: [NSMutableArray array];
    if ([hidden containsObject:col_id]) [hidden removeObject:col_id];
    else                                [hidden addObject:col_id];
    [ud setObject:hidden forKey:files_pref_hidden_columns];
}

/*
 * update_column_visibility — hides each column the user has hidden
 * (files_pref_hidden_columns), and the Git column outside a repository
 * (git_tracked nil). Name always shows and gives up or takes back the
 * width of columns that appear or disappear, so they are not pushed off
 * the right edge. Callers refit the columns if it reports a change.
 *
 * Output: YES if any column was shown or hidden.
 */
- (BOOL)
update_column_visibility
{
    NSArray<NSString *> *hidden =
        [NSUserDefaults.standardUserDefaults stringArrayForKey:files_pref_hidden_columns];
    NSTableColumn *name_col = [self.table tableColumnWithIdentifier:col_name];
    CGFloat delta   = 0.0;
    BOOL    changed = NO;
    for (NSTableColumn *col in self.table.tableColumns) {
        if (col == name_col) continue;
        BOOL hide = [hidden containsObject:col.identifier] ||
                    ([col.identifier isEqualToString:col_git] && self.git_tracked == nil);
        if (col.hidden == hide) continue;
        col.hidden = hide;
        changed    = YES;
        CGFloat w  = col.width + self.table.intercellSpacing.width;
        delta     += hide ? w : -w;
    }
    if (changed) name_col.width = MAX(name_col.minWidth, name_col.width + delta);
    return changed;
}

/*
 * build_context_menu — builds the right-click menu for the table.
 *
 * Output: configured NSMenu.
 */
- (NSMenu *)
build_context_menu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    void (^add)(NSString *, SEL) = ^(NSString *title, SEL action) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:action
                                               keyEquivalent:@""];
        item.target = self;
        [menu addItem:item];
    };

    add(@"Open",          @selector(open_selected:));
    add(@"Open With…",    @selector(open_with:));
    add(@"Run Application", @selector(run_application:));
    add(@"Add to Bookmarks", @selector(add_to_bookmarks:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Cut",           @selector(cut:));
    add(@"Copy",          @selector(copy:));
    add(@"Copy Path to File", @selector(copy_path:));
    add(@"Paste",         @selector(paste:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Rename",        @selector(begin_rename:));
    add(@"Create Archive…", @selector(create_archive:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Get Info",            @selector(get_info_action:));
    add(@"New Terminal Here",   @selector(new_terminal_here:));
    add(@"New Folder",          @selector(new_folder_action:));
    add(@"New File",            @selector(new_file_action:));
    [menu addItem:NSMenuItem.separatorItem];
    /* "Move to Trash" / "Delete" pair: holding ⌘ swaps to the alternate. */
    NSMenuItem *trash_item = [[NSMenuItem alloc] initWithTitle:@"Move to Trash"
                                                        action:@selector(move_to_trash_action:)
                                                 keyEquivalent:@""];
    trash_item.target = self;
    [menu addItem:trash_item];
    NSMenuItem *delete_item = [[NSMenuItem alloc] initWithTitle:@"Delete"
                                                         action:@selector(delete_permanently:)
                                                  keyEquivalent:@""];
    delete_item.target                   = self;
    delete_item.alternate                = YES;
    delete_item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:delete_item];

    menu.delegate = self;  /* menuNeedsUpdate: selects the right-clicked row */
    return menu;
}

/* ── Folder watcher ──────────────────────────────────────────────────── */

/*
 * watch:git_index: — watches dir, and the folder holding git_index when
 * given, with one FSEventStream (folder-level events, 0.3 s latency,
 * kFSEventStreamCreateFlagWatchRoot so a deleted or renamed folder is
 * noticed). fs_event_callback keeps only events naming the folder itself,
 * so activity deeper in the tree (e.g. ~/Library caches while viewing ~)
 * is ignored. Does nothing if that is already what is watched.
 *
 * Inputs:
 *   dir       — directory URL to watch
 *   git_index — resolved path of the enclosing repo's index file, or nil
 */
- (void)
watch:(NSURL *)dir git_index:(NSString *)git_index
{
    if (self.is_shut_down) return;
    /* FSEvents reports resolved paths (/private/var, not /var). */
    NSString *path = dir.URLByResolvingSymlinksInPath.path;
    if (self.fs_stream && [path isEqualToString:self.watched_path] &&
        (git_index == self.watched_git_index ||
         [git_index isEqualToString:self.watched_git_index])) {
        return;
    }
    [self stop_watching];

    self.watched_path      = path;
    self.watched_git_index = git_index;
    NSArray<NSString *> *paths = git_index
        ? @[self.watched_path, git_index.stringByDeletingLastPathComponent]
        : @[self.watched_path];

    FSEventStreamContext ctx = { .info = (__bridge void *)self };
    self.fs_stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        fs_event_callback,
        &ctx,
        (__bridge CFArrayRef)paths,
        kFSEventStreamEventIdSinceNow,
        0.3,
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
    );
    if (self.fs_stream) {
        FSEventStreamSetDispatchQueue(self.fs_stream, dispatch_get_main_queue());
        FSEventStreamStart(self.fs_stream);
    }
}

/*
 * stop_watching — stops and releases the current FSEventStream, if any.
 */
- (void)
stop_watching
{
    if (self.fs_stream) {
        FSEventStreamStop(self.fs_stream);
        FSEventStreamInvalidate(self.fs_stream);
        FSEventStreamRelease(self.fs_stream);
        self.fs_stream = NULL;
    }
}

/*
 * schedule_reload — coalesces watcher events: at most one reload per
 * WATCH_COALESCE_SEC, however many events arrive in that window.
 */
- (void)
schedule_reload
{
    if (self.reload_scheduled) return;
    self.reload_scheduled = YES;
    __weak FilesBrowserView *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WATCH_COALESCE_SEC * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilesBrowserView *s = ws;
        if (!s) return;
        s.reload_scheduled = NO;
        [s reload_directory];
    });
}

/*
 * shut_down — stops the folder watcher, any Spotlight search and the
 * defaults observer. Called when the window closes, so nothing keeps
 * running even if something still holds the view; safe to call twice.
 */
- (void)
shut_down
{
    if (self.defaults_observer) {
        [NSNotificationCenter.defaultCenter removeObserver:self.defaults_observer];
        self.defaults_observer = nil;
    }
    self.is_shut_down = YES;
    [self reset_folder_sizes];
    [self stop_watching];
    [self stop_search_query];
    ++self.list_generation;  /* drop any listing still in flight */
}

/*
 * dealloc — shut_down, in case the window did not.
 */
- (void)
dealloc
{
    [self shut_down];
}

/*
 * apply_view_prefs — applies files_pref_large_rows (normal rows: 20pt,
 * 16pt icons; large rows: twice both), files_pref_auto_fit,
 * files_pref_show_hidden, files_pref_folder_sizes and
 * files_pref_hidden_columns. Cheap when
 * nothing changed, so it runs on every defaults change; otherwise the
 * table is redrawn for a new row height, the rows are re-filtered for
 * Show Hidden Files, and the columns are fitted when auto-fit is on and it
 * was just turned on, the icon size changed or a column appeared or went.
 */
- (void)
apply_view_prefs
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL large  = [ud boolForKey:files_pref_large_rows];
    BOOL fit    = [ud boolForKey:files_pref_auto_fit];
    BOOL hidden = [ud boolForKey:files_pref_show_hidden];
    BOOL sizes  = [ud boolForKey:files_pref_folder_sizes];
    BOOL rows_changed = large != self.large_rows || self.table.rowHeight != [self row_height];
    BOOL fit_turned_on = fit && !self.auto_fit;
    self.auto_fit = fit;
    if (rows_changed) {
        self.large_rows = large;
        self.table.rowHeight = [self row_height];
        [self.table reloadData];
    }
    if (hidden != self.show_hidden) {
        self.show_hidden = hidden;
        [self resort_revealing:NO];
    }
    if (sizes != self.show_folder_sizes) {
        self.show_folder_sizes = sizes;
        [self reset_folder_sizes];
        [self refresh_size_column];
        [self count_folder_sizes];
    }
    BOOL human = [ud boolForKey:files_pref_human_readable_sizes];
    if (human != self.human_readable_sizes) {
        self.human_readable_sizes = human;
        [self refresh_size_column];
        if (self.auto_fit) [self apply_auto_fit];
    }
    BOOL cols_changed = [self update_column_visibility];
    if (fit && (rows_changed || fit_turned_on || cols_changed)) [self apply_auto_fit];
}

/*
 * row_height — current table row height.
 *
 * Output: row_height_normal, doubled for Large Rows.
 */
- (CGFloat)
row_height
{
    return self.large_rows ? 2.0 * row_height_normal : row_height_normal;
}

/*
 * icon_size — current Name-column icon edge length.
 *
 * Output: icon_size_normal, doubled for Large Rows.
 */
- (CGFloat)
icon_size
{
    return self.large_rows ? 2.0 * icon_size_normal : icon_size_normal;
}

/* ── Navigation ──────────────────────────────────────────────────────── */

/*
 * push_history: — appends url to a back/forward stack, dropping the oldest
 * entry beyond HISTORY_LIMIT.
 *
 * Inputs:
 *   url   — location to record; nil is ignored
 *   stack — back_stack or forward_stack
 */
- (void)
push_history:(NSURL *)url onto:(NSMutableArray<NSURL *> *)stack
{
    if (!url) return;
    [stack addObject:url];
    if (stack.count > HISTORY_LIMIT) [stack removeObjectAtIndex:0];
}

/*
 * load_location: — makes url the displayed folder: ends any Spotlight search,
 * starts a listing (which re-targets the watcher and auto-fits when it
 * lands) and notifies the navigation handler. Shared by navigate_to:,
 * go_back and go_forward; does not touch the history stacks.
 *
 * Inputs:
 *   url — directory URL
 */
- (void)
load_location:(NSURL *)url
{
    [self stop_search_query];
    self.current_dir      = url;
    self.auto_fit_pending = YES;
    self.pending_names    = nil;
    self.pending_rename   = NO;
    [self reset_folder_sizes];
    [self reload_directory];

    if (self.navigation_handler) self.navigation_handler(url);
}

/*
 * navigate_to: — shows url if it is a folder (recording history); mounts a
 * disk image, extracts an archive (FilesArchive is_archive:) or otherwise
 * opens it with its default application. A symbolic link is followed first,
 * like a Finder alias: a link to a folder shows the folder it points to
 * (at its real path), and a link whose target is missing reports an error.
 *
 * Inputs:
 *   url — target URL
 */
- (void)
navigate_to:(NSURL *)url
{
    NSNumber *is_link = nil;
    [url getResourceValue:&is_link forKey:NSURLIsSymbolicLinkKey error:nil];
    if (is_link.boolValue) {
        /* realpath(3) follows chains of links and fails (ENOENT) for a
         * broken one; -URLByResolvingSymlinksInPath would silently return
         * the broken link itself. */
        char target[PATH_MAX];
        if (!realpath(url.fileSystemRepresentation, target)) {
            files_show_error([NSString stringWithFormat:
                @"\"%@\" points to an item that no longer exists", url.lastPathComponent],
                [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil],
                self.window);
            return;
        }
        url = [NSURL fileURLWithFileSystemRepresentation:target isDirectory:NO relativeToURL:nil];
    }

    NSNumber *is_dir = nil;
    NSString *uti    = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    if (!is_dir.boolValue) {
        [url getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
        if (uti && [[UTType typeWithIdentifier:uti] conformsToType:UTTypeDiskImage]) {
            [self mount_disk_image:url];
        } else if ([FilesArchive is_archive:url]) {
            [self extract_archive:url password:nil];
        } else {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
        return;
    }
    if (files_same_path(url, self.current_dir)) return;

    [self push_history:self.current_dir onto:self.back_stack];
    [self.forward_stack removeAllObjects];
    [self load_location:url];
}

/*
 * reveal_items: — selects the named items of the current folder: re-lists
 * it (ending any Spotlight search) and selects them when the listing lands.
 * Hidden items are only found while hidden files are shown.
 *
 * Inputs:
 *   names — file names within current_url
 */
- (void)
reveal_items:(NSArray<NSString *> *)names
{
    if (!self.current_dir) return;
    self.pending_names = [NSSet setWithArray:names];
    [self stop_search_query];
    [self reload_directory];
}

/*
 * mount_disk_image: — mounts a disk image (see FilesVolumeManager
 * mount_disk_image:completion:) and shows its volume in a new window via
 * open_window_handler, or in this browser if none is set. The status bar
 * reads "Mounting …" meanwhile.
 *
 * Inputs:
 *   image — disk image file URL
 */
- (void)
mount_disk_image:(NSURL *)image
{
    [self report_status:[NSString stringWithFormat:@"Mounting \"%@\"…",
                         image.lastPathComponent]];
    __weak FilesBrowserView *ws = self;
    [FilesVolumeManager.shared mount_disk_image:image
                                     completion:^(NSURL *volume, NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        [s update_status_bar];
        if (err) {
            files_show_error([NSString stringWithFormat:@"Could not open \"%@\"",
                              image.lastPathComponent], err, s.window);
        } else if (volume && s.open_window_handler) {
            s.open_window_handler(volume);
        } else if (volume) {
            [s navigate_to:volume];
        }
    }];
}

/*
 * extract_archive:password: — expands an archive (FilesArchive extract:…)
 * and shows the new folder in a new window via open_window_handler, or in
 * this browser if none is set. The status bar reads "Extracting …"
 * meanwhile. An encrypted zip asks for its password, again if it was
 * wrong.
 *
 * Inputs:
 *   archive  — archive file URL
 *   password — password to try; nil for the first attempt
 */
- (void)
extract_archive:(NSURL *)archive password:(NSString *)password
{
    [self report_status:[NSString stringWithFormat:@"Extracting \"%@\"…",
                         archive.lastPathComponent]];
    __weak FilesBrowserView *ws = self;
    [FilesArchive extract:archive password:password completion:^(NSURL *folder, NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        [s update_status_bar];
        if (folder) {
            if (s.open_window_handler) s.open_window_handler(folder);
            else                       [s navigate_to:folder];
        } else if ([err.domain isEqualToString:FilesArchiveErrorDomain] &&
                   (err.code == FilesArchiveErrorPasswordRequired ||
                    err.code == FilesArchiveErrorPasswordIncorrect)) {
            [FilesArchive prompt_password_for:archive
                                    incorrect:err.code == FilesArchiveErrorPasswordIncorrect
                                       window:s.window
                                      handler:^(NSString *pw) {
                [s extract_archive:archive password:pw];
            }];
        } else {
            files_show_error([NSString stringWithFormat:@"Could not extract \"%@\"",
                              archive.lastPathComponent], err, s.window);
        }
    }];
}

/*
 * archivable_items — the selection, if it can be archived: something is
 * selected and every item is in the same folder.
 *
 * Output: the selected URLs, or nil.
 */
- (NSArray<NSURL *> *)
archivable_items
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count == 0) return nil;
    NSURL *parent = sel.firstObject.URLByDeletingLastPathComponent;
    for (NSURL *url in sel) {
        if (!files_same_path(url.URLByDeletingLastPathComponent, parent)) return nil;
    }
    return sel;
}

/*
 * create_archive: — context menu ▸ Create Archive…: asks for the format,
 * name and optional password (FilesArchive prompt_create_for:…), archives
 * the selected items next to them, and selects the new archive. The status
 * bar reads "Creating …" meanwhile.
 *
 * Inputs:
 *   sender — context-menu item (unused)
 */
- (void)
create_archive:(id)sender
{
    NSArray<NSURL *> *items = [self archivable_items];
    if (!items) return;
    __weak FilesBrowserView *ws = self;
    [FilesArchive prompt_create_for:items window:self.window
                            handler:^(NSString *name, FilesArchiveFormat format, NSString *pw) {
        FilesBrowserView *s = ws;
        if (!s) return;
        [s report_status:[NSString stringWithFormat:@"Creating \"%@\"…", name]];
        [FilesArchive create_from:items name:name format:format password:pw
                       completion:^(NSURL *archive, NSError *err) {
            FilesBrowserView *s2 = ws;
            if (!s2) return;
            [s2 update_status_bar];
            if (!archive) {
                files_show_error([NSString stringWithFormat:@"Could not create \"%@\"", name],
                                 err, s2.window);
            } else if (files_same_path(archive.URLByDeletingLastPathComponent, s2.current_dir)) {
                [s2 reveal_items:@[archive.lastPathComponent]];
            }
        }];
    }];
}

/*
 * go_back — shows the previous location, if any.
 */
- (void)
go_back
{
    NSURL *prev = self.back_stack.lastObject;
    if (!prev) return;
    [self.back_stack removeLastObject];
    [self push_history:self.current_dir onto:self.forward_stack];
    [self load_location:prev];
}

/*
 * go_forward — shows the next location in the forward stack, if any.
 */
- (void)
go_forward
{
    NSURL *next = self.forward_stack.lastObject;
    if (!next) return;
    [self.forward_stack removeLastObject];
    [self push_history:self.current_dir onto:self.back_stack];
    [self load_location:next];
}

/*
 * can_go_back — whether go_back has somewhere to go.
 *
 * Output: YES if the back stack is non-empty.
 */
- (BOOL)
can_go_back
{
    return self.back_stack.count > 0;
}

/*
 * can_go_forward — whether go_forward has somewhere to go.
 *
 * Output: YES if the forward stack is non-empty.
 */
- (BOOL)
can_go_forward
{
    return self.forward_stack.count > 0;
}

/*
 * current_url — the folder currently displayed.
 *
 * Output: directory URL, or nil before the first navigation.
 */
- (NSURL *)
current_url
{
    return self.current_dir;
}

/*
 * selected_urls — returns the file URLs of selected table rows.
 *
 * Output: NSArray<NSURL *>, empty if nothing is selected.
 */
- (NSArray<NSURL *> *)
selected_urls
{
    return [self.filtered_items objectsAtIndexes:
        [self.table.selectedRowIndexes indexesPassingTest:^BOOL(NSUInteger idx, BOOL *stop) {
            return idx < self.filtered_items.count;
        }]];
}

/* ── Directory loading ───────────────────────────────────────────────── */

/*
 * shows_hidden_items — whether hidden items are listed: when Show Hidden
 * Files is on, and always in the Trash, since the OS marks Trash items
 * hidden.
 *
 * Output: YES to list hidden items.
 */
- (BOOL)
shows_hidden_items
{
    return self.show_hidden ||
           files_same_path(self.current_dir, files_directory_url(NSTrashDirectory));
}

/*
 * row_order — the settings rows are filtered and sorted by, as one value,
 * so a listing prepared in the background can tell whether they changed
 * before it landed.
 *
 * Output: opaque string.
 */
- (NSString *)
row_order
{
    return [NSString stringWithFormat:@"%@/%d/%d", self.sort_key, self.sort_ascending,
            [self shows_hidden_items]];
}

/*
 * reload_directory — lists the current folder on a background queue (so
 * large, slow or unreachable folders never block the UI, nor later
 * listings), filters and sorts it there, then shows it on the main queue,
 * keeping the selection by path. A generation counter drops results that a
 * newer reload or navigation has superseded. No-op while Spotlight results
 * are displayed; postponed while an inline rename is in progress.
 *
 * Inside a git working tree the Git column is filled in by a second step,
 * after the listing is already shown: `git ls-files` runs only when the
 * folder or its index changed since it last ran, and meanwhile the
 * previous answer for this folder (or none) is shown.
 */
- (void)
reload_directory
{
    NSURL *dir = self.current_dir;
    if (!dir || self.search_active || self.is_shut_down) return;
    if (self.rename_url) {             /* reloading now would end the edit */
        self.reload_deferred = YES;
        return;
    }

    NSUInteger generation = ++self.list_generation;
    NSString *order       = [self row_order];
    NSString *sort_key    = self.sort_key;
    BOOL ascending        = self.sort_ascending;
    BOOL show_hidden      = [self shows_hidden_items];
    BOOL same_dir         = [self.git_cache_dir isEqualToString:dir.path];
    NSString *cache_stamp = same_dir ? self.git_cache_stamp : nil;
    NSSet<NSString *> *cache_tracked = same_dir ? self.git_cache_tracked : nil;
    NSDictionary<NSString *, NSNumber *> *sizes = [self.folder_sizes copy];
    __weak FilesBrowserView *ws = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSArray<NSURL *> *items =
            [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir
                                        includingPropertiesForKeys:listing_keys()
                                                           options:0
                                                             error:&err];
        NSURL *work_tree    = files_git_work_tree(dir);
        NSString *git_index = work_tree ? files_git_index_path(work_tree) : nil;
        NSString *stamp     = git_index_stamp(git_index);
        BOOL git_current    = cache_tracked && stamp && [stamp isEqualToString:cache_stamp];
        NSSet<NSString *> *tracked = work_tree ? (cache_tracked ?: [NSSet set]) : nil;
        NSArray<NSURL *> *rows = listing_rows(items ?: @[], sort_key, ascending,
                                              tracked, sizes, show_hidden);
        NSString *error = items ? nil
            : (err.localizedFailureReason ?: err.localizedDescription ?: @"It cannot be read.");

        dispatch_async(dispatch_get_main_queue(), ^{
            FilesBrowserView *s = ws;
            if (!s || generation != s.list_generation || s.search_active) return;
            [s watch:dir git_index:git_index];
            [s set_git_tracked:tracked];
            s.listing_error = error;
            [s show_listing:items ?: @[]
                       rows:[order isEqualToString:[s row_order]] ? rows : nil];
        });
        if (!work_tree || git_current) return;

        /* nil: git failed or timed out; show nothing tracked, but do not
         * cache that, so the next reload asks again. */
        NSSet<NSString *> *fresh = files_git_tracked_names(dir);
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesBrowserView *s = ws;
            if (!s || generation != s.list_generation || s.search_active) return;
            if (fresh) {
                s.git_cache_dir     = dir.path;
                s.git_cache_stamp   = stamp;
                s.git_cache_tracked = fresh;
            }
            [s set_git_tracked:fresh ?: [NSSet set]];
            if ([s.sort_key isEqualToString:col_git]) {
                [s resort_revealing:NO];
            } else {
                NSInteger col = [s.table columnWithIdentifier:col_git];
                [s.table reloadDataForRowIndexes:
                             [NSIndexSet indexSetWithIndexesInRange:
                                 NSMakeRange(0, (NSUInteger)s.table.numberOfRows)]
                                   columnIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)col]];
            }
        });
    });
}

/*
 * set_git_tracked: — records which listed names git tracks; the Git
 * column shows only inside a repository (tracked non-nil) and if the user
 * has not hidden it (update_column_visibility). If the column appears or
 * goes, the next rows shown are auto-fitted.
 *
 * Inputs:
 *   tracked — tracked names, or nil outside a repo / for search results
 */
- (void)
set_git_tracked:(NSSet<NSString *> *)tracked
{
    _git_tracked = [tracked copy];
    if ([self update_column_visibility]) self.auto_fit_pending = YES;
}

/*
 * selected_paths — the paths of the selected items, the key the selection
 * is restored by after the rows are rebuilt or reordered.
 *
 * Output: set of paths, empty if nothing is selected.
 */
- (NSSet<NSString *> *)
selected_paths
{
    return [NSSet setWithArray:[[self selected_urls] valueForKey:@"path"]];
}

/*
 * show_rows:selecting:reveal: — makes rows the table's contents and
 * selects the rows whose paths are in paths (AppKit keeps selected row
 * numbers across reloadData, which point at other items once rows are
 * reordered or rebuilt), updates the status and runs a pending auto-fit
 * (for a search, only once it has results). During an inline rename the
 * table is left alone and a reload is run when the rename ends.
 *
 * Inputs:
 *   rows   — items to show, already filtered and sorted
 *   paths  — paths to select (from selected_paths, taken before the change)
 *   reveal — YES to scroll the first selected row into view
 */
- (void)
show_rows:(NSArray<NSURL *> *)rows selecting:(NSSet<NSString *> *)paths reveal:(BOOL)reveal
{
    if (self.rename_url) {             /* reloading the table would end the edit */
        self.reload_deferred = YES;
        return;
    }
    self.filtered_items = rows;
    [self.table reloadData];
    NSIndexSet *sel = [rows indexesOfObjectsPassingTest:
        ^BOOL(NSURL *item, NSUInteger idx, BOOL *stop) {
            return [paths containsObject:item.path];
        }];
    [self.table selectRowIndexes:sel byExtendingSelection:NO];
    if (reveal && sel.count > 0) [self.table scrollRowToVisible:(NSInteger)sel.firstIndex];

    [self update_status_bar];
    if (self.auto_fit_pending && (rows.count > 0 || !self.search_active)) {
        self.auto_fit_pending = NO;
        if (self.auto_fit) [self apply_auto_fit];
    }
    [self count_folder_sizes];
}

/* ── Folder sizes ────────────────────────────────────────────────────── */

/*
 * reset_folder_sizes — cancels every folder count still running and
 * forgets the totals, so the next count starts afresh (navigation,
 * Reload, Show Folder Sizes turned off or on, shut_down).
 */
- (void)
reset_folder_sizes
{
    [self.size_token cancel];
    self.size_token = nil;
    [self.folder_sizes removeAllObjects];
    [self.sizes_pending removeAllObjects];
}

/*
 * count_folder_sizes — with Show Folder Sizes on, counts every folder and
 * package among the rows that has no total yet and is not already being
 * counted, one at a time on size_queue (files_folder_size), so listing
 * refreshes never restart a long count. Each total is shown as it
 * arrives (refresh_size_column); once all are in, rows sorted by Size are
 * re-sorted.
 */
- (void)
count_folder_sizes
{
    if (!self.show_folder_sizes || self.is_shut_down) return;
    if (!self.size_token) self.size_token = [[FilesCancelToken alloc] init];
    FilesCancelToken *token = self.size_token;
    __weak FilesBrowserView *ws = self;

    for (NSURL *url in self.filtered_items) {
        NSNumber *is_dir = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        NSString *path = url.path;
        if (!is_dir.boolValue || self.folder_sizes[path] ||
            [self.sizes_pending containsObject:path]) continue;
        [self.sizes_pending addObject:path];

        dispatch_async(self.size_queue, ^{
            if (atomic_load([token cancel_flag])) return;
            int64_t total = files_folder_size(path.fileSystemRepresentation, [token cancel_flag]);
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesBrowserView *s = ws;
                if (!s || s.size_token != token) return;   /* reset since */
                [s.sizes_pending removeObject:path];
                if (total >= 0) s.folder_sizes[path] = @(total);
                [s refresh_size_column];
                if (s.sizes_pending.count == 0 && [s.sort_key isEqualToString:col_size]) {
                    [s resort_revealing:NO];
                }
            });
        });
    }
}

/*
 * refresh_size_column — redraws the Size column, at most every 0.2 s
 * however many totals arrive meanwhile.
 */
- (void)
refresh_size_column
{
    if (self.size_refresh_scheduled) return;
    self.size_refresh_scheduled = YES;
    __weak FilesBrowserView *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilesBrowserView *s = ws;
        if (!s) return;
        s.size_refresh_scheduled = NO;
        if (s.rename_url) return;   /* would end the edit; the next listing shows them */
        NSInteger col = [s.table columnWithIdentifier:col_size];
        if (col < 0 || s.table.numberOfRows == 0) return;
        [s.table reloadDataForRowIndexes:
                     [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)s.table.numberOfRows)]
                           columnIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)col]];
    });
}

/*
 * refresh — Reload: forgets the folder totals (they are counted again)
 * and re-lists the folder. Inputs/output are documented in browser_view.h.
 */
- (void)
refresh
{
    [self reset_folder_sizes];
    [self reload_directory];
}

/*
 * resort_revealing: — re-filters and re-sorts the current items (listing
 * or search results) after the sort, Show Hidden Files or git state
 * changed, keeping the selection.
 *
 * Inputs:
 *   reveal — YES to scroll the first selected row into view
 */
- (void)
resort_revealing:(BOOL)reveal
{
    [self show_rows:listing_rows(self.all_items, self.sort_key, self.sort_ascending,
                                 self.git_tracked, self.folder_sizes, [self shows_hidden_items])
          selecting:[self selected_paths] reveal:reveal];
}

/*
 * show_listing:rows: — installs a fresh folder listing, keeping the
 * selection (matched by path). Names requested by pending_names are
 * selected instead, the first of them scrolled into view, and, with
 * pending_rename, renamed in place.
 *
 * Inputs:
 *   items — folder contents with listing_keys() prefetched
 *   rows  — items filtered and sorted for display, or nil if the order
 *           changed while they were prepared (they are then redone here)
 */
- (void)
show_listing:(NSArray<NSURL *> *)items rows:(NSArray<NSURL *> *)rows
{
    NSSet<NSString *> *want = [self selected_paths];
    BOOL reveal = self.pending_names != nil;
    if (reveal) {
        NSMutableSet<NSString *> *paths = [NSMutableSet set];
        for (NSString *name in self.pending_names) {
            [paths addObject:[self.current_dir URLByAppendingPathComponent:name].path];
        }
        want = paths;
    }
    self.pending_names = nil;

    self.all_items = items;
    if (!rows) {
        rows = listing_rows(items, self.sort_key, self.sort_ascending,
                            self.git_tracked, self.folder_sizes, [self shows_hidden_items]);
    }
    [self show_rows:rows selecting:want reveal:reveal];

    if (self.pending_rename) {
        self.pending_rename = NO;
        if (self.table.numberOfSelectedRows == 1) [self begin_rename:nil];
    }
}

/* ── Spotlight search ────────────────────────────────────────────────── */

/*
 * set_search_filter: — starts a Spotlight search for text within the current
 * folder, or ends it when text is nil or empty.
 *
 * Inputs:
 *   text — search string; nil/empty restores the folder listing
 */
- (void)
set_search_filter:(NSString *)text
{
    if (text.length == 0) {
        [self end_spotlight_search];
    } else {
        [self begin_spotlight_search:text];
    }
}

/*
 * stop_search_query — stops the running NSMetadataQuery (if any), removes its
 * observers, drops results still being prepared and leaves search mode.
 * Does not reload the listing.
 */
- (void)
stop_search_query
{
    if (self.search_query) {
        [self.search_query stopQuery];
        [NSNotificationCenter.defaultCenter removeObserver:self
            name:NSMetadataQueryDidUpdateNotification object:self.search_query];
        [NSNotificationCenter.defaultCenter removeObserver:self
            name:NSMetadataQueryDidFinishGatheringNotification object:self.search_query];
        self.search_query = nil;
    }
    ++self.search_generation;
    self.search_active   = NO;
    self.search_overflow = 0;
}

/*
 * begin_spotlight_search: — starts an NSMetadataQuery for items whose display
 * name contains query: anywhere under the current folder, or anywhere on
 * the Mac when files_pref_search_this_mac is on.
 *
 * Inputs:
 *   query — search term (case- and diacritic-insensitive)
 */
- (void)
begin_spotlight_search:(NSString *)query
{
    [self stop_search_query];
    if (!self.current_dir) return;

    self.search_active    = YES;
    self.auto_fit_pending = YES;
    [self set_git_tracked:nil];
    self.all_items      = @[];
    self.filtered_items = @[];
    [self.table reloadData];
    [self update_status_bar];

    self.search_query = [[NSMetadataQuery alloc] init];
    self.search_query.predicate =
        [NSPredicate predicateWithFormat:@"kMDItemDisplayName CONTAINS[cd] %@", query];
    self.search_query.searchScopes =
        [NSUserDefaults.standardUserDefaults boolForKey:files_pref_search_this_mac]
            ? @[NSMetadataQueryLocalComputerScope] : @[self.current_dir];

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(search_results_updated:)
            name:NSMetadataQueryDidUpdateNotification
          object:self.search_query];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(search_results_updated:)
            name:NSMetadataQueryDidFinishGatheringNotification
          object:self.search_query];

    [self.search_query startQuery];
}

/*
 * end_spotlight_search — stops any running search and restores the listing
 * of the current folder.
 */
- (void)
end_spotlight_search
{
    BOOL was_active = self.search_active;
    [self stop_search_query];
    if (was_active) [self reload_directory];
}

/*
 * search_results_updated: — NSMetadataQuery notification handler. Takes the
 * paths of the first SEARCH_RESULT_LIMIT results on the main thread, then
 * on a background queue makes URLs with listing_keys() prefetched and
 * filters and sorts them like a listing, and shows them on the main queue,
 * keeping the selected results selected. A newer update or the end of the
 * search drops the result (search_generation).
 *
 * Inputs:
 *   note — NSMetadataQueryDidUpdateNotification or DidFinishGatheringNotification
 */
- (void)
search_results_updated:(NSNotification *)note
{
    NSMetadataQuery *query = self.search_query;
    [query disableUpdates];
    NSUInteger total = query.resultCount;
    NSUInteger count = MIN(total, (NSUInteger)SEARCH_RESULT_LIMIT);
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *path = [[query resultAtIndex:i] valueForAttribute:NSMetadataItemPathKey];
        if (path) [paths addObject:path];
    }
    [query enableUpdates];

    NSUInteger generation = ++self.search_generation;
    NSString *order       = [self row_order];
    NSString *sort_key    = self.sort_key;
    BOOL ascending        = self.sort_ascending;
    BOOL show_hidden      = [self shows_hidden_items];
    NSDictionary<NSString *, NSNumber *> *sizes = [self.folder_sizes copy];
    __weak FilesBrowserView *ws = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *> *items = [NSMutableArray arrayWithCapacity:paths.count];
        for (NSString *path in paths) {
            NSURL *url = [NSURL fileURLWithPath:path];
            [url resourceValuesForKeys:listing_keys() error:nil];  /* caches them */
            [items addObject:url];
        }
        NSArray<NSURL *> *rows = listing_rows(items, sort_key, ascending, nil, sizes, show_hidden);

        dispatch_async(dispatch_get_main_queue(), ^{
            FilesBrowserView *s = ws;
            if (!s || generation != s.search_generation || !s.search_active) return;
            s.all_items       = items;
            s.search_overflow = total > count ? total : 0;
            if (![order isEqualToString:[s row_order]]) {
                [s resort_revealing:NO];
            } else {
                [s show_rows:rows selecting:[s selected_paths] reveal:NO];
            }
        });
    });
}

/* ── Sort indicators ─────────────────────────────────────────────────── */

/*
 * update_sort_indicators — sets every header to its base title and appends
 * ↑ or ↓ to the sorted column. Uses the title directly because
 * setIndicatorImage:inTableColumn: is unreliable with NSTableViewStylePlain.
 */
- (void)
update_sort_indicators
{
    for (NSTableColumn *col in self.table.tableColumns) {
        NSString *title = column_title(col.identifier);
        if ([col.identifier isEqualToString:self.sort_key]) {
            title = [title stringByAppendingString:self.sort_ascending ? @" ↑" : @" ↓"];
        }
        col.title = title;
    }
    [self.table.headerView setNeedsDisplay:YES];
}

/* ── Cells and column auto-fit ───────────────────────────────────────── */

/*
 * cell_text_for_column:url: — returns the display string for a cell, using
 * only prefetched resource values. Shared by the cell-view builder and the
 * column auto-fit measurement.
 *
 * Inputs:
 *   col_id — column identifier (col_name, col_size, …)
 *   url    — file URL for the row
 *
 * Output: NSString to display; never nil.
 */
- (NSString *)
cell_text_for_column:(NSString *)col_id
                 url:(NSURL *)url
{
    if ([col_id isEqualToString:col_name]) {
        NSString *name = nil;
        [url getResourceValue:&name forKey:NSURLNameKey error:nil];
        return name ?: url.lastPathComponent;

    } else if ([col_id isEqualToString:col_size]) {
        NSNumber *is_dir = nil, *sz = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) {
            /* Show Folder Sizes: the total once counted, "…" until then. */
            if (!self.show_folder_sizes) return @"—";
            NSNumber *total = self.folder_sizes[url.path];
            return total ? files_format_bytes(total.longLongValue) : @"…";
        }
        [url getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        return sz ? files_format_bytes(sz.longLongValue) : @"—";

    } else if ([col_id isEqualToString:col_kind]) {
        /* "Folder" for folders, "Application" for apps and so on. */
        NSString *kind = nil;
        [url getResourceValue:&kind forKey:NSURLLocalizedTypeDescriptionKey error:nil];
        return kind ?: @"—";

    } else if ([col_id isEqualToString:col_perms]) {
        mode_t mode = file_mode(url);
        return mode ? perms_string_for_mode(mode) : @"—";

    } else if ([col_id isEqualToString:col_modified]) {
        NSDate *date = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        return files_format_date(date, NSDateFormatterShortStyle);

    } else if ([col_id isEqualToString:col_comment]) {
        return files_get_finder_comment(url) ?: @"";

    } else if ([col_id isEqualToString:col_git]) {
        return [self.git_tracked containsObject:url.lastPathComponent] ? @"tracked" : @"";
    }
    return @"";
}

/*
 * cell_font_for_column — font a column's cells are drawn in (Permissions is
 * monospaced). Used by the cell builder and by auto-fit measurement.
 *
 * Inputs:
 *   col_id — column identifier
 *
 * Output: NSFont.
 */
static NSFont *
cell_font_for_column(NSString *col_id)
{
    return [col_id isEqualToString:col_perms]
        ? [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular]
        : [NSFont systemFontOfSize:12.0];
}

/*
 * apply_auto_fit — sizes every column to its widest content (header and the
 * first AUTO_FIT_ROW_LIMIT rows, in the column's real font), respecting each
 * column's minWidth, then gives the Name column whatever width is left over
 * (or takes back the overflow, down to its minWidth) so the columns exactly
 * fill the visible width. A horizontal scrollbar therefore only appears when
 * the view is narrower than the minimum the columns need. Runs once per
 * navigation or search and when the Auto-Fit toggle is turned on — not on
 * every watcher refresh.
 */
- (void)
apply_auto_fit
{
    /* Extra fixed pixels: icon+gap for Name col; cell left+right padding
     * elsewhere. Each also loses the intercell spacing, which the table
     * takes out of a column's width before laying out its cell view. */
    CGFloat spacing    = self.table.intercellSpacing.width;
    CGFloat name_extra = [self icon_size] + 4 + 2 + 2 + spacing; /* icon + gap + pads */
    CGFloat cell_extra = 2 + 2 + spacing;                        /* l-pad + r-pad */
    static const CGFloat header_pad = 10;                        /* header padding + margin */

    NSUInteger rows = MIN(self.filtered_items.count, (NSUInteger)AUTO_FIT_ROW_LIMIT);
    CGFloat total = 0;
    for (NSTableColumn *col in self.table.tableColumns) {
        if (col.hidden) continue;
        NSString *col_id = col.identifier;

        CGFloat max_w = [col.title sizeWithAttributes:
            @{ NSFontAttributeName: col.headerCell.font }].width + header_pad;

        NSDictionary *attrs = @{ NSFontAttributeName: cell_font_for_column(col_id) };
        CGFloat extra = [col_id isEqualToString:col_name] ? name_extra : cell_extra;
        /* Folder totals arrive after this runs, so with Show Folder Sizes
         * the Size column has room for a wide one from the start. */
        if (self.show_folder_sizes && [col_id isEqualToString:col_size]) {
            max_w = MAX(max_w, ceil([@"888.8 MB" sizeWithAttributes:attrs].width) + extra);
        }
        /* The Git column only ever shows "tracked", which may be filled in
         * after this runs, so it is sized for that word. */
        BOOL git = [col_id isEqualToString:col_git];
        for (NSUInteger i = 0; i < (git ? 1 : rows); i++) {
            NSString *text = git ? @"tracked"
                                 : [self cell_text_for_column:col_id url:self.filtered_items[i]];
            /* Text fields need whole points: 42.3 pt of text does not fit
             * in 42.3 pt, it is truncated. */
            CGFloat w = ceil([text sizeWithAttributes:attrs].width) + extra;
            if (w > max_w) max_w = w;
        }

        col.width = MAX(col.minWidth, max_w);
        total    += col.width;
    }

    /* Fit to the visible width. With legacy (always-visible) scrollers the
     * vertical scroller takes width whenever the rows overflow, and it may
     * not be tiled in yet on the first load, so reserve it up front. */
    CGFloat rows_h = self.filtered_items.count
                   * (self.table.rowHeight + self.table.intercellSpacing.height)
                   + NSHeight(self.table.headerView.frame);
    Class v_scroller = rows_h > NSHeight(self.scroll.frame) ? NSScroller.class : Nil;
    CGFloat avail = [NSScrollView contentSizeForFrameSize:self.scroll.frame.size
                                  horizontalScrollerClass:Nil
                                    verticalScrollerClass:v_scroller
                                               borderType:self.scroll.borderType
                                              controlSize:NSControlSizeRegular
                                            scrollerStyle:self.scroll.scrollerStyle].width;
    NSTableColumn *name_col = [self.table tableColumnWithIdentifier:col_name];
    name_col.width = MAX(name_col.minWidth, name_col.width + (avail - total));
}

/* ── Trash and status ────────────────────────────────────────────────── */

/*
 * empty_trash_action: — confirms, then empties the Trash with
 * FilesFileOps empty_trash: (locked and read-only items included) and lists
 * any items that could not be removed, with the reason.
 *
 * Inputs:
 *   sender — the Empty Trash button (unused)
 */
- (IBAction)
empty_trash_action:(id)sender
{
    NSAlert *alert        = files_new_alert();
    alert.messageText     = @"Permanently delete the items in the Trash?";
    alert.informativeText = @"You cannot undo this action.";
    alert.alertStyle      = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Empty Trash"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak FilesBrowserView *ws = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        [FilesFileOps empty_trash:^(NSArray<NSURL *> *failed, NSArray<NSString *> *reasons) {
            FilesBrowserView *s = ws;
            if (!s) return;
            [s reload_directory];
            if (failed.count == 0) return;

            NSAlert *report        = files_new_alert();
            report.messageText     = failed.count == 1
                ? @"1 item could not be deleted"
                : [NSString stringWithFormat:@"%lu items could not be deleted",
                   (unsigned long)failed.count];
            report.informativeText = [[reasons componentsJoinedByString:@"\n"]
                stringByAppendingString:@"\n\nmacOS lets only Finder delete other "
                                        @"developers' apps and items owned by root. "
                                        @"Empty with Finder hands the rest of the Trash "
                                        @"to Finder, which may ask for your password."];
            [report addButtonWithTitle:@"Empty with Finder"];
            [report addButtonWithTitle:@"Cancel"];
            files_present_alert(report, s.window, ^(NSModalResponse r) {
                if (r == NSAlertFirstButtonReturn) [ws empty_trash_with_finder];
            });
        }];
    }];
}

/*
 * empty_trash_with_finder — hands the Trash to Finder for the items Files
 * could not delete, then refreshes and reports anything Finder declined.
 */
- (void)
empty_trash_with_finder
{
    __weak FilesBrowserView *ws = self;
    [FilesFileOps empty_trash_with_finder:^(NSString *error) {
        FilesBrowserView *s = ws;
        if (!s) return;
        [s reload_directory];
        if (!error) return;
        NSAlert *alert        = files_new_alert();
        alert.messageText     = @"The Trash was not emptied";
        alert.informativeText = error;
        files_present_alert(alert, s.window, nil);
    }];
}

/*
 * report_status: — records text as status_text and passes it to
 * status_text_handler.
 *
 * Inputs:
 *   text — status text
 */
- (void)
report_status:(NSString *)text
{
    self.status_text = text;
    if (self.status_text_handler) self.status_text_handler(text);
}

/*
 * update_status_bar — reports the item/selection count, why the folder
 * could not be listed, or how many Spotlight matches were not shown.
 */
- (void)
update_status_bar
{
    if (self.listing_error && !self.search_active) {
        [self report_status:[NSString stringWithFormat:@"\"%@\" could not be read: %@",
                             self.current_dir.lastPathComponent, self.listing_error]];
        return;
    }
    NSInteger total    = (NSInteger)self.filtered_items.count;
    NSInteger selected = (NSInteger)self.table.numberOfSelectedRows;
    NSString *msg = [NSString stringWithFormat:@"%ld item%@", (long)total, total == 1 ? @"" : @"s"];
    if (self.search_active && self.search_overflow) {
        msg = [msg stringByAppendingFormat:@" (first %d of %lu matches)",
               SEARCH_RESULT_LIMIT, (unsigned long)self.search_overflow];
    }
    if (selected > 0) {
        msg = [msg stringByAppendingFormat:@" — %ld selected", (long)selected];
    }
    [self report_status:msg];
}

/* ── NSTableViewDataSource / Delegate ────────────────────────────────── */

/*
 * numberOfRowsInTableView: — row count for the table.
 *
 * Inputs:
 *   tv — the table view
 *
 * Output: number of displayed items.
 */
- (NSInteger)
numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)self.filtered_items.count;
}

/*
 * tableView:viewForTableColumn:row: — returns a (reused) cell view for a
 * column and row, filled from prefetched values.
 *
 * Inputs:
 *   tv  — the table view
 *   col — column being displayed
 *   row — row index
 *
 * Output: NSTableCellView, or nil for an out-of-range row.
 */
- (NSView *)
tableView:(NSTableView *)tv
viewForTableColumn:(NSTableColumn *)col
              row:(NSInteger)row
{
    if (row < 0 || (NSUInteger)row >= self.filtered_items.count) return nil;
    NSURL *url = self.filtered_items[row];

    NSString *ident = col.identifier;
    CGFloat icon_sz = [self icon_size];
    /* Name cells are built for one icon size, so each size gets its own
     * reuse identifier. */
    NSString *reuse_id = [ident isEqualToString:col_name]
        ? [NSString stringWithFormat:@"%@.%g", ident, icon_sz] : ident;
    NSTableCellView *cell = [tv makeViewWithIdentifier:reuse_id owner:nil];
    if (!cell) {
        cell            = [[NSTableCellView alloc] init];
        cell.identifier = reuse_id;
        NSTextField *tf = [[NSTextField alloc] init];
        tf.editable        = NO;
        tf.bordered        = NO;
        tf.drawsBackground = NO;
        tf.focusRingType   = NSFocusRingTypeNone;
        tf.font            = cell_font_for_column(ident);
        tf.alignment       = [ident isEqualToString:col_size]
                             ? NSTextAlignmentRight : NSTextAlignmentLeft;
        tf.lineBreakMode   = NSLineBreakByTruncatingMiddle;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        cell.textField = tf;
        [cell addSubview:tf];

        if ([ident isEqualToString:col_name]) {
            /* Sized up front: an image set on a zero-frame image view (Auto
             * Layout has not run yet) is rendered from the icon's largest
             * representation, a 1024 px bitmap of 4 MB that stays cached
             * with the icon and is copied again into the view's layer. */
            NSImageView *iv = [[NSImageView alloc]
                initWithFrame:NSMakeRect(0, 0, icon_sz, icon_sz)];
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            cell.imageView  = iv;
            [cell addSubview:iv];

            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [iv.widthAnchor constraintEqualToConstant:icon_sz],
                [iv.heightAnchor constraintEqualToConstant:icon_sz],
                [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
                [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
    }

    cell.textField.stringValue = [self cell_text_for_column:ident url:url];
    if ([ident isEqualToString:col_name]) cell.imageView.image = files_icon_for_url(url, icon_sz, YES);
    return cell;
}

/*
 * tableView:didClickTableColumn: — handles column header clicks for sorting.
 * Clicking the active sort column flips ascending/descending; clicking another
 * column sorts by it ascending. Works for folder listings and search results.
 * The selection follows its items to their new rows, and the first of them
 * is scrolled into view, as in Finder.
 *
 * Inputs:
 *   tv  — the table view
 *   col — the column that was clicked
 */
- (void)
tableView:(NSTableView *)tv
didClickTableColumn:(NSTableColumn *)col
{
    NSString *new_key = col.identifier;
    if ([new_key isEqualToString:self.sort_key]) {
        self.sort_ascending = !self.sort_ascending;
    } else {
        self.sort_key       = new_key;
        self.sort_ascending = YES;
    }
    [self resort_revealing:YES];
    [self update_sort_indicators];
}

/*
 * tableViewSelectionDidChange: — refreshes the status text and informs the
 * sidebar handler of the new selection.
 *
 * Inputs:
 *   note — NSTableViewSelectionDidChangeNotification (unused)
 */
- (void)
tableViewSelectionDidChange:(NSNotification *)note
{
    [self update_status_bar];
    if (self.sidebar_handler) self.sidebar_handler([self selected_urls]);
    [self.preview_panel reloadData];  /* Quick Look follows the selection */
}

/* ── Opening items ───────────────────────────────────────────────────── */

/*
 * row_double_clicked: — opens the double-clicked item (navigate_to: shows
 * folders and opens files).
 *
 * Inputs:
 *   sender — the table view (unused)
 */
- (void)
row_double_clicked:(id)sender
{
    NSInteger row = self.table.clickedRow;
    if (row < 0 || (NSUInteger)row >= self.filtered_items.count) return;
    [self navigate_to:self.filtered_items[row]];
}

/*
 * menuNeedsUpdate: — NSMenuDelegate for the context menu, called before it
 * opens. AppKit leaves the selection unchanged on right-click, so, as in
 * Finder, a right-clicked row that is not already selected becomes the
 * selection, and a right-click on empty space clears it. Every command
 * then acts on the selection — the same items its menu-bar and keyboard
 * versions use.
 *
 * Inputs:
 *   menu — the table's context menu (unused)
 */
- (void)
menuNeedsUpdate:(NSMenu *)menu
{
    NSInteger row = self.table.clickedRow;
    if (row < 0) {
        [self.table deselectAll:nil];
    } else if (![self.table isRowSelected:row]) {
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                byExtendingSelection:NO];
    }
}

/*
 * open_selected: — opens every selected item via navigate_to: (folders,
 * including app bundles, are shown; files open in their default app).
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
open_selected:(id)sender
{
    for (NSURL *url in [self selected_urls]) {
        [self navigate_to:url];
    }
}

/*
 * open_with: — context menu ▸ Open With…: lets the user pick an application
 * bundle or an executable binary and opens the selected items with it. An
 * application bundle is launched through NSWorkspace; a plain executable is
 * run directly with the selected paths as its arguments.
 *
 * Inputs:
 *   sender — context-menu item (unused)
 */
- (void)
open_with:(id)sender
{
    NSArray<NSURL *> *items = [self selected_urls];
    if (items.count == 0) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title                   = @"Open With";
    panel.prompt                  = @"Open";
    panel.message                 = @"Choose an application or executable";
    panel.canChooseFiles          = YES;
    panel.canChooseDirectories    = NO;
    panel.allowsMultipleSelection = NO;
    panel.treatsFilePackagesAsDirectories = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

    NSURL *tool = panel.URL;
    __weak NSWindow *win = self.window;
    NSNumber *is_app = nil;
    [tool getResourceValue:&is_app forKey:NSURLIsApplicationKey error:nil];

    if (is_app.boolValue) {
        [NSWorkspace.sharedWorkspace openURLs:items
                         withApplicationAtURL:tool
                                configuration:[NSWorkspaceOpenConfiguration configuration]
                            completionHandler:^(NSRunningApplication *ra, NSError *err) {
            if (!err) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                files_show_error(@"Could not open with application", err, win);
            });
        }];
        return;
    }

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (NSURL *url in items) [args addObject:url.path];
    NSTask *task       = [[NSTask alloc] init];
    task.executableURL = tool;
    task.arguments     = args;
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        files_show_error(@"Could not open with program", err, win);
    }
}

/*
 * application_urls: — the application bundles among urls.
 *
 * Inputs:
 *   urls — listed file URLs (NSURLIsApplicationKey prefetched)
 *
 * Output: the subset that are applications, possibly empty.
 */
static NSArray<NSURL *> *
application_urls(NSArray<NSURL *> *urls)
{
    return [urls filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *b) {
            NSNumber *is_app = nil;
            [url getResourceValue:&is_app forKey:NSURLIsApplicationKey error:nil];
            return is_app.boolValue;
        }]];
}

/*
 * run_application: — launches the selected application bundle(s) with
 * NSWorkspace (double-click shows an app bundle's contents instead).
 *
 * Inputs:
 *   sender — context-menu item (unused)
 */
- (void)
run_application:(id)sender
{
    __weak NSWindow *win = self.window;
    for (NSURL *app in application_urls([self selected_urls])) {
        [NSWorkspace.sharedWorkspace openApplicationAtURL:app
                                            configuration:[NSWorkspaceOpenConfiguration configuration]
                                        completionHandler:^(NSRunningApplication *ra, NSError *err) {
            if (!err) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                files_show_error(@"Could not run application", err, win);
            });
        }];
    }
}

/*
 * selected_folder — the selected item if exactly one is selected and it is
 * a folder (not a package such as an app).
 *
 * Output: folder URL, or nil.
 */
- (NSURL *)
selected_folder
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count != 1) return nil;
    NSNumber *dir = nil, *pkg = nil;
    [sel.firstObject getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
    [sel.firstObject getResourceValue:&pkg forKey:NSURLIsPackageKey error:nil];
    return (dir.boolValue && !pkg.boolValue) ? sel.firstObject : nil;
}

/*
 * add_to_bookmarks: — context menu ▸ Add to Bookmarks: hands the selected
 * folder to bookmark_handler, which adds it to the bookmarks bar.
 *
 * Inputs:
 *   sender — context-menu item (unused)
 */
- (void)
add_to_bookmarks:(id)sender
{
    NSURL *folder = [self selected_folder];
    if (folder && self.bookmark_handler) self.bookmark_handler(folder);
}

/*
 * new_terminal_here: — opens a new Terminal window at the selected folder, or
 * at the current directory when nothing is selected or the right-click landed
 * on empty space.
 *
 * Inputs:
 *   sender — context-menu item (unused)
 */
- (void)
new_terminal_here:(id)sender
{
    (void)sender;
    NSURL *target = [self selected_folder] ?: self.current_url;
    if (!target) return;
    NSTask *task         = [[NSTask alloc] init];
    task.executableURL   = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments       = @[@"-a", @"Terminal", target.path];
    [task launchAndReturnError:nil];
}

/*
 * validateMenuItem: — checks each column-header menu item whose column
 * the user shows (Name: always, disabled); shows "Run Application" in the
 * context menu only when
 * the selected items include an application, "Open With…" only when
 * something is selected, "Create Archive…" only when the selected items
 * share a folder, "Add to Bookmarks" only for
 * a single selected folder, and the path item
 * only for a single selected item, titled "Copy Path to File" for a file
 * (packages such as apps count as files) and "Copy Path" for a folder.
 *
 * Inputs:
 *   item — menu item being validated
 *
 * Output: YES if the item should be enabled.
 */
- (BOOL)
validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(open_with:)) {
        BOOL has_sel = [self selected_urls].count > 0;
        item.hidden  = !has_sel;
        return has_sel;
    }
    if (item.action == @selector(create_archive:)) {
        BOOL ok     = [self archivable_items] != nil;
        item.hidden = !ok;
        return ok;
    }
    if (item.action == @selector(run_application:)) {
        BOOL has_app = application_urls([self selected_urls]).count > 0;
        item.hidden  = !has_app;
        return has_app;
    }
    if (item.action == @selector(toggle_column:)) {
        NSString *col_id = item.representedObject;
        NSArray<NSString *> *hidden =
            [NSUserDefaults.standardUserDefaults stringArrayForKey:files_pref_hidden_columns];
        item.state = [hidden containsObject:col_id] ? NSControlStateValueOff
                                                    : NSControlStateValueOn;
        return ![col_id isEqualToString:col_name];
    }
    if (item.action == @selector(add_to_bookmarks:)) {
        BOOL folder = [self selected_folder] != nil;
        item.hidden = !folder;
        return folder;
    }
    if (item.action == @selector(new_terminal_here:)) {
        /* Show when a single folder is selected or when right-clicking empty
         * space (target becomes the current directory). */
        NSArray<NSURL *> *sel = [self selected_urls];
        BOOL ok = (sel.count == 0 || [self selected_folder] != nil);
        item.hidden = !ok;
        return ok;
    }
    if (item.action == @selector(copy_path:)) {
        item.hidden = ([self selected_urls].count != 1);
        if (item.hidden) return NO;
        item.title = [self selected_folder] ? @"Copy Path" : @"Copy Path to File";
        return YES;
    }
    return YES;
}

/* ── Keyboard handling ───────────────────────────────────────────────── */

/*
 * acceptsFirstResponder — the browser takes keyboard focus for its key
 * handling (rename shortcuts) and editing actions.
 *
 * Output: YES.
 */
- (BOOL)
acceptsFirstResponder
{
    return YES;
}

/*
 * keyDown: — Return/Enter opens the selection as a double-click would
 * (open_selected:: folders are shown, files open in their default app;
 * rename is in the context menu); Space opens or closes
 * Quick Look for the selection; ← and → (no modifiers) go back and
 * forward. Move to Trash is deliberately not bound
 * to a bare Delete key: it is only reachable via ⌘⌫ (Edit menu key
 * equivalent), matching Finder.
 *
 * Inputs:
 *   event — key-down event; unhandled keys are passed to super
 */
- (void)
keyDown:(NSEvent *)event
{
    NSString *chars = event.charactersIgnoringModifiers;
    if ([chars isEqualToString:@"\r"] || [chars isEqualToString:@"\n"]) {
        [self open_selected:nil];
        return;
    }
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand |
                                                       NSEventModifierFlagControl |
                                                       NSEventModifierFlagOption);
    if ([chars isEqualToString:@" "] && mods == 0) {
        [self toggle_quick_look];
        return;
    }
    unichar key = chars.length == 1 ? [chars characterAtIndex:0] : 0;
    if (mods == 0 && key == NSLeftArrowFunctionKey) {
        [self go_back];
        return;
    }
    if (mods == 0 && key == NSRightArrowFunctionKey) {
        [self go_forward];
        return;
    }
    [super keyDown:event];
}

/* ── Quick Look ──────────────────────────────────────────────────────── */

/*
 * toggle_quick_look — closes the Quick Look panel if it is open, otherwise
 * opens it for the selection (nothing happens with nothing selected). The
 * panel then asks the responder chain for a controller and finds this
 * browser (acceptsPreviewPanelControl:).
 */
- (void)
toggle_quick_look
{
    if ([QLPreviewPanel sharedPreviewPanelExists] && QLPreviewPanel.sharedPreviewPanel.isVisible) {
        [QLPreviewPanel.sharedPreviewPanel orderOut:nil];
    } else if ([self selected_urls].count > 0) {
        [QLPreviewPanel.sharedPreviewPanel makeKeyAndOrderFront:nil];
    }
}

/*
 * acceptsPreviewPanelControl: — this browser supplies Quick Look's items
 * while it is in the key window's responder chain.
 *
 * Inputs:
 *   panel — the shared Quick Look panel
 *
 * Output: YES.
 */
- (BOOL)
acceptsPreviewPanelControl:(QLPreviewPanel *)panel
{
    return YES;
}

/*
 * beginPreviewPanelControl: — takes over the panel: becomes its data
 * source and delegate.
 *
 * Inputs:
 *   panel — the shared Quick Look panel
 */
- (void)
beginPreviewPanelControl:(QLPreviewPanel *)panel
{
    self.preview_panel = panel;
    panel.dataSource   = self;
    panel.delegate     = self;
}

/*
 * endPreviewPanelControl: — lets go of the panel (it closed, or another
 * controller took it).
 *
 * Inputs:
 *   panel — the shared Quick Look panel (unused)
 */
- (void)
endPreviewPanelControl:(QLPreviewPanel *)panel
{
    self.preview_panel = nil;
}

/*
 * numberOfPreviewItemsInPreviewPanel: — Quick Look shows the selection.
 *
 * Inputs:
 *   panel — the Quick Look panel (unused)
 *
 * Output: number of selected items.
 */
- (NSInteger)
numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel
{
    return (NSInteger)[self selected_urls].count;
}

/*
 * previewPanel:previewItemAtIndex: — the idx-th selected item (NSURL is a
 * QLPreviewItem).
 *
 * Inputs:
 *   panel — the Quick Look panel (unused)
 *   idx   — item index
 *
 * Output: file URL, or nil if the selection has shrunk.
 */
- (id<QLPreviewItem>)
previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)idx
{
    NSArray<NSURL *> *sel = [self selected_urls];
    return (idx >= 0 && (NSUInteger)idx < sel.count) ? sel[(NSUInteger)idx] : nil;
}

/*
 * previewPanel:handleEvent: — while the panel is key, the arrow keys move
 * the list's selection (Quick Look follows via
 * tableViewSelectionDidChange:), as in Finder; Space reaches keyDown:
 * through the table and closes the panel.
 *
 * Inputs:
 *   panel — the Quick Look panel (unused)
 *   event — event the panel received
 *
 * Output: YES if the event was passed to the table.
 */
- (BOOL)
previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event
{
    if (event.type != NSEventTypeKeyDown) return NO;
    unichar ch = event.charactersIgnoringModifiers.length
               ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (ch != NSUpArrowFunctionKey && ch != NSDownArrowFunctionKey && ch != ' ') return NO;
    [self.table keyDown:event];
    return YES;
}

/*
 * previewPanel:sourceFrameOnScreenForPreviewItem: — the item's icon on
 * screen, which the panel zooms from and back to.
 *
 * Inputs:
 *   panel — the Quick Look panel (unused)
 *   item  — the item being shown
 *
 * Output: icon rect in screen coordinates, or NSZeroRect when its row is
 *         not visible (the panel then fades instead).
 */
- (NSRect)
previewPanel:(QLPreviewPanel *)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item
{
    NSInteger row = (NSInteger)[self.filtered_items indexOfObject:(NSURL *)item];
    if (row == NSNotFound) return NSZeroRect;
    NSRect icon = [self.table frameOfCellAtColumn:[self.table columnWithIdentifier:col_name]
                                              row:row];
    icon.size.width = [self icon_size];
    if (!NSIntersectsRect(icon, self.table.visibleRect)) return NSZeroRect;
    return [self.window convertRectToScreen:[self.table convertRect:icon toView:nil]];
}

/* ── Edit / File actions ─────────────────────────────────────────────── */

/*
 * copy: — puts the selected items on the pasteboard.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
copy:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count > 0) [FilesFileOps copy_urls:sel is_cut:NO];
}

/*
 * copy_path: — puts the full path of the selected item (filename
 * included) on the pasteboard as plain text, e.g.
 * "/Users/me/Documents/report.pdf". Only for a single selected item.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
copy_path:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count != 1) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:sel.firstObject.path forType:NSPasteboardTypeString];
}

/*
 * cut: — puts the selected items on the pasteboard marked for moving.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
cut:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count > 0) [FilesFileOps copy_urls:sel is_cut:YES];
}

/*
 * paste: — copies (or moves, after a cut) the pasteboard's files into the
 * current folder.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
paste:(id)sender
{
    if (!self.current_dir || ![FilesFileOps pasteboard_has_files]) return;
    __weak FilesBrowserView *ws = self;
    [FilesFileOps paste_to_directory:self.current_dir completion:^(NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err && err.code != NSUserCancelledError) files_show_error(@"Paste failed", err, s.window);
        [s reload_directory];
    }];
}

/*
 * move_to_trash_action: — moves the selected items to the Trash.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
move_to_trash_action:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count == 0) return;
    __weak FilesBrowserView *ws = self;
    [FilesFileOps move_to_trash:sel completion:^(NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err) files_show_error(@"Could not move to Trash", err, s.window);
        [s reload_directory];
    }];
}

/*
 * delete_permanently: — context menu ▸ Delete (⌘ alternate of Move to Trash):
 * permanently removes selected items after a confirmation sheet. Items are
 * deleted on a background queue; errors are shown per-item in the sheet.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
delete_permanently:(id)sender
{
    (void)sender;
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count == 0) return;

    NSAlert *alert     = [[NSAlert alloc] init];
    alert.alertStyle   = NSAlertStyleCritical;
    alert.messageText  = sel.count == 1
        ? [NSString stringWithFormat:@"Permanently delete \"%@\"?",
           sel.firstObject.lastPathComponent]
        : [NSString stringWithFormat:@"Permanently delete %lu items?",
           (unsigned long)sel.count];
    alert.informativeText = @"This cannot be undone.";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak FilesBrowserView *ws = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        FilesBrowserView *s = ws;
        if (!s) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableArray<NSString *> *failed = [NSMutableArray array];
            for (NSURL *url in sel) {
                NSError *err = nil;
                if (![NSFileManager.defaultManager removeItemAtURL:url error:&err])
                    [failed addObject:[NSString stringWithFormat:@"%@: %@",
                                      url.lastPathComponent, err.localizedDescription]];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesBrowserView *t = ws;
                if (!t) return;
                [t reload_directory];
                if (failed.count > 0) {
                    NSAlert *err_alert   = [[NSAlert alloc] init];
                    err_alert.alertStyle = NSAlertStyleWarning;
                    err_alert.messageText = @"Some items could not be deleted";
                    err_alert.informativeText = [failed componentsJoinedByString:@"\n"];
                    [err_alert beginSheetModalForWindow:t.window completionHandler:nil];
                }
            });
        });
    }];
}

/*
 * create_and_rename: — creates a new folder or empty file in the current
 * folder, then selects it and starts an inline rename once a listing
 * shows it (pending_names / pending_rename; the name is pre-selected
 * without its extension).
 *
 * Inputs:
 *   folder — YES for "untitled folder", NO for "untitled.txt"
 */
- (void)
create_and_rename:(BOOL)folder
{
    if (!self.current_dir) return;
    __weak FilesBrowserView *ws = self;
    [FilesFileOps create_item_in:self.current_dir
                            name:folder ? @"untitled folder" : @"untitled.txt"
                          folder:folder
                      completion:^(NSURL *new_url, NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err) {
            files_show_error(folder ? @"Could not create folder" : @"Could not create file",
                             err, s.window);
            return;
        }
        [s select_after_listing:new_url rename:YES];
        [s reload_directory];
    }];
}

/*
 * select_after_listing:rename: — has the next listing select url (and,
 * with rename, rename it in place), provided it is in the folder shown
 * now: a create or rename that finishes after the user moved on, or
 * while Spotlight results are shown, selects nothing.
 *
 * Inputs:
 *   url    — item to select
 *   rename — YES to start an inline rename of it
 */
- (void)
select_after_listing:(NSURL *)url rename:(BOOL)rename
{
    if (self.search_active ||
        !files_same_path(url.URLByDeletingLastPathComponent, self.current_dir)) return;
    self.pending_names  = [NSSet setWithObject:url.lastPathComponent];
    self.pending_rename = rename;
}

/*
 * new_folder_action: — File ▸ New Folder: creates "untitled folder" in the
 * current folder and starts renaming it.
 *
 * Inputs:
 *   sender — menu item or toolbar item (unused)
 */
- (IBAction)
new_folder_action:(id)sender
{
    [self create_and_rename:YES];
}

/*
 * new_file_action: — File ▸ New File: creates an empty "untitled.txt" in the
 * current folder and starts renaming it.
 *
 * Inputs:
 *   sender — menu item or toolbar item (unused)
 */
- (IBAction)
new_file_action:(id)sender
{
    [self create_and_rename:NO];
}

/*
 * get_info_action: — shows Get Info for the selected item(s) via
 * info_handler, or the shared panel for the first item if none is set.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
get_info_action:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count == 0) return;
    if (self.info_handler) {
        self.info_handler(sel);
    } else {
        [FilesInfoPanel.shared show_for_url:sel.firstObject];
    }
}

/*
 * selectAll: — selects all rows in the table.
 *
 * Inputs:
 *   sender — menu item (forwarded to the table)
 */
- (IBAction)
selectAll:(id)sender
{
    [self.table selectAll:sender];
}

/* ── Inline rename ───────────────────────────────────────────────────── */

/*
 * begin_rename: — edits the selected item's name in place, in the Name
 * cell's own text field (so it lines up with the row and scrolls with it).
 * The field is focused with the name selected minus its extension —
 * "report" of "report.pdf", "Safari" of "Safari.app" — ready for typing;
 * a folder's whole name is selected, since dots in folder names are not
 * extensions.
 *
 * Inputs:
 *   sender — menu item or nil
 */
- (void)
begin_rename:(id)sender
{
    NSInteger row = self.table.selectedRow;
    if (row < 0 || (NSUInteger)row >= self.filtered_items.count || self.rename_url) return;

    [self.table scrollRowToVisible:row];
    NSInteger col = [self.table columnWithIdentifier:col_name];
    NSTableCellView *cell = [self.table viewAtColumn:col row:row makeIfNecessary:YES];
    NSTextField *tf = cell.textField;
    if (!tf) return;

    NSURL *url    = self.filtered_items[row];
    NSString *name = url.lastPathComponent;
    self.rename_url   = url;
    self.rename_field = tf;

    tf.stringValue     = name;
    tf.editable        = YES;
    tf.bordered        = YES;
    tf.drawsBackground = YES;
    tf.backgroundColor = NSColor.textBackgroundColor;
    tf.delegate        = self;
    [self.window makeFirstResponder:tf];

    NSNumber *is_dir = nil, *is_pkg = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&is_pkg forKey:NSURLIsPackageKey error:nil];
    NSUInteger len = (is_dir.boolValue && !is_pkg.boolValue)
                     ? name.length : name.stringByDeletingPathExtension.length;
    tf.currentEditor.selectedRange = NSMakeRange(0, len ? len : name.length);
}

/*
 * finish_rename — returns the Name cell's text field to its display state,
 * gives focus back to the table and runs any reload that was postponed
 * while editing.
 */
- (void)
finish_rename
{
    NSTextField *tf    = self.rename_field;
    self.rename_url    = nil;
    self.rename_field  = nil;
    tf.delegate        = nil;
    tf.editable        = NO;
    tf.bordered        = NO;
    tf.drawsBackground = NO;
    [self.window makeFirstResponder:self.table];

    if (self.reload_deferred) {
        self.reload_deferred = NO;
        [self reload_directory];
    }
}

/*
 * cancel_rename — abandons the edit and restores the original name.
 */
- (void)
cancel_rename
{
    NSTextField *tf = self.rename_field;
    [tf abortEditing];
    tf.stringValue = self.rename_url.lastPathComponent ?: @"";
    [self finish_rename];
}

/*
 * controlTextDidEndEditing: — commits the rename when editing ends (Return,
 * Tab or clicking elsewhere); the renamed item stays selected. An
 * unchanged or empty name is a no-op.
 *
 * Inputs:
 *   note — NSControlTextDidEndEditingNotification
 */
- (void)
controlTextDidEndEditing:(NSNotification *)note
{
    NSTextField *tf = self.rename_field;
    if (note.object != tf) return;
    NSString *new_name = tf.stringValue;
    NSURL *target      = self.rename_url;
    [self finish_rename];

    if (new_name.length == 0 || [new_name isEqualToString:target.lastPathComponent]) {
        tf.stringValue = target.lastPathComponent;
        return;
    }

    __weak FilesBrowserView *ws = self;
    [FilesFileOps rename_url:target to:new_name completion:^(NSURL *new_url, NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err) {
            files_show_error(@"Rename failed", err, s.window);
        } else {
            [s select_after_listing:new_url rename:NO];
        }
        [s reload_directory];
    }];
}

/*
 * control:textView:doCommandBySelector: — intercepts Escape in the rename
 * field to cancel the rename.
 *
 * Inputs:
 *   control  — the control being edited
 *   textView — its field editor (unused)
 *   cmd      — the command selector
 *
 * Output: YES if the command was handled.
 */
- (BOOL)
control:(NSControl *)control
textView:(NSTextView *)textView
doCommandBySelector:(SEL)cmd
{
    if (control != self.rename_field || cmd != @selector(cancelOperation:)) return NO;
    [self cancel_rename];
    return YES;
}

/* ── Drag source ──────────────────────────────────────────────────────── */

/*
 * tableView:pasteboardWriterForRow: — supplies the file URL for one row so
 * AppKit can build the drag pasteboard automatically.
 *
 * Inputs:
 *   tv  — table view (unused)
 *   row — row index
 *
 * Output: the NSURL for that row, which conforms to NSPasteboardWriting.
 */
- (id<NSPasteboardWriting>)
tableView:(NSTableView *)tv
pasteboardWriterForRow:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)self.filtered_items.count) return nil;
    return self.filtered_items[row];
}

/* ── Drag destination ─────────────────────────────────────────────────── */

/*
 * folder_at_row: — the listed folder at row, if the row is a folder.
 *
 * Inputs:
 *   row — row index (any value)
 *
 * Output: folder URL, or nil if row is out of range or not a folder.
 */
- (NSURL *)
folder_at_row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)self.filtered_items.count) return nil;
    NSURL *url = self.filtered_items[row];
    NSNumber *is_dir = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    return is_dir.boolValue ? url : nil;
}

/*
 * dest_url_for_row:op: — resolves the drop destination: the folder under the
 * pointer for an "on" drop onto a folder row, otherwise the current folder.
 *
 * Inputs:
 *   row — proposed drop row (-1 = whole table)
 *   op  — drop operation
 *
 * Output: destination directory URL, or nil if none is loaded.
 */
- (NSURL *)
dest_url_for_row:(NSInteger)row op:(NSTableViewDropOperation)op
{
    NSURL *folder = (op == NSTableViewDropOn) ? [self folder_at_row:row] : nil;
    return folder ?: self.current_dir;
}

/*
 * drop_operation — the operation a drop performs: Move by default, Copy
 * when the source only allows copying (the user holds ⌥, or the source
 * app does not permit moves), None if neither is allowed.
 *
 * Inputs:
 *   info — dragging session info
 *
 * Output: NSDragOperationMove, NSDragOperationCopy or NSDragOperationNone.
 */
static NSDragOperation
drop_operation(id<NSDraggingInfo> info)
{
    NSDragOperation allowed = info.draggingSourceOperationMask;
    if (allowed & NSDragOperationMove) return NSDragOperationMove;
    if (allowed & NSDragOperationCopy) return NSDragOperationCopy;
    return NSDragOperationNone;
}

/*
 * tableView:validateDrop:proposedRow:proposedDropOperation: — accepts file-URL
 * drags. Highlights a folder row when the pointer is over one; otherwise
 * highlights the whole table (drop into the current folder). Refuses drops
 * into the items' own parent folder.
 *
 * Inputs:
 *   tv   — table view
 *   info — dragging session info
 *   row  — proposed row
 *   op   — proposed operation
 *
 * Output: drop_operation(info) (Move unless ⌥ is held), or
 *         NSDragOperationNone if the drop is refused.
 */
- (NSDragOperation)
tableView:(NSTableView *)tv
validateDrop:(id<NSDraggingInfo>)info
proposedRow:(NSInteger)row
proposedDropOperation:(NSTableViewDropOperation)op
{
    NSArray<NSURL *> *srcs =
        [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
             options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (srcs.count == 0) return NSDragOperationNone;

    NSURL *dest = [self dest_url_for_row:row op:op];
    if (files_same_path(dest, self.current_dir)) {
        [tv setDropRow:-1 dropOperation:NSTableViewDropOn];
    }

    for (NSURL *src in srcs) {
        if (files_same_path(src.URLByDeletingLastPathComponent, dest)) return NSDragOperationNone;
    }
    return drop_operation(info);
}

/*
 * tableView:acceptDrop:row:dropOperation: — moves (default) or, with ⌥,
 * copies dragged files to the resolved destination via FilesFileOps
 * transfer_urls (progress panel unless Simple Copies is on).
 *
 * Inputs:
 *   tv   — table view
 *   info — dragging session info
 *   row  — drop row
 *   op   — drop operation
 *
 * Output: YES if the move/copy was initiated.
 */
- (BOOL)
tableView:(NSTableView *)tv
acceptDrop:(id<NSDraggingInfo>)info
       row:(NSInteger)row
dropOperation:(NSTableViewDropOperation)op
{
    NSArray<NSURL *> *srcs =
        [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
             options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSURL *dest = [self dest_url_for_row:row op:op];
    NSDragOperation drop_op = drop_operation(info);
    if (srcs.count == 0 || !dest || drop_op == NSDragOperationNone) return NO;

    BOOL is_move = (drop_op == NSDragOperationMove);
    __weak FilesBrowserView *ws = self;
    [FilesFileOps transfer_urls:srcs to:dest is_cut:is_move completion:^(NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err && err.code != NSUserCancelledError) {
            files_show_error(is_move ? @"Move failed" : @"Copy failed", err, s.window);
        }
        [s reload_directory];
    }];
    return YES;
}

@end
