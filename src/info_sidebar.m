#import "info_sidebar.h"
#import "util.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>

/* ── Layout constants (isFlipped = YES: y=0 at top, increases downward) ─── */
static const CGFloat pad          = 8.0;
static const CGFloat prev_h       = 150.0;   /* thumbnail area height */
static const CGFloat icon_edge    = 128.0;   /* an item's icon in that area */

/* How long a thumbnail may take before the item's icon stands in for it.
 * Quick Look usually answers well inside this, so moving through a folder
 * goes from thumbnail to thumbnail without the icon flashing in between. */
static const NSTimeInterval icon_grace = 0.15;
static const CGFloat row_h        = 18.0;    /* metadata row height */
static const CGFloat name_h       = 34.0;    /* name label (up to 2 lines) */
static const CGFloat key_w        = 70.0;    /* key column width */
static const CGFloat key_val_gap  = 4.0;     /* gap between key and value */

static const CGFloat sep1_y       = pad + prev_h + 6.0;           /* 164 */
static const CGFloat name_y       = sep1_y + 1.0 + 6.0;           /* 171 */
static const CGFloat sep2_y       = name_y + name_h + 4.0;        /* 209 */
static const CGFloat first_row_y  = sep2_y + 1.0 + 6.0;           /* 216 */

/* Metadata rows, in display order; indexes row_keys and _row_vals. */
enum { row_kind, row_opens_with, row_size, row_created, row_modified,
       row_owner, row_group, row_permissions, row_count };
static NSString * const row_keys[row_count] = {
    [row_kind]        = @"Kind",
    [row_opens_with]  = @"Opens with",
    [row_size]        = @"Size",
    [row_created]     = @"Created",
    [row_modified]    = @"Modified",
    [row_owner]       = @"Owner",
    [row_group]       = @"Group",
    [row_permissions] = @"Permissions",
};

/*
 * format_mode — POSIX permission bits as a 9-character rwxrwxrwx string.
 *
 * Inputs:
 *   mode — st_mode from stat(2)
 *
 * Output: NSString like "rwxr-xr-x"
 */
static NSString *
format_mode(mode_t mode)
{
    char buf[10];
    buf[0] = (mode & S_IRUSR) ? 'r' : '-';
    buf[1] = (mode & S_IWUSR) ? 'w' : '-';
    buf[2] = (mode & S_IXUSR) ? 'x' : '-';
    buf[3] = (mode & S_IRGRP) ? 'r' : '-';
    buf[4] = (mode & S_IWGRP) ? 'w' : '-';
    buf[5] = (mode & S_IXGRP) ? 'x' : '-';
    buf[6] = (mode & S_IROTH) ? 'r' : '-';
    buf[7] = (mode & S_IWOTH) ? 'w' : '-';
    buf[8] = (mode & S_IXOTH) ? 'x' : '-';
    buf[9] = '\0';
    return @(buf);
}

/*
 * multi_selection_icon — the image shown for a multi-item selection:
 * documents.png from the app bundle (copied there by the Makefile), falling
 * back to the system "multiple documents" image. Loaded from disk once.
 *
 * Output: shared NSImage (never nil).
 */
static NSImage *
multi_selection_icon(void)
{
    static NSImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"documents" ofType:@"png"];
        icon = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
        if (!icon) icon = [NSImage imageNamed:NSImageNameMultipleDocuments];
    });
    return icon;
}

@implementation FilesInfoSidebar {
    NSImageView  *_preview_view;
    NSTextField  *_name_label;
    NSTextField  *_row_vals[row_count]; /* parallel to row_keys */

    QLThumbnailGenerationRequest *_pending_request;
}

/*
 * isFlipped — makes the view's coordinate system top-down so the layout
 * constants read as distances from the top edge.
 *
 * Output: YES.
 */
- (BOOL)
isFlipped
{
    return YES;
}

/*
 * initWithFrame: — builds all subviews.
 *
 * Inputs:
 *   frame — initial frame (width should be 220)
 *
 * Output: self or nil.
 */
- (instancetype)
initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self build_views];
    return self;
}

/* ── Drawing ─────────────────────────────────────────────────────────────── */

/*
 * drawRect: — fills the background. The split view's divider is the
 * separator at its left.
 *
 * Inputs:
 *   dirty — region to redraw
 */
- (void)
drawRect:(NSRect)dirty
{
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
}

/* ── Construction ────────────────────────────────────────────────────────── */

/*
 * build_views — creates and positions all static subviews.
 */
