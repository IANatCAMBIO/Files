#import "browser_view.h"
#import "file_ops.h"
#import "info_panel.h"
#import <CoreServices/CoreServices.h>
#import <sys/stat.h>


/* Column identifiers */
static NSString * const kColName     = @"name";
static NSString * const kColSize     = @"size";
static NSString * const kColKind     = @"kind";
static NSString * const kColPerms    = @"perms";
static NSString * const kColModified = @"modified";

/* Resource keys fetched for every directory listing. */
static NSArray<NSURLResourceKey> *listing_keys(void)
{
    return @[
        NSURLNameKey,
        NSURLFileSizeKey,
        NSURLFileAllocatedSizeKey,
        NSURLIsDirectoryKey,
        NSURLIsSymbolicLinkKey,
        NSURLLocalizedTypeDescriptionKey,
        NSURLContentModificationDateKey,
        NSURLCreationDateKey,
        NSURLIsHiddenKey,
    ];
}

/* ── FSEvents C callback ─────────────────────────────────────────────── */

/*
 * fs_event_callback — FSEventStream callback; schedules a debounced reload.
 *
 * The client info pointer is a retained reference to the FilesBrowserView;
 * the bridge cast is safe because the view stops and destroys the stream
 * before dealloc.
 */
static void
fs_event_callback(ConstFSEventStreamRef stream,
                  void *client_info,
                  size_t num_events,
                  void *event_paths,
                  const FSEventStreamEventFlags *event_flags,
                  const FSEventStreamEventId *event_ids)
{
    (void)stream; (void)num_events; (void)event_paths;
    (void)event_flags; (void)event_ids;

    FilesBrowserView *self_ref = (__bridge FilesBrowserView *)client_info;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self_ref reload_directory];
    });
}

/* ── FilesBrowserView ────────────────────────────────────────────────── */

@interface FilesBrowserView () <NSTableViewDataSource,
                                NSTableViewDelegate,
                                NSTextFieldDelegate>

@property (nonatomic, strong) NSTableView          *table;
@property (nonatomic, strong) NSScrollView         *scroll;
@property (nonatomic, strong) NSMutableArray<NSURL *> *back_stack;
@property (nonatomic, strong) NSMutableArray<NSURL *> *forward_stack;
@property (nonatomic, strong) NSURL                *current_dir;
@property (nonatomic, strong) NSMutableArray<NSURL *> *all_items;
@property (nonatomic, strong) NSMutableArray<NSURL *> *filtered_items;
@property (nonatomic, copy)   NSString             *search_text;
@property (nonatomic, assign) FSEventStreamRef      fs_stream;

/* Inline rename state */
@property (nonatomic, strong) NSTextField          *rename_field;
@property (nonatomic, strong) NSURL                *rename_url;

/* Sort key and ascending flag */
@property (nonatomic, strong) NSString             *sort_key;
@property (nonatomic, assign) BOOL                  sort_ascending;

/* Spotlight search state */
@property (nonatomic, strong) NSMetadataQuery      *search_query;
@property (nonatomic, assign) BOOL                  search_active;

@end

@implementation FilesBrowserView

- (instancetype)initWithCoder:(NSCoder *)coder
{
    (void)coder;
    return [self init_with_frame:NSZeroRect];
}

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

    self.back_stack    = [NSMutableArray array];
    self.forward_stack = [NSMutableArray array];
    self.all_items     = [NSMutableArray array];
    self.filtered_items = [NSMutableArray array];
    self.sort_key      = kColName;
    self.sort_ascending = YES;

    [self build_table];

    return self;
}

/*
 * build_table — creates the scroll view and NSTableView.
 */
