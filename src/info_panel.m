#import "info_panel.h"
#import "file_ops.h"
#import "file_hash.h"
#import "git_info.h"
#import "util.h"
#include <sys/stat.h>
#include <sys/xattr.h>
#include <pwd.h>
#include <grp.h>
#include <errno.h>
#include <stdatomic.h>

/* ── layout constants ────────────────────────────────────────────────── */
static const CGFloat panel_width = 360.0;
static const CGFloat label_w     = 110.0;
static const CGFloat margin      = 16.0;
static const CGFloat icon_size   = 64.0;

/* Tags on the two "copy" buttons; copy_hash_action: selects the field by tag. */
enum {
    copy_tag_sha256 = 1,
    copy_tag_md5    = 2,
};

/* ── row builder helpers ─────────────────────────────────────────────── */

/*
 * make_label — the key-column label of a row: small, bold, secondary.
 *
 * Inputs:
 *   text — label text
 *
 * Output: configured NSTextField.
 */
static NSTextField *
make_label(NSString *text)
{
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.font         = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
    tf.textColor    = NSColor.secondaryLabelColor;
    return tf;
}

/*
 * make_value — a row's value field: small text, middle-truncated, and
 * willing to shrink to the panel's width rather than widen it.
 *
 * Output: configured NSTextField.
 */
static NSTextField *
make_value(void)
{
    NSTextField *tf  = [NSTextField labelWithString:@""];
    tf.font          = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return tf;
}

/* ── copy-link button helper ─────────────────────────────────────────── */

/*
 * make_copy_btn — creates a borderless link-styled "copy" button.
 *
 * Inputs:
 *   target — action target
 *   action — selector to call on click
 *   tag    — button tag the action uses to tell the buttons apart
 *
 * Output: configured NSButton.
 */
static NSButton *
make_copy_btn(id target, SEL action, NSInteger tag)
{
    NSButton *btn  = [[NSButton alloc] init];
    btn.buttonType = NSButtonTypeMomentaryPushIn;
    btn.bordered   = NO;
    NSMutableAttributedString *t =
        [[NSMutableAttributedString alloc] initWithString:@"copy"];
    [t setAttributes:@{
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSFontAttributeName: [NSFont systemFontOfSize:9.0],
    } range:NSMakeRange(0, t.length)];
    btn.attributedTitle = t;
    btn.target = target;
    btn.action = action;
    btn.tag    = tag;
    [btn setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return btn;
}

/* ── xattr helpers ───────────────────────────────────────────────────── */

/*
 * xattr_val_string — formats an xattr value for display: the raw bytes if
 * they are valid UTF-8, otherwise a hex dump.
 *
 * Inputs:
 *   data — raw xattr bytes
 *
 * Output: display string (never nil)
 */
static NSString *
xattr_val_string(NSData *data)
{
    if (data.length == 0) return @"";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", b[i]];
    return hex;
}

/*
 * make_xattr_btn — a small titled button for the xattr row toolbar.
 *
 * Inputs:
 *   title  — button label
 *   target — action target
 *   action — action selector
 *
 * Output: configured NSButton.
 */
static NSButton *
make_xattr_btn(NSString *title, id target, SEL action)
{
    NSButton *btn   = [NSButton buttonWithTitle:title target:target action:action];
    btn.controlSize = NSControlSizeSmall;
    btn.bezelStyle  = NSBezelStyleRounded;
    return btn;
}

/* ── permissions helper ──────────────────────────────────────────────── */

/*
 * perm_items — the 8 option strings for a single rwx triplet, ordered by
 * octal value 0-7, used as NSPopUpButton titles (item tag = octal value).
 */
static NSString * const perm_items[] = {
    @"---", @"--x", @"-w-", @"-wx",
    @"r--", @"r-x", @"rw-", @"rwx",
};

/*
 * make_perm_popup — one rwx popup with a small caption below it.
 *
 * Inputs:
 *   caption — "Owner", "Group" or "Other"
 *   target  — action target (perms_popup_changed:)
 *   popup   — receives the popup
 *
 * Output: vertical stack holding the popup and its caption.
 */
static NSStackView *
make_perm_popup(NSString *caption, id target, NSPopUpButton **popup)
{
    NSPopUpButton *btn = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    btn.font    = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    btn.toolTip = caption;
    for (NSInteger t = 0; t < 8; t++) {
        [btn addItemWithTitle:perm_items[t]];
        [btn itemAtIndex:t].tag = t;
    }
    btn.target = target;
    btn.action = @selector(perms_popup_changed:);
    *popup = btn;

    NSTextField *label = [NSTextField labelWithString:caption];
    label.font         = [NSFont systemFontOfSize:9.0];
    label.textColor    = NSColor.tertiaryLabelColor;
    NSStackView *stack = [NSStackView stackViewWithViews:@[btn, label]];
    stack.orientation  = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing      = 2.0;
    return stack;
}

/* ── Permission string helper ────────────────────────────────────────── */

/*
 * format_mode_text — formats the lower 9 bits of a POSIX mode as a
 * nine-character rwx string (e.g. "rwxr-xr-x").
 *
 * Inputs:
 *   m — st_mode value (type bits are ignored)
 *
 * Output: NSString of exactly 9 characters.
 */
static NSString *
format_mode_text(mode_t m)
{
    static const char rwx[] = "rwxrwxrwx";
    char buf[10];
    for (int i = 0; i < 9; i++) buf[i] = (m >> (8 - i)) & 1 ? rwx[i] : '-';
    buf[9] = '\0';
    return @(buf);
}

/* ── Ownership helpers ───────────────────────────────────────────────── */

/*
 * local_user_names — sorted list of all local POSIX user account names.
 *
 * Output: alphabetically sorted NSArray of NSString.
 */
static NSArray<NSString *> *
local_user_names(void)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    setpwent();
    struct passwd *pw;
    while ((pw = getpwent()) != NULL) [names addObject:@(pw->pw_name)];
    endpwent();
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

/*
 * local_group_names — sorted list of all local POSIX group names.
 *
 * Output: alphabetically sorted NSArray of NSString.
 */
static NSArray<NSString *> *
local_group_names(void)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    setgrent();
    struct group *gr;
    while ((gr = getgrent()) != NULL) [names addObject:@(gr->gr_name)];
    endgrent();
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

/*
 * make_ownership_popup — a small popup pre-populated with the given names.
 *
 * Inputs:
 *   names  — items to add
 *   target — action target
 *   action — selector called on selection change
 *
 * Output: configured NSPopUpButton.
 */
static NSPopUpButton *
make_ownership_popup(NSArray<NSString *> *names, id target, SEL action)
{
    NSPopUpButton *btn = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    btn.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    for (NSString *name in names) [btn addItemWithTitle:name];
    btn.target = target;
    btn.action = action;
    return btn;
}

/* ── FilesInfoPanel ──────────────────────────────────────────────────── */

@interface FilesInfoPanel () <NSTextFieldDelegate, NSWindowDelegate,
                               NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSURL       *current_url;
@property (nonatomic, assign) BOOL         current_is_dir;
@property (nonatomic, strong) NSImageView *icon_view;
@property (nonatomic, strong) NSTextField *name_field;
@property (nonatomic, strong) NSTextField *comment_field;
@property (nonatomic, copy)   NSString    *comment_original; /* value when editing began */
@property (nonatomic, strong) NSTextField *kind_value;
@property (nonatomic, strong) NSTextField *opens_with_value;
@property (nonatomic, strong) NSTextField *size_value;
@property (nonatomic, strong) NSTextField *where_value;
@property (nonatomic, strong) NSTextField *created_value;
@property (nonatomic, strong) NSTextField *modified_value;
@property (nonatomic, strong) NSPopUpButton *owner_perms_popup;
@property (nonatomic, strong) NSPopUpButton *group_perms_popup;
@property (nonatomic, strong) NSPopUpButton *other_perms_popup;
@property (nonatomic, strong) NSPopUpButton *owner_popup;
@property (nonatomic, strong) NSPopUpButton *group_popup;
/* Read-only text labels shown in place of the interactive controls when locked. */
@property (nonatomic, strong) NSTextField *locked_perm_value;
@property (nonatomic, strong) NSTextField *locked_owner_value;
@property (nonatomic, strong) NSTextField *locked_group_value;
@property (nonatomic, strong) NSTextField *locked_comment_value;
/* Parallel edit / locked grid rows for switching between interactive and label views. */
@property (nonatomic, strong) NSArray<NSGridRow *> *edit_rows_gated;
@property (nonatomic, strong) NSArray<NSGridRow *> *locked_rows_gated;
@property (nonatomic, strong) NSTextField *sha256_value;
@property (nonatomic, strong) NSTextField *md5_value;
@property (nonatomic, strong) NSButton    *lock_check;
@property (nonatomic, assign) BOOL         hashes_on;  /* files_pref_show_hashes, as last applied */
@property (nonatomic, strong) FilesCancelToken *hash_job; /* in-flight hash; stale guard */
@property (nonatomic, strong) NSTextField *branch_value;
@property (nonatomic, strong) NSTextField *pushed_value;
@property (nonatomic, strong) NSTextField *remote_value;
@property (nonatomic, assign) NSUInteger   git_generation; /* stale guard for git reads */
@property (nonatomic, strong) NSArray<NSGridRow *> *git_rows; /* separator, header, rows */

/* Extended-attributes section */
@property (nonatomic, strong) NSMutableArray<NSString *> *xattr_keys;
@property (nonatomic, strong) NSMutableArray<NSData *>   *xattr_vals;
@property (nonatomic, strong) NSTableView                *xattr_table;
@property (nonatomic, strong) NSView                     *xattr_container;
@property (nonatomic, strong) NSButton                   *xattr_disclosure;
@property (nonatomic, strong) NSButton                   *xattr_add_btn;
@property (nonatomic, strong) NSButton                   *xattr_delete_btn;
@property (nonatomic, strong) NSButton                   *xattr_clear_btn;
@property (nonatomic, assign) NSInteger                   xattr_editing_row;
@property (nonatomic, assign) NSInteger                   xattr_editing_col;

@end

@implementation FilesInfoPanel

/*
 * shared — returns the singleton panel instance, creating it on first use.
 *
 * Output: the process-wide FilesInfoPanel (never nil).
 */
+ (instancetype)
shared
{
    static FilesInfoPanel *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FilesInfoPanel alloc] init];
    });
    return instance;
}

