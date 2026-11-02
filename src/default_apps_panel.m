#import "default_apps_panel.h"
#import "shared_ui.h"
#import "shared_tool_panel.h"
#import "util.h"

/* Column identifiers */
static NSString * const col_extensions = @"extensions";
static NSString * const col_kind       = @"kind";
static NSString * const col_app        = @"app";
static NSString * const col_identifier = @"identifier";

static const CGFloat icon_edge   = 16.0;   /* a row's type and app icons          */
static const CGFloat row_h       = 22.0;   /* a row, as All Mounts' rows          */
static const CGFloat bottom_h    = 28.0;   /* the search field and Change… row    */
static const CGFloat bottom_pad  = 8.0;    /* that row, from the window's edges   */
static const CGFloat chooser_w   = 300.0;  /* the chooser's pop-up button         */
static const CGFloat window_w    = 880.0;  /* the window, until the user sizes it */
static const CGFloat window_h    = 560.0;
static const NSUInteger scan_depth = 4;    /* folders descended into under /Applications */

/* ── files_type_record ────────────────────────────────────────────────────── */

/*
 * files_type_record — one row: a content type, the extensions it covers,
 * and the application macOS currently opens them with. Everything a cell
 * draws is read once, with the scan, on a background queue; drawing a row
 * then touches no file system.
 */
@interface files_type_record : NSObject
@property (nonatomic, copy)   NSString *identifier;  /* the UTI, e.g. public.jpeg   */
@property (nonatomic, copy)   NSString *extensions;  /* ".jpeg, .jpg, .jpe"         */
@property (nonatomic, copy)   NSString *kind;        /* localized description, "—"  */
@property (nonatomic, copy)   NSString *app_name;    /* "Preview", or "None"        */
@property (nonatomic, strong) NSURL    *app_url;     /* nil when nothing opens it   */
@property (nonatomic, strong) NSImage  *type_icon;
@property (nonatomic, strong) NSImage  *app_icon;    /* nil when nothing opens it   */
@end

@implementation files_type_record
@end

/* ── Reading the types ────────────────────────────────────────────────────── */

/*
 * add_strings — adds an Info.plist value that is either a string or an
 * array of strings to a set, skipping anything else (a malformed plist
 * must not bring the window down) and the "*" wildcard some applications
 * list as an extension, which stands for no type of its own.
 *
 * Inputs:
 *   value     — the plist value; any class, may be nil
 *   into      — the set to add to
 *   lowercase — YES for filename extensions, which are matched in lower
 *               case; NO for type identifiers, which are used as written
 */
static void
add_strings(id value, NSMutableSet<NSString *> *into, BOOL lowercase)
{
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = lowercase ? [(NSString *)value lowercaseString] : value;
        if (text.length > 0 && ![text isEqualToString:@"*"]) [into addObject:text];
        return;
    }
    if (![value isKindOfClass:NSArray.class]) return;
    for (id item in (NSArray *)value) add_strings(item, into, lowercase);
}

/*
 * collect_type_tags — reads one bundle's Info.plist and collects the file
 * types it has to do with: the content types and extensions of the
 * documents it opens (CFBundleDocumentTypes), and the types it declares
 * for the system, its own or another's (UTExportedTypeDeclarations,
 * UTImportedTypeDeclarations), with the extensions those name.
 *
 * Inputs:
 *   bundle      — bundle URL (an .app, or CoreTypes.bundle)
 *   identifiers — set collecting type identifiers
 *   extensions  — set collecting filename extensions, lower case
 */