- (void)
build_table
{
    /* Table */
    self.table = [[NSTableView alloc] initWithFrame:self.bounds];
    if (@available(macOS 11.0, *)) {
        self.table.style = NSTableViewStylePlain;
    }
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.rowHeight                          = 20.0;
    self.table.allowsMultipleSelection            = YES;
    self.table.allowsEmptySelection               = YES;
    /* First column (Name) fills spare width; other columns are fixed.
     * When the window is narrower than the sum of minimum widths the
     * horizontal scrollbar appears. */
    self.table.columnAutoresizingStyle            = NSTableViewFirstColumnOnlyAutoresizingStyle;

    /* Columns — no sortDescriptorPrototype; clicks handled by didClickTableColumn: */
    struct { NSString *id; NSString *title; CGFloat width; CGFloat min; } cols[] = {
        { kColName,     @"Name",          260, 120 },
        { kColSize,     @"Size",           80,  50 },
        { kColKind,     @"Kind",          120,  80 },
        { kColPerms,    @"Permissions",    90,  70 },
        { kColModified, @"Date Modified", 160, 120 },
    };
    for (size_t i = 0; i < sizeof(cols)/sizeof(cols[0]); i++) {
        NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:cols[i].id];
        tc.title          = cols[i].title;
        tc.width          = cols[i].width;
        tc.minWidth       = cols[i].min;
        tc.resizingMask   = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
        [self.table addTableColumn:tc];
    }

    self.table.dataSource = self;
    self.table.delegate   = self;
    self.table.target     = self;
    self.table.doubleAction = @selector(row_double_clicked:);

    /* Drag source: allow copying rows out to any destination. */
    [self.table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [self.table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];

    /* Drag destination: accept file URL drops from any source. */
    [self.table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    /* Row context menu */
    NSMenu *menu = [self build_context_menu];
    self.table.menu = menu;

    /* Scroll view */
    self.scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    self.scroll.documentView          = self.table;
    self.scroll.hasVerticalScroller   = YES;
    self.scroll.hasHorizontalScroller = YES;
    self.scroll.autohidesScrollers    = YES;
    self.scroll.autoresizingMask      = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:self.scroll];
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
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Cut",           @selector(cut_action:));
    add(@"Copy",          @selector(copy_action:));
    add(@"Paste",         @selector(paste_action:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Move to Trash", @selector(move_to_trash_action:));
    add(@"Rename",        @selector(begin_rename:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Get Info",      @selector(get_info_action:));
    add(@"New Folder",    @selector(new_folder_action:));

    return menu;
}

/* ── FSEvents ────────────────────────────────────────────────────────── */

/*
 * start_watching: — creates and starts an FSEventStream for dir.
 *
 * Inputs:
 *   dir — directory URL to watch
 */
- (void)
start_watching:(NSURL *)dir
{
    [self stop_watching];

    FSEventStreamContext ctx = {
        .version         = 0,
        .info            = (__bridge void *)self,
        .retain          = NULL,
        .release         = NULL,
        .copyDescription = NULL,
    };
    CFArrayRef paths = (__bridge CFArrayRef)@[dir.path];
    self.fs_stream   = FSEventStreamCreate(
        kCFAllocatorDefault,
        fs_event_callback,
        &ctx,
        paths,
        kFSEventStreamEventIdSinceNow,
        0.5,
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
    );
    if (self.fs_stream) {
        FSEventStreamSetDispatchQueue(self.fs_stream, dispatch_get_main_queue());
        FSEventStreamStart(self.fs_stream);
    }
}

/*
 * stop_watching — stops and invalidates the current FSEventStream.
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

- (void)dealloc
{
    [self stop_watching];
}

- (void)
viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (self.window) {
        [self update_sort_indicators];
    }
}

/* ── Navigation ──────────────────────────────────────────────────────── */

/*
 * navigate_to: — loads url; manages back/forward stacks.
 *
 * Inputs:
 *   url — directory URL to navigate to
 */
- (void)
navigate_to:(NSURL *)url
{
    /* Verify it is a directory */
    NSNumber *is_dir = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    if (!is_dir.boolValue) {
        [NSWorkspace.sharedWorkspace openURL:url];
        return;
    }

    /* Cancel any active Spotlight search before navigating */
    if (self.search_active) {
        if (self.search_query) {
            [self.search_query stopQuery];
            [NSNotificationCenter.defaultCenter removeObserver:self
                name:NSMetadataQueryDidUpdateNotification object:self.search_query];
            [NSNotificationCenter.defaultCenter removeObserver:self
                name:NSMetadataQueryDidFinishGatheringNotification object:self.search_query];
            self.search_query = nil;
        }
        self.search_active = NO;
    }

    if (self.current_dir) {
        [self.back_stack addObject:self.current_dir];
    }
    [self.forward_stack removeAllObjects];
    self.current_dir = url;
    [self start_watching:url];
    [self reload_directory];
    if (self.navigation_handler) {
        self.navigation_handler(url);
    }

    /* Show the Empty Trash button only when the user is viewing ~/.Trash. */
    NSString *trash_path = [NSHomeDirectory()
        stringByAppendingPathComponent:@".Trash"];
    if (self.trash_visible_handler)
        self.trash_visible_handler([url.path isEqualToString:trash_path]);
}

/*
 * go_back — navigates to the previous location.
 */
- (void)
go_back
{
    if (self.back_stack.count == 0) return;
    NSURL *prev = self.back_stack.lastObject;
    [self.back_stack removeLastObject];
    if (self.current_dir) {
        [self.forward_stack addObject:self.current_dir];
    }
    self.current_dir = prev;
    [self start_watching:prev];
    [self reload_directory];
    if (self.navigation_handler) {
        self.navigation_handler(prev);
    }
}

/*
 * go_forward — navigates to the next location in the forward stack.
 */
- (void)
go_forward
{
    if (self.forward_stack.count == 0) return;
    NSURL *next = self.forward_stack.lastObject;
    [self.forward_stack removeLastObject];
    if (self.current_dir) {
        [self.back_stack addObject:self.current_dir];
    }
    self.current_dir = next;
    [self start_watching:next];
    [self reload_directory];
    if (self.navigation_handler) {
        self.navigation_handler(next);
    }
}

- (BOOL)can_go_back    { return self.back_stack.count > 0; }
- (BOOL)can_go_forward { return self.forward_stack.count > 0; }
- (NSURL *)current_url { return self.current_dir; }

/*
 * selected_urls — returns the file URLs of selected table rows.
 *
 * Output: NSArray<NSURL *>.
 */
- (NSArray<NSURL *> *)
selected_urls
{
    NSMutableArray<NSURL *> *result = [NSMutableArray array];
    [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.filtered_items.count) {
            [result addObject:self.filtered_items[idx]];
        }
    }];
    return result;
}

/* ── Directory loading ───────────────────────────────────────────────── */

/*
 * reload_directory — re-reads the current directory and refreshes the table.
 * Must be called on the main thread.
 */
- (void)
reload_directory
{
    if (!self.current_dir) return;
    /* Don't overwrite live search results with a directory listing. */
    if (self.search_active) return;

    NSError *err = nil;
    NSArray<NSURL *> *items =
        [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:self.current_dir
          includingPropertiesForKeys:listing_keys()
                             options:0   /* hidden-file filtering done in apply_filter */
                               error:&err];
    if (!items) {
        NSLog(@"[browser] error reading %@: %@", self.current_dir.path, err);
        items = @[];
    }

    /* Snapshot selection by path before reloadData wipes it. */
    NSArray<NSURL *> *prev_sel = [self selected_urls];

    self.all_items = [items mutableCopy];
    [self apply_sort];
    [self apply_filter];
    [self.table reloadData];

    /* Restore selection: match by path since row indices may have shifted. */
    if (prev_sel.count > 0) {
        NSMutableIndexSet *idx_set = [NSMutableIndexSet indexSet];
        for (NSURL *sel in prev_sel) {
            NSUInteger idx = [self.filtered_items indexOfObjectPassingTest:
                ^BOOL(NSURL *item, NSUInteger i, BOOL *stop) {
                    return [item.path isEqualToString:sel.path];
                }];
            if (idx != NSNotFound) [idx_set addIndex:idx];
        }
        if (idx_set.count > 0) {
            [self.table selectRowIndexes:idx_set byExtendingSelection:NO];
        }
    }

    [self update_status_bar];
    [self update_sort_indicators];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"files.auto_fit_columns"]) {
        [self apply_auto_fit];
    }
}

