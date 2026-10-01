#import "info_panel.h"
#import "file_ops.h"
#import "file_hash.h"
#import "git_info.h"
#import "util.h"
#include <sys/stat.h>
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

/* ── FilesInfoPanel ──────────────────────────────────────────────────── */

@interface FilesInfoPanel () <NSTextFieldDelegate, NSWindowDelegate>

@property (nonatomic, strong) NSURL       *current_url;
@property (nonatomic, assign) BOOL         current_is_dir;
@property (nonatomic, strong) NSImageView *icon_view;
@property (nonatomic, strong) NSTextField *name_field;
@property (nonatomic, strong) NSTextField *kind_value;
@property (nonatomic, strong) NSTextField *size_value;
@property (nonatomic, strong) NSTextField *where_value;
@property (nonatomic, strong) NSTextField *created_value;
@property (nonatomic, strong) NSTextField *modified_value;
@property (nonatomic, strong) NSPopUpButton *owner_perms_popup;
@property (nonatomic, strong) NSPopUpButton *group_perms_popup;
@property (nonatomic, strong) NSPopUpButton *other_perms_popup;
@property (nonatomic, strong) NSTextField *owner_value;
@property (nonatomic, strong) NSTextField *group_value;
@property (nonatomic, strong) NSTextField *sha256_value;
@property (nonatomic, strong) NSTextField *md5_value;
@property (nonatomic, strong) NSButton    *lock_check;
@property (nonatomic, strong) NSButton    *hash_check;
@property (nonatomic, strong) FilesCancelToken *hash_job; /* in-flight hash; stale guard */
@property (nonatomic, strong) NSTextField *branch_value;
@property (nonatomic, strong) NSTextField *pushed_value;
@property (nonatomic, strong) NSTextField *remote_value;
@property (nonatomic, assign) NSUInteger   git_generation; /* stale guard for git reads */
@property (nonatomic, strong) NSArray<NSGridRow *> *git_rows; /* separator, header, rows */

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
 * and Show Hashes checkboxes, and a Git section that is hidden except for
 * the top folder of a working tree). The panel is a fixed width and its
 * height follows the visible rows (fit_window).
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

    self.kind_value     = make_value();
    self.size_value     = make_value();
    self.where_value    = make_value();
    self.created_value  = make_value();
    self.modified_value = make_value();
    row(@"Kind:",     self.kind_value);
    row(@"Size:",     self.size_value);
    row(@"Where:",    self.where_value);
    row(@"Created:",  self.created_value);
    row(@"Modified:", self.modified_value);

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
    /* The popups' captions sit below them: align the label with the popups'
     * tops, not a baseline. */
    NSGridRow *perm_row  = row(@"Permissions:", perms);
    perm_row.rowAlignment = NSGridRowAlignmentNone;
    perm_row.yPlacement   = NSGridCellPlacementTop;

    self.owner_value = make_value();
    self.group_value = make_value();
    row(@"Owner:", self.owner_value);
    row(@"Group:", self.group_value);

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
    self.hash_check = [NSButton checkboxWithTitle:@"Show Hashes (SHA-256 / MD5)" target:self
                                           action:@selector(hash_check_toggled:)];
    self.hash_check.state = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hashes]
                            ? NSControlStateValueOn : NSControlStateValueOff;
    row(nil, self.lock_check);
    row(nil, self.hash_check);

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
    NSStackView *all = [NSStackView stackViewWithViews:@[top, sep, grid]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment   = NSLayoutAttributeLeading;
    all.spacing     = 10.0;
    all.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *cv = panel.contentView;
    [cv addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [all.topAnchor      constraintEqualToAnchor:cv.topAnchor constant:margin],
        [all.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor constant:margin],
        [all.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-margin],
        [all.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor constant:-margin],
        [cv.widthAnchor     constraintEqualToConstant:panel_width],
        [top.widthAnchor    constraintEqualToAnchor:all.widthAnchor],
        [sep.widthAnchor    constraintEqualToAnchor:all.widthAnchor],
        [grid.widthAnchor   constraintEqualToAnchor:all.widthAnchor],
    ]];
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
        NSURLIsDirectoryKey, NSURLLocalizedTypeDescriptionKey,
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

    /* Kind: "Folder" for folders, "Application" for apps and so on. */
    BOOL is_dir = [res[NSURLIsDirectoryKey] boolValue];
    self.current_is_dir = is_dir;
    self.kind_value.stringValue = res[NSURLLocalizedTypeDescriptionKey] ?: @"—";

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
        }
        self.owner_value.stringValue = attrs[NSFileOwnerAccountName] ?: @"—";
        self.group_value.stringValue = attrs[NSFileGroupOwnerAccountName] ?: @"—";
    } else {
        [self.owner_perms_popup selectItemWithTag:0];
        [self.group_perms_popup selectItemWithTag:0];
        [self.other_perms_popup selectItemWithTag:0];
        self.owner_value.stringValue = @"—";
        self.group_value.stringValue = @"—";
    }

    /* Lock — the user-immutable flag (uchg), same flag lock_toggled: sets.
     * Read-only permissions alone do not make an item "Locked". */
    self.lock_check.state = [res[NSURLIsUserImmutableKey] boolValue]
                            ? NSControlStateValueOn
                            : NSControlStateValueOff;

    /* Hashes — computed asynchronously when enabled and item is a file. The
     * tooltip doubles as "a real digest is present" for copy_hash_action:. */
    [self update_hashes];

    /* Git — shown only for the top folder of a git working tree. */
    self.git_generation++;
    BOOL is_git = files_is_git_repo(url);
    [self set_git_section_visible:is_git];
    if (is_git) [self start_git_job:url];
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
 * hash_check_toggled: — saves the show-hashes preference and starts or
 * stops hashing the current item (update_hashes); nothing else is re-read.
 *
 * Inputs:
 *   sender — the "Show Hashes" checkbox
 */
- (IBAction)
hash_check_toggled:(NSButton *)sender
{
    BOOL on = (sender.state == NSControlStateValueOn);
    [NSUserDefaults.standardUserDefaults setBool:on forKey:files_pref_show_hashes];
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
}

/*
 * controlTextDidEndEditing: — renames the file when the name field loses focus.
 * On failure shows an error sheet and restores the old name. The rename
 * finishes asynchronously; if the panel has moved on to another item by
 * then, its result is not applied to that item.
 *
 * Inputs:
 *   obj — notification from the name text field
 */
- (void)
controlTextDidEndEditing:(NSNotification *)obj
{
    if (obj.object != self.name_field) return;
    NSString *new_name = self.name_field.stringValue;
    NSURL *old_url     = self.current_url;
    if (!old_url || new_name.length == 0) return;
    if ([new_name isEqualToString:old_url.lastPathComponent]) return;

    [FilesFileOps rename_url:old_url
                          to:new_name
                  completion:^(NSURL *new_url, NSError *err) {
        if (err) files_show_error(@"Rename failed", err, self.window);
        if (![self.current_url isEqual:old_url]) return;  /* showing another item */
        if (err) {
            self.name_field.stringValue = old_url.lastPathComponent;
        } else {
            self.current_url = new_url;
        }
    }];
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
    if (control != self.name_field) return NO;
    if (cmd == @selector(cancelOperation:)) {
        [self.name_field abortEditing];
        self.name_field.stringValue = self.current_url.lastPathComponent ?: @"";
    } else if (cmd != @selector(insertNewline:)) {
        return NO;
    }
    [self.window makeFirstResponder:nil];  /* Return: ends editing -> rename */
    return YES;
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

@end
