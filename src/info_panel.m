#import "info_panel.h"
#import "file_ops.h"
#import "file_hash.h"
#include <sys/stat.h>
#include <errno.h>
#include <CommonCrypto/CommonDigest.h>

/* ── layout constants ────────────────────────────────────────────────── */
static const CGFloat kPanelWidth    = 360.0;
static const CGFloat kRowH          = 22.0;
static const CGFloat kLabelW        = 110.0;
static const CGFloat kMargin        = 16.0;
static const CGFloat kIconSize      = 64.0;
static const CGFloat kSmallLabelH   = 11.0; /* height of per-popup sub-labels */
static const CGFloat kCopyW         = 30.0; /* width of "copy" link button */
static const CGFloat kCopyGap       =  4.0; /* gap between hash field and copy btn */
static const NSUInteger kSha256Row  =  9;   /* index of SHA-256 row in row_keys */
static const NSUInteger kMd5Row     = 10;   /* index of MD5 row in row_keys */

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

/* ── hash helpers ────────────────────────────────────────────────────── */

/*
 * compute_md5_hex — streams a file through the CommonCrypto MD5 engine and
 * returns the lowercase 32-character hex digest.
 *
 * Inputs:
 *   path — null-terminated UTF-8 file path
 *
 * Output: 32-char hex NSString, or nil on I/O error.
 */
static NSString *
compute_md5_hex(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return nil;

    CC_MD5_CTX ctx;
    CC_MD5_Init(&ctx);

    uint8_t buf[65536];
    size_t  n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        CC_MD5_Update(&ctx, buf, (CC_LONG)n);
    fclose(f);

    uint8_t digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/* ── copy-link button helper ─────────────────────────────────────────── */

/*
 * make_copy_btn — creates a borderless link-styled "copy" button.
 *
 * Inputs:
 *   frame  — button frame
 *   target — action target
 *   action — selector to call on click
 *
 * Output: configured NSButton.
 */
static NSButton *
make_copy_btn(NSRect frame, id target, SEL action)
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
    return btn;
}

/* ── permissions helper ──────────────────────────────────────────────── */

/*
 * perms_popup_items — the 8 option strings for a single rwx triplet, ordered
 * by octal value 0-7, used as NSPopUpButton titles.
 */
static NSString * const kPermItems[] = {
    @"---", @"--x", @"-w-", @"-wx",
    @"r--", @"r-x", @"rw-", @"rwx",
};

/* ── VCenterCell — NSTextFieldCell that vertically centers single-line text ── */

@interface VCenterCell : NSTextFieldCell
@end

@implementation VCenterCell

/*
 * drawingRectForBounds: — shrinks the drawing rect to the natural text height
 * and centers it vertically within bounds.
 *
 * Inputs:
 *   bounds — full cell bounds
 *
 * Output: adjusted rect for text drawing/editing.
 */
- (NSRect)
drawingRectForBounds:(NSRect)bounds
{
    NSRect r   = [super drawingRectForBounds:bounds];
    NSSize sz  = [super cellSizeForBounds:bounds];
    CGFloat dy = floor((r.size.height - sz.height) / 2.0);
    if (dy > 0) {
        r.origin.y    += dy;
        r.size.height -= dy * 2.0;
    }
    return r;
}

@end

/* ── FilesInfoPanel ──────────────────────────────────────────────────── */

@interface FilesInfoPanel () <NSTextFieldDelegate>

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
@property (nonatomic, strong) NSTextField   *owner_value;
@property (nonatomic, strong) NSTextField *group_value;
@property (nonatomic, strong) NSTextField *sha256_value;
@property (nonatomic, strong) NSTextField *md5_value;
@property (nonatomic, strong) NSButton    *lock_check;
@property (nonatomic, strong) NSButton    *hash_check;
@property (nonatomic, strong) NSURL       *hash_url; /* URL being hashed; stale guard */

@end

@implementation FilesInfoPanel

/*
 * shared — returns the singleton panel instance.
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
 * Output: self
 */