/*
 * apply_sort — sorts all_items by the current sort descriptor.
 */
- (void)
apply_sort
{
    NSString *key  = self.sort_key;
    BOOL ascending = self.sort_ascending;

    [self.all_items sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        /* Folders first */
        NSNumber *a_dir = nil, *b_dir = nil;
        [a getResourceValue:&a_dir forKey:NSURLIsDirectoryKey error:nil];
        [b getResourceValue:&b_dir forKey:NSURLIsDirectoryKey error:nil];
        if (a_dir.boolValue != b_dir.boolValue) {
            return a_dir.boolValue ? NSOrderedAscending : NSOrderedDescending;
        }

        id av = nil, bv = nil;
        if ([key isEqualToString:kColSize]) {
            [a getResourceValue:&av forKey:NSURLFileSizeKey error:nil];
            [b getResourceValue:&bv forKey:NSURLFileSizeKey error:nil];
        } else if ([key isEqualToString:kColKind]) {
            [a getResourceValue:&av forKey:NSURLLocalizedTypeDescriptionKey error:nil];
            [b getResourceValue:&bv forKey:NSURLLocalizedTypeDescriptionKey error:nil];
        } else if ([key isEqualToString:kColModified]) {
            [a getResourceValue:&av forKey:NSURLContentModificationDateKey error:nil];
            [b getResourceValue:&bv forKey:NSURLContentModificationDateKey error:nil];
        } else {
            [a getResourceValue:&av forKey:NSURLNameKey error:nil];
            [b getResourceValue:&bv forKey:NSURLNameKey error:nil];
        }

        NSComparisonResult cmp = NSOrderedSame;
        if ([av respondsToSelector:@selector(localizedCaseInsensitiveCompare:)]) {
            cmp = [(NSString *)av localizedCaseInsensitiveCompare:(NSString *)bv];
        } else if ([av respondsToSelector:@selector(compare:)]) {
            cmp = [(NSDate *)av compare:(NSDate *)bv];
        }
        return ascending ? cmp : (NSComparisonResult)(-cmp);
    }];
}

/*
 * apply_filter — populates filtered_items from all_items.
 * Hides items whose NSURLIsHiddenKey is YES unless the user preference
 * "files.show_hidden_files" is set. When search_text is set the text is also
 * matched against the filename (case-insensitive substring).
 */
