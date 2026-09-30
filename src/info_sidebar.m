#import "info_sidebar.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

/* ── Layout constants (isFlipped = YES: y=0 at top, increases downward) ─── */
static const CGFloat kPad       = 8.0;
static const CGFloat kPrevH     = 150.0;   /* thumbnail area height */
static const CGFloat kRowH      = 18.0;    /* metadata row height */
static const CGFloat kNameH     = 34.0;    /* name label (up to 2 lines) */
static const CGFloat kKeyW      = 62.0;    /* key column width */
static const CGFloat kKeyValGap = 4.0;     /* gap between key and value */

static const CGFloat kSep1Y     = kPad + kPrevH + 6.0;          /* 164 */
static const CGFloat kNameY     = kSep1Y + 1.0 + 6.0;           /* 171 */
static const CGFloat kSep2Y     = kNameY + kNameH + 4.0;        /* 209 */
static const CGFloat kFirstRowY = kSep2Y + 1.0 + 6.0;           /* 216 */

/* Key strings for each metadata row, in display order. */
static NSString * const kRowKeys[] = { @"Kind", @"Size", @"Created", @"Modified" };
static const NSUInteger kRowCount  = 4;

@implementation FilesInfoSidebar {
    NSImageView  *_preview_view;
    NSTextField  *_name_label;
    NSTextField  *_row_vals[4]; /* parallel to kRowKeys */

    NSURL                        *_current_url;
    QLThumbnailGenerationRequest *_pending_request;
}

- (BOOL)isFlipped { return YES; }

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
 * drawRect: — fills the background and draws a 1pt left separator.
 *
 * Inputs:
 *   dirty — region to redraw
 */
- (void)
drawRect:(NSRect)dirty
{
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 0, 1, self.bounds.size.height));
}

/* ── Construction ────────────────────────────────────────────────────────── */

/*
 * build_views — creates and positions all static subviews.
 */
- (void)
build_views
{
    CGFloat w         = self.bounds.size.width;
    CGFloat content_w = w - 2.0 * kPad;
    CGFloat val_x     = kPad + kKeyW + kKeyValGap;
    CGFloat val_w     = w - val_x - kPad;

    /* ── Thumbnail ── */
    _preview_view = [[NSImageView alloc]
        initWithFrame:NSMakeRect(kPad, kPad, content_w, kPrevH)];
    _preview_view.imageScaling   = NSImageScaleProportionallyUpOrDown;
    _preview_view.imageAlignment = NSImageAlignCenter;
    _preview_view.autoresizingMask = NSViewWidthSizable;
    [self addSubview:_preview_view];

    /* ── Separator 1 ── */
    NSBox *sep1      = [[NSBox alloc] initWithFrame:NSMakeRect(0, kSep1Y, w, 1)];
    sep1.boxType     = NSBoxSeparator;
    sep1.autoresizingMask = NSViewWidthSizable;
    [self addSubview:sep1];

    /* ── Name label ── */
    _name_label = [NSTextField labelWithString:@""];
    _name_label.frame                = NSMakeRect(kPad, kNameY, content_w, kNameH);
    _name_label.alignment            = NSTextAlignmentCenter;
    _name_label.font                 = [NSFont boldSystemFontOfSize:12.0];
    _name_label.lineBreakMode        = NSLineBreakByTruncatingMiddle;
    _name_label.maximumNumberOfLines = 2;
    _name_label.autoresizingMask     = NSViewWidthSizable;
    [self addSubview:_name_label];

    /* ── Separator 2 ── */
    NSBox *sep2      = [[NSBox alloc] initWithFrame:NSMakeRect(0, kSep2Y, w, 1)];
    sep2.boxType     = NSBoxSeparator;
    sep2.autoresizingMask = NSViewWidthSizable;
    [self addSubview:sep2];

    /* ── Metadata rows ── */
    for (NSUInteger i = 0; i < kRowCount; i++) {
        CGFloat y = kFirstRowY + i * kRowH;

        NSTextField *key_lbl = [NSTextField labelWithString:
            [kRowKeys[i] stringByAppendingString:@":"]];
        key_lbl.frame             = NSMakeRect(kPad, y, kKeyW, kRowH);
        key_lbl.alignment         = NSTextAlignmentRight;
        key_lbl.font              = [NSFont systemFontOfSize:10.0];
        key_lbl.textColor         = NSColor.secondaryLabelColor;
        key_lbl.autoresizingMask  = NSViewMaxXMargin;
        [self addSubview:key_lbl];

        _row_vals[i] = [NSTextField labelWithString:@"—"];
        _row_vals[i].frame            = NSMakeRect(val_x, y, val_w, kRowH);
        _row_vals[i].font             = [NSFont systemFontOfSize:11.0];
        _row_vals[i].autoresizingMask = NSViewWidthSizable;
        [self addSubview:_row_vals[i]];
    }
}

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/*
 * cancel_pending — cancels any in-flight QL thumbnail request.
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
 * format_size: — formats a byte count as a human-readable string.
 *
 * Inputs:
 *   bytes — byte count
 *
 * Output: formatted string, e.g. "128 KB"
 */