- (void)
build_views
{
    CGFloat w         = self.bounds.size.width;
    CGFloat content_w = w - 2.0 * pad;
    CGFloat val_x     = pad + key_w + key_val_gap;
    CGFloat val_w     = w - val_x - pad;

    /* ── Thumbnail ── */
    _preview_view = [[NSImageView alloc]
        initWithFrame:NSMakeRect(pad, pad, content_w, prev_h)];
    _preview_view.imageAlignment = NSImageAlignCenter;
    _preview_view.autoresizingMask = NSViewWidthSizable;
    [self addSubview:_preview_view];

    /* ── Separator 1 ── */
    NSBox *sep1      = [[NSBox alloc] initWithFrame:NSMakeRect(0, sep1_y, w, 1)];
    sep1.boxType     = NSBoxSeparator;
    sep1.autoresizingMask = NSViewWidthSizable;
    [self addSubview:sep1];

    /* ── Name label ── */
    _name_label = [NSTextField labelWithString:@""];
    _name_label.frame                = NSMakeRect(pad, name_y, content_w, name_h);
    _name_label.alignment            = NSTextAlignmentCenter;
    _name_label.font                 = [NSFont boldSystemFontOfSize:12.0];
    _name_label.lineBreakMode        = NSLineBreakByTruncatingMiddle;
    _name_label.maximumNumberOfLines = 2;
    _name_label.autoresizingMask     = NSViewWidthSizable;
    [self addSubview:_name_label];

    /* ── Separator 2 ── */
    NSBox *sep2      = [[NSBox alloc] initWithFrame:NSMakeRect(0, sep2_y, w, 1)];
    sep2.boxType     = NSBoxSeparator;
    sep2.autoresizingMask = NSViewWidthSizable;
    [self addSubview:sep2];

    /* ── Metadata rows ── */
    for (NSUInteger i = 0; i < row_count; i++) {
        CGFloat y = first_row_y + i * row_h;

        NSTextField *key_lbl = [NSTextField labelWithString:
            [row_keys[i] stringByAppendingString:@":"]];
        key_lbl.frame             = NSMakeRect(pad, y, key_w, row_h);
        key_lbl.alignment         = NSTextAlignmentRight;
        key_lbl.font              = [NSFont systemFontOfSize:10.0];
        key_lbl.textColor         = NSColor.secondaryLabelColor;
        key_lbl.autoresizingMask  = NSViewMaxXMargin;
        [self addSubview:key_lbl];

        _row_vals[i] = [NSTextField labelWithString:@"—"];
        _row_vals[i].frame            = NSMakeRect(val_x, y, val_w, row_h);
        _row_vals[i].font             = [NSFont systemFontOfSize:11.0];
        _row_vals[i].lineBreakMode    = NSLineBreakByTruncatingTail;
        _row_vals[i].autoresizingMask = NSViewWidthSizable;
        [self addSubview:_row_vals[i]];
    }
}

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/*
 * show_preview:scale_up: — puts an image in the thumbnail area.
 *
 * Inputs:
 *   image    — image to show
 *   scale_up — YES to enlarge an image smaller than the area until it fits
 *              it, NO to show it no larger than its own size
 */
- (void)
show_preview:(NSImage *)image scale_up:(BOOL)scale_up
{
    _preview_view.imageScaling = scale_up ? NSImageScaleProportionallyUpOrDown
                                          : NSImageScaleProportionallyDown;
    _preview_view.image = image;
}

/*
 * cancel_pending — cancels any in-flight QL thumbnail request. A completion
 * that still arrives afterwards fails the identity check in show_url:.
 */
- (void)
cancel_pending
{
    if (_pending_request) {
        [QLThumbnailGenerator.sharedGenerator cancelRequest:_pending_request];
        _pending_request = nil;
    }
}

/*
 * show_icon_for: — shows url's icon in the thumbnail area at icon_edge, not
 * enlarged to the area's height: enlarged, it is drawn from the icon's
 * 512 px representation, 1 MB plus a layer copy that stay loaded for each
 * file type ever selected, because the file list's icon cache keeps the
 * type's icon alive.
 *
 * Inputs:
 *   url — item whose icon to show
 */
- (void)
show_icon_for:(NSURL *)url
{
    [self show_preview:files_icon_for_url(url, icon_edge, NO) scale_up:NO];
}

/*
 * request_thumbnail: — asks Quick Look for a thumbnail of url sized to the
 * preview view (in points, at the window's backing scale) and shows it when
 * it arrives, unless a newer request or clear/cancel has superseded it.
 * Until then the area keeps what it showed; url's icon replaces that if
 * Quick Look has no thumbnail, or has not answered within icon_grace.
 *
 * Inputs:
 *   url — item to thumbnail
 */
- (void)
request_thumbnail:(NSURL *)url
{
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0) scale = 2.0;

    QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
        initWithFileAtURL:url
                     size:_preview_view.bounds.size
                    scale:scale
      representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    _pending_request = req;

    __weak FilesInfoSidebar *ws = self;
    [QLThumbnailGenerator.sharedGenerator
        generateBestRepresentationForRequest:req
        completionHandler:^(QLThumbnailRepresentation *rep, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesInfoSidebar *s = ws;
                if (!s || s->_pending_request != req) return;
                s->_pending_request = nil;
                if (rep) {
                    [s show_preview:rep.NSImage scale_up:YES];
                } else {
                    [s show_icon_for:url];
                }
            });
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(icon_grace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilesInfoSidebar *s = ws;
        if (s && s->_pending_request == req) [s show_icon_for:url];
    });
}

/* ── Public API ──────────────────────────────────────────────────────────── */