static void
collect_type_tags(NSURL *bundle, NSMutableSet<NSString *> *identifiers,
                  NSMutableSet<NSString *> *extensions)
{
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
                             [bundle URLByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![info isKindOfClass:NSDictionary.class]) return;

    id docs = info[@"CFBundleDocumentTypes"];
    if ([docs isKindOfClass:NSArray.class]) {
        for (id doc in (NSArray *)docs) {
            if (![doc isKindOfClass:NSDictionary.class]) continue;
            add_strings(((NSDictionary *)doc)[@"LSItemContentTypes"],     identifiers, NO);
            add_strings(((NSDictionary *)doc)[@"CFBundleTypeExtensions"], extensions,  YES);
        }
    }

    for (NSString *key in @[@"UTExportedTypeDeclarations", @"UTImportedTypeDeclarations"]) {
        id declarations = info[key];
        if (![declarations isKindOfClass:NSArray.class]) continue;
        for (id declaration in (NSArray *)declarations) {
            if (![declaration isKindOfClass:NSDictionary.class]) continue;
            add_strings(((NSDictionary *)declaration)[@"UTTypeIdentifier"], identifiers, NO);
            id tags = ((NSDictionary *)declaration)[@"UTTypeTagSpecification"];
            if ([tags isKindOfClass:NSDictionary.class]) {
                add_strings(((NSDictionary *)tags)[@"public.filename-extension"],
                            extensions, YES);
            }
        }
    }
}

/*
 * type_source_bundles — the bundles whose Info.plists say which file types
 * this Mac knows: every application bundle in the folders applications are
 * installed in, plus CoreTypes.bundle, which is where macOS declares the
 * types no application owns (public.jpeg, public.plain-text and several
 * hundred more).
 *
 * An application folder is walked rather than listed, because installers
 * nest bundles (/Applications/Utilities, a vendor's own folder); the walk
 * stops at scan_depth and never enters a bundle it has found, so a deep
 * tree cannot make it run away.
 *
 * Output: bundle URLs, in no useful order.
 */
static NSArray<NSURL *> *
type_source_bundles(void)
{
    NSMutableArray<NSURL *> *bundles = [NSMutableArray array];
    NSArray<NSURL *> *roots = @[
        [NSURL fileURLWithPath:@"/Applications"                     isDirectory:YES],
        [NSURL fileURLWithPath:@"/System/Applications"              isDirectory:YES],
        [NSURL fileURLWithPath:@"/System/Library/CoreServices"      isDirectory:YES],
        [files_home_url() URLByAppendingPathComponent:@"Applications" isDirectory:YES],
    ];

    for (NSURL *root in roots) {
        NSDirectoryEnumerator<NSURL *> *walk =
            [NSFileManager.defaultManager enumeratorAtURL:root
                               includingPropertiesForKeys:nil
                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                             errorHandler:nil];
        for (NSURL *url in walk) {
            if ((NSUInteger)walk.level > scan_depth) {
                [walk skipDescendants];
                continue;
            }
            if ([url.pathExtension isEqualToString:@"app"]) {
                [bundles addObject:url];
                [walk skipDescendants];
            }
        }
    }

    [bundles addObject:[NSURL fileURLWithPath:@"/System/Library/CoreServices/CoreTypes.bundle"
                                  isDirectory:YES]];
    return bundles;
}

/*
 * claim_extension — adds the types a file carrying an extension can
 * actually turn out to be. There are two, because resolving an extension
 * depends on what the file is: a plain file's extension gives one type
 * (.app is com.apple.application-file), the same extension on a package
 * gives another (com.apple.application-bundle), and several types that
 * only ever appear as packages — .rtfd, .workflow, .photoslibrary — are
 * reachable no other way.
 *
 * Only a type a file really resolves to is added, which is what drops the
 * declarations nothing can reach: two installed applications may both
 * declare a type for .ada, but a .ada file gets exactly one of them, and
 * setting a default on the other would change nothing a user could see.
 *
 * An extension no declaration names at all is kept under the dynamic type
 * macOS makes for it (a "dyn." identifier), because LaunchServices still
 * records a default application against that.
 *
 * Inputs:
 *   extension — filename extension, lower case, without the dot
 *   by_id     — types collected so far, keyed by identifier; added to
 */
static void
claim_extension(NSString *extension, NSMutableDictionary<NSString *, UTType *> *by_id)
{
    UTType *resolved[2];  /* not an NSArray: either may be nil */
    resolved[0] = [UTType typeWithFilenameExtension:extension];
    resolved[1] = [UTType typeWithFilenameExtension:extension
                                   conformingToType:UTTypePackage];

    BOOL declared = NO;
    for (int i = 0; i < 2; i++) {
        if (resolved[i] == nil || resolved[i].isDynamic) continue;
        by_id[resolved[i].identifier] = resolved[i];
        declared = YES;
    }
    if (!declared && resolved[0] != nil) by_id[resolved[0].identifier] = resolved[0];
}

