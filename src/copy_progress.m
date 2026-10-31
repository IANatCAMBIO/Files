#import "copy_progress.h"
#import "shared_tool_panel.h"
#import "file_ops.h"
#import "util.h"
#include <os/lock.h>

/* The panel picks up the engine's log lines and progress this often. The
 * engine reports far more frequently than that — once per megabyte copied
 * or hashed — so the panel, not the engine, sets the redraw rate. */
static const CFTimeInterval tick_interval = 0.25;

/* Panel geometry. The status line and the bars are pinned to the top, the
 * Cancel/Close button and the Transfer Log toggle to the bottom; the log,
 * when expanded, fills what is between them. */
static const CGFloat panel_width   = 500.0;
static const CGFloat edge          = 12.0;  /* content inset from the window edges */
static const CGFloat status_height = 16.0;
static const CGFloat bar_height    = 15.0;
static const CGFloat bar_gap       = 4.0;   /* between the two bars */
static const CGFloat status_gap    = 10.0;  /* status line to the first bar */
static const CGFloat button_height = 22.0;
static const CGFloat button_gap    = 14.0;  /* last bar to the button row */

static const CGFloat log_height = 160.0;    /* extra window height for the transfer log */
static const CGFloat log_gap    = 8.0;      /* space above and below the log */

/* Cells in a progress bar, chosen so the widest bar — label, percentage
 * and rate included — fits the panel's width in the bar font. */
static const NSUInteger bar_cells = 40;

/* The transfer log keeps at most log_max_lines lines; once log_trim_batch
 * extra lines have accumulated, the oldest are dropped in one edit. */
static const NSUInteger log_max_lines  = 1000;
static const NSUInteger log_trim_batch = 100;

/*
 * bar_font — the type the progress bars are drawn in: monospaced, so the
 * block characters butt up against each other and the two bars line up
 * cell for cell.
 *
 * Output: the shared bar font.
 */
static NSFont *
bar_font(void)
{
    static NSFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    });
    return font;
}

/*
 * bar_text — one text progress bar: an optional label, the bar itself with
 * the part done in full blocks and the rest in light shade, then the
 * percentage and, for the bar that stands for the whole job, the rate it
 * has averaged.
 *
 * Inputs:
 *   label — short prefix such as @"File ", or nil for none
 *   frac  — 0..1; values outside that range are clamped
 *   rate  — bytes a second to show after the percentage; 0 for none
 *
 * Output: e.g. "Total  ██████░░░░░░  52% @ 5.7 MB/s". The percentage is
 * rounded down, so it reads 100% only once the bar is actually full.
 */
static NSString *
bar_text(NSString *label, double frac, double rate)
{
    if (frac < 0.0) frac = 0.0;
    if (frac > 1.0) frac = 1.0;

    NSUInteger filled = (NSUInteger)(frac * bar_cells + 0.5);
    NSString *done = [@"" stringByPaddingToLength:filled
                                       withString:@"█" startingAtIndex:0];
    NSString *left = [@"" stringByPaddingToLength:bar_cells - filled
                                       withString:@"░" startingAtIndex:0];
    return [NSString stringWithFormat:@"%@%@%@  %3d%%%@",
            label ? [label stringByAppendingString:@"  "] : @"",
            done, left, (int)(frac * 100.0),
            rate > 0.0 ? [@" @ " stringByAppendingString:files_format_rate(rate)] : @""];
}

/*
 * log_attributes — how transfer log text is drawn: small monospaced type
 * in the system text color, which follows Light and Dark mode, with extra
 * leading so the lines are easy to tell apart (a little more between log
 * entries than between the wrapped lines of one entry).
 *
 * Output: attributes for the log's text storage.
 */
static NSDictionary<NSAttributedStringKey, id> *
log_attributes(void)
{
    static NSDictionary<NSAttributedStringKey, id> *attrs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
        para.lineSpacing      = 2.0;
        para.paragraphSpacing = 2.0;
        attrs = @{
            NSParagraphStyleAttributeName:  para,
            NSFontAttributeName:            [NSFont monospacedSystemFontOfSize:10.0
                                                                       weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.textColor,
        };
    });
    return attrs;
}