/*
 * init — creates the panel: the icon and an editable name field on top,
 * a separator, then an NSGridView of labelled rows (Kind … MD5, the Locked
 * checkbox, and a Git section that is hidden except for the top folder of
 * a working tree). The panel is a fixed width and its height follows the
 * visible rows (fit_window). The hash rows follow Preferences ▸ Show
 * Hashes in Get Info (files_pref_show_hashes), live.
 *
 * Output: self, or nil if the window controller could not be initialised.
 */
- (instancetype)
init
{
    NSPanel *panel = [[NSPanel alloc]
                         initWithContentRect:NSMakeRect(0, 0, panel_width, 400)
                                   styleMask:NSWindowStyleMaskTitled
                                            | NSWindowStyleMaskClosable
                                            | NSWindowStyleMaskUtilityWindow
                                     backing:NSBackingStoreBuffered
                                       defer:NO];
    panel.title              = @"Info";
    panel.releasedWhenClosed = NO;
    panel.level              = NSFloatingWindowLevel;
    panel.hidesOnDeactivate  = NO;

    self = [super initWithWindow:panel];
    if (!self) {
        return nil;
    }
    panel.delegate = self;

    /* Icon + name at top. A rounded-bezel field centres its text itself. */
    self.icon_view = [NSImageView imageViewWithImage:[[NSImage alloc] init]];
    self.icon_view.imageScaling = NSImageScaleProportionallyUpOrDown;
    [NSLayoutConstraint activateConstraints:@[
        [self.icon_view.widthAnchor  constraintEqualToConstant:icon_size],
        [self.icon_view.heightAnchor constraintEqualToConstant:icon_size],
    ]];
    self.name_field               = [NSTextField textFieldWithString:@""];
    self.name_field.bezelStyle    = NSTextFieldRoundedBezel;
    self.name_field.font          = [NSFont boldSystemFontOfSize:13.0];
    self.name_field.delegate      = self;
    self.name_field.focusRingType = NSFocusRingTypeNone;
    self.name_field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.name_field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *top = [NSStackView stackViewWithViews:@[self.icon_view, self.name_field]];
    top.spacing      = 12.0;

    NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    grid.rowSpacing    = 6.0;
    grid.columnSpacing = 8.0;
    [grid columnAtIndex:0].width      = label_w;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    NSGridRow *(^row)(NSString *, NSView *) = ^NSGridRow *(NSString *label, NSView *value) {
        NSGridRow *r = [grid addRowWithViews:@[label ? make_label(label)
                                                     : NSGridCell.emptyContentView, value]];
        r.rowAlignment = NSGridRowAlignmentFirstBaseline;
        return r;
    };

    self.kind_value       = make_value();
    self.opens_with_value = make_value();
    self.size_value       = make_value();
    self.where_value      = make_value();
    self.created_value    = make_value();
    self.modified_value   = make_value();
    self.comment_field = [NSTextField textFieldWithString:@""];
    self.comment_field.placeholderString = @"Add a comment…";
    self.comment_field.font             = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.comment_field.delegate         = self;
    self.comment_field.focusRingType    = NSFocusRingTypeNone;
    self.comment_field.usesSingleLineMode = NO;
    self.comment_field.cell.wraps       = YES;
    [self.comment_field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];

    row(@"Kind:",       self.kind_value);
    row(@"Opens with:", self.opens_with_value);
    row(@"Size:",       self.size_value);
    row(@"Where:",      self.where_value);
    row(@"Created:",    self.created_value);
    row(@"Modified:",   self.modified_value);

    /* Comments — editable row + locked-state label row. */
    NSGridRow *comment_edit_row = row(@"Comments:", self.comment_field);
    self.locked_comment_value = [NSTextField wrappingLabelWithString:@""];
    self.locked_comment_value.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [self.locked_comment_value setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSGridRow *comment_locked_row = row(@"Comments:", self.locked_comment_value);
    comment_locked_row.hidden = YES;

    /* Permissions — three-popup edit row + locked-state text row. */
    NSPopUpButton *owner = nil, *group = nil, *other = nil;
    NSStackView *perms = [NSStackView stackViewWithViews:@[
        make_perm_popup(@"Owner", self, &owner),
        make_perm_popup(@"Group", self, &group),
        make_perm_popup(@"Other", self, &other),
    ]];
    perms.distribution = NSStackViewDistributionFillEqually;
    perms.spacing      = 6.0;
    self.owner_perms_popup = owner;
    self.group_perms_popup = group;
    self.other_perms_popup = other;
    NSGridRow *perm_edit_row  = row(@"Permissions:", perms);
    perm_edit_row.rowAlignment = NSGridRowAlignmentNone;
    perm_edit_row.yPlacement   = NSGridCellPlacementTop;
    self.locked_perm_value = make_value();
    self.locked_perm_value.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize
                                                              weight:NSFontWeightRegular];
    NSGridRow *perm_locked_row = row(@"Permissions:", self.locked_perm_value);
    perm_locked_row.hidden = YES;

    /* Owner and Group — popup edit rows + locked-state label rows. */
    self.owner_popup = make_ownership_popup(local_user_names(),  self, @selector(ownership_popup_changed:));
    self.group_popup = make_ownership_popup(local_group_names(), self, @selector(ownership_popup_changed:));
    NSGridRow *owner_edit_row = row(@"Owner:", self.owner_popup);
    self.locked_owner_value = make_value();
    NSGridRow *owner_locked_row = row(@"Owner:", self.locked_owner_value);
    owner_locked_row.hidden = YES;
    NSGridRow *group_edit_row = row(@"Group:", self.group_popup);
    self.locked_group_value = make_value();
    NSGridRow *group_locked_row = row(@"Group:", self.locked_group_value);
    group_locked_row.hidden = YES;

    self.edit_rows_gated   = @[comment_edit_row,   perm_edit_row,   owner_edit_row,   group_edit_row];
    self.locked_rows_gated = @[comment_locked_row, perm_locked_row, owner_locked_row, group_locked_row];

    /* Hash fields: monospaced, tail-truncated with "…", selectable to copy. */
    self.sha256_value = make_value();
    self.md5_value    = make_value();
    NSFont *hash_font = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightRegular];
    NSInteger tag = copy_tag_sha256;
    for (NSTextField *hf in @[self.sha256_value, self.md5_value]) {
        hf.font          = hash_font;
        hf.selectable    = YES;
        hf.lineBreakMode = NSLineBreakByTruncatingTail;
        NSStackView *line = [NSStackView stackViewWithViews:@[
            hf, make_copy_btn(self, @selector(copy_hash_action:), tag)]];
        line.spacing = 4.0;
        row(tag == copy_tag_sha256 ? @"SHA-256:" : @"MD5:", line);
        tag = copy_tag_md5;
    }

    self.lock_check = [NSButton checkboxWithTitle:@"Locked" target:self
                                           action:@selector(lock_toggled:)];

    /* Git section: a separator and a title across both columns, then rows. */
    NSBox *git_sep = [[NSBox alloc] init];
    git_sep.boxType = NSBoxSeparator;
    NSTextField *git_title = [NSTextField labelWithString:@"Git"];
    git_title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    NSMutableArray<NSGridRow *> *git_rows = [NSMutableArray array];
    for (NSView *v in @[git_sep, git_title]) {
        NSGridRow *r = [grid addRowWithViews:@[v]];
        [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2)
                            verticalRange:NSMakeRange((NSUInteger)[grid indexOfRow:r], 1)];
        [r cellAtIndex:0].xPlacement = NSGridCellPlacementFill;
        [git_rows addObject:r];
    }
    self.branch_value = make_value();
    self.pushed_value = make_value();
    self.remote_value = make_value();
    self.remote_value.selectable = YES;  /* so the URL can be copied */
    [git_rows addObject:row(@"Current Branch:", self.branch_value)];
    [git_rows addObject:row(@"Pushed:",         self.pushed_value)];
    [git_rows addObject:row(@"Remote URL:",     self.remote_value)];
    for (NSGridRow *r in git_rows) r.hidden = YES;
    self.git_rows = git_rows;

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;

    NSBox *xattr_sep    = [[NSBox alloc] init];
    xattr_sep.boxType   = NSBoxSeparator;
    NSView *xattr_section = [self build_xattr_section];

    NSStackView *all = [NSStackView stackViewWithViews:@[top, sep, grid]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment   = NSLayoutAttributeLeading;
    all.spacing     = 10.0;
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [all addArrangedSubview:xattr_sep];
    [all addArrangedSubview:xattr_section];

    /* Lock checkbox pinned to the bottom-right: a spacer pushes it trailing. */
    NSView *lock_spacer = [[NSView alloc] init];
    [lock_spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *lock_row = [NSStackView stackViewWithViews:@[lock_spacer, self.lock_check]];
    lock_row.spacing = 0;
    [all addArrangedSubview:lock_row];

    NSView *cv = panel.contentView;
    [cv addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [all.topAnchor      constraintEqualToAnchor:cv.topAnchor constant:margin],
        [all.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor constant:margin],
        [all.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-margin],
        [all.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor constant:-margin],
        [cv.widthAnchor     constraintEqualToConstant:panel_width],
        [top.widthAnchor          constraintEqualToAnchor:all.widthAnchor],
        [sep.widthAnchor          constraintEqualToAnchor:all.widthAnchor],
        [grid.widthAnchor         constraintEqualToAnchor:all.widthAnchor],
        [xattr_sep.widthAnchor    constraintEqualToAnchor:all.widthAnchor],
        [xattr_section.widthAnchor constraintEqualToAnchor:all.widthAnchor],
        [lock_row.widthAnchor      constraintEqualToAnchor:all.widthAnchor],
    ]];
    /* Defaults can change on any thread; act on the main queue, and only
     * when Show Hashes itself changed. */
    self.hashes_on = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hashes];
    __weak FilesInfoPanel *ws = self;
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        [ws show_hashes_changed];
    }];
    [self fit_window];
    return self;
}