/*
 * files_default_app_types — the file types this Mac knows about.
 * Output is documented in default_apps_panel.h.
 */
NSArray<UTType *> *
files_default_app_types(void)
{
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    NSMutableSet<NSString *> *extensions  = [NSMutableSet set];
    for (NSURL *bundle in type_source_bundles()) {
        collect_type_tags(bundle, identifiers, extensions);
    }

    /* A type a bundle names by identifier alone reaches the list through
     * the extensions it covers, which is the only way a user can name it. */
    for (NSString *identifier in identifiers) {
        for (NSString *extension in
                 [UTType typeWithIdentifier:identifier].tags[UTTagClassFilenameExtension]) {
            [extensions addObject:extension.lowercaseString];
        }
    }

    NSMutableDictionary<NSString *, UTType *> *by_id = [NSMutableDictionary dictionary];
    for (NSString *extension in extensions) claim_extension(extension, by_id);
    return by_id.allValues;
}

/*
 * record_for_type — one row's worth of data for a type: the extensions it
 * covers, its kind, its icon, and the application macOS opens it with.
 * Reads the LaunchServices database and icons, so it belongs on a
 * background queue.
 *
 * Inputs:
 *   type — the content type
 *
 * Output: the record, never nil.
 */
static files_type_record *
record_for_type(UTType *type)
{
    files_type_record *rec = [[files_type_record alloc] init];
    rec.identifier = type.identifier;

    NSMutableArray<NSString *> *dotted = [NSMutableArray array];
    for (NSString *extension in type.tags[UTTagClassFilenameExtension]) {
        [dotted addObject:[@"." stringByAppendingString:extension]];
    }
    rec.extensions = [dotted componentsJoinedByString:@", "];

    /* A dynamic type — an extension no installed application declares a
     * type for — has no description of its own; the Type column's "dyn."
     * identifier says why. */
    rec.kind = type.localizedDescription ?: @"—";

    rec.type_icon      = [[NSWorkspace.sharedWorkspace iconForContentType:type] copy];
    rec.type_icon.size = NSMakeSize(icon_edge, icon_edge);

    rec.app_url  = [NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:type];
    rec.app_name = files_app_display_name(rec.app_url);
    rec.app_icon = rec.app_url ? files_icon_for_url(rec.app_url, icon_edge, YES) : nil;
    return rec;
}

/*
 * read_type_records — one record per type from files_default_app_types.
 * Reads Info.plists, the LaunchServices database and icons, so it runs on
 * a background queue.
 *
 * Inputs:
 *   extra — a type to list even if the scan did not find it (Get Info's
 *           "change" link on a file whose extension nothing declares);
 *           may be nil, and is ignored if the scan found it anyway
 *
 * Output: the records, sorted by extension so the list has an order before
 *         the table's sort descriptors are applied.
 */
static NSArray<files_type_record *> *
read_type_records(UTType *extra)
{
    NSArray<UTType *> *types = files_default_app_types();
    NSMutableArray<files_type_record *> *records =
        [NSMutableArray arrayWithCapacity:types.count + 1];
    BOOL has_extra = NO;

    for (UTType *type in types) {
        [records addObject:record_for_type(type)];
        if ([type.identifier isEqualToString:extra.identifier]) has_extra = YES;
    }
    if (extra && !has_extra) [records addObject:record_for_type(extra)];

    [records sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"extensions"
                                                                 ascending:YES
                                                                  selector:@selector(localizedStandardCompare:)]]];
    return records;
}

/*
 * type_phrase — how a record is named in a sentence: its extensions when
 * it has any (".jpeg, .jpg, .jpe"), else its kind, else its identifier.
 * Nearly every type has extensions — the list is built from them — but a
 * type reached through Get Info's "change" link need not: a file macOS
 * recognises no type for is public.data, which has none.
 *
 * Inputs:
 *   rec — the record
 *
 * Output: the phrase, never empty.
 */
static NSString *
type_phrase(files_type_record *rec)
{
    if (rec.extensions.length > 0)        return rec.extensions;
    if (![rec.kind isEqualToString:@"—"]) return rec.kind;
    return rec.identifier;
}