/* ── FilesCopyProgress implementation ───────────────────────────────────── */

@interface FilesCopyProgress () <NSWindowDelegate>

@property (nonatomic, strong) NSTextField  *status_label;
@property (nonatomic, strong) NSTextField  *file_bar;
@property (nonatomic, strong) NSTextField  *total_bar;
@property (nonatomic, strong) NSButton     *cancel_button;
@property (nonatomic, strong) NSButton     *log_toggle;
@property (nonatomic, strong) NSScrollView *log_scroll;
@property (nonatomic, strong) NSTextView   *log_text;

@end

@implementation FilesCopyProgress {
    atomic_int         _cancel;       /* non-zero = abort; address passed to the engine */
    NSTimer           *_tick_timer;   /* takes the engine's updates every tick_interval */
    NSString          *_ed;           /* "Copied" or "Moved", for the final title */
    NSString          *_noun;         /* "copy" or "move" */
    FilesCopyProgress *_self_ref;     /* retains self while window is on screen */
    NSUInteger         _log_lines;    /* lines currently in the transfer log */
    BOOL               _log_expanded; /* YES when the transfer log panel is open */
    BOOL               _bars_set;     /* the file count has settled the bar count */

    /* Written by the engine on the copy thread, taken by take_engine_updates
     * on the main thread; all guarded by _engine_lock. */
    os_unfair_lock     _engine_lock;
    NSMutableArray<NSString *> *_engine_log;  /* timestamped lines not yet shown */
    int64_t            _engine_files;     /* files the job will touch; 0 until counted */
    double             _engine_file_frac;  /* 0..1 through the current file */
    double             _engine_job_frac;   /* 0..1 through the job */
    double             _engine_rate;       /* bytes a second so far, 0 if unknown */
}

/* ── Panel construction ─────────────────────────────────────────────────── */

/*
 * init_with_dest:is_cut: — build the progress panel. Its text says
 * "Moving"/"Moved"/"move" for a move and "Copying"/"Copied"/"copy"
 * otherwise. The panel is built with both progress bars; show_bars: drops
 * the second one once the engine reports a single-file job.
 *
 * Inputs:
 *   dest   — destination directory URL
 *   is_cut — YES for a move
 *
 * Output: configured window controller or nil.
 */
- (instancetype)
init_with_dest:(NSURL *)dest is_cut:(BOOL)is_cut
{
    NSString *ing    = is_cut ? @"Moving" : @"Copying";
    CGFloat   height = edge + status_height + status_gap + bar_height + bar_gap
                       + bar_height + button_gap + button_height + edge;
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, panel_width, height)
                  styleMask:NSWindowStyleMaskTitled
                           | NSWindowStyleMaskClosable
                           | NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title                  = [ing stringByAppendingString:@"..."];
    panel.worksWhenModal         = YES;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.hidesOnDeactivate      = NO;

    self = [super initWithWindow:panel];
    if (!self) return nil;

    atomic_init(&_cancel, 0);
    _ed        = is_cut ? @"Moved" : @"Copied";
    _noun      = is_cut ? @"move"  : @"copy";
    _self_ref  = self;  /* broken in windowWillClose: */
    _engine_lock = OS_UNFAIR_LOCK_INIT;
    _engine_log  = [NSMutableArray array];

    panel.delegate = self;
    [self build_views_with_verb:ing dest:dest.lastPathComponent];
    [panel center];
    return self;
}

/*
 * build_views_with_verb:dest: — lay out all subviews in the panel content
 * view: the status line and the two progress bars pinned to the top, the
 * Cancel/Close button in the bottom-right corner (edge from both sides)
 * and the Transfer Log toggle at the bottom-left on the same row. When the
 * window grows downward to reveal the transfer log, the log fills the space
 * between the last bar and the button row.
 *
 * Inputs:
 *   verb — "Copying" or "Moving", for the opening status line
 *   dest — destination folder name, for the same line
 */