- (void)
apply_filter
{
    BOOL show_hidden =
        [NSUserDefaults.standardUserDefaults boolForKey:@"files.show_hidden_files"];

    /* Items inside ~/.Trash are all tagged UF_HIDDEN by the OS; always show them
     * regardless of the show-hidden-files preference. */
    NSString *trash_path = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
    if ([self.current_dir.path isEqualToString:trash_path]) show_hidden = YES;

    NSString *q = self.search_text;

    self.filtered_items = [NSMutableArray array];
    for (NSURL *url in self.all_items) {
        /* Hidden-file gate */
        if (!show_hidden) {
            NSNumber *hidden = nil;
            [url getResourceValue:&hidden forKey:NSURLIsHiddenKey error:nil];
            if (hidden.boolValue) continue;
        }
        /* Text filter (only active when search is not delegated to Spotlight) */
        if (!self.search_active && q.length > 0) {
            NSString *name = nil;
            [url getResourceValue:&name forKey:NSURLNameKey error:nil];
            if ([name rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) {
                continue;
            }
        }
        [self.filtered_items addObject:url];
    }
}

/*
 * set_search_filter: — starts a Spotlight search for text, or ends it when
 * text is nil or empty.
 *
 * Inputs:
 *   text — search string; nil/empty restores the directory listing
 */
- (void)
set_search_filter:(NSString *)text
{
    if (text.length == 0) {
        [self end_spotlight_search];
    } else {
        [self begin_spotlight_search:text scope:self.current_dir];
    }
}

/*
 * begin_spotlight_search:scope: — starts an NSMetadataQuery search for
 * filenames containing query within scope and its subdirectories.
 *
 * Inputs:
 *   query — search term matched against kMDItemDisplayName (case-insensitive)
 *   scope — directory URL to scope the search to
 */
- (void)
begin_spotlight_search:(NSString *)query scope:(NSURL *)scope
{
    /* Stop any previous query */
    if (self.search_query) {
        [self.search_query stopQuery];
        [NSNotificationCenter.defaultCenter removeObserver:self
            name:NSMetadataQueryDidUpdateNotification object:self.search_query];
        [NSNotificationCenter.defaultCenter removeObserver:self
            name:NSMetadataQueryDidFinishGatheringNotification object:self.search_query];
        self.search_query = nil;
    }

    self.search_active  = YES;
    self.filtered_items = [NSMutableArray array];
    [self.table reloadData];
    [self update_status_bar];

    self.search_query = [[NSMetadataQuery alloc] init];
    self.search_query.predicate =
        [NSPredicate predicateWithFormat:@"kMDItemDisplayName CONTAINS[cd] %@", query];
    self.search_query.searchScopes = @[scope ?: self.current_dir];

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
 * end_spotlight_search — stops any running search and restores the directory
 * listing for the current directory.
 */
- (void)
end_spotlight_search
{
    if (!self.search_query) {
        self.search_active = NO;
        return;
    }
    [self.search_query stopQuery];
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:NSMetadataQueryDidUpdateNotification object:self.search_query];
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:NSMetadataQueryDidFinishGatheringNotification object:self.search_query];
    self.search_query  = nil;
    self.search_active = NO;
    [self reload_directory];
}

/*
 * search_results_updated: — NSMetadataQuery notification handler; converts
 * result items to file URLs and refreshes the table.
 *
 * Inputs:
 *   note — NSMetadataQueryDidUpdateNotification or DidFinishGatheringNotification
 */
- (void)
search_results_updated:(NSNotification *)note
{
    [self.search_query disableUpdates];

    NSMutableArray<NSURL *> *results = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.search_query.resultCount; i++) {
        NSMetadataItem *item = [self.search_query resultAtIndex:i];
        NSString *path = [item valueForAttribute:NSMetadataItemPathKey];
        if (path) {
            [results addObject:[NSURL fileURLWithPath:path]];
        }
    }

    self.filtered_items = results;
    [self.table reloadData];
    [self update_status_bar];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"files.auto_fit_columns"]) {
        [self apply_auto_fit];
    }

    [self.search_query enableUpdates];
}

/* ── Sort indicators ─────────────────────────────────────────────────── */

/*
 * update_sort_indicators — appends ↑ or ↓ to the sorted column's title and
 * strips any prior arrow from the others. Uses the title directly because
 * setIndicatorImage:inTableColumn: is unreliable with NSTableViewStylePlain
 * on macOS 13+.
 */
- (void)
update_sort_indicators
{
    /* Strip any existing arrow suffix from every column. */
    for (NSTableColumn *col in self.table.tableColumns) {
        if ([col.title hasSuffix:@" ↑"] || [col.title hasSuffix:@" ↓"]) {
            col.title = [col.title substringToIndex:col.title.length - 2];
        }
    }

    NSTableColumn *col = [self.table tableColumnWithIdentifier:self.sort_key];
    if (!col) return;

    col.title = [col.title stringByAppendingString:
                 self.sort_ascending ? @" ↑" : @" ↓"];
    [self.table.headerView setNeedsDisplay:YES];
}

/* ── Column auto-fit ─────────────────────────────────────────────────── */

/*
/*
 * perms_string_for_mode: — formats a POSIX mode_t as the 10-char ls -la string.
 *
 * Inputs:
 *   mode — st_mode from lstat(2)
 *
 * Output: e.g. "drwxr-xr-x"
 */
static NSString *
perms_string_for_mode(mode_t mode)
{
    char b[11];

    switch (mode & S_IFMT) {
    case S_IFDIR:  b[0] = 'd'; break;
    case S_IFLNK:  b[0] = 'l'; break;
    case S_IFCHR:  b[0] = 'c'; break;
    case S_IFBLK:  b[0] = 'b'; break;
    case S_IFIFO:  b[0] = 'p'; break;
    case S_IFSOCK: b[0] = 's'; break;
    default:       b[0] = '-'; break;
    }

    b[1] = (mode & S_IRUSR) ? 'r' : '-';
    b[2] = (mode & S_IWUSR) ? 'w' : '-';
    b[3] = (mode & S_ISUID) ? ((mode & S_IXUSR) ? 's' : 'S')
                             : ((mode & S_IXUSR) ? 'x' : '-');

    b[4] = (mode & S_IRGRP) ? 'r' : '-';
    b[5] = (mode & S_IWGRP) ? 'w' : '-';
    b[6] = (mode & S_ISGID) ? ((mode & S_IXGRP) ? 's' : 'S')
                             : ((mode & S_IXGRP) ? 'x' : '-');

    b[7] = (mode & S_IROTH) ? 'r' : '-';
    b[8] = (mode & S_IWOTH) ? 'w' : '-';
    b[9] = (mode & S_ISVTX) ? ((mode & S_IXOTH) ? 't' : 'T')
                             : ((mode & S_IXOTH) ? 'x' : '-');
    b[10] = '\0';
    return [NSString stringWithUTF8String:b];
}