/*
 * fit_window — sizes the panel to its visible rows, keeping its top edge
 * in place.
 */
- (void)
fit_window
{
    NSWindow *w = self.window;
    [w.contentView layoutSubtreeIfNeeded];
    NSSize fit = w.contentView.fittingSize;
    NSRect c   = [w contentRectForFrameRect:w.frame];
    CGFloat top = NSMaxY(c);
    c.size      = NSMakeSize(panel_width, fit.height);
    c.origin.y  = top - fit.height;
    [w setFrame:[w frameRectForContentRect:c] display:YES];
}

/*
 * show_for_url: — populates all fields and shows the panel.
 *
 * Inputs:
 *   url — file or directory to inspect
 */
- (void)
show_for_url:(NSURL *)url
{
    self.current_url = url;
    [self populate_fields:url];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    /* Deselect the name field so it doesn't open with all text highlighted. */
    [self.window makeFirstResponder:nil];
}

/*
 * cancel_hash_job — stops the in-flight hash read (if any) and forgets it,
 * so its result, should it still arrive, fails the stale guard.
 */
- (void)
cancel_hash_job
{
    [self.hash_job cancel];
    self.hash_job = nil;
}

/*
 * start_hash_job: — computes SHA-256 and MD5 of url in one background read
 * pass and fills the hash fields when done. Superseded or cancelled jobs
 * never touch the UI.
 *
 * Inputs:
 *   url — regular file to hash
 */
