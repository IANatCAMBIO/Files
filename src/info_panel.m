#import "info_panel.h"
#import "file_ops.h"
#import "file_hash.h"
#import "git_info.h"
#import "util.h"
#include <sys/stat.h>
#include <errno.h>
#include <stdatomic.h>

/* ── layout constants ────────────────────────────────────────────────── */
static const CGFloat panel_width    = 360.0;
static const CGFloat row_h          = 22.0;
static const CGFloat label_w        = 110.0;
static const CGFloat margin         = 16.0;
static const CGFloat icon_size      = 64.0;
static const CGFloat small_label_h  = 11.0; /* height of per-popup sub-labels */
static const CGFloat copy_w         = 30.0; /* width of "copy" link button */
static const CGFloat copy_gap       =  4.0; /* gap between hash field and copy btn */
static const CGFloat git_sep_gap    =  8.0; /* space for the separator above Git rows */

/* Indices into the row_keys table built in -init. The Git rows come last
 * (below the checkboxes) so shrinking the panel hides them. */
enum {
    row_kind, row_size, row_where, row_created, row_modified,
    row_permissions, row_owner, row_group, row_sha256, row_md5,
    row_git, row_branch, row_pushed,
    row_count
};
static const NSUInteger git_row_count = row_count - row_git;

/* Tags on the two "copy" buttons; copy_hash_action: selects the field by tag. */
enum {
    copy_tag_sha256 = 1,
    copy_tag_md5    = 2,
};

/* ── row builder helpers ─────────────────────────────────────────────── */

/*
 * make_label — creates a right-aligned, bold label for the key column.
 *
 * Inputs:
 *   text  — label text
 *   frame — frame rect
 *
 * Output: configured NSTextField.
 */
static NSTextField *
make_label(NSString *text, NSRect frame)
{
    NSTextField *tf = [[NSTextField alloc] initWithFrame:frame];
    tf.stringValue       = text;
    tf.editable          = NO;
    tf.bordered          = NO;
    tf.drawsBackground   = NO;
    tf.alignment         = NSTextAlignmentRight;
    tf.font              = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
    tf.textColor         = NSColor.secondaryLabelColor;
    tf.lineBreakMode     = NSLineBreakByClipping;
    return tf;
}

/*
 * make_value — creates a left-aligned value text field.
 *
 * Inputs:
 *   frame — frame rect
 *
 * Output: configured NSTextField.
 */
static NSTextField *
make_value(NSRect frame)
{
    NSTextField *tf = [[NSTextField alloc] initWithFrame:frame];
    tf.stringValue       = @"";
    tf.editable          = NO;
    tf.bordered          = NO;
    tf.drawsBackground   = NO;
    tf.alignment         = NSTextAlignmentLeft;
    tf.font              = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    tf.lineBreakMode     = NSLineBreakByTruncatingMiddle;
    return tf;
}

/* ── copy-link button helper ─────────────────────────────────────────── */

/*
 * make_copy_btn — creates a borderless link-styled "copy" button.
 *
 * Inputs:
 *   frame  — button frame
 *   target — action target
 *   action — selector to call on click
 *   tag    — button tag the action uses to tell the buttons apart
 *
 * Output: configured NSButton.
 */