- (void)
build_views_with_verb:(NSString *)verb dest:(NSString *)dest
{
    NSView *cv = self.window.contentView;
    CGFloat w  = cv.bounds.size.width - 2 * edge;
    CGFloat y  = cv.bounds.size.height - edge;

    /* Status line — the latest line of the transfer log */
    y -= status_height;
    self.status_label = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%@ to \"%@\"...", verb, dest]];
    self.status_label.frame            = NSMakeRect(edge, y, w, status_height);
    self.status_label.font             = [NSFont systemFontOfSize:12.0];
    self.status_label.lineBreakMode    = NSLineBreakByTruncatingMiddle;
    self.status_label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:self.status_label];

    /* Progress bars — the current file, and the whole job under it */
    y -= status_gap + bar_height;
    self.file_bar = [self add_bar_at:y label:@"File " to:cv];
    y -= bar_gap + bar_height;
    self.total_bar = [self add_bar_at:y label:@"Total" to:cv];

    /* Cancel/Close button — fixed distance from the bottom and right edges */
    self.cancel_button = [NSButton buttonWithTitle:@"Cancel"
                                            target:self
                                            action:@selector(cancel_clicked:)];
    self.cancel_button.frame            = NSMakeRect(cv.bounds.size.width - edge - 88, edge,
                                                     88, button_height);
    self.cancel_button.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.cancel_button.keyEquivalent    = @"\033"; /* Escape */
    [cv addSubview:self.cancel_button];

    /* Transfer Log toggle — on the button's row, left edge aligned with the
     * bars and vertically centred on the button */
    self.log_toggle = [NSButton buttonWithTitle:@"▶  Transfer Log"
                                         target:self
                                         action:@selector(toggle_log:)];
    self.log_toggle.frame            = NSMakeRect(edge, edge + (button_height - 16) / 2.0,
                                                  103, 16);
    self.log_toggle.bordered         = NO;
    self.log_toggle.font             = [NSFont systemFontOfSize:11.0];
    self.log_toggle.autoresizingMask = NSViewMaxYMargin;
    [cv addSubview:self.log_toggle];

    /* Transfer log scroll view — hidden until expanded; toggle_log: places it
     * between the last bar and the button. */
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(edge, 0, w, log_height)];
    sv.hasVerticalScroller   = YES;
    sv.hasHorizontalScroller = NO;
    sv.borderType            = NSBezelBorder;
    sv.autohidesScrollers    = YES;
    sv.hidden                = YES;
    sv.autoresizingMask      = NSViewWidthSizable | NSViewHeightSizable;
    [cv addSubview:sv];
    self.log_scroll = sv;

    NSSize cs = sv.contentSize;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
    tv.minSize               = NSMakeSize(0, cs.height);
    tv.maxSize               = NSMakeSize(cs.width, FLT_MAX);
    tv.verticallyResizable   = YES;
    tv.horizontallyResizable = NO;
    tv.editable              = NO;
    tv.selectable            = YES;
    tv.richText              = NO;
    tv.typingAttributes      = log_attributes();
    tv.backgroundColor       = NSColor.textBackgroundColor;
    tv.textContainerInset    = NSMakeSize(4, 4);
    tv.autoresizingMask      = NSViewWidthSizable;
    [tv.textContainer setContainerSize:NSMakeSize(cs.width, FLT_MAX)];
    [tv.textContainer setWidthTracksTextView:YES];
    /* Lay out only what is visible, so appending and scrolling to the end
     * do not re-lay-out the whole log. */
    tv.layoutManager.allowsNonContiguousLayout = YES;
    sv.documentView = tv;
    self.log_text   = tv;
}