/*
 * cell_text_for_column:url: — returns the display string for a cell.
 * Shared by the cell-view builder and the column auto-fit measurement.
 *
 * Inputs:
 *   col_id — column identifier (kColName, kColSize, …)
 *   url    — file URL for the row
 *
 * Output: NSString to display; never nil.
 */
- (NSString *)
cell_text_for_column:(NSString *)col_id
                 url:(NSURL *)url
{
    if ([col_id isEqualToString:kColName]) {
        NSString *name = nil;
        [url getResourceValue:&name forKey:NSURLNameKey error:nil];
        return name ?: url.lastPathComponent;

    } else if ([col_id isEqualToString:kColSize]) {
        NSNumber *is_dir = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) return @"—";
        NSNumber *sz = nil;
        [url getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        if (!sz) return @"—";
        NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
        fmt.countStyle = NSByteCountFormatterCountStyleFile;
        return [fmt stringFromByteCount:sz.longLongValue];

    } else if ([col_id isEqualToString:kColKind]) {
        NSNumber *is_dir = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) return @"Folder";
        NSString *kind = nil;
        [url getResourceValue:&kind forKey:NSURLLocalizedTypeDescriptionKey error:nil];
        return kind ?: @"—";

    } else if ([col_id isEqualToString:kColPerms]) {
        struct stat st;
        if (lstat(url.fileSystemRepresentation, &st) != 0) return @"—";
        return perms_string_for_mode(st.st_mode);

    } else if ([col_id isEqualToString:kColModified]) {
        NSDate *date = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        if (!date) return @"—";
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterShortStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
        return [fmt stringFromDate:date];
    }
    return @"";
}

/*
 * apply_auto_fit — resizes every column to the widest content across all
 * visible rows, respecting each column's minWidth.
 */
- (void)
apply_auto_fit
{
    NSDictionary *cell_attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12.0] };

    /* Extra fixed pixels: icon+gap for Name col; cell left+right padding elsewhere. */
    static const CGFloat kNameExtra = 16 + 4 + 2 + 2; /* icon + gap + l-pad + r-pad */
    static const CGFloat kCellExtra = 2 + 2;           /* l-pad + r-pad */
    static const CGFloat kColPad    = 10;              /* header side padding + margin */

    for (NSTableColumn *col in self.table.tableColumns) {
        NSString *col_id = col.identifier;

        /* Measure header — strip any sort-indicator suffix first. */
        NSString *hdr = col.title;
        if ([hdr hasSuffix:@" ↑"] || [hdr hasSuffix:@" ↓"]) {
            hdr = [hdr substringToIndex:hdr.length - 2];
        }
        CGFloat max_w = [hdr sizeWithAttributes:
            @{ NSFontAttributeName: col.headerCell.font }].width + kColPad;

        /* Measure every row. */
        CGFloat extra = [col_id isEqualToString:kColName] ? kNameExtra : kCellExtra;
        for (NSURL *url in self.filtered_items) {
            NSString *text = [self cell_text_for_column:col_id url:url];
            CGFloat w = [text sizeWithAttributes:cell_attrs].width + extra;
            if (w > max_w) max_w = w;
        }

        col.width = MAX(col.minWidth, max_w);
    }
}

/* ── Status bar ──────────────────────────────────────────────────────── */

/*
 * empty_trash_action: — confirms and permanently deletes everything in
 * ~/.Trash, then reloads the directory listing.
 *
 * Inputs:
 *   sender — the Empty Trash button (unused)
 */
- (IBAction)
empty_trash_action:(id)sender
{
    NSAlert *alert       = [[NSAlert alloc] init];
    alert.messageText    = @"Permanently delete the items in the Trash?";
    alert.informativeText = @"You cannot undo this action.";
    [alert addButtonWithTitle:@"Empty Trash"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSString *trash_path = [NSHomeDirectory()
            stringByAppendingPathComponent:@".Trash"];
        NSURL *trash_url = [NSURL fileURLWithPath:trash_path];
        NSArray<NSURL *> *items =
            [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:trash_url
                includingPropertiesForKeys:nil
                options:NSDirectoryEnumerationSkipsHiddenFiles
                error:nil];
        for (NSURL *item in items) {
            [NSFileManager.defaultManager removeItemAtURL:item error:nil];
        }
        [self reload_directory];
        if (self.status_text_handler) self.status_text_handler(@"Trash emptied.");
        __weak FilesBrowserView *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ws update_status_bar];
        });
    }];
}

