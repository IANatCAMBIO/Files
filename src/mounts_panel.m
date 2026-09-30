#import "mounts_panel.h"
#import "volume_manager.h"
#import <sys/mount.h>

/* Column identifiers */
static NSString * const kColDevice    = @"device";
static NSString * const kColMount     = @"mount";
static NSString * const kColType      = @"type";
static NSString * const kColOptions   = @"options";
static NSString * const kColRemovable = @"removable";
static NSString * const kColTotal     = @"total";
static NSString * const kColFree      = @"free";

/* ── FilesMountRecord ─────────────────────────────────────────────────────── */

/*
 * FilesMountRecord — data model for one mounted filesystem.
 */
@interface FilesMountRecord : NSObject
@property (nonatomic, copy)   NSString *device;
@property (nonatomic, copy)   NSString *mount_point;
@property (nonatomic, copy)   NSString *fs_type;
@property (nonatomic, copy)   NSString *options;
@property (nonatomic)         BOOL      ejectable;
@property (nonatomic, strong) NSURL    *volume_url; /* nil if not a known volume */
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

/* ── FilesMountsPanel ─────────────────────────────────────────────────────── */

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

@interface FilesMountsPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView                     *table;
@property (nonatomic, strong) NSMutableArray<FilesMountRecord *> *records;
@property (nonatomic, strong) NSButton                        *unmount_btn;
@end

@implementation FilesMountsPanel

static FilesMountsPanel *g_shared = nil;

/*
 * shared — returns the process-wide singleton.
 *
 * Output: FilesMountsPanel singleton.
 */
+ (instancetype)
shared
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_shared = [[FilesMountsPanel alloc] init];
    });
    return g_shared;
}

- (instancetype)initWithCoder:(NSCoder *)c { (void)c; return [self init]; }

/*
 * init — builds the mounts panel window and table.
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

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/* ── UI construction ─────────────────────────────────────────────────────── */

/*
 * build_table — creates the NSScrollView + NSTableView with data columns.
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
    if (@available(macOS 11.0, *)) {
        self.table.style = NSTableViewStylePlain;
    }
    self.table.dataSource                     = self;
    self.table.delegate                       = self;
    self.table.rowHeight                      = 22.0;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.columnAutoresizingStyle        = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.table.allowsEmptySelection           = YES;

    [self.table addTableColumn:make_col(kColDevice,    @"Device",      160, YES)];
    [self.table addTableColumn:make_col(kColMount,     @"Mount Point", 140, YES)];
    [self.table addTableColumn:make_col(kColType,      @"Type",         60, YES)];
    [self.table addTableColumn:make_col(kColOptions,   @"Options",     160, YES)];
    [self.table addTableColumn:make_col(kColTotal,     @"Total",        80, YES)];
    [self.table addTableColumn:make_col(kColFree,      @"Free",         80, YES)];
    [self.table addTableColumn:make_col(kColRemovable, @"Removable",    72,  YES)];

    /* Sort descriptors — clicking a header sorts that column ascending/descending. */
    [self.table tableColumnWithIdentifier:kColDevice].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"device"      ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:kColMount].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"mount_point" ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:kColType].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"fs_type"     ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:kColOptions].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"options"     ascending:YES selector:@selector(localizedCompare:)];
    [self.table tableColumnWithIdentifier:kColTotal].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"total_bytes" ascending:YES];
    [self.table tableColumnWithIdentifier:kColFree].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"free_bytes"  ascending:YES];
    [self.table tableColumnWithIdentifier:kColRemovable].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"ejectable"   ascending:YES];

    scroll.documentView = self.table;
    [content addSubview:scroll];
}

/*
 * build_toolbar_row — adds Unmount and Refresh buttons at the bottom-right.
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

    /* Legend: coloured swatch + label on the left. */
    NSView *swatch = [[NSView alloc] initWithFrame:NSMakeRect(10, 11, 12, 12)];
    swatch.wantsLayer              = YES;
    swatch.layer.backgroundColor   = [NSColor colorWithRed:1.0
                                                     green:0.3
                                                      blue:0.2
                                                     alpha:0.30].CGColor;
    swatch.layer.borderColor       = [NSColor colorWithRed:0.8
                                                     green:0.2
                                                      blue:0.1
                                                     alpha:0.50].CGColor;
    swatch.layer.borderWidth       = 1.0;
    swatch.layer.cornerRadius      = 2.0;
    swatch.autoresizingMask        = NSViewMaxXMargin;
    [content addSubview:swatch];

    NSTextField *legend = [NSTextField labelWithString:@"< 10% free space"];
    legend.font          = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    legend.textColor     = NSColor.secondaryLabelColor;
    legend.frame         = NSMakeRect(27, 8, 140, 16);
    legend.autoresizingMask = NSViewMaxXMargin;
    [content addSubview:legend];
}

