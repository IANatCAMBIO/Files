#import "browser_view.h"
#import "file_ops.h"
#import "info_panel.h"
#import "util.h"
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/stat.h>

/* Column identifiers */
static NSString * const col_name     = @"name";
static NSString * const col_size     = @"size";
static NSString * const col_kind     = @"kind";
static NSString * const col_perms    = @"perms";
static NSString * const col_modified = @"modified";

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
};
#define COLUMN_COUNT (sizeof(column_specs) / sizeof(column_specs[0]))

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
 * Output: NSURLResourceKey (name for unknown columns).
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
 * perms_string_for_mode — formats a POSIX mode_t as the 10-char ls -l string.
 *
 * Inputs:
 *   mode — st_mode (type and permission bits)
 *
 * Output: e.g. "drwxr-xr-x".
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
    return @(b);
}

/*
 * icon_for_url — 16pt icon for a listed item, cached. Plain files share one
 * icon per type (keyed by UTI) so a folder of 10,000 JPEGs costs one image;
 * folders, packages and apps can carry custom icons, so they are cached per
 * path. The cache is bounded and evictable under memory pressure.
 *
 * Inputs:
 *   url — file URL from a listing (resource values prefetched)
 *
 * Output: NSImage sized 16×16.
 */
static NSImage *
icon_for_url(NSURL *url)
{
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });

    NSNumber *is_dir = nil;
    NSString *uti    = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
    BOOL by_type = !is_dir.boolValue && uti.length > 0;
    NSString *key = by_type ? uti : url.path;

    NSImage *icon = [cache objectForKey:key];
    if (!icon) {
        UTType *type = by_type ? [UTType typeWithIdentifier:uti] : nil;
        icon = type ? [NSWorkspace.sharedWorkspace iconForContentType:type]
                    : [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon = [icon copy];
        icon.size = NSMakeSize(16, 16);
        [cache setObject:icon forKey:key];
    }
    return icon;
}

/* ── FilesBrowserView ────────────────────────────────────────────────── */

@interface FilesBrowserView () <NSTableViewDataSource,
                                NSTableViewDelegate,
                                NSTextFieldDelegate>

@property (nonatomic, strong) NSTableView             *table;
@property (nonatomic, strong) NSScrollView            *scroll;
@property (nonatomic, strong) NSMutableArray<NSURL *> *back_stack;
@property (nonatomic, strong) NSMutableArray<NSURL *> *forward_stack;
@property (nonatomic, strong) NSURL                   *current_dir;
@property (nonatomic, strong) NSMutableArray<NSURL *> *all_items;
@property (nonatomic, strong) NSMutableArray<NSURL *> *filtered_items;

/* Folder watcher: stream plus the resolved path events are compared with. */
@property (nonatomic, assign) FSEventStreamRef         fs_stream;
@property (nonatomic, copy)   NSString                *watched_path;
@property (nonatomic, assign) BOOL                     reload_scheduled;

/* Background listing: serial queue and a counter that discards stale results. */
@property (nonatomic, strong) dispatch_queue_t         list_queue;
@property (nonatomic, assign) NSUInteger               list_generation;
@property (nonatomic, assign) BOOL                     auto_fit_pending;

/* Inline rename state */
@property (nonatomic, strong) NSTextField             *rename_field;
@property (nonatomic, strong) NSURL                   *rename_url;

/* Sort key and ascending flag */
@property (nonatomic, copy)   NSString                *sort_key;
@property (nonatomic, assign) BOOL                     sort_ascending;

/* Spotlight search state */
@property (nonatomic, strong) NSMetadataQuery         *search_query;
@property (nonatomic, assign) BOOL                     search_active;

- (void)schedule_reload;

@end

