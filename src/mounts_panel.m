#import "mounts_panel.h"
#import "volume_manager.h"
#import "util.h"
#import <sys/mount.h>

/* Column identifiers */
static NSString * const col_device      = @"device";
static NSString * const col_mount       = @"mount";
static NSString * const col_type        = @"type";
static NSString * const col_options     = @"options";
static NSString * const col_unmountable = @"unmountable";
static NSString * const col_total       = @"total";
static NSString * const col_free        = @"free";
static NSString * const col_description = @"description";

/* ── FilesMountRecord ─────────────────────────────────────────────────────── */

/*
 * FilesMountRecord — data model for one mounted filesystem.
 */
@interface FilesMountRecord : NSObject
@property (nonatomic, copy)   NSString *device;
@property (nonatomic, copy)   NSString *mount_point;
@property (nonatomic, copy)   NSString *fs_type;
@property (nonatomic, copy)   NSString *options;
@property (nonatomic, copy)   NSString *mount_description; /* what it is, what macOS uses it for */
@property (nonatomic)         BOOL      is_system;  /* mounted by macOS, not by the user */
@property (nonatomic)         BOOL      can_unmount;
@property (nonatomic, strong) NSURL    *volume_url; /* nil for pseudo mounts */
@property (nonatomic)         int64_t   total_bytes;
@property (nonatomic)         int64_t   free_bytes;
@end

@implementation FilesMountRecord
@end

/* ── Helpers ──────────────────────────────────────────────────────────────── */

/*
 * format_mount_flags — converts MNT_* flag bits into a comma-separated string.
 *
 * Inputs:
 *   flags — f_flags from struct statfs
 *
 * Output: NSString such as "rw,local,journaled"
 */
static NSString *
format_mount_flags(uint32_t flags)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    [parts addObject:(flags & MNT_RDONLY) ? @"ro" : @"rw"];
    if (flags & MNT_LOCAL)       [parts addObject:@"local"];
    if (flags & MNT_JOURNALED)   [parts addObject:@"journaled"];
    if (flags & MNT_ASYNC)       [parts addObject:@"async"];
    if (flags & MNT_SYNCHRONOUS) [parts addObject:@"sync"];
    if (flags & MNT_NOEXEC)      [parts addObject:@"noexec"];
    if (flags & MNT_NOSUID)      [parts addObject:@"nosuid"];
    if (flags & MNT_EXPORTED)    [parts addObject:@"exported"];
    if (flags & MNT_ROOTFS)      [parts addObject:@"rootfs"];
    if (flags & MNT_QUOTA)       [parts addObject:@"quota"];
    if (flags & MNT_UNION)       [parts addObject:@"union"];

    return [parts componentsJoinedByString:@","];
}

/*
 * mount_description — a short explanation of what a system mount is and
 * what macOS uses it for: the volumes macOS mounts by default are matched
 * by mount point, other system mounts by path pattern or filesystem type.
 *
 * Inputs:
 *   mount_point — where it is mounted
 *   fs_type     — filesystem type name (f_fstypename)
 *
 * Output: description string, never nil.
 */
