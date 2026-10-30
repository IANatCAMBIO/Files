#import "prefs_window.h"
#import "browser_view.h"
#import "default_viewer.h"
#import "util.h"

/* Width of wrapped explanatory text under a control. */
static const CGFloat note_width = 320.0;

/*
 * files_view_pref_groups — the View menu's preference items.
 * Inputs/output are documented in prefs_window.h.
 */
NSArray<NSArray<NSArray<NSString *> *> *> *
files_view_pref_groups(void)
{
    return @[
        @[ @[@"Always Show Folders First", files_pref_folders_first],
           @[@"Show Bookmarks Bar", files_pref_show_bookmarks],
           @[@"Auto-Fit Columns", files_pref_auto_fit],
           @[@"Large Rows",       files_pref_large_rows],
           @[@"Show Folder Sizes", files_pref_folder_sizes],
           @[@"Human Readable File Sizes", files_pref_human_readable_sizes],
           @[@"Show Used Disk Space", files_pref_show_used_space],
           @[@"Show Full Path in Title", files_pref_full_path_title] ],
        @[ @[@"Simple Copies",                files_pref_simple_copies],
           @[@"Validate Copies with SHA-256", files_pref_hash_validation] ],
    ];
}

/*
 * section_label — a bold section heading.
 *
 * Inputs:
 *   title — heading text
 *
 * Output: configured label.
 */
static NSTextField *
section_label(NSString *title)
{
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    return label;
}

/*
 * note_label — small secondary text explaining the control above it,
 * wrapped to note_width.
 *
 * Inputs:
 *   text — explanation
 *
 * Output: configured label.
 */
static NSTextField *
note_label(NSString *text)
{
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font      = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = NSColor.secondaryLabelColor;
    label.preferredMaxLayoutWidth = note_width;
    return label;
}

@interface FilesPrefsWindow ()
@property (nonatomic, strong) NSMutableArray<NSButton *> *pref_boxes;  /* identifier = pref key */
@property (nonatomic, strong) NSTextField                *browser_label;  /* current choice */
@property (nonatomic, strong) NSButton                   *files_button;
@property (nonatomic, strong) NSButton                   *finder_button;
/* Default sort: the column to sort by (item representedObject = column
 * identifier) and its direction (item 0 ascending, item 1 descending),
 * whose titles are re-worded for the chosen column. */
@property (nonatomic, strong) NSPopUpButton              *sort_column_popup;
@property (nonatomic, strong) NSPopUpButton              *sort_order_popup;
@end

@implementation FilesPrefsWindow

/*
 * shared — returns the process-wide singleton, creating it on first call.
 *
 * Output: FilesPrefsWindow singleton, never nil.
 */
+ (instancetype)
shared
{
    static FilesPrefsWindow *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FilesPrefsWindow alloc] init];
    });
    return instance;
}

/*
 * init — builds the tool window and its controls, sized to fit them, and
 * redraws them whenever a preference changes (on the main queue, since
 * defaults can change on any thread).
 *
 * Output: self or nil.
 */
- (instancetype)
init
{
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 360, 300)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title             = @"Preferences";
    panel.hidesOnDeactivate = NO;

    self = [super initWithWindow:panel];
    if (!self) return nil;

    self.pref_boxes = [NSMutableArray array];
    [self build_content];
    [panel center];
    [self refresh];

    __weak FilesPrefsWindow *ws = self;
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        [ws refresh];
    }];
    return self;
}

/*
 * pref_box: — a checkbox bound to a BOOL preference (toggle_pref_box:
 * writes it, refresh reads it).
 *
 * Inputs:
 *   title — checkbox title
 *   key   — files_pref_* key
 *
 * Output: configured checkbox, recorded in pref_boxes.
 */
- (NSButton *)
pref_box:(NSString *)title key:(NSString *)key
{
    NSButton *box  = [NSButton checkboxWithTitle:title
                                          target:self
                                          action:@selector(toggle_pref_box:)];
    box.identifier = key;
    [self.pref_boxes addObject:box];
    return box;
}