/*
 * update_status_bar — updates the status label text.
 */
- (void)
update_status_bar
{
    NSInteger total    = (NSInteger)self.filtered_items.count;
    NSInteger selected = (NSInteger)self.table.numberOfSelectedRows;
    NSString *msg;
    if (selected > 0) {
        msg = [NSString stringWithFormat:@"%ld item%@ — %ld selected",
               (long)total,   total == 1   ? @"" : @"s",
               (long)selected];
    } else {
        msg = [NSString stringWithFormat:@"%ld item%@",
               (long)total, total == 1 ? @"" : @"s"];
    }
    if (self.status_text_handler) self.status_text_handler(msg);
}

/* ── NSTableViewDataSource ───────────────────────────────────────────── */

- (NSInteger)
numberOfRowsInTableView:(NSTableView *)tv
{
    NSInteger n = (NSInteger)self.filtered_items.count;
    return n;
}

/*
 * tableView:viewForTableColumn:row: — returns the cell view for a given
 * column and row.
 */
- (NSView *)
tableView:(NSTableView *)tv
viewForTableColumn:(NSTableColumn *)col
              row:(NSInteger)row
{
    if (row < 0 || (NSUInteger)row >= self.filtered_items.count) return nil;
    NSURL *url = self.filtered_items[row];

    NSString *ident = col.identifier;
    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:nil];
    if (!cell) {
        cell            = [[NSTableCellView alloc] init];
        cell.identifier = ident;
        NSTextField *tf = [[NSTextField alloc] init];
        tf.editable        = NO;
        tf.bordered        = NO;
        tf.drawsBackground = NO;
        tf.font            = [NSFont systemFontOfSize:12.0];
        tf.lineBreakMode   = NSLineBreakByTruncatingMiddle;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        cell.textField = tf;
        [cell addSubview:tf];

        if ([ident isEqualToString:kColName]) {
            NSImageView *iv = [[NSImageView alloc] init];
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            cell.imageView  = iv;
            [cell addSubview:iv];

            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [iv.widthAnchor constraintEqualToConstant:16],
                [iv.heightAnchor constraintEqualToConstant:16],
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

    if ([ident isEqualToString:kColName]) {
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size     = NSMakeSize(16, 16);
        cell.imageView.image = icon;
    } else if ([ident isEqualToString:kColSize]) {
        cell.textField.alignment = NSTextAlignmentRight;
    } else if ([ident isEqualToString:kColPerms]) {
        cell.textField.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
        cell.textField.alignment = NSTextAlignmentLeft;
    }

    return cell;
}

/*
 * tableView:didClickTableColumn: — handles column header clicks for sorting.
 * Clicking the active sort column flips ascending/descending; clicking another
 * column sorts by it ascending.
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
    [self apply_sort];
    [self apply_filter];
    [tv reloadData];
    [self update_sort_indicators];
}

/* ── NSTableViewDelegate ─────────────────────────────────────────────── */

- (void)
tableViewSelectionDidChange:(NSNotification *)note
{
    [self update_status_bar];
    if (self.sidebar_handler) {
        self.sidebar_handler([self selected_urls]);
    }
}

/* ── Double-click ────────────────────────────────────────────────────── */

/*
 * row_double_clicked: — navigates into a folder or opens a file.
 *
 * Inputs:
 *   sender — the table view (unused)
 */
- (void)
row_double_clicked:(id)sender
{
    NSInteger row = self.table.clickedRow;
    if (row < 0 || (NSUInteger)row >= self.filtered_items.count) return;
    NSURL *url = self.filtered_items[row];
    NSNumber *is_dir = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    if (is_dir.boolValue) {
        [self navigate_to:url];
    } else {
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

/* ── Keyboard handling ───────────────────────────────────────────────── */

- (BOOL)
acceptsFirstResponder
{
    return YES;
}

- (void)
keyDown:(NSEvent *)event
{
    NSString *chars = event.charactersIgnoringModifiers;

    /* Return/Enter: begin rename */
    if ([chars isEqualToString:@"\r"] || [chars isEqualToString:@"\n"]) {
        [self begin_rename:nil];
        return;
    }

    /* Escape: cancel rename */
    if (event.keyCode == 53) {
        [self cancel_rename];
        return;
    }

    /* Backspace/Delete without modifiers: move to trash */
    if ([chars isEqualToString:@"\x7f"] || [chars isEqualToString:@"\x08"]) {
        [self move_to_trash_action:nil];
        return;
    }

    [super keyDown:event];
}

/* ── Actions ─────────────────────────────────────────────────────────── */

/*
 * open_selected: — opens selected files/folders.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (void)
open_selected:(id)sender
{
    for (NSURL *url in [self selected_urls]) {
        NSNumber *is_dir = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) {
            [self navigate_to:url];
        } else {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
    }
}

/*
 * copy_action: — copies selected URLs to the pasteboard.
 */
- (IBAction)
copy_action:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count > 0) {
        [FilesFileOps copy_urls:sel is_cut:NO];
    }
}

/*
 * cut_action: — copies selected URLs as a cut operation.
 */
- (IBAction)
cut_action:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count > 0) {
        [FilesFileOps copy_urls:sel is_cut:YES];
    }
}