/*
 * record_matches — whether a record is one of those a filter string
 * leaves: a case-insensitive match anywhere in its extensions, kind,
 * application name or type identifier, so ".md", "markdown", "Preview"
 * and "public.jpeg" all find their rows.
 *
 * Inputs:
 *   rec   — the record
 *   query — the filter; empty or nil matches everything
 *
 * Output: YES if the record should be listed.
 */
static BOOL
record_matches(files_type_record *rec, NSString *query)
{
    if (query.length == 0) return YES;
    for (NSString *field in @[rec.extensions, rec.kind, rec.app_name, rec.identifier]) {
        if ([field rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

/* ── files_default_apps_panel ─────────────────────────────────────────────── */

@interface files_default_apps_panel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) SharedTable                        *table;
@property (nonatomic, copy)   NSArray<files_type_record *>       *all_records;  /* every type  */
@property (nonatomic, strong) NSMutableArray<files_type_record *> *records;     /* those shown */
@property (nonatomic, strong) NSSearchField                      *search;
@property (nonatomic, strong) NSTextField                        *count_label;
@property (nonatomic, strong) NSButton                           *change_btn;
@property (nonatomic, assign) NSUInteger                          load_generation;
@property (nonatomic, strong) UTType                             *pending_type;   /* to select once loaded */
@end

@implementation files_default_apps_panel

/*
 * shared — the process-wide singleton, created on first call.
 *
 * Output: the panel, never nil.
 */
+ (instancetype)
shared
{
    static files_default_apps_panel *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[files_default_apps_panel alloc] init];
    });
    return instance;
}

/*
 * init — builds the window, its table and the row under it. An ordinary
 * titled window, as All Mounts is: the list is something to read and work
 * in alongside a browser window, so it keeps a full title bar and
 * minimises like any other window.
 *
 * Output: self or nil.
 */
- (instancetype)
init
{
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, window_w, window_h)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title   = @"Default Apps";
    window.minSize = NSMakeSize(560, 240);
    [window center];

    self = [super initWithWindow:window];
    if (!self) return nil;

    self.records = [NSMutableArray array];
    [self build_content];
    return self;
}

/*
 * build_content — the table in its scroll view, with the search field, the
 * count of listed types and the Change… button in a row beneath it.
 *
 * Output: none; sets table, search, count_label and change_btn.
 */