/*
 * add_bar_at:label:to: — builds one empty progress bar and adds it to the
 * content view. The bar sticks to the top of the window, like the status
 * line above it.
 *
 * Inputs:
 *   y     — bottom edge of the bar in the content view
 *   label — short prefix, as bar_text takes it
 *   cv    — content view to add it to
 *
 * Output: the new label, retained by cv.
 */
- (NSTextField *)
add_bar_at:(CGFloat)y label:(NSString *)label to:(NSView *)cv
{
    NSTextField *bar = [NSTextField labelWithString:bar_text(label, 0.0, 0.0)];
    bar.frame            = NSMakeRect(edge, y, cv.bounds.size.width - 2 * edge, bar_height);
    bar.font             = bar_font();
    bar.textColor        = NSColor.secondaryLabelColor;
    bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:bar];
    return bar;
}

/*
 * show_bars: — settles how many bars the job needs, the first time the
 * engine reports its file count: one bar for a single file, a second
 * "Total" bar under it for more. Dropping the second bar shrinks the window
 * by its height, keeping the top edge where it is.
 *
 * Inputs:
 *   files — regular files the job will touch
 */
- (void)
show_bars:(int64_t)files
{
    if (_bars_set) return;
    _bars_set = YES;
    if (files > 1) return;  /* the panel was built with both bars */

    self.total_bar.hidden     = YES;
    self.file_bar.stringValue = bar_text(nil, 0.0, 0.0);

    CGFloat delta = bar_height + bar_gap;
    NSRect  wf    = self.window.frame;
    wf.origin.y    += delta;
    wf.size.height -= delta;
    [self.window setFrame:wf display:YES];
}

/*
 * toggle_log: — expand or collapse the transfer log panel.
 *
 * Grows the window downward by log_height + log_gap when expanding, then
 * places the log between the last visible bar and the Cancel/Close button
 * (log_gap from each) and scrolls it to the newest line. Collapsing hides
 * the log first, then shrinks the window back. The top rows stay pinned to
 * the top and the button to the bottom-right throughout.
 *
 * Inputs:
 *   sender — the log_toggle NSButton (ignored)
 */
- (void)
toggle_log:(id)sender
{
    _log_expanded = !_log_expanded;
    self.log_toggle.title = _log_expanded
        ? @"▼  Transfer Log"
        : @"▶  Transfer Log";

    CGFloat delta = log_height + log_gap;
    NSRect  wf    = self.window.frame;

    if (_log_expanded) {
        wf.origin.y    -= delta;
        wf.size.height += delta;
        [self.window setFrame:wf display:YES animate:YES];

        NSTextField *last   = self.total_bar.hidden ? self.file_bar : self.total_bar;
        CGFloat      bottom = NSMaxY(self.cancel_button.frame) + log_gap;
        CGFloat      top    = NSMinY(last.frame) - log_gap;
        self.log_scroll.frame  = NSMakeRect(NSMinX(last.frame), bottom,
                                            NSWidth(last.frame), top - bottom);
        self.log_scroll.hidden = NO;
        [self.log_text scrollToEndOfDocument:nil];
    } else {
        self.log_scroll.hidden = YES;
        wf.origin.y    += delta;
        wf.size.height -= delta;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.2;
            [self.window.animator setFrame:wf display:YES];
        }];
    }
}

/* Length of the "[HH:mm:ss]" stamp that stamped() puts on each log line. */
static const NSUInteger stamp_length = 10;

/*
 * stamped — line prefixed with the current time, as the log shows it.
 *
 * Inputs:
 *   line — log text
 *
 * Output: "[HH:mm:ss] line"; the bracketed stamp is stamp_length characters.
 */
static NSString *
stamped(NSString *line)
{
    static NSDateFormatter *fmt;
    static dispatch_once_t  once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    return [NSString stringWithFormat:@"[%@] %@", [fmt stringFromDate:NSDate.date], line];
}