/*
 * paste_action: — pastes from pasteboard into the current directory.
 */
- (IBAction)
paste_action:(id)sender
{
    if (!self.current_dir) return;
    if (![FilesFileOps pasteboard_has_files]) return;
    [FilesFileOps paste_to_directory:self.current_dir completion:^(NSError *err) {
        if (err && err.code != NSUserCancelledError) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText     = @"Paste failed";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
        }
        [self reload_directory];
    }];
}

/*
 * move_to_trash_action: — moves selected files to the trash.
 */
- (IBAction)
move_to_trash_action:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (sel.count == 0) return;
    [FilesFileOps move_to_trash:sel completion:^(NSError *err) {
        if (err) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText     = @"Could not move to Trash";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
        }
        [self reload_directory];
    }];
}

/*
 * new_folder_action: — creates an "untitled folder" in the current directory.
 */
- (IBAction)
new_folder_action:(id)sender
{
    if (!self.current_dir) return;
    [FilesFileOps create_folder_in:self.current_dir
                              name:@"untitled folder"
                        completion:^(NSURL *new_url, NSError *err) {
        if (err) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText     = @"Could not create folder";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
            return;
        }
        [self reload_directory];
        /* Select and begin rename of new folder */
        NSUInteger idx = [self.filtered_items indexOfObject:new_url];
        if (idx != NSNotFound) {
            [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:idx]
                    byExtendingSelection:NO];
            [self.table scrollRowToVisible:(NSInteger)idx];
            self.rename_url = new_url;
            [self begin_rename:nil];
        }
    }];
}

/*
 * get_info_action: — shows the info panel for the selected file(s).
 */
- (IBAction)
get_info_action:(id)sender
{
    NSArray<NSURL *> *sel = [self selected_urls];
    if (self.info_handler && sel.count > 0) {
        self.info_handler(sel);
    } else if (sel.count > 0) {
        [FilesInfoPanel.shared show_for_url:sel.firstObject];
    }
}

/*
 * select_all_action: — selects all rows in the table.
 */
- (IBAction)
select_all_action:(id)sender
{
    [self.table selectAll:sender];
}

/*
 * go_back_action: / go_forward_action: — navigation from menu.
 */
- (IBAction)go_back_action:(id)sender    { [self go_back]; }
- (IBAction)go_forward_action:(id)sender { [self go_forward]; }

/*
 * go_home_action: / go_desktop_action: / go_downloads_action: /
 * go_documents_action: — Go menu convenience actions.
 */
- (IBAction)
go_home_action:(id)sender
{
    [self navigate_to:[NSURL fileURLWithPath:NSHomeDirectory()]];
}

- (IBAction)
go_desktop_action:(id)sender
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    [self navigate_to:[NSURL fileURLWithPath:path]];
}

- (IBAction)
go_downloads_action:(id)sender
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    [self navigate_to:[NSURL fileURLWithPath:path]];
}

- (IBAction)
go_documents_action:(id)sender
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [self navigate_to:[NSURL fileURLWithPath:path]];
}

/*
 * toggle_hidden_files_action: — flips the show-hidden-files preference and
 * reloads the directory listing.
 *
 * Inputs:
 *   sender — toolbar toggle button or menu item
 */
- (IBAction)
toggle_hidden_files_action:(id)sender
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL current = [ud boolForKey:@"files.show_hidden_files"];
    [ud setBool:!current forKey:@"files.show_hidden_files"];
    if ([sender isKindOfClass:NSButton.class]) {
        ((NSButton *)sender).state = !current
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self reload_directory];
}

/* ── Inline rename ───────────────────────────────────────────────────── */

/*
 * begin_rename: — shows an NSTextField overlay over the name cell of the
 * selected row.
 *
 * Inputs:
 *   sender — menu item or nil
 */
- (void)
begin_rename:(id)sender
{
    NSInteger row = self.table.selectedRow;
    if (row < 0 || (NSUInteger)row >= self.filtered_items.count) return;

    NSURL *url      = self.filtered_items[row];
    self.rename_url = url;

    NSRect row_rect  = [self.table rectOfRow:row];
    NSRect col_rect  = [self.table rectOfColumn:0];
    NSRect cell_rect = NSIntersectionRect(row_rect, col_rect);
    /* Offset for icon and scroll position */
    cell_rect.origin.x   += 22.0;
    cell_rect.size.width -= 22.0;

    NSRect field_rect = [self.table convertRect:cell_rect toView:self];
    field_rect = [self.scroll convertRect:field_rect fromView:self.table];
    field_rect = [self convertRect:field_rect fromView:self.scroll];

    if (!self.rename_field) {
        self.rename_field              = [[NSTextField alloc] init];
        self.rename_field.delegate     = self;
        self.rename_field.font         = [NSFont systemFontOfSize:12.0];
        self.rename_field.bezelStyle   = NSTextFieldSquareBezel;
    }
    self.rename_field.frame          = field_rect;
    self.rename_field.stringValue    = url.lastPathComponent;
    [self addSubview:self.rename_field];
    [self.window makeFirstResponder:self.rename_field];
    [self.rename_field selectText:nil];
}

/*
 * cancel_rename — removes the rename field without saving.
 */