- (void)
build_content
{
    NSView *content = self.window.contentView;

    self.table = [[SharedTable alloc] initWithFrame:NSZeroRect];
    self.table.style                              = NSTableViewStylePlain;
    self.table.dataSource                         = self;
    self.table.delegate                           = self;
    self.table.rowHeight                          = row_h;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.allowsEmptySelection               = YES;
    self.table.allowsMultipleSelection            = NO;
    self.table.columnAutoresizingStyle            = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.table.target                             = self;
    self.table.doubleAction                       = @selector(row_activated:);

    /* Extensions is the widest it is because a type that covers several
     * (.markdown, .markd, .mdown, .md) is the reason a row is a type and
     * not an extension: seeing them together is the point. Anything that
     * still does not fit is in the cell's tooltip. */
    [self.table addTableColumn:files_table_column(col_extensions, @"Extensions", 210, YES)];
    [self.table addTableColumn:files_table_column(col_kind,       @"Kind",       200, YES)];
    [self.table addTableColumn:files_table_column(col_app,        @"Opens With", 170, YES)];
    [self.table addTableColumn:files_table_column(col_identifier, @"Type",       240, YES)];

    [self.table tableColumnWithIdentifier:col_extensions].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"extensions" ascending:YES
                                       selector:@selector(localizedStandardCompare:)];
    [self.table tableColumnWithIdentifier:col_kind].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"kind" ascending:YES
                                       selector:@selector(localizedStandardCompare:)];
    [self.table tableColumnWithIdentifier:col_app].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"app_name" ascending:YES
                                       selector:@selector(localizedStandardCompare:)];
    [self.table tableColumnWithIdentifier:col_identifier].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"identifier" ascending:YES
                                       selector:@selector(localizedStandardCompare:)];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller   = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers    = YES;
    scroll.documentView          = self.table;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scroll];

    self.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.search.placeholderString = @"Extension, kind or app";
    self.search.font              = [NSFont systemFontOfSize:shared_look_ui_font];
    self.search.controlSize       = NSControlSizeSmall;
    self.search.target            = self;
    self.search.action            = @selector(filter_changed:);
    self.search.translatesAutoresizingMaskIntoConstraints = NO;
    [self.search.widthAnchor constraintEqualToConstant:shared_look_toolbar_search_w].active = YES;

    self.count_label           = [NSTextField labelWithString:@""];
    self.count_label.font      = [NSFont systemFontOfSize:shared_look_ui_font];
    self.count_label.textColor = NSColor.secondaryLabelColor;

    self.change_btn = [NSButton buttonWithTitle:@"Change…"
                                         target:self
                                         action:@selector(change_clicked:)];
    self.change_btn.bezelStyle  = NSBezelStyleRounded;
    self.change_btn.controlSize = NSControlSizeSmall;
    self.change_btn.font        = [NSFont systemFontOfSize:shared_look_ui_font];
    self.change_btn.enabled     = NO;
    self.change_btn.toolTip     = @"Choose the application that opens the selected file type";

    NSStackView *row = [NSStackView stackViewWithViews:@[self.search, self.count_label,
                                                         shared_ui_spacer(), self.change_btn]];
    row.spacing   = bottom_pad;
    row.alignment = NSLayoutAttributeCenterY;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor      constraintEqualToAnchor:content.topAnchor],
        [scroll.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor   constraintEqualToAnchor:row.topAnchor constant:-bottom_pad],

        [row.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor  constant:bottom_pad],
        [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-bottom_pad],
        [row.bottomAnchor   constraintEqualToAnchor:content.bottomAnchor   constant:-bottom_pad],
        [row.heightAnchor   constraintEqualToConstant:bottom_h],
    ]];

    /* Last: setting the sort order calls back into show_records, which
     * reads the controls above. */
    self.table.sortDescriptors =
        @[[self.table tableColumnWithIdentifier:col_extensions].sortDescriptorPrototype];
}

/* ── Data ────────────────────────────────────────────────────────────────── */

/*
 * show_records — fills the table from all_records with the types the
 * search field leaves, in the table's sort order, and updates the count
 * and the Change… button.
 */
- (void)
show_records
{
    NSString *selected = self.table.selectedRow >= 0 &&
                         self.table.selectedRow < (NSInteger)self.records.count
                       ? self.records[self.table.selectedRow].identifier : nil;

    NSString *query = self.search.stringValue;
    self.records = [NSMutableArray array];
    for (files_type_record *rec in self.all_records) {
        if (record_matches(rec, query)) [self.records addObject:rec];
    }
    [self.records sortUsingDescriptors:self.table.sortDescriptors];
    [self.table reloadData];

    /* Keep the row the user had selected on it, so setting a default (which
     * reloads) does not move the selection out from under them. */
    if (![self select_identifier:selected]) [self.table deselectAll:nil];

    self.count_label.stringValue = self.records.count == self.all_records.count
        ? [NSString stringWithFormat:@"%lu file types", (unsigned long)self.all_records.count]
        : [NSString stringWithFormat:@"%lu of %lu file types",
           (unsigned long)self.records.count, (unsigned long)self.all_records.count];
    self.change_btn.enabled = self.table.selectedRow >= 0;
}

/*
 * select_identifier: — selects the listed row for a type and scrolls it
 * into view. The one place a row is found by its type, for both the
 * selection a reload keeps and the row Get Info's "change" link asks for.
 *
 * Inputs:
 *   identifier — the type identifier; nil or unlisted selects nothing
 *
 * Output: YES if the row was found and selected.
 */
- (BOOL)
select_identifier:(NSString *)identifier
{
    if (identifier == nil) return NO;
    for (NSUInteger i = 0; i < self.records.count; i++) {
        if (![self.records[i].identifier isEqualToString:identifier]) continue;
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        [self.table scrollRowToVisible:(NSInteger)i];
        return YES;
    }
    return NO;
}