/* ── Data ────────────────────────────────────────────────────────────────── */

/*
 * load_mounts — reads the kernel mount table via getmntinfo and cross-references
 * FilesVolumeManager for ejectability.
 */
- (void)
load_mounts
{
    [self.records removeAllObjects];

    struct statfs *buf = NULL;
    int count = getmntinfo(&buf, MNT_NOWAIT);
    if (count <= 0) return;

    FilesVolumeManager *vm = FilesVolumeManager.shared;
    NSArray<NSURL *> *volumes = [vm mounted_volumes];

    for (int i = 0; i < count; i++) {
        FilesMountRecord *rec = [[FilesMountRecord alloc] init];
        rec.device      = [NSString stringWithUTF8String:buf[i].f_mntfromname];
        rec.mount_point = [NSString stringWithUTF8String:buf[i].f_mntonname];
        rec.fs_type     = [NSString stringWithUTF8String:buf[i].f_fstypename];
        rec.options     = format_mount_flags((uint32_t)buf[i].f_flags);

        rec.total_bytes = (int64_t)buf[i].f_blocks * (int64_t)buf[i].f_bsize;
        rec.free_bytes  = (int64_t)buf[i].f_bavail * (int64_t)buf[i].f_bsize;

        rec.ejectable  = NO;
        rec.volume_url = nil;
        for (NSURL *vol in volumes) {
            if ([vol.path isEqualToString:rec.mount_point]) {
                rec.ejectable  = [vm can_eject_volume:vol];
                rec.volume_url = vol;
                break;
            }
        }

        [self.records addObject:rec];
    }
}

/*
 * cell_text_for_col:record: — returns the display string for one column/record
 * pair, matching the logic in tableView:viewForTableColumn:row:.
 *
 * Inputs:
 *   ident — column identifier
 *   rec   — mount record
 *   fmt   — byte-count formatter (caller owns)
 *
 * Output: display string, never nil.
 */
- (NSString *)
cell_text_for_col:(NSString *)ident
           record:(FilesMountRecord *)rec
        formatter:(NSByteCountFormatter *)fmt
{
    if ([ident isEqualToString:kColDevice])    return rec.device;
    if ([ident isEqualToString:kColMount])     return rec.mount_point;
    if ([ident isEqualToString:kColType])      return rec.fs_type;
    if ([ident isEqualToString:kColOptions])   return rec.options;
    if ([ident isEqualToString:kColTotal])
        return rec.total_bytes > 0 ? [fmt stringFromByteCount:rec.total_bytes] : @"—";
    if ([ident isEqualToString:kColFree])
        return rec.total_bytes > 0 ? [fmt stringFromByteCount:rec.free_bytes] : @"—";
    if ([ident isEqualToString:kColRemovable]) return rec.ejectable ? @"Yes" : @"No";
    return @"";
}

/*
 * fit_columns — sizes each column to the maximum of its header title and its
 * widest data cell, then returns the total column width.
 *
 * Output: sum of all column widths (excluding intercell spacing).
 */
- (CGFloat)
fit_columns
{
    NSDictionary *cell_attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.0
                                                        weight:NSFontWeightRegular]
    };
    NSDictionary *head_attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize]
    };

    static const CGFloat kCellPad = 16.0; /* left + right cell inset */
    static const CGFloat kHeadPad = 20.0; /* extra for sort arrow */

    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;

    CGFloat total = 0.0;

    for (NSTableColumn *col in self.table.tableColumns) {
        CGFloat w = ceil([col.title sizeWithAttributes:head_attrs].width) + kHeadPad;

        for (FilesMountRecord *rec in self.records) {
            NSString *text = [self cell_text_for_col:col.identifier record:rec formatter:fmt];
            CGFloat tw = ceil([text sizeWithAttributes:cell_attrs].width) + kCellPad;
            if (tw > w) w = tw;
        }

        col.minWidth = 40.0;
        col.width    = w;
        total       += w;
    }

    return total;
}

/*
 * resize_to_fit — sizes columns to content, then resizes the window to show all
 * rows and all columns without scrolling, clamped to 90% of visible screen area.
 */