- (void)
start_hash_job:(NSURL *)url
{
    FilesCancelToken *job = [[FilesCancelToken alloc] init];
    self.hash_job = job;
    self.sha256_value.stringValue = @"Computing…";
    self.md5_value.stringValue    = @"Computing…";

    __weak FilesInfoPanel *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint8_t sha_buf[FILE_SHA256_LEN];
        uint8_t md5_buf[FILE_MD5_LEN];
        int rc = file_digests(url.fileSystemRepresentation, sha_buf, md5_buf,
                              [job cancel_flag]);
        if (rc == -2) return;
        NSString *sha = (rc == 0) ? digest_hex(sha_buf, FILE_SHA256_LEN) : nil;
        NSString *md5 = (rc == 0) ? digest_hex(md5_buf, FILE_MD5_LEN) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesInfoPanel *s = ws;
            if (!s || s.hash_job != job) return;
            s.hash_job = nil;
            s.sha256_value.stringValue = sha ?: @"Error";
            s.sha256_value.toolTip     = sha;
            s.md5_value.stringValue    = md5 ?: @"Error";
            s.md5_value.toolTip        = md5;
        });
    });
}

/*
 * populate_fields: — reads file attributes and fills UI fields. Cancels any
 * hash job still running for a previously shown item.
 *
 * Inputs:
 *   url — file URL
 */
- (void)
populate_fields:(NSURL *)url
{
    [self cancel_hash_job];

    NSArray<NSURLResourceKey> *keys = @[
        NSURLNameKey, NSURLFileSizeKey, NSURLFileAllocatedSizeKey,
        NSURLIsDirectoryKey,
        NSURLCreationDateKey, NSURLContentModificationDateKey,
        NSURLIsUserImmutableKey
    ];
    /* url often comes from the browser listing with values cached at list
     * time; read a fresh URL so the panel shows the item's current state
     * without clearing the browser row's cache. */
    NSURL *fresh = [NSURL fileURLWithPath:url.path];
    NSDictionary<NSURLResourceKey, id> *res =
        [fresh resourceValuesForKeys:keys error:nil];

    /* Icon */
    self.icon_view.image = files_icon_for_url(fresh, icon_size, NO);

    /* Name */
    self.name_field.stringValue = res[NSURLNameKey] ?: url.lastPathComponent;

    /* Kind: "Folder" for folders, "Application Container" for apps and so on. */
    BOOL is_dir = [res[NSURLIsDirectoryKey] boolValue];
    self.current_is_dir = is_dir;
    self.kind_value.stringValue       = files_kind_text(fresh);
    self.opens_with_value.stringValue = files_opens_with_text(fresh);

    /* Size */
    NSNumber *sz       = res[NSURLFileSizeKey];
    NSNumber *alloc_sz = res[NSURLFileAllocatedSizeKey];
    if (sz && !is_dir) {
        self.size_value.stringValue =
            [NSString stringWithFormat:@"%@ (%@ on disk)",
                files_format_bytes(sz.longLongValue),
                files_format_bytes(alloc_sz.longLongValue)];
    } else {
        self.size_value.stringValue = @"—";
    }

    /* Where */
    self.where_value.stringValue = url.URLByDeletingLastPathComponent.path ?: @"—";

    /* Dates */
    self.created_value.stringValue =
        files_format_date(res[NSURLCreationDateKey], NSDateFormatterMediumStyle);
    self.modified_value.stringValue =
        files_format_date(res[NSURLContentModificationDateKey], NSDateFormatterMediumStyle);

    /* POSIX permissions, owner, group via NSDictionary attributes */
    NSDictionary<NSFileAttributeKey, id> *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (attrs) {
        NSNumber *posix = attrs[NSFilePosixPermissions];
        if (posix) {
            mode_t m = (mode_t)posix.shortValue;
            [self.owner_perms_popup selectItemWithTag:(m >> 6) & 7];
            [self.group_perms_popup selectItemWithTag:(m >> 3) & 7];
            [self.other_perms_popup selectItemWithTag:m & 7];
            self.locked_perm_value.stringValue = format_mode_text(m);
        }
        void (^select_or_insert)(NSPopUpButton *, NSTextField *, NSString *) =
            ^(NSPopUpButton *popup, NSTextField *label, NSString *name) {
            if (!name || name.length == 0) { label.stringValue = @"—"; return; }
            if ([popup indexOfItemWithTitle:name] < 0) [popup insertItemWithTitle:name atIndex:0];
            [popup selectItemWithTitle:name];
            label.stringValue = name;
        };
        select_or_insert(self.owner_popup, self.locked_owner_value, attrs[NSFileOwnerAccountName]);
        select_or_insert(self.group_popup, self.locked_group_value, attrs[NSFileGroupOwnerAccountName]);
    } else {
        [self.owner_perms_popup selectItemWithTag:0];
        [self.group_perms_popup selectItemWithTag:0];
        [self.other_perms_popup selectItemWithTag:0];
        self.locked_perm_value.stringValue  = @"—";
        self.locked_owner_value.stringValue = @"—";
        self.locked_group_value.stringValue = @"—";
    }

    /* Lock — the user-immutable flag (uchg), same flag lock_toggled: sets.
     * Read-only permissions alone do not make an item "Locked". */
    self.lock_check.state = [res[NSURLIsUserImmutableKey] boolValue]
                            ? NSControlStateValueOn
                            : NSControlStateValueOff;
    [self update_editable_state];

    /* Hashes — computed asynchronously when enabled and item is a file. The
     * tooltip doubles as "a real digest is present" for copy_hash_action:. */
    [self update_hashes];

    /* Git — shown only for the top folder of a git working tree. */
    self.git_generation++;
    BOOL is_git = files_is_git_repo(url);
    [self set_git_section_visible:is_git];
    if (is_git) [self start_git_job:url];

    /* Spotlight / Finder comment */
    NSString *comment = files_get_finder_comment(fresh) ?: @"";
    self.comment_field.stringValue        = comment;
    self.locked_comment_value.stringValue = comment;
    self.comment_original = comment;

    /* Extended attributes */
    [self reload_xattrs];
}