static NSString *
mount_description(NSString *mount_point, NSString *fs_type)
{
    static NSDictionary<NSString *, NSString *> *by_mount_point;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        by_mount_point = @{
            @"/":                              @"System volume: the sealed, read-only copy of macOS itself",
            @"/System/Volumes/Data":           @"Data volume: your files, apps and settings (merged into / for you)",
            @"/System/Volumes/VM":             @"Virtual memory: swap files macOS uses when RAM is full",
            @"/System/Volumes/Preboot":        @"Boot support: per-volume boot files used at startup and FileVault unlock",
            @"/System/Volumes/Update":         @"Software Update: working space for downloading and staging macOS updates",
            @"/System/Volumes/Update/mnt1":    @"Update snapshot: the system volume as the updater sees it while installing",
            @"/System/Volumes/xarts":          @"Secure Enclave anti-replay storage (xART) for secure boot and data protection",
            @"/System/Volumes/iSCPreboot":     @"Boot data for the iBoot System Container, read early at startup (Apple silicon)",
            @"/System/Volumes/Hardware":       @"Hardware support data for this Mac's own hardware (Apple silicon)",
            @"/dev":                           @"Device files: /dev/null, terminals and disks, created by the kernel",
            @"/System/Volumes/Data/home":      @"Automounter for /home: network home folders, normally empty",
        };
    });
    NSString *known = by_mount_point[mount_point];
    if (known) return known;

    if ([mount_point containsString:@"/AppTranslocation/"])
        return @"Gatekeeper: a read-only view of a downloaded app so it runs from a random location";
    if ([mount_point containsString:@"cryptex"] || [mount_point hasPrefix:@"/System/Cryptexes/"])
        return @"Cryptex: a signed system component (such as Safari) kept apart from the system volume";
    if ([mount_point hasPrefix:@"/Library/Developer/CoreSimulator/Volumes/"])
        return @"Xcode: a simulator runtime disk image";
    if ([fs_type isEqualToString:@"devfs"])   return @"Device files created by the kernel";
    if ([fs_type isEqualToString:@"autofs"])  return @"Automounter: mounts network folders on demand";
    if ([fs_type isEqualToString:@"nullfs"])  return @"A second view of another folder, with no copy of its data";
    if ([fs_type isEqualToString:@"smbfs"] || [fs_type isEqualToString:@"nfs"] ||
        [fs_type isEqualToString:@"afpfs"] || [fs_type isEqualToString:@"webdav"])
        return @"Network share";
    if ([fs_type isEqualToString:@"cd9660"] || [fs_type isEqualToString:@"udf"])
        return @"Optical disc or disk image";
    if ([mount_point hasPrefix:@"/Volumes/"]) return @"Hidden volume mounted for the system";
    return @"";
}

/*
 * make_col — allocates and configures one NSTableColumn.
 *
 * Inputs:
 *   ident     — column identifier string
 *   title     — header title
 *   width     — initial width in points
 *   resizable — YES if user may resize; NO for fixed columns
 *
 * Output: configured NSTableColumn.
 */
static NSTableColumn *
make_col(NSString *ident, NSString *title, CGFloat width, BOOL resizable)
{
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title          = title;
    col.width          = width;
    col.minWidth       = 40.0;
    col.resizingMask   = resizable ? NSTableColumnUserResizingMask
                                    : NSTableColumnNoResizing;
    return col;
}

/* ── FilesMountsPanel ─────────────────────────────────────────────────────── */

@interface FilesMountsPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView                        *table;
@property (nonatomic, strong) NSMutableArray<FilesMountRecord *> *records;      /* the rows shown */
@property (nonatomic, copy)   NSArray<FilesMountRecord *>        *all_records;  /* everything mounted */
@property (nonatomic, strong) NSButton                           *hide_system_check;
@property (nonatomic, strong) NSButton                           *unmount_btn;
@property (nonatomic, assign) NSUInteger                          load_generation;
@end

@implementation FilesMountsPanel

/*
 * shared — returns the process-wide singleton, creating it on first call.
 *
 * Output: FilesMountsPanel singleton, never nil.
 */
+ (instancetype)
shared
{
    static FilesMountsPanel *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FilesMountsPanel alloc] init];
    });
    return instance;
}

/*
 * init — builds the mounts panel window and table and subscribes to
 * FilesVolumesChangedNotification.
 *
 * Output: self or nil.
 */
- (instancetype)
init
{
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 800, 300)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title              = @"All Mounts";
    panel.minSize            = NSMakeSize(600, 150);
    panel.hidesOnDeactivate  = NO;
    [panel center];

    self = [super initWithWindow:panel];
    if (!self) return nil;

    self.records = [NSMutableArray array];

    [self build_table];
    [self build_toolbar_row];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(volumes_changed:)
               name:FilesVolumesChangedNotification
             object:nil];

    return self;
}

/* ── UI construction ─────────────────────────────────────────────────────── */

/*
 * build_table — creates the NSScrollView + NSTableView with data columns and
 * their sort descriptor prototypes.
 *
 * Output: none; sets self.table.
 */