/*
 * append_log_lines: — append already-timestamped lines to the transfer log
 * text view in one edit.
 *
 * Each line's timestamp is drawn bold.
 *
 * Keeps at most log_max_lines lines: when log_trim_batch lines beyond that
 * have accumulated, the oldest ones are deleted from the start of the text
 * storage in a single edit. Scrolls to the end only while the log is
 * expanded. Must be called on the main thread.
 *
 * Inputs:
 *   lines — lines from stamped(), without trailing newlines
 */
- (void)
append_log_lines:(NSArray<NSString *> *)lines
{
    if (lines.count == 0) return;
    NSTextStorage *ts  = self.log_text.textStorage;
    NSString      *sep = ts.length ? @"\n" : @"";

    NSMutableAttributedString *added = [[NSMutableAttributedString alloc]
        initWithString:[sep stringByAppendingString:[lines componentsJoinedByString:@"\n"]]
            attributes:log_attributes()];
    NSFont *bold = [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold];
    NSUInteger at = sep.length;
    for (NSString *line in lines) {
        [added addAttribute:NSFontAttributeName value:bold
                      range:NSMakeRange(at, MIN(stamp_length, line.length))];
        at += line.length + 1;
    }

    [ts beginEditing];
    [ts appendAttributedString:added];
    _log_lines += lines.count;

    if (_log_lines > log_max_lines + log_trim_batch) {
        NSString  *text  = ts.string;
        NSUInteger drop  = _log_lines - log_max_lines;
        NSUInteger cut   = 0;
        for (NSUInteger i = 0; i < drop; i++) {
            NSRange nl = [text rangeOfString:@"\n" options:NSLiteralSearch
                                       range:NSMakeRange(cut, text.length - cut)];
            cut = NSMaxRange(nl);
        }
        [ts deleteCharactersInRange:NSMakeRange(0, cut)];
        _log_lines = log_max_lines;
    }
    [ts endEditing];

    if (_log_expanded) [self.log_text scrollToEndOfDocument:nil];
}

/*
 * engine_progress:file_frac:job_frac:rate: — records the engine's latest
 * progress. Called on the copy thread for every report, which is far more
 * often than the panel redraws; take_engine_updates shows the newest on the
 * next tick.
 *
 * Inputs:
 *   files     — regular files the job will touch
 *   file_frac — 0..1 through the current file's steps
 *   job_frac  — 0..1 through the job's steps
 *   rate      — bytes a second the job has averaged, 0 if not yet known
 */
- (void)
engine_progress:(int64_t)files file_frac:(double)file_frac job_frac:(double)job_frac
           rate:(double)rate
{
    os_unfair_lock_lock(&_engine_lock);
    _engine_files     = files;
    _engine_file_frac = file_frac;
    _engine_job_frac  = job_frac;
    _engine_rate      = rate;
    os_unfair_lock_unlock(&_engine_lock);
}

/*
 * engine_log: — timestamps an engine log line and holds it for the next
 * tick, so a copy of thousands of small files costs one text edit per tick
 * instead of a main-queue hop per line. Called on the copy thread.
 *
 * Inputs:
 *   line — engine log text
 */
- (void)
engine_log:(NSString *)line
{
    NSString *entry = stamped(line);
    os_unfair_lock_lock(&_engine_lock);
    [_engine_log addObject:entry];
    os_unfair_lock_unlock(&_engine_lock);
}

/*
 * take_engine_updates — shows what the engine reported since the last call:
 * appends its log lines, puts the newest of them in the status line — which
 * is why the status line and the log always agree — and moves the progress
 * bars. Main thread only.
 */