/*
 * update_editable_state — switches between interactive controls and read-only
 * text labels to match the current lock state. When locked, all fields become
 * plain labels identical to the sidebar; the lock checkbox stays enabled so
 * the user can unlock. Calls fit_window because hidden grid rows collapse.
 */
- (void)
update_editable_state
{
    BOOL editable = (self.lock_check.state != NSControlStateValueOn);

    /* Name field: bezel + editable vs. plain label. */
    self.name_field.editable        = editable;
    self.name_field.bordered        = editable;
    self.name_field.drawsBackground = editable;

    /* Swap the interactive grid rows for read-only label rows (or vice versa). */
    for (NSGridRow *r in self.edit_rows_gated)   r.hidden = !editable;
    for (NSGridRow *r in self.locked_rows_gated) r.hidden =  editable;

    [self update_xattr_buttons];
    [self fit_window];
}

/*
 * set_git_section_visible: — shows or hides the Git rows and refits the
 * panel to them (fit_window), keeping its top edge in place.
 *
 * Inputs:
 *   visible — YES to show the Git rows
 */
- (void)
set_git_section_visible:(BOOL)visible
{
    if (visible == !self.git_rows.firstObject.hidden) return;
    for (NSGridRow *r in self.git_rows) r.hidden = !visible;
    [self fit_window];
}

/*
 * update_hashes — fills the hash rows for the current item: starts a hash
 * job for a file while Show Hashes is on, otherwise shows "—" (and stops
 * any job still running). The tooltip doubles as "a real digest is
 * present" for copy_hash_action:.
 */
- (void)
update_hashes
{
    [self cancel_hash_job];
    self.sha256_value.stringValue = @"—";
    self.md5_value.stringValue    = @"—";
    self.sha256_value.toolTip     = nil;
    self.md5_value.toolTip        = nil;
    if (self.current_url && !self.current_is_dir &&
        [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hashes]) {
        [self start_hash_job:self.current_url];
    }
}

/*
 * start_git_job: — reads the branch, push state and remote URL of repo on
 * a background queue and fills the Git rows when done, unless the panel
 * has moved on to another item (git_generation changed) in the meantime.
 *
 * Inputs:
 *   repo — git working-tree root
 */
- (void)
start_git_job:(NSURL *)repo
{
    NSUInteger gen = self.git_generation;
    for (NSTextField *f in @[self.branch_value, self.pushed_value, self.remote_value]) {
        f.stringValue = @"Checking…";
        f.toolTip     = nil;
    }

    __weak FilesInfoPanel *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *branch = nil, *pushed = nil, *remote = nil;
        BOOL ok = files_git_describe(repo, &branch, &pushed, &remote);
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesInfoPanel *s = ws;
            if (!s || s.git_generation != gen) return;
            if (!ok) {
                s.branch_value.stringValue = @"Unavailable (git could not read it)";
                s.pushed_value.stringValue = @"—";
                s.remote_value.stringValue = @"—";
                return;
            }
            /* Tooltips carry the full text, which may be truncated. */
            s.branch_value.stringValue = branch;
            s.branch_value.toolTip     = branch;
            s.pushed_value.stringValue = pushed;
            s.pushed_value.toolTip     = [pushed stringByAppendingString:
                @"\nCompared with the upstream branch as of the last fetch."];
            s.remote_value.stringValue = remote;
            s.remote_value.toolTip     = remote;
        });
    });
}

/*
 * perms_popup_changed: — reads the three permission popups and applies the new
 * mode to the current item via lchmod(2), preserving file-type and setuid/
 * setgid/sticky bits from the existing mode. lstat/lchmod act on a symlink
 * itself (never its target), matching the mode shown by populate_fields:.
 * On failure shows an error sheet and reverts the popups.
 *
 * Inputs:
 *   sender — any of the three NSPopUpButton controls (unused; all three are read)
 */
- (IBAction)
perms_popup_changed:(id)sender
{
    (void)sender;
    if (!self.current_url) return;

    struct stat st;
    if (lstat(self.current_url.fileSystemRepresentation, &st) != 0) return;

    /* Preserve type bits and special bits (setuid, setgid, sticky). */
    mode_t special = st.st_mode & (S_IFMT | S_ISUID | S_ISGID | S_ISVTX);
    mode_t owner   = (mode_t)(self.owner_perms_popup.selectedTag & 7);
    mode_t group   = (mode_t)(self.group_perms_popup.selectedTag & 7);
    mode_t other   = (mode_t)(self.other_perms_popup.selectedTag & 7);
    mode_t new_mode = special | (owner << 6) | (group << 3) | other;

    if (lchmod(self.current_url.fileSystemRepresentation, new_mode) != 0) {
        NSError *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        files_show_error(@"Could not change permissions", err, self.window);
        /* Revert popups to reflect the unchanged on-disk mode. */
        [self.owner_perms_popup selectItemWithTag:(st.st_mode >> 6) & 7];
        [self.group_perms_popup selectItemWithTag:(st.st_mode >> 3) & 7];
        [self.other_perms_popup selectItemWithTag:st.st_mode & 7];
    }
}

/*
 * ownership_popup_changed: — applies the current owner and group popup
 * selections to the current item via lchown(2). Acts on a symlink itself
 * rather than its target. On failure shows an error sheet and reverts
 * both popups to match the item's current on-disk ownership.
 *
 * Inputs:
 *   sender — either the owner or group NSPopUpButton (both are read)
 */
- (IBAction)
ownership_popup_changed:(id)sender
{
    (void)sender;
    if (!self.current_url) return;

    const char *path = self.current_url.fileSystemRepresentation;
    struct stat st;
    if (lstat(path, &st) != 0) return;

    struct passwd *pw = getpwnam(self.owner_popup.selectedItem.title.UTF8String);
    struct group  *gr = getgrnam(self.group_popup.selectedItem.title.UTF8String);
    if (!pw || !gr) return;

    if (lchown(path, pw->pw_uid, gr->gr_gid) != 0) {
        NSError *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        files_show_error(@"Could not change ownership", err, self.window);
        /* Revert popups to the actual on-disk owner and group. */
        struct passwd *cur_pw = getpwuid(st.st_uid);
        struct group  *cur_gr = getgrgid(st.st_gid);
        if (cur_pw) [self.owner_popup selectItemWithTitle:@(cur_pw->pw_name)];
        if (cur_gr) [self.group_popup selectItemWithTitle:@(cur_gr->gr_name)];
    }
}

/*
 * copy_hash_action: — copies the SHA-256 or MD5 digest (chosen by the
 * sender's tag) to the general pasteboard. Does nothing unless a digest has
 * actually been computed (placeholders like "Computing…" or "Error" are never
 * copied).
 *
 * Inputs:
 *   sender — copy link button tagged copy_tag_sha256 or copy_tag_md5
 */
