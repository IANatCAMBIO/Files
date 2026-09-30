#import "sidebar.h"
#import "volume_manager.h"
#import <objc/runtime.h>

/* ── FilesSidebarItem ────────────────────────────────────────────────── */

@implementation FilesSidebarItem
@end

/* ── FilesSidebarSection ─────────────────────────────────────────────── */

@implementation FilesSidebarSection

- (instancetype)
init
{
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
    }
    return self;
}

@end

/* ── Sidebar cell with optional eject button ─────────────────────────── */

/*
 * FilesSidebarCellView — NSTableCellView subclass that adds an eject button
 * for ejectable volumes.
 */
@interface FilesSidebarCellView : NSTableCellView
@property (nonatomic, strong) NSButton *eject_button;
@end

@implementation FilesSidebarCellView

/*
 * init_with_frame: — builds the icon, label, and (hidden) eject button.
 *
 * Inputs:
 *   frame — initial frame rect
 *
 * Output: configured view.
 */
- (instancetype)
initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    /* Icon view */
    NSImageView *iv    = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 2, 16, 16)];
    iv.imageScaling    = NSImageScaleProportionallyUpOrDown;
    self.imageView     = iv;
    [self addSubview:iv];

    /* Label */
    NSTextField *tf    = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 1, frame.size.width - 60, 18)];
    tf.editable        = NO;
    tf.bordered        = NO;
    tf.drawsBackground = NO;
    tf.font            = [NSFont systemFontOfSize:12.0];
    tf.lineBreakMode   = NSLineBreakByTruncatingTail;
    self.textField     = tf;
    [self addSubview:tf];

    /* Eject button */
    NSButton *eb = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 24, 1, 20, 18)];
    [eb setButtonType:NSButtonTypeMomentaryLight];
    eb.bordered    = NO;
    eb.title       = @"";
    if (@available(macOS 11.0, *)) {
        eb.image   = [NSImage imageWithSystemSymbolName:@"eject"
                                  accessibilityDescription:@"Eject"];
    } else {
        eb.image   = [NSImage imageNamed:NSImageNameRemoveTemplate];
    }
    eb.imageScaling  = NSImageScaleProportionallyDown;
    eb.hidden        = YES;
    eb.autoresizingMask = NSViewMinXMargin;
    self.eject_button   = eb;
    [self addSubview:eb];

    tf.autoresizingMask = NSViewWidthSizable;
    return self;
}

- (void)
resizeSubviewsWithOldSize:(NSSize)old_size
{
    [super resizeSubviewsWithOldSize:old_size];
    CGFloat w = self.bounds.size.width;
    self.textField.frame  = NSMakeRect(24, 1, w - 60, 18);
    self.eject_button.frame = NSMakeRect(w - 24, 1, 20, 18);
}

@end

/* ── FilesSidebar ────────────────────────────────────────────────────── */

@interface FilesSidebar () <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (nonatomic, strong) FilesSidebarSection *devices_section;
@property (nonatomic, strong) NSArray<FilesSidebarSection *> *sections;

@end

@implementation FilesSidebar

/*
 * setup — builds the favourites and devices sections, wires up the outline
 * view, and starts volume-change observation.
 */
