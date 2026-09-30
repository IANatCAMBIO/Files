#import "copy_progress.h"
#import "file_ops.h"
#import "speed_graph.h"
#import "util.h"

/* Minimum time between progress updates sent to the main queue, and between
 * speed samples; the engine reports every 1 MB, far more often on fast disks. */
static const CFTimeInterval progress_interval = 0.1;

static const CGFloat log_height    = 160.0; /* extra window height for the transfer log */
static const CGFloat log_gap       = 8.0;   /* space above and below the log */
static const CGFloat button_margin = 12.0;  /* Cancel/Close inset from bottom and right */

/* The transfer log keeps at most log_max_lines lines; once log_trim_batch
 * extra lines have accumulated, the oldest are dropped in one edit. */
static const NSUInteger log_max_lines  = 1000;
static const NSUInteger log_trim_batch = 100;

/* ── Speed sliding-window state ─────────────────────────────────────────── */

/* Samples in the sliding window; samples are at least progress_interval
 * apart, so the window spans at least ~1.5 s of transfer. */
enum { speed_ring_len = 16 };

/*
 * speed_sample_t — one point of the speed sliding window.
 *
 * Fields:
 *   timestamp  — CFAbsoluteTime taken on the copy thread when reported
 *   total_done — bytes copied across the whole operation at that time
 */
typedef struct {
    CFAbsoluteTime timestamp;
    int64_t        total_done;
} speed_sample_t;

/*
 * speed_ring_t — circular buffer of the last speed_ring_len samples.
 *
 * Fields:
 *   samples — sample storage
 *   head    — index the next sample is written to
 *   count   — valid samples (≤ speed_ring_len)
 */
typedef struct {
    speed_sample_t samples[speed_ring_len];
    int            head;
    int            count;
} speed_ring_t;

/* ── FilesCopyProgress implementation ───────────────────────────────────── */

@interface FilesCopyProgress () <NSWindowDelegate>

@property (nonatomic, strong) NSTextField     *status_label;
@property (nonatomic, strong) FilesSpeedGraph *speed_graph;
@property (nonatomic, strong) NSTextField     *elapsed_label;
@property (nonatomic, strong) NSButton        *cancel_button;
@property (nonatomic, strong) NSButton        *log_toggle;
@property (nonatomic, strong) NSScrollView    *log_scroll;
@property (nonatomic, strong) NSTextView      *log_text;

@end

@implementation FilesCopyProgress {
    atomic_int         _cancel;       /* non-zero = abort; address passed to the engine */
    speed_ring_t       _speed;        /* speed sliding window (main thread only) */
    NSString          *_dest_name;    /* destination folder name for labels */
    NSString          *_cur_name;     /* file most recently reported by the engine */
    int64_t            _total_done;   /* bytes copied so far across all files */
    CFAbsoluteTime     _start_time;   /* set when the copy is started */
    FilesCopyProgress *_self_ref;     /* retains self while window is on screen */
    NSUInteger         _log_lines;    /* lines currently in the transfer log */
    BOOL               _log_expanded; /* YES when the transfer log panel is open */
}

/* ── Panel construction ─────────────────────────────────────────────────── */

/*
 * init_with_dest: — build the progress panel.
 *
 * Inputs:
 *   dest — destination directory URL
 *
 * Output: configured window controller or nil.
 */
- (instancetype)
init_with_dest:(NSURL *)dest
{
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 460, 210)
                  styleMask:NSWindowStyleMaskTitled
                           | NSWindowStyleMaskClosable
                           | NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title                  = @"Copying...";
    panel.worksWhenModal         = YES;
    panel.becomesKeyOnlyIfNeeded = YES;

    self = [super initWithWindow:panel];
    if (!self) return nil;

    atomic_init(&_cancel, 0);
    _dest_name = dest.lastPathComponent;
    _cur_name  = @"";
    _self_ref  = self;  /* broken in windowWillClose: */

    panel.delegate = self;
    [self build_views];
    [panel center];
    return self;
}

/*
 * build_views — lay out all subviews in the panel content view.
 *
 * The status line, graph and Transfer Log row are pinned to the top; the
 * Cancel/Close button is pinned to the bottom-right corner (button_margin
 * from both edges). When the window grows downward to reveal the transfer
 * log, the log fills the space between the Transfer Log row and the button.
 * Uses _dest_name for the initial status text.
 */