- (IBAction)
copy_hash_action:(NSButton *)sender
{
    NSTextField *field = (sender.tag == copy_tag_md5) ? self.md5_value : self.sha256_value;
    NSString *digest   = field.toolTip;
    if (digest.length == 0) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:digest forType:NSPasteboardTypeString];
}

/*
 * show_hashes_changed — when files_pref_show_hashes has changed since it
 * was last applied, starts or stops hashing the current item
 * (update_hashes); nothing else is re-read.
 */
- (void)
show_hashes_changed
{
    BOOL on = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hashes];
    if (on == self.hashes_on) return;
    self.hashes_on = on;
    [self update_hashes];
}

/*
 * lock_toggled: — sets or clears the user-immutable flag (uchg) on the
 * current item via NSURLIsUserImmutableKey — the same key populate_fields:
 * reads, and like it, applied to a symlink itself rather than its target.
 * On failure shows an error sheet and reverts the checkbox.
 *
 * Inputs:
 *   sender — the lock checkbox
 */
- (void)
lock_toggled:(NSButton *)sender
{
    if (!self.current_url) return;
    BOOL lock = (sender.state == NSControlStateValueOn);
    NSError *err = nil;
    BOOL ok = [self.current_url setResourceValue:@(lock)
                                          forKey:NSURLIsUserImmutableKey
                                           error:&err];
    if (!ok) {
        files_show_error(@"Could not change lock status", err, self.window);
        sender.state = lock ? NSControlStateValueOff : NSControlStateValueOn;
    }
    [self update_editable_state];
}

/*
 * controlTextDidEndEditing: — commits edits from the name field (rename) or
 * an xattr table cell (key rename or value update). Escape (NSCancelTextMovement)
 * is a no-op here because doCommandBySelector: already reverted and aborted.
 *
 * Inputs:
 *   obj — notification from the text field that finished editing
 */
- (void)
controlTextDidEndEditing:(NSNotification *)obj
{
    /* Escape: the field already reverted its text; nothing to commit. */
    if ([obj.userInfo[@"NSTextMovement"] integerValue] == NSCancelTextMovement) {
        self.xattr_editing_row = -1;
        self.xattr_editing_col = -1;
        return;
    }

    if (obj.object == self.name_field) {
        NSString *new_name = self.name_field.stringValue;
        NSURL *old_url     = self.current_url;
        if (!old_url || new_name.length == 0) return;
        if ([new_name isEqualToString:old_url.lastPathComponent]) return;

        [FilesFileOps rename_url:old_url
                              to:new_name
                      completion:^(NSURL *new_url, NSError *err) {
            if (err) files_show_error(@"Rename failed", err, self.window);
            if (![self.current_url isEqual:old_url]) return;
            if (err) {
                self.name_field.stringValue = old_url.lastPathComponent;
            } else {
                self.current_url = new_url;
            }
        }];
        return;
    }

    if (obj.object == self.comment_field) {
        NSString *comment = self.comment_field.stringValue;
        if (self.current_url && ![comment isEqualToString:self.comment_original]) {
            files_set_finder_comment(self.current_url, comment);
            self.comment_original = comment;
        }
        return;
    }

    /* xattr table cell */
    NSInteger row = self.xattr_editing_row;
    NSInteger col = self.xattr_editing_col;
    self.xattr_editing_row = -1;
    self.xattr_editing_col = -1;
    if (row < 0 || row >= (NSInteger)self.xattr_keys.count) return;

    NSTextField *tf = (NSTextField *)obj.object;
    if (![self xattr_commit_edit:row col:col text:tf.stringValue])
        [self xattr_revert_cell:row col:col];
}

/*
 * control:textView:doCommandBySelector: — in the name field, Return commits
 * the rename and Escape restores the current name; either way editing ends
 * and the field loses focus (instead of AppKit re-selecting all the text).
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
    (void)textView;
    if (control == self.name_field) {
        if (cmd == @selector(cancelOperation:)) {
            [self.name_field abortEditing];
            self.name_field.stringValue = self.current_url.lastPathComponent ?: @"";
        } else if (cmd != @selector(insertNewline:)) {
            return NO;
        }
        [self.window makeFirstResponder:nil];
        return YES;
    }
    if (control == self.comment_field) {
        if (cmd == @selector(cancelOperation:)) {
            [self.comment_field abortEditing];
            self.comment_field.stringValue = self.comment_original ?: @"";
        } else if (cmd != @selector(insertNewline:)) {
            return NO;
        }
        [self.window makeFirstResponder:nil];
        return YES;
    }
    /* Escape in an xattr cell: revert text and abort editing. */
    if (cmd == @selector(cancelOperation:) && self.xattr_editing_row >= 0) {
        NSInteger row = self.xattr_editing_row;
        NSInteger col = self.xattr_editing_col;
        self.xattr_editing_row = -1;
        self.xattr_editing_col = -1;
        [self xattr_revert_cell:row col:col];
        [self.xattr_table abortEditing];
        return YES;
    }
    return NO;
}

/*
 * windowWillClose: — stops any in-flight hash read when the panel closes so
 * a multi-GB file is not read to the end for nobody.
 *
 * Inputs:
 *   notification — NSWindowWillCloseNotification for the panel (unused)
 */
- (void)
windowWillClose:(NSNotification *)notification
{
    [self cancel_hash_job];
}

/* ── Extended Attributes ─────────────────────────────────────────────── */

/*
 * make_xattr_cell_view — creates a reusable NSTableCellView with an editable
 * text field that has self as its delegate.
 *
 * Output: configured NSTableCellView.
 */