- (void)
setup
{
    /* Devices only — favourites are shown in the bookmarks bar */
    self.devices_section       = [[FilesSidebarSection alloc] init];
    self.devices_section.title = @"Devices";

    self.sections = @[self.devices_section];

    /* Outline view config */
    self.outline_view.dataSource        = self;
    self.outline_view.delegate          = self;
    self.outline_view.headerView        = nil;
    self.outline_view.indentationPerLevel = 0.0;
    self.outline_view.rowHeight         = 22.0;
    self.outline_view.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
    [self.outline_view setFloatsGroupRows:YES];

    [self reload_volumes];
    [self.outline_view reloadData];
    [self.outline_view expandItem:nil expandChildren:YES];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(volumes_changed:)
               name:FilesVolumesChangedNotification
             object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/*
 * reload_volumes — repopulates the Devices section from FilesVolumeManager.
 */
- (void)
reload_volumes
{
    [self.devices_section.items removeAllObjects];
    FilesVolumeManager *vm = FilesVolumeManager.shared;
    for (NSURL *vol in vm.mounted_volumes) {
        FilesSidebarItem *item = [[FilesSidebarItem alloc] init];
        item.name      = [vm display_name_for_volume:vol];
        item.url       = vol;
        item.is_volume = YES;
        item.can_eject = [vm can_eject_volume:vol];
        [self.devices_section.items addObject:item];
    }
}

/*
 * volumes_changed: — notification handler; reloads the devices section.
 *
 * Inputs:
 *   note — FilesVolumesChangedNotification
 */
- (void)
volumes_changed:(NSNotification *)note
{
    [self reload_volumes];
    [self.outline_view reloadData];
    [self.outline_view expandItem:nil expandChildren:YES];
}

/*
 * select_url: — selects the sidebar row whose URL matches url.
 *
 * Inputs:
 *   url — URL to highlight
 */
- (void)
select_url:(NSURL *)url
{
    for (FilesSidebarSection *sec in self.sections) {
        for (FilesSidebarItem *item in sec.items) {
            if ([item.url.path isEqualToString:url.path]) {
                NSInteger row = [self.outline_view rowForItem:item];
                if (row >= 0) {
                    [self.outline_view selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                  byExtendingSelection:NO];
                }
                return;
            }
        }
    }
}

/* ── NSOutlineViewDataSource ─────────────────────────────────────────── */

- (NSInteger)
outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item
{
    if (item == nil) {
        return (NSInteger)self.sections.count;
    }
    if ([item isKindOfClass:FilesSidebarSection.class]) {
        return (NSInteger)((FilesSidebarSection *)item).items.count;
    }
    return 0;
}

- (id)
outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item
{
    if (item == nil) {
        return self.sections[index];
    }
    return ((FilesSidebarSection *)item).items[index];
}

- (BOOL)
outlineView:(NSOutlineView *)ov isItemExpandable:(id)item
{
    return [item isKindOfClass:FilesSidebarSection.class];
}

/* ── NSOutlineViewDelegate ───────────────────────────────────────────── */

- (BOOL)
outlineView:(NSOutlineView *)ov isGroupItem:(id)item
{
    return [item isKindOfClass:FilesSidebarSection.class];
}

- (BOOL)
outlineView:(NSOutlineView *)ov shouldSelectItem:(id)item
{
    return [item isKindOfClass:FilesSidebarItem.class];
}

- (NSView *)
outlineView:(NSOutlineView *)ov
 viewForTableColumn:(NSTableColumn *)col
               item:(id)item
{
    if ([item isKindOfClass:FilesSidebarSection.class]) {
        NSTableCellView *cell =
            [ov makeViewWithIdentifier:@"HeaderCell" owner:nil];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 180, 22)];
            NSTextField *tf    = [[NSTextField alloc] initWithFrame:NSMakeRect(4, 2, 176, 18)];
            tf.editable        = NO;
            tf.bordered        = NO;
            tf.drawsBackground = NO;
            tf.font            = [NSFont boldSystemFontOfSize:11.0];
            tf.textColor       = NSColor.secondaryLabelColor;
            cell.textField     = tf;
            [cell addSubview:tf];
            cell.identifier    = @"HeaderCell";
        }
        cell.textField.stringValue = ((FilesSidebarSection *)item).title.uppercaseString;
        return cell;
    }

    FilesSidebarItem *si = (FilesSidebarItem *)item;
    FilesSidebarCellView *cell =
        [ov makeViewWithIdentifier:@"SidebarCell" owner:nil];
    if (!cell) {
        cell            = [[FilesSidebarCellView alloc] initWithFrame:NSMakeRect(0, 0, 180, 22)];
        cell.identifier = @"SidebarCell";
    }

    cell.textField.stringValue = si.name;
    NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:si.url.path];
    icon.size     = NSMakeSize(16, 16);
    cell.imageView.image = icon;
    cell.eject_button.hidden   = !si.can_eject;

    if (si.can_eject) {
        cell.eject_button.target = self;
        /* Attach the item URL via associated object so the action knows which volume. */
        objc_setAssociatedObject(cell.eject_button, "vol_url", si.url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.eject_button.action = @selector(eject_button_clicked:);
    }

    return cell;
}

- (CGFloat)
outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item
{
    return 22.0;
}

/*
 * outlineViewSelectionDidChange: — calls selection_handler with the URL of
 * the selected item.
 *
 * Inputs:
 *   note — NSOutlineViewSelectionDidChangeNotification
 */
- (void)
outlineViewSelectionDidChange:(NSNotification *)note
{
    NSInteger row = self.outline_view.selectedRow;
    if (row < 0) return;
    id item = [self.outline_view itemAtRow:row];
    if (![item isKindOfClass:FilesSidebarItem.class]) return;
    FilesSidebarItem *si = (FilesSidebarItem *)item;
    if (self.selection_handler) {
        self.selection_handler(si.url);
    }
}

/*
 * eject_button_clicked: — ejects the volume associated with the sender button.
 *
 * Inputs:
 *   sender — eject NSButton (has vol_url associated object)
 */
- (void)
eject_button_clicked:(NSButton *)sender
{
    NSURL *vol = objc_getAssociatedObject(sender, "vol_url");
    if (!vol) return;
    [FilesVolumeManager.shared eject_volume:vol completion:^(NSError *err) {
        if (err) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText     = @"Could not eject volume";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
        }
    }];
}

@end