- (void)
take_engine_updates
{
    os_unfair_lock_lock(&_engine_lock);
    NSArray<NSString *> *lines = _engine_log.count ? [_engine_log copy] : nil;
    [_engine_log removeAllObjects];
    int64_t files     = _engine_files;
    double  file_frac = _engine_file_frac;
    double  job_frac  = _engine_job_frac;
    double  rate      = _engine_rate;
    os_unfair_lock_unlock(&_engine_lock);

    if (lines) {
        [self append_log_lines:lines];
        /* The stamp is in the log, not the status line. */
        NSString *newest = lines.lastObject;
        self.status_label.stringValue = newest.length > stamp_length + 1
            ? [newest substringFromIndex:stamp_length + 1] : newest;
    }

    /* The rate is the job's, so it goes on the bar that stands for the
     * job: the Total bar, or the single bar of a one-file job. */
    if (files > 0) [self show_bars:files];
    BOOL one_bar = self.total_bar.hidden;
    self.file_bar.stringValue = bar_text(one_bar ? nil : @"File ", file_frac,
                                         one_bar ? rate : 0.0);
    if (!one_bar) {
        self.total_bar.stringValue = bar_text(@"Total", job_frac, rate);
    }
}

/*
 * stop_tick_timer — stops taking the engine's updates.
 */
- (void)
stop_tick_timer
{
    [_tick_timer invalidate];
    _tick_timer = nil;
}

/*
 * finish_with_error: — show the final state after the copy ends: takes the
 * engine's last updates, which include the line stating how the job ended
 * and how long it took, so the status line needs nothing added; sets the
 * window title ("Copied"/"Moved", or "Copy Failed"/"Move Failed") and
 * switches the button to "Close".
 *
 * Inputs:
 *   err — engine error, or nil on success
 */
- (void)
finish_with_error:(NSError *)err
{
    [self stop_tick_timer];
    [self take_engine_updates];

    self.window.title = err == nil
        ? _ed
        : [NSString stringWithFormat:@"%@ Failed", _noun.capitalizedString];
    self.cancel_button.title         = @"Close";
    self.cancel_button.action        = @selector(close_clicked:);
    self.cancel_button.enabled       = YES;
    self.cancel_button.keyEquivalent = @"\r";
}

/*
 * close_clicked: — close the panel.
 *
 * Inputs:
 *   sender — ignored
 */
- (void)
close_clicked:(id)sender
{
    [self close];
}

/* ── Class-level entry point ────────────────────────────────────────────── */

/*
 * begin_copy:to:is_cut:hash_validate:completion: — shows the progress panel
 * immediately so Cancel is available from the start, then starts the copy.
 *
 * Inputs:
 *   srcs          — source URLs; empty = call completion(nil) and return
 *   dest          — destination directory URL
 *   is_cut        — YES = move sources after copying
 *   hash_validate — YES = SHA-256 verify each file
 *   completion    — called on main queue after the panel shows its final state
 */
+ (void)
begin_copy:(NSArray<NSURL *> *)srcs
        to:(NSURL *)dest
    is_cut:(BOOL)is_cut
hash_validate:(BOOL)hash_validate
completion:(void (^)(NSError *))completion
{
    if (srcs.count == 0) {
        if (completion) completion(nil);
        return;
    }

    FilesCopyProgress *panel = [[FilesCopyProgress alloc] init_with_dest:dest is_cut:is_cut];
    [panel showWindow:nil];
    [panel start_copy:srcs to:dest is_cut:is_cut
        hash_validate:hash_validate completion:completion];
}

/* ── Instance copy driver ───────────────────────────────────────────────── */

/*
 * start_copy:to:is_cut:hash_validate:completion: — kick off the copy using
 * the FilesFileOps engine. Its progress and log blocks run on the copy
 * thread and only record what they are given (engine_progress:file_frac:…,
 * engine_log:); the tick timer shows it every tick_interval.
 *
 * Inputs:
 *   srcs          — source URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = move
 *   hash_validate — YES = verify hashes
 *   completion    — called after the panel shows its final state
 */
- (void)
start_copy:(NSArray<NSURL *> *)srcs
        to:(NSURL *)dest
    is_cut:(BOOL)is_cut