- (void)
cancel_rename
{
    [self.rename_field removeFromSuperview];
    [self.window makeFirstResponder:self.table];
    self.rename_url = nil;
}

/*
 * controlTextDidEndEditing: — commits or cancels rename based on return key.
 *
 * Inputs:
 *   note — NSControlTextDidEndEditingNotification
 */
- (void)
controlTextDidEndEditing:(NSNotification *)note
{
    if (note.object != self.rename_field) return;
    NSString *new_name = self.rename_field.stringValue;
    NSURL *target      = self.rename_url;
    [self.rename_field removeFromSuperview];
    [self.window makeFirstResponder:self.table];
    self.rename_url = nil;

    if (!target || new_name.length == 0) return;
    if ([new_name isEqualToString:target.lastPathComponent]) return;

    [FilesFileOps rename_url:target to:new_name completion:^(NSURL *new_url, NSError *err) {
        if (err) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText     = @"Rename failed";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
        }
        [self reload_directory];
    }];
}

/*
 * control:textView:doCommandBySelector: — intercepts Escape to cancel rename.
 */
- (BOOL)
control:(NSControl *)control
textView:(NSTextView *)textView
doCommandBySelector:(SEL)cmd
{
    if (control != self.rename_field) return NO;
    if (cmd == @selector(cancelOperation:)) {
        [self cancel_rename];
        return YES;
    }
    return NO;
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
    (void)tv;
    if (row < 0 || row >= (NSInteger)self.filtered_items.count) return nil;
    return self.filtered_items[row];
}

/* ── Drag destination ─────────────────────────────────────────────────── */

/*
 * dest_url_for_row:op: — resolves the copy destination directory.
 * If the drop lands on a folder row, copies into that folder; otherwise
 * copies into the current directory.
 *
 * Inputs:
 *   row — proposed drop row (-1 = whole table)
 *   op  — drop operation
 *
 * Output: destination directory URL, or nil if not usable.
 */
- (NSURL *)
dest_url_for_row:(NSInteger)row op:(NSTableViewDropOperation)op
{
    if (op == NSTableViewDropOn && row >= 0
            && row < (NSInteger)self.filtered_items.count) {
        NSURL *target = self.filtered_items[row];
        BOOL is_dir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:target.path
                                               isDirectory:&is_dir] && is_dir) {
            return target;
        }
    }
    return self.current_dir;
}

/*
 * tableView:validateDrop:proposedRow:proposedDropOperation: — accepts file-URL
 * drags. Highlights a folder row when the pointer is over one; otherwise
 * highlights the whole table (drop into the current directory).
 *
 * Inputs:
 *   tv  — table view
 *   info — dragging session info
 *   row  — proposed row
 *   op   — proposed operation
 *
 * Output: NSDragOperationCopy, or NSDragOperationNone if not a file drag.
 */
- (NSDragOperation)
tableView:(NSTableView *)tv
validateDrop:(id<NSDraggingInfo>)info
proposedRow:(NSInteger)row
proposedDropOperation:(NSTableViewDropOperation)op
{
    if (![info.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
            options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) {
        return NSDragOperationNone;
    }

    /* Highlight a folder row if the pointer is over one; else use the table. */
    BOOL over_folder = NO;
    if (op == NSTableViewDropOn && row >= 0
            && row < (NSInteger)self.filtered_items.count) {
        BOOL is_dir = NO;
        NSString *path = self.filtered_items[row].path;
        [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&is_dir];
        over_folder = is_dir;
    }

    if (!over_folder) {
        [tv setDropRow:-1 dropOperation:NSTableViewDropOn];
    }

    /* Refuse a drop that would copy files into their own parent directory. */
    NSURL *dest = [self dest_url_for_row:over_folder ? row : -1
                                      op:NSTableViewDropOn];
    NSArray<NSURL *> *srcs =
        [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
             options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *src in srcs) {
        if ([src.URLByDeletingLastPathComponent isEqual:dest])
            return NSDragOperationNone;
    }

    return NSDragOperationCopy;
}

/*
 * tableView:acceptDrop:row:dropOperation: — copies dragged files to the
 * resolved destination via FilesFileOps (handles collisions and shows progress).
 *
 * Inputs:
 *   tv   — table view
 *   info — dragging session info
 *   row  — drop row
 *   op   — drop operation
 *
 * Output: YES if the copy was initiated.
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
    if (!srcs.count || !self.current_dir) return NO;

    NSURL *dest = [self dest_url_for_row:row op:op];
    if (!dest) return NO;

    __weak FilesBrowserView *ws = self;
    [FilesFileOps run_copy_srcs:srcs
                             to:dest
                         is_cut:NO
                  hash_validate:NO
                    cancel_flag:nil
                    known_total:0
                       progress:nil
                     completion:^(NSError *err, NSDictionary *_) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err && err.code != NSUserCancelledError) {
                NSAlert *alert        = [[NSAlert alloc] init];
                alert.messageText     = @"Copy failed";
                alert.informativeText = err.localizedDescription ?: @"Unknown error";
                [alert runModal];
            }
            FilesBrowserView *s = ws;
            if (s) [s reload_directory];
        });
    }];
    return YES;
}

@end