- (void)
build_views
{
    NSView *cv = self.window.contentView;
    CGFloat w  = cv.bounds.size.width;
    CGFloat y  = cv.bounds.size.height - 10;

    /* Status line */
    y -= 14;
    self.status_label = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Copying to \"%@\"...", _dest_name]];
    self.status_label.frame            = NSMakeRect(12, y, w - 24, 14);
    self.status_label.font             = [NSFont systemFontOfSize:12.0];
    self.status_label.lineBreakMode    = NSLineBreakByTruncatingMiddle;
    self.status_label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:self.status_label];

    /* Speed graph */
    y -= 8;
    CGFloat graph_h = 110.0;
    y -= graph_h;
    self.speed_graph = [[FilesSpeedGraph alloc]
        initWithFrame:NSMakeRect(12, y, w - 24, graph_h)];
    self.speed_graph.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:self.speed_graph];

    /* Transfer Log toggle + elapsed-time row.
     * label_top = graph_bottom - 8 gap -> label_origin = y - 8 - 14. */
    CGFloat label_y = y - 8 - 14;

    /* Transfer Log toggle — left edge aligned with graph */
    self.log_toggle = [NSButton buttonWithTitle:@"▶  Transfer Log"
                                         target:self
                                         action:@selector(toggle_log:)];
    self.log_toggle.frame            = NSMakeRect(12, label_y - 1, 103, 16);
    self.log_toggle.bordered         = NO;
    self.log_toggle.font             = [NSFont systemFontOfSize:11.0];
    self.log_toggle.autoresizingMask = NSViewMinYMargin;
    [cv addSubview:self.log_toggle];

    /* Elapsed-time label — filled in when the copy finishes */
    self.elapsed_label = [NSTextField labelWithString:@""];
    self.elapsed_label.frame            = NSMakeRect(220, label_y, w - 232, 14);
    self.elapsed_label.font             = [NSFont systemFontOfSize:11.0];
    self.elapsed_label.textColor        = NSColor.secondaryLabelColor;
    self.elapsed_label.alignment        = NSTextAlignmentRight;
    self.elapsed_label.autoresizingMask = NSViewWidthSizable | NSViewMinXMargin | NSViewMinYMargin;
    [cv addSubview:self.elapsed_label];

    /* Cancel/Close button — fixed distance from the bottom and right edges */
    self.cancel_button = [NSButton buttonWithTitle:@"Cancel"
                                            target:self
                                            action:@selector(cancel_clicked:)];
    self.cancel_button.frame             = NSMakeRect(w - button_margin - 88, button_margin, 88, 22);
    self.cancel_button.autoresizingMask  = NSViewMinXMargin | NSViewMaxYMargin;
    self.cancel_button.keyEquivalent     = @"\033"; /* Escape */
    [cv addSubview:self.cancel_button];

    /* Transfer log scroll view — hidden until expanded; toggle_log: places it
     * between the Transfer Log row and the button. */
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(12, 0, w - 24, log_height)];
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
    tv.font                  = [NSFont monospacedSystemFontOfSize:10.0
                                                          weight:NSFontWeightRegular];
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
 * toggle_log: — expand or collapse the transfer log panel.
 *
 * Grows the window downward by log_height + log_gap when expanding, then
 * places the log between the Transfer Log row and the Cancel/Close button
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

        CGFloat bottom = NSMaxY(self.cancel_button.frame) + log_gap;
        CGFloat top    = NSMinY(self.log_toggle.frame) - log_gap;
        self.log_scroll.frame  = NSMakeRect(NSMinX(self.speed_graph.frame), bottom,
                                            NSWidth(self.speed_graph.frame), top - bottom);
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

/*
 * append_log: — append a timestamped line to the transfer log text view.
 *
 * Keeps at most log_max_lines lines: when log_trim_batch lines beyond that
 * have accumulated, the oldest ones are deleted from the start of the text
 * storage in a single edit. Scrolls to the new line only while the log is
 * expanded. Must be called on the main thread.
 *
 * Inputs:
 *   line — text to append (no trailing newline needed)
 */