- (void)
build_table
{
    NSView *content = self.window.contentView;
    CGFloat w = content.bounds.size.width;
    CGFloat h = content.bounds.size.height;

    NSScrollView *scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 32, w, h - 32)];
    scroll.autoresizingMask      = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller   = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers    = YES;

    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.table.style                          = NSTableViewStylePlain;
    self.table.dataSource                     = self;
    self.table.delegate                       = self;
    self.table.rowHeight                      = 22.0;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.columnAutoresizingStyle        = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.table.allowsEmptySelection           = YES;

    [self.table addTableColumn:make_col(col_device,      @"Device",      160, YES)];
    [self.table addTableColumn:make_col(col_mount,       @"Mount Point", 140, YES)];
    [self.table addTableColumn:make_col(col_type,        @"Type",         60, YES)];
    [self.table addTableColumn:make_col(col_options,     @"Options",     160, YES)];
    [self.table addTableColumn:make_col(col_total,       @"Total",        80, YES)];
    [self.table addTableColumn:make_col(col_free,        @"Free",         80, YES)];
    [self.table addTableColumn:make_col(col_unmountable, @"Unmountable",  72, YES)];
    [self.table addTableColumn:make_col(col_description, @"Description", 300, YES)];

    /* Sort descriptors — clicking a header sorts that column ascending/descending. */
    [self.table tableColumnWithIdentifier:col_device].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"device"      ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:col_mount].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"mount_point" ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:col_type].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"fs_type"     ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:col_options].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"options"     ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:col_total].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"total_bytes" ascending:YES];
    [self.table tableColumnWithIdentifier:col_free].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"free_bytes"  ascending:YES];
    [self.table tableColumnWithIdentifier:col_unmountable].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"can_unmount" ascending:YES];
    [self.table tableColumnWithIdentifier:col_description].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"mount_description" ascending:YES
                                       selector:@selector(localizedCompare:)];

    scroll.documentView = self.table;
    [content addSubview:scroll];
}

/*
 * build_toolbar_row — adds Unmount and Refresh buttons at the bottom-right and
 * the Hide System Volumes checkbox at the bottom-left.
 *
 * Output: none; sets self.unmount_btn (initially disabled) and
 *         self.hide_system_check.
 */
- (void)
build_toolbar_row
{
    NSView *content = self.window.contentView;
    CGFloat w = content.bounds.size.width;

    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh"
                                           target:self
                                           action:@selector(refresh_clicked:)];
    refresh.bezelStyle    = NSBezelStyleRounded;
    refresh.frame         = NSMakeRect(w - 90, 4, 84, 24);
    refresh.autoresizingMask = NSViewMinXMargin;
    [content addSubview:refresh];

    self.unmount_btn = [NSButton buttonWithTitle:@"Unmount"
                                          target:self
                                          action:@selector(unmount_clicked:)];
    self.unmount_btn.bezelStyle    = NSBezelStyleRounded;
    self.unmount_btn.frame         = NSMakeRect(w - 178, 4, 84, 24);
    self.unmount_btn.autoresizingMask = NSViewMinXMargin;
    self.unmount_btn.enabled       = NO;
    [content addSubview:self.unmount_btn];

    /* Checkbox on the left: list only the volumes the user mounted. */
    self.hide_system_check = [NSButton checkboxWithTitle:@"Hide System Volumes"
                                                  target:self
                                                  action:@selector(hide_system_toggled:)];
    self.hide_system_check.state = [NSUserDefaults.standardUserDefaults
        boolForKey:files_pref_hide_system_mounts] ? NSControlStateValueOn : NSControlStateValueOff;
    self.hide_system_check.font  = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.hide_system_check.frame = NSMakeRect(10, 6, 190, 18);
    self.hide_system_check.autoresizingMask = NSViewMaxXMargin;
    [content addSubview:self.hide_system_check];
}

/* ── Data ────────────────────────────────────────────────────────────────── */

/*
 * read_mounts — one record per entry in the kernel mount table
 * (getmntinfo_r_np, MNT_NOWAIT: no file system is asked to refresh, so a
 * dead network server cannot stall it). Browsable mounts — the volumes
 * Finder shows, i.e. those without MNT_DONTBROWSE — take total and free
 * space from NSURLVolumeTotalCapacityKey and
 * NSURLVolumeAvailableCapacityForImportantUsageKey (counts APFS purgeable
 * space, as Finder does) and get can_unmount; pseudo and hidden mounts
 * (devfs, autofs, system volumes, …) use statfs block counts. These
 * queries can be slow (purgeable space) or hang on an unreachable server,
 * so this runs off the main thread.
 *
 * Output: array of records, empty if the mount table cannot be read.
 */