hash_validate:(BOOL)hash_validate
completion:(void (^)(NSError *))completion
{
    /* The engine's blocks capture self strongly, keeping it (and so the
     * _cancel ivar whose address the engine holds) alive until the copy
     * completes. NSWindow.windowController is unsafe_unretained; without
     * this the panel could be freed mid-copy. */
    FilesCopyProgress *alive = self;
    __weak FilesCopyProgress *weak_self = self;

    _tick_timer = [NSTimer timerWithTimeInterval:tick_interval repeats:YES
                                           block:^(NSTimer *t) {
        [weak_self take_engine_updates];
    }];
    [NSRunLoop.mainRunLoop addTimer:_tick_timer forMode:NSRunLoopCommonModes];

    FileCopyProgressBlock progress = ^(int64_t files, double file_frac,
                                       double job_frac, double rate) {
        [alive engine_progress:files file_frac:file_frac job_frac:job_frac rate:rate];
    };
    FileCopyLogBlock log = ^(NSString *line) {
        [alive engine_log:line];
    };

    [FilesFileOps run_copy_srcs:srcs to:dest is_cut:is_cut
                  hash_validate:hash_validate conflict:[self make_conflict_block]
                    cancel_flag:&_cancel progress:progress log:log
                     completion:^(NSError *err)
    {
        /* Called on main queue. */
        if (err.code == NSUserCancelledError &&
            [err.domain isEqualToString:NSCocoaErrorDomain]) {
            [alive close];
        } else {
            [alive finish_with_error:err];
        }
        if (completion) completion(err);
    }];
}

/* ── Conflict resolution ────────────────────────────────────────────────── */

/*
 * make_conflict_block — returns a block that presents a conflict sheet when a
 * destination file already exists. The block must run off the main thread:
 * it blocks its (background copy) thread on a semaphore until the user
 * dismisses the sheet.
 *
 * Output: block returning FilesConflictKeepBoth, FilesConflictOverwrite, or
 *         FilesConflictCancel (user chose Cancel, or the panel is gone).
 */
- (FilesConflictBlock)
make_conflict_block
{
    __weak FilesCopyProgress *weak_self = self;
    return ^FilesConflictResolution(NSURL *src, NSURL *dst) {
        NSCAssert(!NSThread.isMainThread,
                  @"conflict block blocks on a semaphore; never call it on main");
        __block FilesConflictResolution result = FilesConflictCancel;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        dispatch_async(dispatch_get_main_queue(), ^{
            FilesCopyProgress *p = weak_self;
            if (!p) {
                dispatch_semaphore_signal(sem);
                return;
            }
            [SharedToolPanel show_message:[NSString stringWithFormat:
                                              @"\"%@\" already exists in this location.",
                                              dst.lastPathComponent]
                                  message:[NSString stringWithFormat:
                                              @"Keep both files, replace the existing one, "
                                              @"or stop the %@?", p->_noun]
                                   symbol:@"doc.on.doc"
                                  buttons:@[@"Keep Both", @"Replace", @"Cancel"]
                              destructive:1
                                     over:p.window
                                  handler:^(NSInteger resp) {
                if (resp == 0)      result = FilesConflictKeepBoth;
                else if (resp == 1) result = FilesConflictOverwrite;
                else                result = FilesConflictCancel;
                dispatch_semaphore_signal(sem);
            }];
        });

        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return result;
    };
}

/* ── Cancel / close ─────────────────────────────────────────────────────── */

/*
 * cancel_clicked: — set the cancel flag and disable the button.
 *
 * Inputs:
 *   sender — cancel NSButton
 */
- (void)
cancel_clicked:(id)sender
{
    atomic_store(&_cancel, 1);
    self.cancel_button.enabled    = NO;
    self.status_label.stringValue = @"Cancelling...";
}

/*
 * windowWillClose: — set cancel flag so any in-flight copy drains cleanly,
 * stop taking the engine's updates, and drop the self-reference that kept
 * the panel alive while on screen.
 *
 * Inputs:
 *   n — NSWindowWillCloseNotification
 */
- (void)
windowWillClose:(NSNotification *)n
{
    atomic_store(&_cancel, 1);
    [self stop_tick_timer];
    _self_ref = nil;
}

@end