- (instancetype)
init
{
    /* Build rows bottom-up; calculate total height. */
    NSArray<NSString *> *row_keys = @[
        @"Name:", @"Kind:", @"Size:", @"Where:",
        @"Created:", @"Modified:", @"Permissions:", @"Owner:", @"Group:",
        @"SHA-256:", @"MD5:",
    ];
    NSUInteger n_rows    = row_keys.count;
    CGFloat content_h    = kMargin              /* top margin */
                         + kIconSize + kMargin  /* icon row */
                         + (n_rows * (kRowH + 4)) /* attribute rows */
                         + kSmallLabelH + 2.0   /* extra for perm sub-labels */
                         + (kRowH + 4) * 2      /* lock + hash checkboxes */
                         + kMargin;             /* bottom margin */

    NSRect win_rect = NSMakeRect(0, 0, kPanelWidth, content_h);
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
    [panel setContentSize:NSMakeSize(kPanelWidth, content_h)];

    self = [super initWithWindow:panel];
    if (!self) {
        return nil;
    }

    NSView *cv = panel.contentView;
    CGFloat x_label = kMargin;
    CGFloat x_value = kMargin + kLabelW + 8.0;
    CGFloat w_value = kPanelWidth - x_value - kMargin;

    /* Icon + name at top. */
    CGFloat icon_y = content_h - kMargin - kIconSize;
    NSRect icon_rect = NSMakeRect(kMargin, icon_y, kIconSize, kIconSize);
    self.icon_view                    = [[NSImageView alloc] initWithFrame:icon_rect];
    self.icon_view.imageScaling       = NSImageScaleProportionallyUpOrDown;
    [cv addSubview:self.icon_view];

    CGFloat name_x = kMargin + kIconSize + 12.0;
    CGFloat name_w = kPanelWidth - name_x - kMargin;
    CGFloat name_y = icon_y + (kIconSize - kRowH) / 2.0;
    NSRect name_box_rect = NSMakeRect(name_x, name_y, name_w, kRowH);

    /* Rounded container — NSBoxCustom adapts its colors to dark/light mode. */
    NSBox *name_box         = [[NSBox alloc] initWithFrame:name_box_rect];
    name_box.boxType        = NSBoxCustom;
    name_box.cornerRadius   = 6.0;
    name_box.borderWidth    = 0.5;
    name_box.borderColor    = NSColor.separatorColor;
    name_box.fillColor      = NSColor.controlBackgroundColor;
    name_box.contentViewMargins = NSZeroSize;
    [cv addSubview:name_box];

    NSRect name_rect = NSMakeRect(5.0, 1.0, name_w - 10.0, kRowH - 2.0);
    self.name_field                   = [[NSTextField alloc] initWithFrame:name_rect];
    /* Swap in the centering cell before setting any cell-derived properties. */
    VCenterCell *name_cell            = [[VCenterCell alloc] init];
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

    /* Attribute rows. */
    NSTextField *value_fields[] = {
        nil, /* name row handled above */
    };
    (void)value_fields;

    NSMutableArray<NSTextField *> *values = [NSMutableArray array];
    CGFloat row_y = icon_y - kMargin;

    /* kPermRow is the index of "Permissions:" in row_keys; handled specially. */
    static const NSUInteger kPermRow = 6;

    for (NSUInteger i = 0; i < row_keys.count; i++) {
        NSString *key = row_keys[i];
        row_y -= (kRowH + 4.0);
        NSRect lr = NSMakeRect(x_label, row_y, kLabelW, kRowH);
        [cv addSubview:make_label(key, lr)];

        if (i == kPermRow) {
            /* Three side-by-side NSPopUpButton controls: owner | group | other.
             * Each takes one third of the value column width with a small gap. */
            CGFloat gap         = 6.0;
            CGFloat pop_w       = (w_value - 2.0 * gap) / 3.0;
            NSString * const tips[3] = { @"Owner", @"Group", @"Other" };
            NSPopUpButton *btns[3];
            for (int p = 0; p < 3; p++) {
                CGFloat px    = x_value + p * (pop_w + gap);
                NSRect pr     = NSMakeRect(px, row_y, pop_w, kRowH);
                NSPopUpButton *btn = [[NSPopUpButton alloc] initWithFrame:pr pullsDown:NO];
                btn.font    = [NSFont monospacedSystemFontOfSize:11.0
                                                         weight:NSFontWeightRegular];
                btn.toolTip = tips[p];
                for (NSUInteger t = 0; t < 8; t++) {
                    [btn addItemWithTitle:kPermItems[t]];
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
            row_y -= (kSmallLabelH + 2.0);
            for (int p = 0; p < 3; p++) {
                CGFloat px  = x_value + p * (pop_w + gap);
                NSRect slr  = NSMakeRect(px, row_y, pop_w, kSmallLabelH);
                NSTextField *sl = [NSTextField labelWithString:tips[p]];
                sl.frame       = slr;
                sl.alignment   = NSTextAlignmentCenter;
                sl.font        = [NSFont systemFontOfSize:9.0];
                sl.textColor   = NSColor.tertiaryLabelColor;
                [cv addSubview:sl];
            }
            continue; /* no text field added to values */
        }

        BOOL is_hash = (i == kSha256Row || i == kMd5Row);
        CGFloat fw = is_hash ? (w_value - kCopyW - kCopyGap) : w_value;
        NSRect vr = NSMakeRect(x_value, row_y, fw, kRowH);
        NSTextField *vf = make_value(vr);
        [cv addSubview:vf];
        [values addObject:vf];

        if (is_hash) {
            NSRect br = NSMakeRect(x_value + fw + kCopyGap, row_y, kCopyW, kRowH);
            SEL sel = (i == kSha256Row) ? @selector(copy_sha256_action:)
                                         : @selector(copy_md5_action:);
            [cv addSubview:make_copy_btn(br, self, sel)];
        }
    }

    /* values indices: 0=Name(unused), 1=Kind, 2=Size, 3=Where,
     *   4=Created, 5=Modified, (kPermRow skipped), 6=Owner, 7=Group,
     *   8=SHA-256, 9=MD5                                               */
    self.kind_value      = values[1];
    self.size_value      = values[2];
    self.where_value     = values[3];
    self.created_value   = values[4];
    self.modified_value  = values[5];
    self.owner_value     = values[6];
    self.group_value     = values[7];
    self.sha256_value    = values[8];
    self.md5_value       = values[9];

    /* Hash value fields: monospaced, tail-truncated with "…", selectable to copy. */
    NSFont *hash_font = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightRegular];
    for (NSTextField *hf in @[self.sha256_value, self.md5_value]) {
        hf.font          = hash_font;
        hf.selectable    = YES;
        hf.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    /* Lock checkbox. */
    row_y -= (kRowH + 4.0);
    NSRect lock_rect = NSMakeRect(x_value, row_y, w_value, kRowH);
    self.lock_check = [NSButton checkboxWithTitle:@"Locked" target:self action:@selector(lock_toggled:)];
    self.lock_check.frame = lock_rect;
    [cv addSubview:self.lock_check];

    /* Show Hashes checkbox. */
    row_y -= (kRowH + 4.0);
    NSRect hash_rect = NSMakeRect(x_value, row_y, w_value, kRowH);
    self.hash_check = [NSButton checkboxWithTitle:@"Show Hashes (SHA-256 / MD5)"
                                           target:self
                                           action:@selector(hash_check_toggled:)];
    self.hash_check.frame = hash_rect;
    self.hash_check.state = [NSUserDefaults.standardUserDefaults boolForKey:@"files.show_hashes"]
                            ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.hash_check];

    /* Separator below icon. */
    NSBox *sep        = [[NSBox alloc] initWithFrame:NSMakeRect(kMargin, icon_y - 8.0, kPanelWidth - kMargin * 2.0, 1.0)];
    sep.boxType       = NSBoxSeparator;
    [cv addSubview:sep];

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
 * populate_fields: — reads file attributes and fills UI fields.
 *
 * Inputs:
 *   url — file URL
 */
- (void)
populate_fields:(NSURL *)url
{
    NSArray<NSURLResourceKey> *keys = @[
        NSURLNameKey, NSURLFileSizeKey, NSURLFileAllocatedSizeKey,
        NSURLIsDirectoryKey, NSURLLocalizedTypeDescriptionKey,
        NSURLCreationDateKey, NSURLContentModificationDateKey,
        NSURLIsWritableKey
    ];
    NSDictionary<NSURLResourceKey, id> *res =
        [url resourceValuesForKeys:keys error:nil];

    /* Icon */
    self.icon_view.image = [NSWorkspace.sharedWorkspace iconForFile:url.path];

    /* Name */
    self.name_field.stringValue = res[NSURLNameKey] ?: url.lastPathComponent;

    /* Kind */
    NSNumber *is_dir = res[NSURLIsDirectoryKey];
    NSString *kind   = is_dir.boolValue ? @"Folder" : (res[NSURLLocalizedTypeDescriptionKey] ?: @"—");
    self.kind_value.stringValue = kind;

    /* Size */
    NSNumber *sz   = res[NSURLFileSizeKey];
    NSNumber *alloc_sz = res[NSURLFileAllocatedSizeKey];
    if (sz && !is_dir.boolValue) {
        NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
        fmt.countStyle = NSByteCountFormatterCountStyleFile;
        NSString *sz_str   = [fmt stringFromByteCount:sz.longLongValue];
        NSString *alloc_str = [fmt stringFromByteCount:alloc_sz.longLongValue];
        self.size_value.stringValue = [NSString stringWithFormat:@"%@ (%@ on disk)", sz_str, alloc_str];
    } else {
        self.size_value.stringValue = @"—";
    }

    /* Where */
    self.where_value.stringValue = url.URLByDeletingLastPathComponent.path ?: @"—";

    /* Dates */
    NSDateFormatter *dfmt = [[NSDateFormatter alloc] init];
    dfmt.dateStyle  = NSDateFormatterMediumStyle;
    dfmt.timeStyle  = NSDateFormatterShortStyle;

    NSDate *created  = res[NSURLCreationDateKey];
    NSDate *modified = res[NSURLContentModificationDateKey];
    self.created_value.stringValue  = created  ? [dfmt stringFromDate:created]  : @"—";
    self.modified_value.stringValue = modified ? [dfmt stringFromDate:modified] : @"—";

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

    /* Lock */
    NSNumber *writable = res[NSURLIsWritableKey];
    self.lock_check.state = (writable && !writable.boolValue)
                            ? NSControlStateValueOn
                            : NSControlStateValueOff;

    /* Hashes — computed asynchronously when enabled and item is a file. */
    self.sha256_value.stringValue = @"—";
    self.md5_value.stringValue    = @"—";
    self.hash_url = nil;

    BOOL show_hashes = [NSUserDefaults.standardUserDefaults boolForKey:@"files.show_hashes"];
    if (show_hashes && !is_dir.boolValue) {
        self.hash_url = url;
        self.sha256_value.stringValue = @"Computing…";
        self.md5_value.stringValue    = @"Computing…";
        __weak FilesInfoPanel *ws = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            uint8_t sha_buf[32];
            NSString *sha = (file_sha256(url.fileSystemRepresentation, sha_buf) == 0)
                            ? sha256_hex(sha_buf) : nil;
            NSString *md5 = compute_md5_hex(url.fileSystemRepresentation);
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesInfoPanel *s = ws;
                if (!s || ![s.hash_url isEqual:url]) return;
                s.sha256_value.stringValue = sha ?: @"Error";
                s.sha256_value.toolTip     = sha;
                s.md5_value.stringValue    = md5 ?: @"Error";
                s.md5_value.toolTip        = md5;
            });
        });
    }
}