/*
 * reload_table_then: — the one reload path: reads the types on a
 * background queue, then shows them on the main queue. A newer reload
 * supersedes an older one, so a reload after a default was set cannot be
 * overtaken by the one that opened the window.
 *
 * Inputs:
 *   done — called on the main queue once the table shows the new records;
 *          not called if superseded. May be nil.
 */
- (void)
reload_table_then:(void (^)(void))done
{
    NSUInteger generation = ++self.load_generation;
    /* Read on the main queue and cleared here: the scan runs off it, and a
     * later reload (after a default is set) must not select the row again. */
    UTType *wanted    = self.pending_type;
    self.pending_type = nil;

    __weak files_default_apps_panel *weak_self = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<files_type_record *> *records = read_type_records(wanted);
        dispatch_async(dispatch_get_main_queue(), ^{
            files_default_apps_panel *panel = weak_self;
            if (!panel || generation != panel.load_generation) return;
            panel.all_records = records;
            [panel show_records];
            if (wanted) {
                [panel select_identifier:wanted.identifier];
                panel.change_btn.enabled = panel.table.selectedRow >= 0;
            }
            if (done) done();
        });
    });
}

/* ── Actions ─────────────────────────────────────────────────────────────── */

/*
 * show_panel — see default_apps_panel.h.
 */
- (void)
show_panel
{
    [self showWindow:nil];
    self.count_label.stringValue = @"Reading file types…";
    [self reload_table_then:nil];
}

/*
 * show_panel_for_type: — see default_apps_panel.h.
 */
- (void)
show_panel_for_type:(UTType *)type
{
    self.pending_type      = type;
    self.search.stringValue = @"";   /* a filter in force would hide the row */
    [self show_panel];
}

/*
 * filter_changed: — the search field: lists the types it leaves.
 *
 * Inputs:
 *   sender — the search field (unused)
 */
- (void)
filter_changed:(id)sender
{
    [self show_records];
}

/*
 * row_activated: — a double-click or Return on a row: opens the chooser
 * for it, which is the gesture the window is for.
 *
 * Inputs:
 *   sender — the table (unused)
 */
- (void)
row_activated:(id)sender
{
    NSIndexSet *rows = shared_ui_activated_rows(self.table);
    if (rows.firstIndex == NSNotFound || rows.firstIndex >= self.records.count) return;
    [self choose_app_for:self.records[rows.firstIndex]];
}

/*
 * change_clicked: — the Change… button: opens the chooser for the selected
 * row, for anyone who does not know a double-click does it.
 *
 * Inputs:
 *   sender — the button (unused)
 */
- (void)
change_clicked:(id)sender
{
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.records.count) return;
    [self choose_app_for:self.records[row]];
}

/*
 * choose_app_for: — asks which application should open a type and sets it.
 * The applications offered are the ones that say they can open it
 * (LaunchServices), in a pop-up button with the current default selected;
 * Other App… instead picks any application on the Mac, and is the only
 * choice when nothing claims the type.
 *
 * Inputs:
 *   rec — the record whose type is being pointed at an application
 */
- (void)
choose_app_for:(files_type_record *)rec
{
    UTType *type = [UTType typeWithIdentifier:rec.identifier];
    if (!type) return;

    NSArray<NSURL *> *candidates =
        [NSWorkspace.sharedWorkspace URLsForApplicationsToOpenContentType:type];
    if (candidates.count == 0) {
        [self pick_other_app_for:rec];
        return;
    }

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.font        = [NSFont systemFontOfSize:shared_look_ui_font];
    popup.controlSize = NSControlSizeSmall;
    popup.translatesAutoresizingMaskIntoConstraints = NO;
    [popup.widthAnchor constraintEqualToConstant:chooser_w].active = YES;

    for (NSURL *app in candidates) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:files_app_display_name(app)
                                                      action:NULL
                                               keyEquivalent:@""];
        item.image             = files_icon_for_url(app, icon_edge, YES);
        item.representedObject = app;
        [popup.menu addItem:item];
        if (files_same_path(app, rec.app_url)) [popup selectItem:item];
    }

    __weak files_default_apps_panel *weak_self = self;
    SharedToolPanel *panel = [SharedToolPanel
        panel_with_title:@"Default App"
                headline:[NSString stringWithFormat:@"Open %@ files with", type_phrase(rec)]
                subtitle:[rec.kind isEqualToString:@"—"] ? rec.identifier : rec.kind
                  symbol:@"app.badge.checkmark"
                 content:popup
                 buttons:@[@"Set Default", @"Other App…", @"Cancel"]
             destructive:-1
                 handler:^NSString *(NSInteger index) {
        files_default_apps_panel *strong_self = weak_self;
        if (!strong_self || index == 2) return nil;
        if (index == 1) {
            /* Let the panel close before the system's own picker goes up:
             * that one is app-modal and would run inside this handler. */
            dispatch_async(dispatch_get_main_queue(), ^{ [strong_self pick_other_app_for:rec]; });
            return nil;
        }
        NSURL *app = popup.selectedItem.representedObject;
        if (!app) return @"Choose an application.";
        [strong_self set_app:app for_record:rec];
        return nil;
    }];
    [panel show_over:self.window];
}