static NSArray<FilesMountRecord *> *
read_mounts(void)
{
    struct statfs *buf = NULL;
    int count = getmntinfo_r_np(&buf, MNT_NOWAIT);
    if (count <= 0) return @[];

    FilesVolumeManager *vm = FilesVolumeManager.shared;
    NSArray<NSURLResourceKey> *capacity_keys =
        @[NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityForImportantUsageKey];
    NSMutableArray<FilesMountRecord *> *records = [NSMutableArray arrayWithCapacity:(NSUInteger)count];

    for (int i = 0; i < count; i++) {
        FilesMountRecord *rec = [[FilesMountRecord alloc] init];
        rec.device      = [NSString stringWithUTF8String:buf[i].f_mntfromname];
        rec.mount_point = [NSString stringWithUTF8String:buf[i].f_mntonname];
        rec.fs_type     = [NSString stringWithUTF8String:buf[i].f_fstypename];
        rec.options     = format_mount_flags((uint32_t)buf[i].f_flags);
        /* A volume Finder does not show, and the startup volume, are the
         * system's; everything else was mounted by the user. */
        rec.is_system   = (buf[i].f_flags & MNT_DONTBROWSE) || [rec.mount_point isEqualToString:@"/"];
        rec.mount_description = rec.is_system
            ? mount_description(rec.mount_point, rec.fs_type) : @"";

        NSDictionary<NSURLResourceKey, id> *cap = nil;
        if (!(buf[i].f_flags & MNT_DONTBROWSE)) {
            rec.volume_url  = [NSURL fileURLWithPath:rec.mount_point isDirectory:YES];
            rec.can_unmount = [vm can_unmount_volume:rec.volume_url];
            cap = [rec.volume_url resourceValuesForKeys:capacity_keys error:nil];
        }
        if (cap) {
            rec.total_bytes = [cap[NSURLVolumeTotalCapacityKey] longLongValue];
            rec.free_bytes  =
                [cap[NSURLVolumeAvailableCapacityForImportantUsageKey] longLongValue];
        } else {
            rec.total_bytes = (int64_t)buf[i].f_blocks * (int64_t)buf[i].f_bsize;
            rec.free_bytes  = (int64_t)buf[i].f_bavail * (int64_t)buf[i].f_bsize;
        }
        [records addObject:rec];
    }
    free(buf);
    return records;
}

/*
 * cell_text_for_col:record: — returns the display string for one
 * column/record pair; the single source for both cell views and column
 * fitting.
 *
 * Inputs:
 *   ident — column identifier
 *   rec   — mount record
 *
 * Output: display string, never nil.
 */
- (NSString *)
cell_text_for_col:(NSString *)ident
           record:(FilesMountRecord *)rec
{
    if ([ident isEqualToString:col_device])      return rec.device;
    if ([ident isEqualToString:col_mount])       return rec.mount_point;
    if ([ident isEqualToString:col_type])        return rec.fs_type;
    if ([ident isEqualToString:col_options])     return rec.options;
    if ([ident isEqualToString:col_total])
        return rec.total_bytes > 0 ? files_format_bytes(rec.total_bytes) : @"—";
    if ([ident isEqualToString:col_free])
        return rec.total_bytes > 0 ? files_format_bytes(rec.free_bytes) : @"—";
    if ([ident isEqualToString:col_unmountable]) return rec.can_unmount ? @"Yes" : @"No";
    if ([ident isEqualToString:col_description]) return rec.mount_description;
    return @"";
}

/*
 * fit_columns — sizes each column to the maximum of its header title and its
 * widest data cell.
 *
 * Output: none; column widths are updated.
 */