/*
 * sort_row — the Default sort controls: a label, the column to sort new
 * file lists by, and its direction. The column menu is built from
 * files_sort_columns(), so Preferences offers exactly the columns the
 * listing can sort by; the direction menu is filled in by refresh, which
 * words it for the chosen column.
 *
 * Output: the row, with sort_column_popup and sort_order_popup recorded.
 */
- (NSView *)
sort_row
{
    self.sort_column_popup = [NSPopUpButton buttonWithTitle:@""
                                                     target:self
                                                     action:@selector(choose_sort:)];
    for (NSArray<NSString *> *column in files_sort_columns()) {
        [self.sort_column_popup addItemWithTitle:column[0]];
        self.sort_column_popup.lastItem.representedObject = column[1];
    }
    self.sort_order_popup = [NSPopUpButton buttonWithTitle:@""
                                                    target:self
                                                    action:@selector(choose_sort:)];

    NSStackView *row = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Default sort:"],
        self.sort_column_popup,
        self.sort_order_popup,
    ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing     = 6.0;
    return row;
}

/*
 * build_content — lays out the View, Move/Copy and Integration sections in
 * a vertical stack and sizes the window to fit. Each section heading gets
 * the same space above and below it, so a new section needs no extra
 * spacing rules.
 */
- (void)
build_content
{
    NSMutableArray<NSView *> *rows        = [NSMutableArray array];
    NSMutableArray<NSView *> *headings    = [NSMutableArray array];
    NSArray<NSArray<NSArray<NSString *> *> *> *groups = files_view_pref_groups();

    /* View: the order new lists start in, the View menu's first group of
     * preferences, and Show Hashes in Get Info. */
    NSTextField *view_heading = section_label(@"View");
    [rows addObject:view_heading];
    [headings addObject:view_heading];
    NSView *sort_row = [self sort_row];
    [rows addObject:sort_row];
    for (NSArray<NSString *> *item in groups.firstObject) {
        [rows addObject:[self pref_box:item[0] key:item[1]]];
    }
    [rows addObject:[self pref_box:@"Show Hashes in Get Info (SHA-256 / MD5) *"
                               key:files_pref_show_hashes]];
    [rows addObject:note_label(@"* When Show Hashes is enabled, Get Info will have to read the "
                                "entire file to compute the hash. For large files, this may "
                                "take a while.")];

    /* Move/Copy: the View menu's remaining preference groups, which all
     * govern how transfers run. */
    NSTextField *transfer_heading = section_label(@"Move/Copy");
    [rows addObject:transfer_heading];
    [headings addObject:transfer_heading];
    for (NSArray<NSArray<NSString *> *> *group in groups) {
        if (group == groups.firstObject) continue;
        for (NSArray<NSString *> *item in group) {
            [rows addObject:[self pref_box:item[0] key:item[1]]];
        }
    }

    NSTextField *integration_heading = section_label(@"Integration");
    [rows addObject:integration_heading];
    [headings addObject:integration_heading];
    self.browser_label = [NSTextField labelWithString:@""];
    self.files_button  = [NSButton buttonWithTitle:@"Set default file browser to Files"
                                            target:self
                                            action:@selector(choose_browser:)];
    self.finder_button = [NSButton buttonWithTitle:@"Set default file browser to Finder"
                                            target:self
                                            action:@selector(choose_browser:)];
    [rows addObject:self.browser_label];
    [rows addObject:self.files_button];
    [rows addObject:self.finder_button];
    [rows addObject:note_label(@"\"Show in Finder\" and other reveal requests from other apps go to the "
                                "default file browser, and Archive Utility opens "
                                "a Finder window on what it creates or expands only while "
                                "Finder is the default. In zsh, `open <folder>` follows the "
                                "default too. A folder another app opens rather than reveals "
                                "(a Dock folder, a Spotlight result) always opens in Finder. "
                                "Each button opens a log of every "
                                "setting it checked or changed, the matching Terminal "
                                "command, and whether the change took effect.")];

    [rows addObject:[self pref_box:@"Keep Files running for faster startup"
                               key:files_pref_keep_running]];
    [rows addObject:note_label(@"Files opens at login and stays open when its last window "
                                "closes, so new windows appear instantly.")];

    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment   = NSLayoutAttributeLeading;
    stack.spacing     = 6.0;
    stack.edgeInsets  = NSEdgeInsetsMake(16, 20, 20, 20);
    /* Space under the Default sort row, and around every section heading. */
    [stack setCustomSpacing:10.0 afterView:sort_row];
    for (NSView *heading in headings) {
        [stack setCustomSpacing:8.0 afterView:heading];
        NSUInteger index = [rows indexOfObject:heading];
        if (index > 0) [stack setCustomSpacing:18.0 afterView:rows[index - 1]];
    }

    self.window.contentView = stack;
    [self.window setContentSize:stack.fittingSize];
}