/*
 * perms_popup_changed: — reads the three permission popups and applies the new
 * mode to the current file via chmod(2), preserving file-type and setuid/setgid/
 * sticky bits from the existing mode.
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

    if (chmod(self.current_url.fileSystemRepresentation, new_mode) != 0) {
        NSString *err_str = [NSString stringWithUTF8String:strerror(errno)];
        NSAlert *alert        = [[NSAlert alloc] init];
        alert.messageText     = @"Could not change permissions";
        alert.informativeText = err_str ?: @"Unknown error";
        [alert runModal];
        /* Revert popups to reflect the unchanged on-disk mode. */
        [self.owner_perms_popup selectItemWithTag:(st.st_mode >> 6) & 7];
        [self.group_perms_popup selectItemWithTag:(st.st_mode >> 3) & 7];
        [self.other_perms_popup selectItemWithTag:st.st_mode & 7];
    }
}

/*
 * copy_sha256_action: — copies the SHA-256 hash to the general pasteboard.
 *
 * Inputs:
 *   sender — copy link button (unused)
 */
- (IBAction)
copy_sha256_action:(id)sender
{
    (void)sender;
    NSString *val = self.sha256_value.stringValue;
    if (!val.length || [val isEqualToString:@"—"] || [val isEqualToString:@"Computing…"]) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:val forType:NSPasteboardTypeString];
}