- (NSTableCellView *)
make_xattr_cell_view
{
    NSTableCellView *cell = [[NSTableCellView alloc] init];
    NSTextField *tf = [NSTextField textFieldWithString:@""];
    tf.font            = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    tf.bordered        = NO;
    tf.drawsBackground = NO;
    tf.lineBreakMode   = NSLineBreakByTruncatingTail;
    tf.delegate        = self;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:tf];
    cell.textField = tf;
    [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor  constant:2.0],
        [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2.0],
        [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

/*
 * xattr_update_disclosure_title — sets the disclosure button title to reflect
 * whether the section is expanded or collapsed.
 */
- (void)
xattr_update_disclosure_title
{
    BOOL open = (self.xattr_disclosure.state == NSControlStateValueOn);
    self.xattr_disclosure.title = open ? @"▾  Extended Attributes"
                                       : @"▸  Extended Attributes";
}

/*
 * build_xattr_section — creates the Extended Attributes collapsible section:
 * a disclosure toggle, a two-column table in a scroll view, and an +/−/
 * Clear All toolbar below it. Returns the section's root view.
 *
 * Output: root NSView to add to the panel's main stack.
 */
- (NSView *)
build_xattr_section
{
    self.xattr_editing_row = -1;
    self.xattr_editing_col = -1;
    self.xattr_keys = [NSMutableArray array];
    self.xattr_vals = [NSMutableArray array];

    /* Disclosure toggle */
    self.xattr_disclosure             = [[NSButton alloc] init];
    self.xattr_disclosure.buttonType  = NSButtonTypeOnOff;
    self.xattr_disclosure.bordered    = NO;
    self.xattr_disclosure.font        = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
    self.xattr_disclosure.alignment   = NSTextAlignmentLeft;
    self.xattr_disclosure.target      = self;
    self.xattr_disclosure.action      = @selector(xattr_disclosure_toggled:);
    [self xattr_update_disclosure_title];

    /* Table */
    NSTableView *tv       = [[NSTableView alloc] initWithFrame:NSZeroRect];
    tv.dataSource         = self;
    tv.delegate           = self;
    tv.rowHeight          = 18.0;
    tv.intercellSpacing   = NSMakeSize(6.0, 2.0);
    tv.doubleAction       = @selector(xattr_double_click:);
    tv.target             = self;
    tv.allowsMultipleSelection = YES;
    /* NoColumnAutoresizing keeps columns at their set widths; combined with
     * hasHorizontalScroller this lets the table scroll sideways when content
     * is wider than the panel rather than squashing columns to fit. */
    tv.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    tv.usesAlternatingRowBackgroundColors = YES;
    self.xattr_table = tv;

    NSTableColumn *key_col = [[NSTableColumn alloc] initWithIdentifier:@"key"];
    key_col.title        = @"Attribute";
    key_col.minWidth     = 60.0;
    key_col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    NSTableColumn *val_col = [[NSTableColumn alloc] initWithIdentifier:@"val"];
    val_col.title        = @"Value";
    val_col.minWidth     = 60.0;
    val_col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [tv addTableColumn:key_col];
    [tv addTableColumn:val_col];

    NSScrollView *scroll       = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView        = tv;
    scroll.hasVerticalScroller   = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers    = YES;
    scroll.borderType          = NSBezelBorder;
    [scroll.heightAnchor constraintEqualToConstant:120.0].active = YES;

    /* Toolbar: leading spacer pushes buttons to the right */
    self.xattr_add_btn    = make_xattr_btn(@"+",        self, @selector(xattr_add:));
    NSButton *add_btn     = self.xattr_add_btn;
    self.xattr_delete_btn = make_xattr_btn(@"−",        self, @selector(xattr_delete:));
    self.xattr_clear_btn  = make_xattr_btn(@"Clear All", self, @selector(xattr_clear:));
    self.xattr_delete_btn.enabled = NO;
    self.xattr_clear_btn.enabled  = NO;

    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *btn_row = [NSStackView stackViewWithViews:@[
        spacer, add_btn, self.xattr_delete_btn, self.xattr_clear_btn
    ]];
    btn_row.spacing   = 4.0;
    btn_row.alignment = NSLayoutAttributeCenterY;

    /* Container (scroll + toolbar) */
    NSStackView *container = [NSStackView stackViewWithViews:@[scroll, btn_row]];
    container.orientation  = NSUserInterfaceLayoutOrientationVertical;
    container.spacing      = 4.0;
    container.alignment    = NSLayoutAttributeLeading;
    [scroll.widthAnchor  constraintEqualToAnchor:container.widthAnchor].active = YES;
    [btn_row.widthAnchor constraintEqualToAnchor:container.widthAnchor].active = YES;
    container.hidden   = YES;
    self.xattr_container = container;

    /* Section root (disclosure + container) */
    NSStackView *section = [NSStackView stackViewWithViews:@[self.xattr_disclosure, container]];
    section.orientation  = NSUserInterfaceLayoutOrientationVertical;
    section.spacing      = 6.0;
    section.alignment    = NSLayoutAttributeLeading;
    [self.xattr_disclosure.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
    [container.widthAnchor             constraintEqualToAnchor:section.widthAnchor].active = YES;

    return section;
}

/*
 * xattr_disclosure_toggled: — shows or hides the xattr table and resizes the
 * panel to fit.
 *
 * Inputs:
 *   sender — the disclosure button (state already toggled)
 */
- (IBAction)
xattr_disclosure_toggled:(NSButton *)sender
{
    (void)sender;
    self.xattr_container.hidden = (self.xattr_disclosure.state != NSControlStateValueOn);
    [self xattr_update_disclosure_title];
    [self fit_window];
}

/*
 * reload_xattrs — reads all extended attributes for the current item via
 * listxattr/getxattr (XATTR_NOFOLLOW) into xattr_keys/xattr_vals, then
 * reloads the table.
 */
- (void)
reload_xattrs
{
    [self.xattr_keys removeAllObjects];
    [self.xattr_vals removeAllObjects];

    if (self.current_url) {
        const char *path = self.current_url.fileSystemRepresentation;
        ssize_t list_size = listxattr(path, NULL, 0, XATTR_NOFOLLOW);
        if (list_size > 0) {
            char *list = malloc((size_t)list_size);
            if (list) {
                ssize_t got = listxattr(path, list, (size_t)list_size, XATTR_NOFOLLOW);
                if (got > 0) {
                    char *p = list, *end = list + got;
                    while (p < end) {
                        NSString *key = @(p);
                        p += strlen(p) + 1;
                        ssize_t vsz = getxattr(path, key.UTF8String,
                                               NULL, 0, 0, XATTR_NOFOLLOW);
                        NSData *data = [NSData data];
                        if (vsz > 0) {
                            NSMutableData *md = [NSMutableData dataWithLength:(NSUInteger)vsz];
                            ssize_t n = getxattr(path, key.UTF8String, md.mutableBytes,
                                                 (size_t)vsz, 0, XATTR_NOFOLLOW);
                            if (n >= 0)
                                data = [md subdataWithRange:NSMakeRange(0, (NSUInteger)n)];
                        }
                        [self.xattr_keys addObject:key];
                        [self.xattr_vals addObject:data];
                    }
                }
                free(list);
            }
        }
    }

    [self.xattr_table reloadData];
    [self update_xattr_buttons];
}

/*
 * update_xattr_buttons — enables or disables the delete and clear buttons to
 * match the current selection and row count.
 */
- (void)
update_xattr_buttons
{
    BOOL editable = (self.lock_check.state != NSControlStateValueOn);
    self.xattr_add_btn.enabled    = editable;
    self.xattr_delete_btn.enabled = editable && (self.xattr_table.selectedRowIndexes.count > 0);
    self.xattr_clear_btn.enabled  = editable && (self.xattr_keys.count > 0);
}

/*
 * xattr_double_click: — begins editing the clicked key or value cell.
 *
 * Inputs:
 *   sender — the table view (unused)
 */
- (void)
xattr_double_click:(id)sender
{
    (void)sender;
    if (self.lock_check.state == NSControlStateValueOn) return;
    NSInteger row = self.xattr_table.clickedRow;
    NSInteger col = self.xattr_table.clickedColumn;
    if (row < 0 || row >= (NSInteger)self.xattr_keys.count) return;
    if (col < 0 || col > 1) return;
    self.xattr_editing_row = row;
    self.xattr_editing_col = col;
    [self.xattr_table editColumn:col row:row withEvent:nil select:YES];
}

/*
 * xattr_commit_edit:col:text: — writes an edited key or value to disk and
 * updates the local arrays. On error, reverts the cell and shows a sheet.
 * Returns YES on success.
 *
 * Inputs:
 *   row  — row index
 *   col  — 0 = key column, 1 = value column
 *   text — new string the user typed
 *
 * Output: YES if the write succeeded.
 */
- (BOOL)
xattr_commit_edit:(NSInteger)row col:(NSInteger)col text:(NSString *)text
{
    const char *path = self.current_url.fileSystemRepresentation;

    if (col == 0) {  /* key rename */
        NSString *old_key = self.xattr_keys[(NSUInteger)row];
        if ([text isEqualToString:old_key]) return YES;
        if (text.length == 0) return NO;
        if ([self.xattr_keys containsObject:text]) {
            files_show_error([NSString stringWithFormat:@"Attribute \"%@\" already exists", text],
                             nil, self.window);
            return NO;
        }
        NSData *val = self.xattr_vals[(NSUInteger)row];
        if (setxattr(path, text.UTF8String, val.bytes, val.length, 0, XATTR_NOFOLLOW) != 0) {
            files_show_error(@"Could not rename attribute",
                             [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil],
                             self.window);
            return NO;
        }
        removexattr(path, old_key.UTF8String, XATTR_NOFOLLOW);
        self.xattr_keys[(NSUInteger)row] = text;

    } else {  /* value edit */
        NSString *key    = self.xattr_keys[(NSUInteger)row];
        NSData *new_data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        if (setxattr(path, key.UTF8String, new_data.bytes, new_data.length,
                     0, XATTR_NOFOLLOW) != 0) {
            files_show_error(@"Could not set attribute value",
                             [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil],
                             self.window);
            return NO;
        }
        self.xattr_vals[(NSUInteger)row] = new_data;
    }
    return YES;
}

/*
 * xattr_revert_cell:col: — restores a table cell's text field to the value in
 * xattr_keys/xattr_vals (after a failed commit or an Escape).
 *
 * Inputs:
 *   row — row index
 *   col — 0 = key, 1 = value
 */
- (void)
xattr_revert_cell:(NSInteger)row col:(NSInteger)col
{
    NSTableCellView *cell = [self.xattr_table viewAtColumn:col
                                                       row:row
                                          makeIfNecessary:NO];
    if (!cell) return;
    cell.textField.stringValue = (col == 0)
        ? self.xattr_keys[(NSUInteger)row]
        : xattr_val_string(self.xattr_vals[(NSUInteger)row]);
}

/*
 * xattr_add: — writes a new xattr with a unique placeholder key, adds it to
 * the table, and begins editing its key cell.
 *
 * Inputs:
 *   sender — the + button (unused)
 */
- (IBAction)
xattr_add:(id)sender
{
    (void)sender;
    if (!self.current_url) return;

    NSString *key  = @"new.attribute";
    NSInteger n    = 1;
    while ([self.xattr_keys containsObject:key])
        key = [NSString stringWithFormat:@"new.attribute.%ld", (long)n++];

    const char *path = self.current_url.fileSystemRepresentation;
    if (setxattr(path, key.UTF8String, "", 0, 0, XATTR_NOFOLLOW) != 0) {
        files_show_error(@"Could not add attribute",
                         [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil],
                         self.window);
        return;
    }
    [self.xattr_keys addObject:key];
    [self.xattr_vals addObject:[NSData data]];
    NSInteger new_row = (NSInteger)self.xattr_keys.count - 1;
    [self.xattr_table reloadData];
    [self.xattr_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)new_row]
                  byExtendingSelection:NO];
    [self.xattr_table scrollRowToVisible:new_row];
    self.xattr_editing_row = new_row;
    self.xattr_editing_col = 0;
    [self.xattr_table editColumn:0 row:new_row withEvent:nil select:YES];
    [self update_xattr_buttons];
}

