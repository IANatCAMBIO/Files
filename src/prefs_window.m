#import "prefs_window.h"
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
        @[ @[@"Show Bookmarks Bar", files_pref_show_bookmarks],
           @[@"Auto-Fit Columns", files_pref_auto_fit],
           @[@"Large Rows",       files_pref_large_rows],
           @[@"Show Folder Sizes", files_pref_folder_sizes],
           @[@"Show Used Disk Space", files_pref_show_used_space] ],
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
 * build_content — lays out the View and Integration sections in a
 * vertical stack and sizes the window to fit.
 */
- (void)
build_content
{
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    NSTextField *view_heading        = section_label(@"View");
    NSTextField *integration_heading = section_label(@"Integration");

    [rows addObject:view_heading];
    for (NSArray<NSArray<NSString *> *> *group in files_view_pref_groups()) {
        for (NSArray<NSString *> *item in group) {
            [rows addObject:[self pref_box:item[0] key:item[1]]];
        }
    }
    [rows addObject:[self pref_box:@"Show Hashes in Get Info (SHA-256 / MD5)"
                               key:files_pref_show_hashes]];
    [rows addObject:note_label(@"Get Info reads the whole file to compute them, which takes "
                                "a while for large files.")];

    [rows addObject:integration_heading];
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
    [rows addObject:note_label(@"\"Show in Finder\" and folders opened from other apps "
                                "go to the default file browser, and Archive Utility opens "
                                "a Finder window on what it creates or expands only while "
                                "Finder is the default. Folders switch over after "
                                "you log out and back in. Each button opens a log of every "
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
    /* Space under each heading, and between the sections. */
    [stack setCustomSpacing:8.0 afterView:view_heading];
    [stack setCustomSpacing:8.0 afterView:integration_heading];
    [stack setCustomSpacing:18.0
                  afterView:rows[[rows indexOfObject:integration_heading] - 1]];

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