- (void)
fit_columns
{
    NSDictionary *cell_attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.0
                                                        weight:NSFontWeightRegular]
    };
    NSDictionary *head_attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize]
    };

    static const CGFloat cell_pad = 16.0; /* left + right cell inset */
    static const CGFloat head_pad = 20.0; /* extra for sort arrow */

    for (NSTableColumn *col in self.table.tableColumns) {
        CGFloat w = ceil([col.title sizeWithAttributes:head_attrs].width) + head_pad;

        for (FilesMountRecord *rec in self.records) {
            NSString *text = [self cell_text_for_col:col.identifier record:rec];
            CGFloat tw = ceil([text sizeWithAttributes:cell_attrs].width) + cell_pad;
            if (tw > w) w = tw;
        }

        col.minWidth = 40.0;
        col.width    = w;
    }
}

/*
 * show_records — fills the table from all_records: only the volumes the
 * user mounted while Hide System Volumes is checked, else every mount;
 * the Description column, which only system mounts have, is hidden along
 * with them. Applies the table's sort descriptors, reloads, refits the columns and
 * clears the selection (which disables Unmount via
 * tableViewSelectionDidChange:).
 */
- (void)
show_records
{
    BOOL hide_system = self.hide_system_check.state == NSControlStateValueOn;
    self.records = [NSMutableArray array];
    for (FilesMountRecord *rec in self.all_records) {
        if (!(hide_system && rec.is_system)) [self.records addObject:rec];
    }
    [self.records sortUsingDescriptors:self.table.sortDescriptors];
    [self.table tableColumnWithIdentifier:col_description].hidden = hide_system;
    [self.table reloadData];
    [self fit_columns];
    [self.table deselectAll:nil];
}

/*
 * hide_system_toggled: — the Hide System Volumes checkbox: remembers the
 * choice, shows or hides the system volumes and resizes the window to the
 * rows now listed.
 *
 * Inputs:
 *   sender — the checkbox (unused)
 */
- (void)
hide_system_toggled:(id)sender
{
    [NSUserDefaults.standardUserDefaults
        setBool:self.hide_system_check.state == NSControlStateValueOn
         forKey:files_pref_hide_system_mounts];
    [self show_records];
    [self resize_to_fit];
}

/*
 * reload_table_then: — the one reload path: reads the mount records on a
 * background queue (read_mounts), then on the main queue shows them
 * (show_records). A newer reload supersedes an older one.
 *
 * Inputs:
 *   done — called on the main queue once the table shows the new records;
 *          not called if superseded. May be nil.
 */
- (void)
reload_table_then:(void (^)(void))done
{
    NSUInteger generation = ++self.load_generation;
    __weak FilesMountsPanel *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<FilesMountRecord *> *records = read_mounts();
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesMountsPanel *s = ws;
            if (!s || generation != s.load_generation) return;
            s.all_records = records;
            [s show_records];
            if (done) done();
        });
    });
}

/*
 * resize_to_fit — resizes the window to show all rows and all (already
 * fitted) columns without scrolling, clamped to a share of the visible
 * screen area.
 *
 * Output: none; the window frame is updated, top-left corner kept in place.
 */
- (void)
resize_to_fit
{
    CGFloat col_total = 0.0;
    NSUInteger shown  = 0;
    for (NSTableColumn *col in self.table.tableColumns) {
        if (col.hidden) continue;
        col_total += col.width;
        shown++;
    }
    CGFloat spacing    = self.table.intercellSpacing.width * (CGFloat)(shown - 1);
    CGFloat content_w  = col_total + spacing + 2.0; /* 1pt each side for borders */

    CGFloat max_w      = NSScreen.mainScreen.visibleFrame.size.width  * 0.9;
    content_w = MAX(600.0, MIN(content_w, max_w));

    CGFloat row_area   = self.records.count * self.table.rowHeight;
    CGFloat header_h   = self.table.headerView ? self.table.headerView.frame.size.height : 0.0;
    CGFloat toolbar_h  = 32.0;
    CGFloat content_h  = row_area + header_h + toolbar_h;

    CGFloat max_h      = NSScreen.mainScreen.visibleFrame.size.height * 0.8;
    content_h = MAX(150.0, MIN(content_h, max_h));

    NSRect frame       = self.window.frame;
    CGFloat dh         = content_h - self.window.contentView.bounds.size.height;
    CGFloat dw         = content_w - self.window.contentView.bounds.size.width;
    frame.origin.y    -= dh;   /* grow upward so top-left stays put */
    frame.size.height += dh;
    frame.size.width  += dw;
    [self.window setFrame:frame display:YES animate:NO];
}