/*
 * refresh — sets every control from the current preferences.
 */
- (void)
refresh
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSButton *box in self.pref_boxes) {
        box.state = [ud boolForKey:box.identifier] ? NSControlStateValueOn
                                                   : NSControlStateValueOff;
    }
    self.browser_label.stringValue = [NSString stringWithFormat:@"Default file browser: %@",
                                      [ud boolForKey:files_pref_default_viewer] ? @"Files" : @"Finder"];

    NSString *sort_column = files_sort_default_column();
    for (NSMenuItem *item in self.sort_column_popup.itemArray) {
        if ([item.representedObject isEqual:sort_column]) [self.sort_column_popup selectItem:item];
    }
    /* The direction menu is worded for the column, so it is refilled
     * whenever the column changes (which clears the selection, set below). */
    NSArray<NSString *> *titles = files_sort_order_titles(sort_column);
    if (![self.sort_order_popup.itemTitles isEqualToArray:titles]) {
        [self.sort_order_popup removeAllItems];
        [self.sort_order_popup addItemsWithTitles:titles];
    }
    [self.sort_order_popup selectItemAtIndex:[ud boolForKey:files_pref_sort_ascending] ? 0 : 1];
}

/*
 * choose_sort: — writes both Default sort menus to their preferences;
 * every browser applies the new order (apply_view_prefs), and refresh
 * re-words the direction menu for the column just chosen.
 *
 * Both menus are read before either preference is written: writing the
 * first one brings refresh straight back, which re-selects the direction
 * menu from the preference still to be written, so reading it afterwards
 * would write back the direction the user just replaced.
 *
 * Inputs:
 *   sender — sort_column_popup or sort_order_popup (unused: both are read)
 */
- (void)
choose_sort:(NSPopUpButton *)sender
{
    NSString *column = self.sort_column_popup.selectedItem.representedObject;
    BOOL ascending   = self.sort_order_popup.indexOfSelectedItem == 0;

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setObject:column    forKey:files_pref_sort_column];
    [ud setBool:ascending   forKey:files_pref_sort_ascending];
}

/*
 * toggle_pref_box: — writes a checkbox's state to its preference; whatever
 * depends on the preference observes it.
 *
 * Inputs:
 *   sender — checkbox made by pref_box:key:
 */
- (void)
toggle_pref_box:(NSButton *)sender
{
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                          forKey:sender.identifier];
}

/*
 * choose_browser: — makes the clicked button's app the default file
 * browser through files_default_viewer_choose (confirming a switch to
 * Finder; the change log opens when it is done). Both buttons are disabled
 * until it finishes, so changes never overlap.
 *
 * Inputs:
 *   sender — files_button or finder_button
 */
- (void)
choose_browser:(NSButton *)sender
{
    self.files_button.enabled  = NO;
    self.finder_button.enabled = NO;
    __weak FilesPrefsWindow *ws = self;
    files_default_viewer_choose(sender == self.files_button, self.window, ^{
        ws.files_button.enabled  = YES;
        ws.finder_button.enabled = YES;
        [ws refresh];
    });
}

/*
 * show_window — refreshes the controls and brings the window to the front.
 */
- (void)
show_window
{
    [self refresh];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

@end