/*
 * copy_md5_action: — copies the MD5 hash to the general pasteboard.
 *
 * Inputs:
 *   sender — copy link button (unused)
 */
- (IBAction)
copy_md5_action:(id)sender
{
    (void)sender;
    NSString *val = self.md5_value.stringValue;
    if (!val.length || [val isEqualToString:@"—"] || [val isEqualToString:@"Computing…"]) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:val forType:NSPasteboardTypeString];
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
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"files.show_hashes"];
    if (self.current_url) [self populate_fields:self.current_url];
}

/*
 * lock_toggled: — toggles the immutable flag on the current file.
 *
 * Inputs:
 *   sender — the lock checkbox
 */
- (void)
lock_toggled:(NSButton *)sender
{
    if (!self.current_url) return;
    BOOL lock = (sender.state == NSControlStateValueOn);
    NSDictionary *attrs = @{NSFileImmutable: @(lock)};
    NSError *err = nil;
    BOOL ok = [NSFileManager.defaultManager setAttributes:attrs
                                             ofItemAtPath:self.current_url.path
                                                    error:&err];
    if (!ok) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Could not change lock status";
        alert.informativeText = err.localizedDescription ?: @"Unknown error";
        [alert runModal];
        /* Revert checkbox. */
        sender.state = lock ? NSControlStateValueOff : NSControlStateValueOn;
    }
}

/*
 * controlTextDidEndEditing: — renames the file when the name field loses focus.
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
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText     = @"Rename failed";
            alert.informativeText = err.localizedDescription ?: @"Unknown error";
            [alert runModal];
            self.name_field.stringValue = self.current_url.lastPathComponent;
        } else {
            self.current_url = new_url;
        }
    }];
}

@end