/*
 * xattr_delete: — removes all selected xattrs from disk and from the table.
 *
 * Inputs:
 *   sender — the − button (unused)
 */
- (IBAction)
xattr_delete:(id)sender
{
    (void)sender;
    if (!self.current_url) return;
    NSIndexSet *sel = self.xattr_table.selectedRowIndexes;
    if (sel.count == 0) return;
    const char *path = self.current_url.fileSystemRepresentation;
    [sel enumerateIndexesWithOptions:NSEnumerationReverse
                          usingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop;
        removexattr(path, self.xattr_keys[idx].UTF8String, XATTR_NOFOLLOW);
        [self.xattr_keys removeObjectAtIndex:idx];
        [self.xattr_vals removeObjectAtIndex:idx];
    }];
    [self.xattr_table reloadData];
    [self update_xattr_buttons];
}

/*
 * xattr_clear: — removes every xattr on the current item.
 *
 * Inputs:
 *   sender — the Clear All button (unused)
 */
- (IBAction)
xattr_clear:(id)sender
{
    (void)sender;
    if (!self.current_url || self.xattr_keys.count == 0) return;
    const char *path = self.current_url.fileSystemRepresentation;
    for (NSString *key in self.xattr_keys)
        removexattr(path, key.UTF8String, XATTR_NOFOLLOW);
    [self.xattr_keys removeAllObjects];
    [self.xattr_vals removeAllObjects];
    [self.xattr_table reloadData];
    [self update_xattr_buttons];
}

/* ── NSTableViewDataSource ───────────────────────────────────────────── */

/*
 * numberOfRowsInTableView: — Output: the number of extended attributes.
 */
- (NSInteger)
numberOfRowsInTableView:(NSTableView *)tv
{
    (void)tv;
    return (NSInteger)self.xattr_keys.count;
}

/* ── NSTableViewDelegate ─────────────────────────────────────────────── */

/*
 * tableView:viewForTableColumn:row: — returns a cell view with the attribute
 * key or value string. Reuses views by identifier.
 */
- (NSView *)
tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    (void)tv;
    BOOL is_key = [col.identifier isEqualToString:@"key"];
    NSString *ident = is_key ? @"xk" : @"xv";
    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell            = [self make_xattr_cell_view];
        cell.identifier = ident;
    }
    cell.textField.delegate    = self;
    cell.textField.stringValue = is_key
        ? self.xattr_keys[(NSUInteger)row]
        : xattr_val_string(self.xattr_vals[(NSUInteger)row]);
    return cell;
}

/*
 * tableViewSelectionDidChange: — updates delete/clear button enabled state
 * when the selection changes.
 */
- (void)
tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    [self update_xattr_buttons];
}

@end