/* ── Actions ─────────────────────────────────────────────────────────────── */

/*
 * show_panel — brings the panel forward, then reloads the table and, once
 * the mounts are read, sizes the window to fit and scrolls to the top.
 *
 * Output: none.
 */
- (void)
show_panel
{
    [self showWindow:nil];
    __weak FilesMountsPanel *ws = self;
    [self reload_table_then:^{
        [ws resize_to_fit];
        [ws.table scrollRowToVisible:0];
    }];
}

/*
 * refresh_clicked: — reloads the table in place (window size unchanged).
 *
 * Inputs:
 *   sender — Refresh button
 *
 * Output: none.
 */
- (IBAction)
refresh_clicked:(id)sender
{
    [self reload_table_then:nil];
}

/*
 * unmount_clicked: — unmounts the volume for the selected row. On success
 * the workspace unmount notification reloads the table; on failure an error
 * sheet is shown.
 *
 * Inputs:
 *   sender — Unmount button
 *
 * Output: none.
 */
- (IBAction)
unmount_clicked:(id)sender
{
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.records.count) return;
    FilesMountRecord *rec = self.records[row];
    if (!rec.can_unmount || !rec.volume_url) return;

    NSWindow *window = self.window;
    [FilesVolumeManager.shared unmount_volume:rec.volume_url completion:^(NSError *err) {
        if (err) {
            files_show_error(@"Could not unmount volume", err, window);
        }
    }];
}

/*
 * volumes_changed: — notification handler; reloads the table when a volume
 * is mounted, unmounted or renamed while the panel is visible.
 *
 * Inputs:
 *   note — FilesVolumesChangedNotification
 *
 * Output: none.
 */
- (void)
volumes_changed:(NSNotification *)note
{
    if (self.window.isVisible) {
        [self reload_table_then:nil];
    }
}

/* ── NSTableViewDataSource ────────────────────────────────────────────────── */

/*
 * numberOfRowsInTableView: — row count for the mounts table.
 *
 * Inputs:
 *   tv — the table view
 *
 * Output: number of mount records.
 */
- (NSInteger)
numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)self.records.count;
}

/* ── NSTableViewDelegate ─────────────────────────────────────────────────── */

/*
 * tableView:viewForTableColumn:row: — returns a (reused or new) monospaced
 * text cell showing cell_text_for_col:record: for the given row and column.
 *
 * Inputs:
 *   tv  — the table view
 *   col — the column being displayed
 *   row — row index into self.records
 *
 * Output: configured NSTableCellView.
 */
- (NSView *)
tableView:(NSTableView *)tv
viewForTableColumn:(NSTableColumn *)col
              row:(NSInteger)row
{
    NSString *ident = col.identifier;

    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.font          = [NSFont monospacedSystemFontOfSize:11.0
                                                       weight:NSFontWeightRegular];
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    cell.textField.stringValue = [self cell_text_for_col:ident record:self.records[row]];
    return cell;
}

/*
 * tableView:sortDescriptorsDidChange: — re-sorts the records array and reloads.
 *
 * Inputs:
 *   tv  — the table view
 *   old — previous sort descriptors (unused)
 *
 * Output: none.
 */
- (void)
tableView:(NSTableView *)tv
sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old
{
    [self.records sortUsingDescriptors:tv.sortDescriptors];
    [tv reloadData];
}

/*
 * tableViewSelectionDidChange: — enables the Unmount button only when the
 * selected row's volume can be unmounted.
 *
 * Inputs:
 *   note — NSTableViewSelectionDidChangeNotification
 *
 * Output: none.
 */
- (void)
tableViewSelectionDidChange:(NSNotification *)note
{
    NSInteger row = self.table.selectedRow;
    BOOL can_unmount = NO;
    if (row >= 0 && row < (NSInteger)self.records.count) {
        can_unmount = self.records[row].can_unmount;
    }
    self.unmount_btn.enabled = can_unmount;
}

@end