/*
 * show_url: — shows the QL thumbnail and metadata for a single item.
 * Files and packages show their QL thumbnail, or their icon when there is
 * none (request_thumbnail:). A plain folder shows its icon at once: its
 * thumbnail would be that icon anyway (minus the git badge of a working
 * tree).
 *
 * Inputs:
 *   url — file-system URL of the item to inspect
 */
- (void)
show_url:(NSURL *)url
{
    [self cancel_pending];

    NSDictionary<NSURLResourceKey, id> *res =
        [url resourceValuesForKeys:@[
            NSURLNameKey, NSURLIsDirectoryKey,
            NSURLIsPackageKey, NSURLFileSizeKey, NSURLCreationDateKey,
            NSURLContentModificationDateKey,
        ] error:nil];

    _name_label.stringValue = res[NSURLNameKey] ?: url.lastPathComponent ?: @"";
    _row_vals[row_kind].stringValue       = files_kind_text(url);
    _row_vals[row_opens_with].stringValue = files_opens_with_text(url);

    NSNumber *sz = res[NSURLFileSizeKey];
    _row_vals[row_size].stringValue = ([res[NSURLIsDirectoryKey] boolValue] || !sz)
                                      ? @"—" : files_format_bytes(sz.longLongValue);
    _row_vals[row_size].toolTip = nil;

    _row_vals[row_created].stringValue =
        files_format_date(res[NSURLCreationDateKey], NSDateFormatterMediumStyle);
    _row_vals[row_modified].stringValue =
        files_format_date(res[NSURLContentModificationDateKey], NSDateFormatterMediumStyle);

    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) == 0) {
        _row_vals[row_permissions].stringValue = format_mode(st.st_mode);

        char pw_buf[256];
        struct passwd pw, *pw_res;
        _row_vals[row_owner].stringValue =
            (getpwuid_r(st.st_uid, &pw, pw_buf, sizeof(pw_buf), &pw_res) == 0 && pw_res)
            ? @(pw.pw_name) : [NSString stringWithFormat:@"%u", st.st_uid];

        char gr_buf[256];
        struct group gr, *gr_res;
        _row_vals[row_group].stringValue =
            (getgrgid_r(st.st_gid, &gr, gr_buf, sizeof(gr_buf), &gr_res) == 0 && gr_res)
            ? @(gr.gr_name) : [NSString stringWithFormat:@"%u", st.st_gid];
    } else {
        _row_vals[row_permissions].stringValue = @"—";
        _row_vals[row_owner].stringValue       = @"—";
        _row_vals[row_group].stringValue       = @"—";
    }

    BOOL plain_folder = [res[NSURLIsDirectoryKey] boolValue] && ![res[NSURLIsPackageKey] boolValue];
    if (plain_folder) {
        [self show_icon_for:url];
    } else {
        [self request_thumbnail:url];
    }
}

/*
 * show_urls: — shows aggregate info for a multi-item selection: item count
 * and the combined size of the selected files. Folder contents are not
 * walked; when folders are selected the size is marked "excl. folders", and
 * is "—" if only folders are selected.
 *
 * Inputs:
 *   urls — selected URLs (count > 1)
 */
- (void)
show_urls:(NSArray<NSURL *> *)urls
{
    [self cancel_pending];

    [self show_preview:multi_selection_icon() scale_up:YES];
    _name_label.stringValue  = [NSString stringWithFormat:@"%lu items selected",
                                 (unsigned long)urls.count];
    _row_vals[row_kind].stringValue        = @"—";
    _row_vals[row_opens_with].stringValue  = @"—";
    _row_vals[row_created].stringValue     = @"—";
    _row_vals[row_modified].stringValue    = @"—";
    _row_vals[row_owner].stringValue       = @"—";
    _row_vals[row_group].stringValue       = @"—";
    _row_vals[row_permissions].stringValue = @"—";

    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLFileSizeKey];
    int64_t    total    = 0;
    NSUInteger n_files  = 0;
    BOOL       has_dirs = NO;
    for (NSURL *u in urls) {
        NSDictionary<NSURLResourceKey, id> *res = [u resourceValuesForKeys:keys error:nil];
        if ([res[NSURLIsDirectoryKey] boolValue]) {
            has_dirs = YES;
            continue;
        }
        total += [res[NSURLFileSizeKey] longLongValue];
        n_files++;
    }

    NSTextField *size_field = _row_vals[row_size];
    if (n_files == 0) {
        size_field.stringValue = @"—";
    } else if (has_dirs) {
        size_field.stringValue = [NSString stringWithFormat:@"%@ (excl. folders)",
                                  files_format_bytes(total)];
    } else {
        size_field.stringValue = files_format_bytes(total);
    }
    size_field.toolTip = has_dirs ? @"Folder contents are not counted in the total." : nil;
}

/*
 * clear — resets to empty state when no item is selected (or the sidebar is
 * collapsed): cancels any in-flight Quick Look request and drops the
 * thumbnail image so it is not kept in memory.
 */
- (void)
clear
{
    [self cancel_pending];
    _preview_view.image = nil;
    _name_label.stringValue = @"";
    for (NSUInteger i = 0; i < row_count; i++) {
        _row_vals[i].stringValue = @"—";
        _row_vals[i].toolTip     = nil;
    }
}

@end