static NSButton *
make_copy_btn(NSRect frame, id target, SEL action, NSInteger tag)
{
    NSButton *btn  = [[NSButton alloc] initWithFrame:frame];
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

/* ── FilesVCenterCell — NSTextFieldCell that vertically centers text ─── */

@interface FilesVCenterCell : NSTextFieldCell
@end

@implementation FilesVCenterCell {
    /* YES while the field editor is being placed: its frame arrives already
     * centered, so drawingRectForBounds: must not center it again. */
    BOOL _placing_editor;
}

/*
 * drawingRectForBounds: — shrinks the drawing rect to the natural text height
 * and centers it vertically within bounds.
 *
 * Inputs:
 *   bounds — full cell bounds
 *
 * Output: adjusted rect for text drawing.
 */
- (NSRect)
drawingRectForBounds:(NSRect)bounds
{
    NSRect r = [super drawingRectForBounds:bounds];
    if (_placing_editor) return r;
    NSSize  sz = [super cellSizeForBounds:bounds];
    CGFloat dy = floor((r.size.height - sz.height) / 2.0);
    if (dy > 0) {
        r.origin.y    += dy;
        r.size.height -= dy * 2.0;
    }
    return r;
}

/*
 * editWithFrame:inView:editor:delegate:event: — places the field editor in
 * the same vertically centered rect the text is drawn in, so the text does
 * not jump when editing starts.
 *
 * Inputs:
 *   frame, view, editor, delegate, event — as for NSCell
 */
- (void)
editWithFrame:(NSRect)frame inView:(NSView *)view editor:(NSText *)editor
     delegate:(id)delegate event:(NSEvent *)event
{
    NSRect centered = [self drawingRectForBounds:frame];
    _placing_editor = YES;
    [super editWithFrame:centered inView:view editor:editor delegate:delegate event:event];
    _placing_editor = NO;
}

/*
 * selectWithFrame:inView:editor:delegate:start:length: — as
 * editWithFrame:…, for editing that begins with a selection (tabbing or
 * clicking into the field).
 *
 * Inputs:
 *   frame, view, editor, delegate, start, length — as for NSCell
 */
- (void)
selectWithFrame:(NSRect)frame inView:(NSView *)view editor:(NSText *)editor
       delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length
{
    NSRect centered = [self drawingRectForBounds:frame];
    _placing_editor = YES;
    [super selectWithFrame:centered inView:view editor:editor delegate:delegate
                     start:start length:length];
    _placing_editor = NO;
}

@end

/* ── FilesHashJob — cancel flag shared with one background hash pass ──── */

/*
 * FilesHashJob — owns the atomic cancel flag polled by file_digests(). The
 * background block holds a strong reference, so the flag stays valid for the
 * whole read even after the panel has moved on and dropped its reference.
 */
@interface FilesHashJob : NSObject
- (const atomic_int *)cancel_flag;
- (void)cancel;
@end

@implementation FilesHashJob {
    atomic_int _cancel;
}

/*
 * cancel_flag — exposes the flag for file_digests() to poll.
 *
 * Output: pointer to the job's cancel flag, valid while the job is alive.
 */
- (const atomic_int *)
cancel_flag
{
    return &_cancel;
}

/*
 * cancel — asks the running file_digests() pass to stop at its next read.
 */
- (void)
cancel
{
    atomic_store(&_cancel, 1);
}

@end

/* ── FilesInfoPanel ──────────────────────────────────────────────────── */

@interface FilesInfoPanel () <NSTextFieldDelegate, NSWindowDelegate>

@property (nonatomic, strong) NSURL       *current_url;
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
@property (nonatomic, strong) FilesHashJob *hash_job; /* in-flight hash; stale guard */
@property (nonatomic, strong) NSTextField *git_value;
@property (nonatomic, strong) NSTextField *branch_value;
@property (nonatomic, strong) NSTextField *pushed_value;
@property (nonatomic, assign) NSUInteger   git_generation; /* stale guard for git reads */
@property (nonatomic, assign) CGFloat      git_section_h;  /* height the Git rows add */
@property (nonatomic, assign) BOOL         git_section_shown;
@property (nonatomic, strong) NSArray<NSView *> *git_views; /* separator, labels, values */

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
 * init — creates the panel window and all subviews programmatically.
 *
 * Output: self, or nil if the window controller could not be initialised.
 */
- (instancetype)
init
{
    NSString * const row_keys[row_count] = {
        [row_kind]        = @"Kind:",
        [row_size]        = @"Size:",
        [row_where]       = @"Where:",
        [row_created]     = @"Created:",
        [row_modified]    = @"Modified:",
        [row_permissions] = @"Permissions:",
        [row_owner]       = @"Owner:",
        [row_group]       = @"Group:",
        [row_sha256]      = @"SHA-256:",
        [row_md5]         = @"MD5:",
        [row_git]         = @"Git:",
        [row_branch]      = @"Branch:",
        [row_pushed]      = @"Pushed:",
    };
    CGFloat git_section_h = git_sep_gap + git_row_count * (row_h + 4);
    CGFloat content_h    = margin                  /* top margin */
                         + icon_size + margin      /* icon row */
                         + (row_count * (row_h + 4)) /* attribute rows */
                         + small_label_h + 2.0     /* extra for perm sub-labels */
                         + (row_h + 4) * 2         /* lock + hash checkboxes */
                         + git_sep_gap             /* separator above Git rows */
                         + margin;                 /* bottom margin */

    NSRect win_rect = NSMakeRect(0, 0, panel_width, content_h);
    NSPanel *panel  = [[NSPanel alloc]
                           initWithContentRect:win_rect
                                     styleMask:NSWindowStyleMaskTitled
                                              | NSWindowStyleMaskClosable
                                              | NSWindowStyleMaskUtilityWindow
                                       backing:NSBackingStoreBuffered
                                         defer:NO];
    panel.title            = @"Info";
    panel.releasedWhenClosed = NO;
    panel.level            = NSFloatingWindowLevel;
    [panel setContentSize:NSMakeSize(panel_width, content_h)];

    self = [super initWithWindow:panel];
    if (!self) {
        return nil;
    }
    panel.delegate = self;

    NSView *cv = panel.contentView;
    CGFloat x_label = margin;
    CGFloat x_value = margin + label_w + 8.0;
    CGFloat w_value = panel_width - x_value - margin;

    /* Icon + name at top. */
    CGFloat icon_y = content_h - margin - icon_size;
    NSRect icon_rect = NSMakeRect(margin, icon_y, icon_size, icon_size);
    self.icon_view                    = [[NSImageView alloc] initWithFrame:icon_rect];
    self.icon_view.imageScaling       = NSImageScaleProportionallyUpOrDown;
    [cv addSubview:self.icon_view];

    CGFloat name_x = margin + icon_size + 12.0;
    CGFloat name_w = panel_width - name_x - margin;
    CGFloat name_y = icon_y + (icon_size - row_h) / 2.0;
    NSRect name_box_rect = NSMakeRect(name_x, name_y, name_w, row_h);

    /* Rounded container — NSBoxCustom adapts its colors to dark/light mode. */
    NSBox *name_box         = [[NSBox alloc] initWithFrame:name_box_rect];
    name_box.boxType        = NSBoxCustom;
    name_box.cornerRadius   = 6.0;
    name_box.borderWidth    = 0.5;
    name_box.borderColor    = NSColor.separatorColor;
    name_box.fillColor      = NSColor.controlBackgroundColor;
    name_box.contentViewMargins = NSZeroSize;
    [cv addSubview:name_box];

    NSRect name_rect = NSMakeRect(5.0, 1.0, name_w - 10.0, row_h - 2.0);
    self.name_field                   = [[NSTextField alloc] initWithFrame:name_rect];
    /* Swap in the centering cell before setting any cell-derived properties. */
    FilesVCenterCell *name_cell       = [[FilesVCenterCell alloc] init];
    name_cell.editable                = YES;
    name_cell.selectable              = YES;
    [self.name_field setCell:name_cell];
    self.name_field.font              = [NSFont boldSystemFontOfSize:13.0];
    self.name_field.bordered          = NO;
    self.name_field.drawsBackground   = NO;
    self.name_field.focusRingType     = NSFocusRingTypeNone;
    self.name_field.delegate          = self;
    self.name_field.lineBreakMode     = NSLineBreakByTruncatingMiddle;
    [name_box addSubview:self.name_field];

    /* Attribute rows; fields[i] is the value field of row i (nil for the
     * permissions row, which uses popups instead). */
    NSTextField *fields[row_count] = { nil };
    NSMutableArray<NSView *> *git_views = [NSMutableArray array];
    CGFloat row_y = icon_y - margin;

    for (NSUInteger i = 0; i < row_count; i++) {
        if (i == row_git) {
            /* Lock and Show Hashes checkboxes, then a separator, between the
             * file rows and the Git section. */
            row_y -= (row_h + 4.0);
            NSRect lock_rect = NSMakeRect(x_value, row_y, w_value, row_h);
            self.lock_check = [NSButton checkboxWithTitle:@"Locked" target:self
                                                   action:@selector(lock_toggled:)];
            self.lock_check.frame = lock_rect;
            [cv addSubview:self.lock_check];

            row_y -= (row_h + 4.0);
            NSRect hash_rect = NSMakeRect(x_value, row_y, w_value, row_h);
            self.hash_check = [NSButton checkboxWithTitle:@"Show Hashes (SHA-256 / MD5)"
                                                   target:self
                                                   action:@selector(hash_check_toggled:)];
            self.hash_check.frame = hash_rect;
            self.hash_check.state = [NSUserDefaults.standardUserDefaults
                                        boolForKey:files_pref_show_hashes]
                                    ? NSControlStateValueOn : NSControlStateValueOff;
            [cv addSubview:self.hash_check];

            row_y -= git_sep_gap;
            NSBox *git_sep  = [[NSBox alloc] initWithFrame:NSMakeRect(margin, row_y + git_sep_gap / 2.0,
                                                                      panel_width - margin * 2.0, 1.0)];
            git_sep.boxType = NSBoxSeparator;
            [cv addSubview:git_sep];
            [git_views addObject:git_sep];
        }

        row_y -= (row_h + 4.0);
        NSRect lr = NSMakeRect(x_label, row_y, label_w, row_h);
        NSTextField *label = make_label(row_keys[i], lr);
        [cv addSubview:label];

        if (i == row_permissions) {
            /* Three side-by-side NSPopUpButton controls: owner | group | other.
             * Each takes one third of the value column width with a small gap. */
            CGFloat gap         = 6.0;
            CGFloat pop_w       = (w_value - 2.0 * gap) / 3.0;
            NSString * const tips[3] = { @"Owner", @"Group", @"Other" };
            NSPopUpButton *btns[3];
            for (int p = 0; p < 3; p++) {
                CGFloat px    = x_value + p * (pop_w + gap);
                NSRect pr     = NSMakeRect(px, row_y, pop_w, row_h);
                NSPopUpButton *btn = [[NSPopUpButton alloc] initWithFrame:pr pullsDown:NO];
                btn.font    = [NSFont monospacedSystemFontOfSize:11.0
                                                         weight:NSFontWeightRegular];
                btn.toolTip = tips[p];
                for (NSUInteger t = 0; t < 8; t++) {
                    [btn addItemWithTitle:perm_items[t]];
                    [[btn itemAtIndex:(NSInteger)t] setTag:(NSInteger)t];
                }
                btn.target = self;
                btn.action = @selector(perms_popup_changed:);
                [cv addSubview:btn];
                btns[p] = btn;
            }
            self.owner_perms_popup = btns[0];
            self.group_perms_popup = btns[1];
            self.other_perms_popup = btns[2];

            /* Small centered labels below each popup. */
            row_y -= (small_label_h + 2.0);
            for (int p = 0; p < 3; p++) {
                CGFloat px  = x_value + p * (pop_w + gap);
                NSRect slr  = NSMakeRect(px, row_y, pop_w, small_label_h);
                NSTextField *sl = [NSTextField labelWithString:tips[p]];
                sl.frame       = slr;
                sl.alignment   = NSTextAlignmentCenter;
                sl.font        = [NSFont systemFontOfSize:9.0];
                sl.textColor   = NSColor.tertiaryLabelColor;
                [cv addSubview:sl];
            }
            continue;
        }

        BOOL is_hash = (i == row_sha256 || i == row_md5);
        CGFloat fw = is_hash ? (w_value - copy_w - copy_gap) : w_value;
        NSRect vr = NSMakeRect(x_value, row_y, fw, row_h);
        fields[i] = make_value(vr);
        [cv addSubview:fields[i]];
        if (i >= row_git) [git_views addObjectsFromArray:@[label, fields[i]]];

        if (is_hash) {
            NSRect br = NSMakeRect(x_value + fw + copy_gap, row_y, copy_w, row_h);
            NSInteger tag = (i == row_sha256) ? copy_tag_sha256 : copy_tag_md5;
            [cv addSubview:make_copy_btn(br, self, @selector(copy_hash_action:), tag)];
        }
    }

    self.kind_value      = fields[row_kind];
    self.size_value      = fields[row_size];
    self.where_value     = fields[row_where];
    self.created_value   = fields[row_created];
    self.modified_value  = fields[row_modified];
    self.owner_value     = fields[row_owner];
    self.group_value     = fields[row_group];
    self.sha256_value    = fields[row_sha256];
    self.md5_value       = fields[row_md5];
    self.git_value       = fields[row_git];
    self.branch_value    = fields[row_branch];
    self.pushed_value    = fields[row_pushed];

    /* Hash value fields: monospaced, tail-truncated with "…", selectable to copy. */
    NSFont *hash_font = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightRegular];
    for (NSTextField *hf in @[self.sha256_value, self.md5_value]) {
        hf.font          = hash_font;
        hf.selectable    = YES;
        hf.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    /* Separator below icon. */
    NSBox *sep        = [[NSBox alloc] initWithFrame:NSMakeRect(margin, icon_y - 8.0, panel_width - margin * 2.0, 1.0)];
    sep.boxType       = NSBoxSeparator;
    [cv addSubview:sep];

    /* Pin everything to the top edge so the panel can grow and shrink at the
     * bottom, where the Git section sits; it starts hidden. */
    for (NSView *v in cv.subviews) v.autoresizingMask = NSViewMinYMargin;
    for (NSView *v in git_views) v.hidden = YES;
    self.git_views     = git_views;
    self.git_section_h = git_section_h;
    [panel setContentSize:NSMakeSize(panel_width, content_h - git_section_h)];

    return self;
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
    FilesHashJob *job = [[FilesHashJob alloc] init];
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
     * time; drop them so the panel shows the item's current state. */
    [url removeAllCachedResourceValues];
    NSDictionary<NSURLResourceKey, id> *res =
        [url resourceValuesForKeys:keys error:nil];

    /* Icon */
    self.icon_view.image = files_icon_for_url(url);

    /* Name */
    self.name_field.stringValue = res[NSURLNameKey] ?: url.lastPathComponent;

    /* Kind */
    BOOL is_dir = [res[NSURLIsDirectoryKey] boolValue];
    self.kind_value.stringValue = is_dir ? @"Folder"
                                         : (res[NSURLLocalizedTypeDescriptionKey] ?: @"—");

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
    self.sha256_value.stringValue = @"—";
    self.md5_value.stringValue    = @"—";
    self.sha256_value.toolTip     = nil;
    self.md5_value.toolTip        = nil;
    if (!is_dir && [NSUserDefaults.standardUserDefaults boolForKey:files_pref_show_hashes]) {
        [self start_hash_job:url];
    }

    /* Git — shown only for the top folder of a git working tree. */
    self.git_generation++;
    BOOL is_git = files_is_git_repo(url);
    [self set_git_section_visible:is_git];
    if (is_git) [self start_git_job:url];
}

/*
 * set_git_section_visible: — grows or shrinks the panel at the bottom to
 * show or hide the Git rows, keeping its top edge in place. The rows are
 * also hidden, since the top of the section would otherwise show in the
 * bottom margin.
 *
 * Inputs:
 *   visible — YES to show the Git rows
 */
- (void)
set_git_section_visible:(BOOL)visible
{
    if (visible == self.git_section_shown) return;
    self.git_section_shown = visible;
    for (NSView *v in self.git_views) v.hidden = !visible;
    NSWindow *w  = self.window;
    NSRect   c   = [w contentRectForFrameRect:w.frame];
    CGFloat  dh  = visible ? self.git_section_h : -self.git_section_h;
    c.size.height += dh;
    c.origin.y    -= dh;
    [w setFrame:[w frameRectForContentRect:c] display:YES];
}

/*
 * start_git_job: — reads the branch and push state of repo on a background
 * queue and fills the Git rows when done, unless the panel has moved on to
 * another item (git_generation changed) in the meantime.
 *
 * Inputs:
 *   repo — git working-tree root
 */
- (void)
start_git_job:(NSURL *)repo
{
    NSUInteger gen = self.git_generation;
    self.git_value.stringValue    = @"Git folder detected";
    self.branch_value.stringValue = @"Checking…";
    self.pushed_value.stringValue = @"Checking…";
    self.branch_value.toolTip     = nil;
    self.pushed_value.toolTip     = nil;

    __weak FilesInfoPanel *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *branch = nil, *pushed = nil;
        BOOL ok = files_git_describe(repo, &branch, &pushed);
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesInfoPanel *s = ws;
            if (!s || s.git_generation != gen) return;
            if (!ok) {
                s.branch_value.stringValue = @"Unavailable (git could not read it)";
                s.pushed_value.stringValue = @"—";
                return;
            }
            /* Tooltips carry the full text, which may be truncated. */
            s.branch_value.stringValue = branch;
            s.branch_value.toolTip     = branch;
            s.pushed_value.stringValue = pushed;
            s.pushed_value.toolTip     = [pushed stringByAppendingString:
                @"\nCompared with the upstream branch as of the last fetch."];
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
 * hash_check_toggled: — saves the show-hashes preference and refreshes the
 * hash fields for the currently displayed file.
 *
 * Inputs:
 *   sender — the "Show Hashes" checkbox
 */
- (IBAction)
hash_check_toggled:(NSButton *)sender
{
    BOOL on = (sender.state == NSControlStateValueOn);
    [NSUserDefaults.standardUserDefaults setBool:on forKey:files_pref_show_hashes];
    if (self.current_url) [self populate_fields:self.current_url];
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
 * On failure shows an error sheet and restores the old name.
 *
 * Inputs:
 *   obj — notification from the name text field
 */
- (void)
controlTextDidEndEditing:(NSNotification *)obj
{
    if (obj.object != self.name_field) return;
    NSString *new_name = self.name_field.stringValue;
    if (!self.current_url || new_name.length == 0) return;
    if ([new_name isEqualToString:self.current_url.lastPathComponent]) return;

    [FilesFileOps rename_url:self.current_url
                          to:new_name
                  completion:^(NSURL *new_url, NSError *err) {
        if (err) {
            files_show_error(@"Rename failed", err, self.window);
            self.name_field.stringValue = self.current_url.lastPathComponent;
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