/*
 * fs_event_callback — FSEventStream callback (main queue). Schedules one
 * coalesced reload if any event concerns a direct child of the watched
 * folder (or the folder itself); events deeper in the tree are ignored.
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

    for (size_t i = 0; i < num_events; i++) {
        NSString *path = paths[i];
        BOOL relevant =
            (event_flags[i] & (kFSEventStreamEventFlagMustScanSubDirs |
                               kFSEventStreamEventFlagRootChanged)) ||
            [path isEqualToString:watched] ||
            [path.stringByDeletingLastPathComponent isEqualToString:watched];
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
    self.all_items      = [NSMutableArray array];
    self.filtered_items = [NSMutableArray array];
    self.sort_key       = col_name;
    self.sort_ascending = YES;
    self.list_queue     = dispatch_queue_create("files.browser.listing",
                                                DISPATCH_QUEUE_SERIAL);

    [self build_table];
    [self update_sort_indicators];

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
    self.table.rowHeight                          = 20.0;
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

    self.table.dataSource   = self;
    self.table.delegate     = self;
    self.table.target       = self;
    self.table.doubleAction = @selector(row_double_clicked:);

    /* Drag source: allow copying rows out to any destination. */
    [self.table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [self.table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];

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
    add(@"Cut",           @selector(cut:));
    add(@"Copy",          @selector(copy:));
    add(@"Paste",         @selector(paste:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Move to Trash", @selector(move_to_trash_action:));
    add(@"Rename",        @selector(begin_rename:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Get Info",      @selector(get_info_action:));
    add(@"New Folder",    @selector(new_folder_action:));

    return menu;
}

/* ── Folder watcher ──────────────────────────────────────────────────── */

/*
 * start_watching: — watches dir with an FSEventStream (file-level events,
 * 0.3 s latency). fs_event_callback filters to direct children, so activity
 * deeper in the tree (e.g. ~/Library caches while viewing ~) is ignored.
 *
 * Inputs:
 *   dir — directory URL to watch
 */
- (void)
start_watching:(NSURL *)dir
{
    [self stop_watching];

    /* FSEvents reports resolved paths (/private/var, not /var). */
    self.watched_path = dir.URLByResolvingSymlinksInPath.path;

    FSEventStreamContext ctx = { .info = (__bridge void *)self };
    self.fs_stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        fs_event_callback,
        &ctx,
        (__bridge CFArrayRef)@[self.watched_path],
        kFSEventStreamEventIdSinceNow,
        0.3,
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
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
 * dealloc — stops the folder watcher and any Spotlight query.
 */
- (void)
dealloc
{
    [self stop_watching];
    [self stop_search_query];
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
 * re-targets the watcher, starts a listing (auto-fit runs when it lands) and
 * notifies the navigation and Empty Trash handlers. Shared by navigate_to:,
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
    [self start_watching:url];
    [self reload_directory];

    if (self.navigation_handler) self.navigation_handler(url);
    if (self.trash_visible_handler) {
        self.trash_visible_handler(files_same_path(url, files_directory_url(NSTrashDirectory)));
    }
}

/*
 * navigate_to: — shows url if it is a folder (recording history), otherwise
 * opens it with its default application.
 *
 * Inputs:
 *   url — target URL
 */
- (void)
navigate_to:(NSURL *)url
{
    NSNumber *is_dir = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    if (!is_dir.boolValue) {
        [NSWorkspace.sharedWorkspace openURL:url];
        return;
    }
    if (files_same_path(url, self.current_dir)) return;

    [self push_history:self.current_dir onto:self.back_stack];
    [self.forward_stack removeAllObjects];
    [self load_location:url];
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
 * reload_directory — re-reads the current folder and refreshes the table.
 * See reload_directory_then:.
 */
- (void)
reload_directory
{
    [self reload_directory_then:nil];
}

/*
 * reload_directory_then: — lists the current folder on a background queue
 * (so large or network folders never block the UI), then on the main queue
 * sorts, filters, reloads the table and restores the selection by path.
 * A generation counter drops results that a newer reload or navigation
 * has superseded. No-op while Spotlight results are displayed.
 *
 * Inputs:
 *   done — called on the main queue after the table shows the new
 *          listing; not called if the result was superseded. May be nil.
 */
- (void)
reload_directory_then:(void (^)(void))done
{
    NSURL *dir = self.current_dir;
    if (!dir || self.search_active) return;

    NSUInteger generation = ++self.list_generation;
    __weak FilesBrowserView *ws = self;
    dispatch_async(self.list_queue, ^{
        NSError *err = nil;
        NSArray<NSURL *> *items =
            [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir
                                        includingPropertiesForKeys:listing_keys()
                                                           options:0
                                                             error:&err];
        if (!items) NSLog(@"[browser] error reading %@: %@", dir.path, err);

        dispatch_async(dispatch_get_main_queue(), ^{
            FilesBrowserView *s = ws;
            if (!s || generation != s.list_generation || s.search_active) return;
            [s show_listing:items ?: @[]];
            if (done) done();
        });
    });
}

/*
 * show_listing: — installs a fresh folder listing in the table, keeping the
 * selection (matched by path) and running a pending auto-fit.
 *
 * Inputs:
 *   items — folder contents with listing_keys() prefetched
 */
- (void)
show_listing:(NSArray<NSURL *> *)items
{
    NSSet<NSString *> *prev_sel = [NSSet setWithArray:
        [[self selected_urls] valueForKey:@"path"]];

    self.all_items = [items mutableCopy];
    [self apply_sort];
    [self apply_filter];
    [self.table reloadData];

    if (prev_sel.count > 0) {
        NSIndexSet *rows = [self.filtered_items indexesOfObjectsPassingTest:
            ^BOOL(NSURL *item, NSUInteger idx, BOOL *stop) {
                return [prev_sel containsObject:item.path];
            }];
        [self.table selectRowIndexes:rows byExtendingSelection:NO];
    }

    [self update_status_bar];
    if (self.auto_fit_pending) {
        self.auto_fit_pending = NO;
        if ([NSUserDefaults.standardUserDefaults boolForKey:files_pref_auto_fit]) {
            [self apply_auto_fit];
        }
    }
}

/*
 * apply_sort — sorts all_items folders-first, then by the sort column using
 * prefetched values (Finder-style natural order for names and kinds).
 */
- (void)
apply_sort
{
    NSURLResourceKey key = sort_resource_key(self.sort_key);
    BOOL ascending       = self.sort_ascending;

    [self.all_items sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *a_dir = nil, *b_dir = nil;
        [a getResourceValue:&a_dir forKey:NSURLIsDirectoryKey error:nil];
        [b getResourceValue:&b_dir forKey:NSURLIsDirectoryKey error:nil];
        if (a_dir.boolValue != b_dir.boolValue) {
            return a_dir.boolValue ? NSOrderedAscending : NSOrderedDescending;
        }

        id av = nil, bv = nil;
        [a getResourceValue:&av forKey:key error:nil];
        [b getResourceValue:&bv forKey:key error:nil];

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
}

/*
 * apply_filter — populates filtered_items from all_items, hiding items whose
 * NSURLIsHiddenKey is set unless files_pref_show_hidden is on. Everything in
 * the Trash is shown, since the OS marks Trash items hidden.
 */
- (void)
apply_filter
{
    BOOL show_hidden =
        [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hidden] ||
        files_same_path(self.current_dir, files_directory_url(NSTrashDirectory));

    self.filtered_items = [NSMutableArray arrayWithCapacity:self.all_items.count];
    for (NSURL *url in self.all_items) {
        if (!show_hidden) {
            NSNumber *hidden = nil;
            [url getResourceValue:&hidden forKey:NSURLIsHiddenKey error:nil];
            if (hidden.boolValue) continue;
        }
        [self.filtered_items addObject:url];
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
 * observers and leaves search mode. Does not reload the listing.
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
    self.search_active = NO;
}

/*
 * begin_spotlight_search: — starts an NSMetadataQuery for items whose display
 * name contains query, anywhere under the current folder.
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
    self.filtered_items   = [NSMutableArray array];
    [self.table reloadData];
    [self update_status_bar];

    self.search_query = [[NSMetadataQuery alloc] init];
    self.search_query.predicate =
        [NSPredicate predicateWithFormat:@"kMDItemDisplayName CONTAINS[cd] %@", query];
    self.search_query.searchScopes = @[self.current_dir];

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
 * search_results_updated: — NSMetadataQuery notification handler; shows the
 * results (sorted and hidden-filtered like a listing) in the table.
 *
 * Inputs:
 *   note — NSMetadataQueryDidUpdateNotification or DidFinishGatheringNotification
 */
- (void)
search_results_updated:(NSNotification *)note
{
    [self.search_query disableUpdates];

    NSMutableArray<NSURL *> *results = [NSMutableArray arrayWithCapacity:self.search_query.resultCount];
    for (NSUInteger i = 0; i < self.search_query.resultCount; i++) {
        NSMetadataItem *item = [self.search_query resultAtIndex:i];
        NSString *path = [item valueForAttribute:NSMetadataItemPathKey];
        if (path) [results addObject:[NSURL fileURLWithPath:path]];
    }

    self.all_items = results;
    [self apply_sort];
    [self apply_filter];
    [self.table reloadData];
    [self update_status_bar];
    if (self.auto_fit_pending && results.count > 0) {
        self.auto_fit_pending = NO;
        if ([NSUserDefaults.standardUserDefaults boolForKey:files_pref_auto_fit]) {
            [self apply_auto_fit];
        }
    }

    [self.search_query enableUpdates];
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
        [url getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        if (is_dir.boolValue || !sz) return @"—";
        return files_format_bytes(sz.longLongValue);

    } else if ([col_id isEqualToString:col_kind]) {
        NSNumber *is_dir = nil;
        [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) return @"Folder";
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
    /* Extra fixed pixels: icon+gap for Name col; cell left+right padding elsewhere. */
    static const CGFloat name_extra = 16 + 4 + 2 + 2; /* icon + gap + l-pad + r-pad */
    static const CGFloat cell_extra = 2 + 2;           /* l-pad + r-pad */
    static const CGFloat header_pad = 10;              /* header side padding + margin */

    NSUInteger rows = MIN(self.filtered_items.count, (NSUInteger)AUTO_FIT_ROW_LIMIT);
    CGFloat total = 0;
    for (NSTableColumn *col in self.table.tableColumns) {
        NSString *col_id = col.identifier;

        CGFloat max_w = [col.title sizeWithAttributes:
            @{ NSFontAttributeName: col.headerCell.font }].width + header_pad;

        NSDictionary *attrs = @{ NSFontAttributeName: cell_font_for_column(col_id) };
        CGFloat extra = [col_id isEqualToString:col_name] ? name_extra : cell_extra;
        for (NSUInteger i = 0; i < rows; i++) {
            NSString *text = [self cell_text_for_column:col_id url:self.filtered_items[i]];
            CGFloat w = [text sizeWithAttributes:attrs].width + extra;
            if (w > max_w) max_w = w;
        }

        col.width = MAX(col.minWidth, max_w);
        total    += col.width + self.table.intercellSpacing.width;
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
 * empty_trash_action: — confirms, then permanently deletes everything in the
 * Trash (including dotfiles such as .DS_Store) on a background queue, and
 * reports any items that could not be removed.
 *
 * Inputs:
 *   sender — the Empty Trash button (unused)
 */
- (IBAction)
empty_trash_action:(id)sender
{
    NSAlert *alert        = [[NSAlert alloc] init];
    alert.messageText     = @"Permanently delete the items in the Trash?";
    alert.informativeText = @"You cannot undo this action.";
    alert.alertStyle      = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Empty Trash"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak FilesBrowserView *ws = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSURL *trash = files_directory_url(NSTrashDirectory);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *first_err = nil;
            NSArray<NSURL *> *items = [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:trash includingPropertiesForKeys:nil
                                 options:0 error:&first_err];
            for (NSURL *item in items) {
                NSError *err = nil;
                if (![NSFileManager.defaultManager removeItemAtURL:item error:&err] && !first_err) {
                    first_err = err;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesBrowserView *s = ws;
                if (!s) return;
                if (first_err) files_show_error(@"Some items could not be deleted", first_err, s.window);
                [s reload_directory];
            });
        });
    }];
}

/*
 * update_status_bar — sends the item/selection count to status_text_handler.
 */
- (void)
update_status_bar
{
    NSInteger total    = (NSInteger)self.filtered_items.count;
    NSInteger selected = (NSInteger)self.table.numberOfSelectedRows;
    NSString *msg = [NSString stringWithFormat:@"%ld item%@", (long)total, total == 1 ? @"" : @"s"];
    if (selected > 0) {
        msg = [msg stringByAppendingFormat:@" — %ld selected", (long)selected];
    }
    if (self.status_text_handler) self.status_text_handler(msg);
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
    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:nil];
    if (!cell) {
        cell            = [[NSTableCellView alloc] init];
        cell.identifier = ident;
        NSTextField *tf = [[NSTextField alloc] init];
        tf.editable        = NO;
        tf.bordered        = NO;
        tf.drawsBackground = NO;
        tf.font            = cell_font_for_column(ident);
        tf.alignment       = [ident isEqualToString:col_size]
                             ? NSTextAlignmentRight : NSTextAlignmentLeft;
        tf.lineBreakMode   = NSLineBreakByTruncatingMiddle;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        cell.textField = tf;
        [cell addSubview:tf];

        if ([ident isEqualToString:col_name]) {
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
    if ([ident isEqualToString:col_name]) cell.imageView.image = icon_for_url(url);
    return cell;
}

/*
 * tableView:didClickTableColumn: — handles column header clicks for sorting.
 * Clicking the active sort column flips ascending/descending; clicking another
 * column sorts by it ascending. Works for folder listings and search results.
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
 * open_selected: — opens every selected item via navigate_to:.
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
 * keyDown: — Return/Enter begins an inline rename. Move to Trash is
 * deliberately not bound to a bare Delete key: it is only reachable via ⌘⌫
 * (Edit menu key equivalent), matching Finder.
 *
 * Inputs:
 *   event — key-down event; unhandled keys are passed to super
 */
- (void)
keyDown:(NSEvent *)event
{
    NSString *chars = event.charactersIgnoringModifiers;
    if ([chars isEqualToString:@"\r"] || [chars isEqualToString:@"\n"]) {
        [self begin_rename:nil];
        return;
    }
    [super keyDown:event];
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
 * new_folder_action: — creates an "untitled folder" in the current folder,
 * then selects it and starts an inline rename once the listing shows it.
 *
 * Inputs:
 *   sender — menu item (unused)
 */
- (IBAction)
new_folder_action:(id)sender
{
    if (!self.current_dir) return;
    __weak FilesBrowserView *ws = self;
    [FilesFileOps create_folder_in:self.current_dir
                              name:@"untitled folder"
                        completion:^(NSURL *new_url, NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err) {
            files_show_error(@"Could not create folder", err, s.window);
            return;
        }
        [s reload_directory_then:^{
            NSUInteger idx = [s.filtered_items indexOfObjectPassingTest:
                ^BOOL(NSURL *item, NSUInteger i, BOOL *stop) {
                    return files_same_path(item, new_url);
                }];
            if (idx == NSNotFound) return;
            [s.table selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
            [s.table scrollRowToVisible:(NSInteger)idx];
            [s begin_rename:nil];
        }];
    }];
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
 * begin_rename: — shows an NSTextField over the name cell of the selected
 * row, pre-filled with the current name.
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
        self.rename_field            = [[NSTextField alloc] init];
        self.rename_field.delegate   = self;
        self.rename_field.font       = [NSFont systemFontOfSize:12.0];
        self.rename_field.bezelStyle = NSTextFieldSquareBezel;
    }
    self.rename_field.frame       = field_rect;
    self.rename_field.stringValue = url.lastPathComponent;
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
    self.rename_url = nil;
    [self.rename_field abortEditing];
    [self.rename_field removeFromSuperview];
    [self.window makeFirstResponder:self.table];
}

/*
 * controlTextDidEndEditing: — commits the rename when the field ends editing
 * (unless it was cancelled, which clears rename_url first).
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
    self.rename_url    = nil;
    [self.rename_field removeFromSuperview];
    [self.window makeFirstResponder:self.table];

    if (!target || new_name.length == 0) return;
    if ([new_name isEqualToString:target.lastPathComponent]) return;

    __weak FilesBrowserView *ws = self;
    [FilesFileOps rename_url:target to:new_name completion:^(NSURL *new_url, NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err) files_show_error(@"Rename failed", err, s.window);
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
 * Output: NSDragOperationCopy, or NSDragOperationNone if the drop is refused.
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
    return NSDragOperationCopy;
}

/*
 * tableView:acceptDrop:row:dropOperation: — copies dragged files to the
 * resolved destination via FilesFileOps transfer_urls (progress panel,
 * conflict prompts, cancel).
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
    NSURL *dest = [self dest_url_for_row:row op:op];
    if (srcs.count == 0 || !dest) return NO;

    __weak FilesBrowserView *ws = self;
    [FilesFileOps transfer_urls:srcs to:dest is_cut:NO completion:^(NSError *err) {
        FilesBrowserView *s = ws;
        if (!s) return;
        if (err && err.code != NSUserCancelledError) files_show_error(@"Copy failed", err, s.window);
        [s reload_directory];
    }];
    return YES;
}

@end