- (NSString *)
format_size:(int64_t)bytes
{
    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;
    return [fmt stringFromByteCount:bytes];
}

/*
 * format_date: — formats an NSDate in medium date + short time style.
 *
 * Inputs:
 *   date — date to format, or nil
 *
 * Output: formatted string, or em-dash on nil.
 */
- (NSString *)
format_date:(NSDate *)date
{
    if (!date) return @"—";
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
    });
    return [fmt stringFromDate:date];
}

/* ── Public API ──────────────────────────────────────────────────────────── */

/*
 * show_url: — shows the QL thumbnail and metadata for a single item.
 * Immediately sets a Workspace icon as a placeholder, then replaces it with
 * the QL thumbnail when the system cache delivers it.
 *
 * Inputs:
 *   url — file-system URL of the item to inspect
 */
- (void)
show_url:(NSURL *)url
{
    [self cancel_pending];
    _current_url = url;

    /* ── Metadata (kernel-cached reads) ── */
    NSString *name = nil;
    [url getResourceValue:&name forKey:NSURLNameKey error:nil];
    _name_label.stringValue = name ?: url.lastPathComponent ?: @"";

    NSString *kind = nil;
    [url getResourceValue:&kind forKey:NSURLLocalizedTypeDescriptionKey error:nil];
    _row_vals[0].stringValue = kind ?: @"—";

    NSNumber *is_dir = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    if (is_dir.boolValue) {
        _row_vals[1].stringValue = @"—";
    } else {
        NSNumber *sz = nil;
        [url getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        _row_vals[1].stringValue = sz ? [self format_size:sz.longLongValue] : @"—";
    }

    NSDate *created = nil;
    [url getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
    _row_vals[2].stringValue = [self format_date:created];

    NSDate *modified = nil;
    [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
    _row_vals[3].stringValue = [self format_date:modified];

    /* ── Immediate placeholder icon, then async QL thumbnail ── */
    NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
    icon.size = NSMakeSize(128, 128);
    _preview_view.image = icon;

    CGFloat scale = NSScreen.mainScreen.backingScaleFactor;
    CGSize  sz    = CGSizeMake(_preview_view.bounds.size.width * scale,
                               _preview_view.bounds.size.height * scale);
    _pending_request = [[QLThumbnailGenerationRequest alloc]
        initWithFileAtURL:url
                     size:sz
                    scale:scale
      representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];

    __weak FilesInfoSidebar *ws = self;
    [QLThumbnailGenerator.sharedGenerator
        generateBestRepresentationForRequest:_pending_request
        completionHandler:^(QLThumbnailRepresentation *rep, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FilesInfoSidebar *s = ws;
                if (!s || ![s->_current_url isEqual:url] || !rep) return;
                s->_preview_view.image  = rep.NSImage;
                s->_pending_request     = nil;
            });
        }];
}

/*
 * show_urls: — shows aggregate info for a multi-item selection: item count
 * and combined file size. Directories are excluded from the size total.
 *
 * Inputs:
 *   urls — selected URLs (count > 1)
 */
- (void)
show_urls:(NSArray<NSURL *> *)urls
{
    [self cancel_pending];
    _current_url = nil;

    /* Load documents.png from the app bundle (copied there by the Makefile). */
    NSString *img_path = [NSBundle.mainBundle pathForResource:@"documents" ofType:@"png"];
    NSImage  *multi_icon = img_path ? [[NSImage alloc] initWithContentsOfFile:img_path] : nil;
    if (!multi_icon) {
        multi_icon = [NSImage imageNamed:NSImageNameMultipleDocuments];
    }
    _preview_view.image = multi_icon;

    NSUInteger count = urls.count;
    _name_label.stringValue  = [NSString stringWithFormat:@"%lu items selected",
                                 (unsigned long)count];
    _row_vals[0].stringValue = @"—"; /* Kind */
    _row_vals[2].stringValue = @"—"; /* Created */
    _row_vals[3].stringValue = @"—"; /* Modified */

    /* Sum file sizes; skip directories. */
    int64_t total    = 0;
    BOOL    has_dirs = NO;
    for (NSURL *u in urls) {
        NSNumber *is_dir = nil;
        [u getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        if (is_dir.boolValue) { has_dirs = YES; continue; }
        NSNumber *sz = nil;
        [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        total += sz.longLongValue;
    }
    _row_vals[1].stringValue = has_dirs ? @"—" : [self format_size:total];
}

/*
 * clear — resets to empty state when no item is selected.
 */
- (void)
clear
{
    [self cancel_pending];
    _current_url        = nil;
    _preview_view.image = nil;
    _name_label.stringValue = @"";
    for (NSUInteger i = 0; i < kRowCount; i++) {
        _row_vals[i].stringValue = @"—";
    }
}

@end