/*
 * pick_other_app_for: — the system file picker, limited to applications,
 * for pointing a type at one that does not claim it (a text editor for a
 * config file, say). Sets the default if one is chosen.
 *
 * Inputs:
 *   rec — the record whose type is being pointed at an application
 */
- (void)
pick_other_app_for:(files_type_record *)rec
{
    __weak files_default_apps_panel *weak_self = self;
    shared_ui_pick_path(SharedPickOpenFile,
                        [NSString stringWithFormat:@"Choose the application to open %@ files",
                         type_phrase(rec)],
                        @"Choose", @[UTTypeApplicationBundle], @"/Applications",
                        ^(NSString *path) {
        if (path) [weak_self set_app:[NSURL fileURLWithPath:path] for_record:rec];
    });
}

/*
 * user_cancelled — whether an error is the user turning macOS's own
 * confirmation down. Changing a default handler puts up a system prompt
 * ("Do you want to allow … ?"); declining it comes back as
 * userCanceledErr (-128), wrapped in an NSCocoaErrorDomain error whose
 * own code says nothing useful, so the chain is walked. Saying no is an
 * answer, not a failure, and must not raise an alert of its own.
 *
 * Inputs:
 *   err — the error, may be nil
 *
 * Output: YES if the user declined.
 */
static BOOL
user_cancelled(NSError *err)
{
    for (NSError *error = err; error != nil; error = error.userInfo[NSUnderlyingErrorKey]) {
        if ([error.domain isEqualToString:NSCocoaErrorDomain] &&
            error.code == NSUserCancelledError) return YES;
        if ([error.domain isEqualToString:NSOSStatusErrorDomain] &&
            error.code == -128) return YES;  /* userCanceledErr */
    }
    return NO;
}

/*
 * set_app:for_record: — makes an application the system default for a
 * record's content type, then reloads the list, which is what shows the
 * change: every row sharing the type (the same extensions, listed
 * together) and every other row that application now opens.
 *
 * macOS puts up a confirmation of its own first, so the answer can take as
 * long as the user does; it arrives on the completion handler, which is
 * why nothing here races it on a timer. Three answers are told apart:
 * the user declining the confirmation (nothing to report), an error
 * (reported as one), and LaunchServices reporting success while the
 * default did not actually change — measured with an application inside a
 * hidden cache folder, and with a type macOS keeps for itself — which
 * would otherwise leave the user looking at a list that did not change
 * and no reason why.
 *
 * Inputs:
 *   app — the application bundle
 *   rec — the record whose type it should open
 */
- (void)
set_app:(NSURL *)app for_record:(files_type_record *)rec
{
    UTType *type = [UTType typeWithIdentifier:rec.identifier];
    if (!type) return;

    __weak files_default_apps_panel *weak_self = self;
    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:app
                                          toOpenContentType:type
                                          completionHandler:^(NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            files_default_apps_panel *panel = weak_self;
            if (!panel) return;

            NSURL *now = [NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:type];
            if (!files_same_path(now, app) && !user_cancelled(err)) {
                if (err) {
                    files_show_error([NSString stringWithFormat:
                                      @"Could not set %@ to open %@ files",
                                      files_app_display_name(app), type_phrase(rec)],
                                     err, panel.window);
                } else {
                    shared_ui_notice(panel.window,
                        [NSString stringWithFormat:@"macOS would not open %@ files with %@",
                         type_phrase(rec), files_app_display_name(app)],
                        [NSString stringWithFormat:@"They still open with %@. macOS turns down an "
                         "application it will not register — one inside a cache folder, a disk "
                         "image or a folder it does not index — and keeps a few of its own file "
                         "types for itself. Moving the application to /Applications is worth "
                         "trying.", files_app_display_name(now)],
                        nil);
                }
            }
            [panel reload_table_then:nil];
        });
    }];
}