- (void)
resize_to_fit
{
    CGFloat col_total  = [self fit_columns];
    CGFloat spacing    = self.table.intercellSpacing.width
                         * (CGFloat)(self.table.tableColumns.count - 1);
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
 * show_panel — loads mount data, sizes the window to fit, and brings it forward.
 */
- (void)
show_panel
{
    [self load_mounts];
    [self.table reloadData];
    [self resize_to_fit];
    [self.table scrollRowToVisible:0];
    [self.table deselectAll:nil];
    self.unmount_btn.enabled = NO;
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

/*
 * refresh_clicked: — reloads the mount table.
 *
 * Inputs:
 *   sender — Refresh button
 */
- (IBAction)
refresh_clicked:(id)sender
{
    [self load_mounts];
    [self.table reloadData];
    [self fit_columns];
    [self.table deselectAll:nil];
    self.unmount_btn.enabled = NO;
}

/*
 * unmount_clicked: — ejects the volume for the selected row.
 *
 * Inputs:
 *   sender — Unmount button
 */
- (IBAction)
unmount_clicked:(id)sender
{
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.records.count) return;
    FilesMountRecord *rec = self.records[row];
    if (!rec.ejectable || !rec.volume_url) return;

    [FilesVolumeManager.shared eject_volume:rec.volume_url completion:^(NSError *err) {
        if (err) {
            NSAlert *alert       = [[NSAlert alloc] init];
            alert.messageText    = @"Could not unmount volume";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
        } else {
            [self load_mounts];
            [self.table reloadData];
            [self.table deselectAll:nil];
            self.unmount_btn.enabled = NO;
        }
    }];
}

/*
 * volumes_changed: — notification handler; refreshes when volumes mount/unmount.
 *
 * Inputs:
 *   note — FilesVolumesChangedNotification
 */
- (void)
volumes_changed:(NSNotification *)note
{
    if (self.window.isVisible) {
        [self load_mounts];
        [self.table reloadData];
        [self.table deselectAll:nil];
        self.unmount_btn.enabled = NO;
    }
}

/* ── NSTableViewDataSource ────────────────────────────────────────────────── */

- (NSInteger)
numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)self.records.count;
}

/* ── NSTableViewDelegate ─────────────────────────────────────────────────── */

- (NSView *)
tableView:(NSTableView *)tv
viewForTableColumn:(NSTableColumn *)col
              row:(NSInteger)row
{
    FilesMountRecord *rec   = self.records[row];
    NSString         *ident = col.identifier;

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

    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;

    NSString *value = @"";
    if ([ident isEqualToString:kColDevice])        value = rec.device;
    else if ([ident isEqualToString:kColMount])    value = rec.mount_point;
    else if ([ident isEqualToString:kColType])     value = rec.fs_type;
    else if ([ident isEqualToString:kColOptions])  value = rec.options;
    else if ([ident isEqualToString:kColTotal])
        value = rec.total_bytes > 0 ? [fmt stringFromByteCount:rec.total_bytes] : @"—";
    else if ([ident isEqualToString:kColFree])
        value = rec.total_bytes > 0 ? [fmt stringFromByteCount:rec.free_bytes]  : @"—";
    else if ([ident isEqualToString:kColRemovable]) value = rec.ejectable ? @"Yes" : @"No";

    cell.textField.stringValue = value;
    return cell;
}

/*
 * tableView:sortDescriptorsDidChange: — re-sorts the records array and reloads.
 *
 * Inputs:
 *   tv  — the table view
 *   old — previous sort descriptors (unused)
 */
- (void)
tableView:(NSTableView *)tv
sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old
{
    [self.records sortUsingDescriptors:tv.sortDescriptors];
    [tv reloadData];
}

/*
 * tableView:didAddRowView:forRow: — tints rows with less than 10% free space.
 *
 * Inputs:
 *   tv      — table view
 *   rowView — the row view just added
 *   row     — row index
 */
- (void)
tableView:(NSTableView *)tv
didAddRowView:(NSTableRowView *)rowView
   forRow:(NSInteger)row
{
    (void)tv;
    if (row < 0 || row >= (NSInteger)self.records.count) return;
    FilesMountRecord *rec = self.records[row];
    BOOL low = rec.total_bytes > 0 &&
               (double)rec.free_bytes / (double)rec.total_bytes < 0.10;
    /* nil restores the default alternating-row background. */
    rowView.backgroundColor = low
        ? [NSColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:0.10]
        : nil;
}

/*
 * tableViewSelectionDidChange: — enables the Unmount button only when the
 * selected row represents a removable (ejectable) volume.
 *
 * Inputs:
 *   note — NSTableViewSelectionDidChangeNotification
 */
- (void)
tableViewSelectionDidChange:(NSNotification *)note
{
    NSInteger row = self.table.selectedRow;
    BOOL can_unmount = NO;
    if (row >= 0 && row < (NSInteger)self.records.count) {
        can_unmount = self.records[row].ejectable;
    }
    self.unmount_btn.enabled = can_unmount;
}

@end