- (void)
append_log:(NSString *)line
{
    static NSDateFormatter *fmt;
    static dispatch_once_t  once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    NSTextStorage *ts  = self.log_text.textStorage;
    NSString      *sep = ts.length ? @"\n" : @"";

    [ts beginEditing];
    [ts replaceCharactersInRange:NSMakeRange(ts.length, 0)
                      withString:[NSString stringWithFormat:@"%@[%@] %@",
                                  sep, [fmt stringFromDate:NSDate.date], line]];
    _log_lines++;

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
 * show_progress:file_total:total_done:time: — apply one throttled progress
 * report to the panel. Updates the status label and logs the file when the
 * file name changes; adds a speed-graph sample when at least
 * progress_interval has passed since the previous one. Main thread only.
 *
 * Inputs:
 *   name       — current file name
 *   file_total — size of the current file in bytes
 *   total_done — bytes copied across all files so far
 *   now        — CFAbsoluteTime at which the engine reported this progress
 */
- (void)
show_progress:(NSString *)name
   file_total:(int64_t)file_total
   total_done:(int64_t)total_done
         time:(CFAbsoluteTime)now
{
    _total_done = total_done;

    if (![name isEqualToString:_cur_name]) {
        _cur_name = name;
        self.status_label.stringValue = [NSString stringWithFormat:
            @"Copying \"%@\" to %@", name, _dest_name];
        if (name.length) {
            [self append_log:file_total > 0
                ? [NSString stringWithFormat:@"-> %@ (%@)", name,
                   files_format_bytes(file_total)]
                : [NSString stringWithFormat:@"-> %@", name]];
        }
    }

    /* Speed via sliding window over time-spaced samples */
    speed_ring_t *spd = &_speed;
    if (spd->count > 0) {
        int newest = (spd->head - 1 + speed_ring_len) % speed_ring_len;
        if (now - spd->samples[newest].timestamp < progress_interval) return;
    }
    spd->samples[spd->head] = (speed_sample_t){now, total_done};
    spd->head               = (spd->head + 1) % speed_ring_len;
    if (spd->count < speed_ring_len) spd->count++;

    double bps = 0;
    if (spd->count >= 2) {
        int oldest = (spd->head - spd->count + speed_ring_len) % speed_ring_len;
        int newest = (spd->head - 1 + speed_ring_len) % speed_ring_len;
        CFTimeInterval dt = spd->samples[newest].timestamp
                          - spd->samples[oldest].timestamp;
        int64_t        db = spd->samples[newest].total_done
                          - spd->samples[oldest].total_done;
        if (dt > 0.01) bps = (double)db / dt;
    }

    /* Running average: total bytes transferred / elapsed wall time */
    CFTimeInterval elapsed = now - _start_time;
    double avg_bps = (elapsed > 0.001 && total_done > 0)
                   ? (double)total_done / elapsed : 0.0;

    [self.speed_graph add_sample:bps average:avg_bps];
}

/*
 * finish_with_error:hash_results: — show the final state after the copy
 * ends: logs the error and per-file hash results, sets the status line,
 * switches the button to "Close", adds a final average-speed graph sample
 * (so single-chunk copies still show something) and shows elapsed time.
 *
 * Inputs:
 *   err          — engine error, or nil on success
 *   hash_results — per-destination-URL hash match flags; may be nil
 */
- (void)
finish_with_error:(NSError *)err
     hash_results:(NSDictionary<NSURL *, NSNumber *> *)hash_results
{
    BOOL all_ok = (err == nil);
    if (err) {
        [self append_log:[NSString stringWithFormat:@"✗ %@", err.localizedDescription]];
    }
    for (NSURL *url in hash_results) {
        BOOL match = [hash_results[url] boolValue];
        if (!match) all_ok = NO;
        [self append_log:[NSString stringWithFormat:@"%@ SHA256 Validation: %@ [%@]",
            match ? @"✓" : @"✗", url.lastPathComponent,
            match ? @"PASSED" : @"FAILED"]];
    }
    self.status_label.stringValue = all_ok
        ? [NSString stringWithFormat:@"Copied \"%@\" to %@",
           _cur_name.length ? _cur_name : @"files", _dest_name]
        : @"Copy failed.";

    self.cancel_button.title         = @"Close";
    self.cancel_button.action        = @selector(close_clicked:);
    self.cancel_button.enabled       = YES;
    self.cancel_button.keyEquivalent = @"\r";

    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - _start_time;
    if (elapsed < 0.001) elapsed = 0.001;

    double avg_bps = (_total_done > 0) ? (double)_total_done / elapsed : 0.0;

    [self append_log:all_ok
        ? [NSString stringWithFormat:@"✓ Done — avg %@, %.1f sec total",
           files_format_rate(avg_bps), elapsed]
        : @"✗ Copy failed"];

    [self.speed_graph add_sample:avg_bps average:avg_bps];

    if (elapsed < 1.0) {
        self.elapsed_label.stringValue =
            [NSString stringWithFormat:@"Completed in %.2f sec", elapsed];
    } else if (elapsed < 60.0) {
        self.elapsed_label.stringValue =
            [NSString stringWithFormat:@"Completed in %.1f sec", elapsed];
    } else {
        int64_t s = (int64_t)elapsed;
        self.elapsed_label.stringValue =
            [NSString stringWithFormat:@"Completed in %lld min %lld sec",
             s / 60, s % 60];
    }
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

    FilesCopyProgress *panel = [[FilesCopyProgress alloc] init_with_dest:dest];
    [panel showWindow:nil];
    [panel start_copy:srcs to:dest is_cut:is_cut
        hash_validate:hash_validate completion:completion];
}

/* ── Instance copy driver ───────────────────────────────────────────────── */

/*
 * start_copy:to:is_cut:hash_validate:completion: — kick off the copy using
 * the FilesFileOps engine, piping throttled progress events into the panel.
 *
 * The progress block runs on the copy thread and forwards a report to the
 * main queue only when a file starts (file_done == 0), a file finishes
 * (file_done >= file_total), or progress_interval has passed since the last
 * forwarded report.
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
    /* Strong capture keeps self (and so the _cancel ivar whose address the
     * engine holds) alive until the copy completes. NSWindow.windowController
     * is unsafe_unretained; without this the panel could be freed mid-copy. */
    FilesCopyProgress *alive = self;
    __weak FilesCopyProgress *weak_self = self;

    _start_time = CFAbsoluteTimeGetCurrent();

    NSString *src_desc = srcs.count == 1
        ? [NSString stringWithFormat:@"\"%@\"", srcs.firstObject.lastPathComponent]
        : [NSString stringWithFormat:@"%lu files", (unsigned long)srcs.count];
    [self append_log:[NSString stringWithFormat:@"Copying %@ -> %@%@",
        src_desc, _dest_name, hash_validate ? @" (SHA256)" : @""]];

    __block CFAbsoluteTime last_sent = 0;  /* copy thread only */
    FileCopyProgressBlock progress = ^(NSString *name, int64_t f_done, int64_t f_total,
                                       int64_t t_done)
    {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (f_done != 0 && f_done < f_total && now - last_sent < progress_interval) {
            return;
        }
        last_sent = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weak_self show_progress:name file_total:f_total total_done:t_done time:now];
        });
    };

    [FilesFileOps run_copy_srcs:srcs to:dest is_cut:is_cut
                  hash_validate:hash_validate conflict:[self make_conflict_block]
                    cancel_flag:&_cancel progress:progress
                     completion:^(NSError *err, NSDictionary<NSURL *, NSNumber *> *hash_results)
    {
        /* Called on main queue. alive keeps _cancel valid until here. */
        (void)alive;
        FilesCopyProgress *p = weak_self;
        if (p) {
            if (err.code == NSUserCancelledError &&
                [err.domain isEqualToString:NSCocoaErrorDomain]) {
                [p close];
            } else {
                [p finish_with_error:err hash_results:hash_results];
            }
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
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText =
                [NSString stringWithFormat:@"\"%@\" already exists in this location.",
                 dst.lastPathComponent];
            alert.informativeText =
                @"Keep both files, replace the existing one, or stop the copy?";
            [alert addButtonWithTitle:@"Keep Both"];
            [alert addButtonWithTitle:@"Replace"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:p.window
                          completionHandler:^(NSModalResponse resp) {
                if (resp == NSAlertFirstButtonReturn)       result = FilesConflictKeepBoth;
                else if (resp == NSAlertSecondButtonReturn) result = FilesConflictOverwrite;
                else                                        result = FilesConflictCancel;
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
 * and drop the self-reference that kept the panel alive while on screen.
 *
 * Inputs:
 *   n — NSWindowWillCloseNotification
 */
- (void)
windowWillClose:(NSNotification *)n
{
    atomic_store(&_cancel, 1);
    _self_ref = nil;
}

@end