/* ── NSTableViewDataSource ───────────────────────────────────────────────── */

/*
 * numberOfRowsInTableView: — the listed types.
 *
 * Inputs:
 *   tv — the table view (unused)
 *
 * Output: number of records shown.
 */
- (NSInteger)
numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)self.records.count;
}

/* ── NSTableViewDelegate ─────────────────────────────────────────────────── */

/*
 * cell_text_for_col:record: — what one cell says: the one source for the
 * cell views, so a column's text is defined once.
 *
 * Inputs:
 *   ident — column identifier
 *   rec   — the record
 *
 * Output: display string, never nil.
 */
- (NSString *)
cell_text_for_col:(NSString *)ident record:(files_type_record *)rec
{
    if ([ident isEqualToString:col_extensions]) {
        return rec.extensions.length > 0 ? rec.extensions : @"—";
    }
    if ([ident isEqualToString:col_kind])       return rec.kind;
    if ([ident isEqualToString:col_app])        return rec.app_name;
    if ([ident isEqualToString:col_identifier]) return rec.identifier;
    return @"";
}

/*
 * tableView:viewForTableColumn:row: — a (reused or new) cell for one row
 * and column: the Extensions and Opens With columns carry an icon before
 * their text, the other two text alone. The icons were read with the scan,
 * so building a cell touches no file system.
 *
 * Inputs:
 *   tv  — the table view
 *   col — the column
 *   row — row index into records
 *
 * Output: configured cell view.
 */
- (NSView *)
tableView:(NSTableView *)tv
viewForTableColumn:(NSTableColumn *)col
              row:(NSInteger)row
{
    NSString *ident = col.identifier;
    BOOL has_icon   = [ident isEqualToString:col_extensions] || [ident isEqualToString:col_app];

    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:nil];
    if (!cell) {
        cell            = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;

        NSTextField *field  = [NSTextField labelWithString:@""];
        field.font          = [NSFont systemFontOfSize:shared_look_ui_font];
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:field];
        cell.textField = field;

        NSLayoutXAxisAnchor *text_leading = cell.leadingAnchor;
        CGFloat text_gap = shared_look_cell_pad_h;
        if (has_icon) {
            NSImageView *image = shared_ui_image_view(nil, icon_edge, icon_edge);
            [cell addSubview:image];
            cell.imageView = image;
            [NSLayoutConstraint activateConstraints:@[
                [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor
                                                    constant:shared_look_cell_pad_h],
                [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
            text_leading = image.trailingAnchor;
        }

        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor  constraintEqualToAnchor:text_leading constant:text_gap],
            [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor
                                                 constant:-shared_look_cell_pad_h],
            [field.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    files_type_record *rec     = self.records[row];
    NSString *text             = [self cell_text_for_col:ident record:rec];
    cell.textField.stringValue = text;
    cell.toolTip               = text;  /* readable when the column is too narrow */
    if (has_icon) {
        cell.imageView.image = [ident isEqualToString:col_app] ? rec.app_icon : rec.type_icon;
    }
    return cell;
}

/*
 * tableView:sortDescriptorsDidChange: — re-sorts the listed types and
 * reloads, keeping the selected row selected (show_records).
 *
 * Inputs:
 *   tv  — the table view (unused)
 *   old — the previous descriptors (unused)
 */
- (void)
tableView:(NSTableView *)tv
sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old
{
    [self show_records];
}

/*
 * tableViewSelectionDidChange: — Change… applies to the selected row, so
 * it is enabled only while there is one.
 *
 * Inputs:
 *   note — the notification (unused)
 */
- (void)
tableViewSelectionDidChange:(NSNotification *)note
{
    self.change_btn.enabled = self.table.selectedRow >= 0;
}

@end
