#import "copy_progress.h"
#import "file_ops.h"
#import "speed_graph.h"
#include <libkern/OSAtomic.h>

/* ── Speed sliding-window state ─────────────────────────────────────────── */

#define SPEED_RING 16  /* samples in sliding window (each ~250 ms apart) */

typedef struct {
    CFTimeInterval timestamp;
    int64_t        total_done;
} speed_sample_t;

/* Heap-allocated ring so blocks can capture a pointer, not an array. */
typedef struct {
    speed_sample_t samples[SPEED_RING];
    int            head;
    int            count;
} speed_ring_t;

/* ── Cancel token — heap-allocated so both queue and main thread see it ── */

typedef struct { volatile int32_t flag; } cancel_token_t;

#define LOG_HEIGHT  160.0   /* height of expanded transfer log panel */

/*
 * format_bytes — format a byte count as a human-readable size string.
 *
 * Inputs:
 *   n — byte count (non-negative)
 *
 * Output: string such as "1.2 GB", "512 MB", "64 KB", or "512 B".
 */
static NSString *
format_bytes(int64_t n)
{
    if (n >= (int64_t)1073741824)
        return [NSString stringWithFormat:@"%.1f GB", (double)n / 1073741824.0];
    if (n >= (int64_t)1048576)
        return [NSString stringWithFormat:@"%.1f MB", (double)n / 1048576.0];
    if (n >= (int64_t)1024)
        return [NSString stringWithFormat:@"%.0f KB", (double)n / 1024.0];
    return [NSString stringWithFormat:@"%lld B", n];
}

/* ── FilesCopyProgress implementation ───────────────────────────────────── */

@interface FilesCopyProgress () <NSWindowDelegate>

@property (nonatomic, strong) NSTextField     *status_label;
@property (nonatomic, strong) FilesSpeedGraph *speed_graph;
@property (nonatomic, strong) NSTextField     *eta_label;
@property (nonatomic, strong) NSButton        *cancel_button;
@property (nonatomic, strong) NSButton        *log_toggle;
@property (nonatomic, strong) NSScrollView    *log_scroll;
@property (nonatomic, strong) NSTextView      *log_text;

- (void)append_log:(NSString *)line;
- (BOOL)is_cancelled;

@end

@implementation FilesCopyProgress {
    cancel_token_t    *_cancel;       /* heap-allocated, shared with copy queue */
    CFAbsoluteTime     _start_time;   /* set when copy thread is dispatched */
    FilesCopyProgress *_self_ref;     /* retains self while window is on screen */
    BOOL               _log_expanded; /* YES when the transfer log panel is open */
}

/* ── Panel construction ─────────────────────────────────────────────────── */

/*
 * init_with_dest:hash_validate: — build the progress panel.
 *
 * Inputs:
 *   dest — destination directory URL
 *   hash — YES if hash validation will run
 *
 * Output: configured window controller or nil.
 */
- (instancetype)
init_with_dest:(NSURL *)dest hash_validate:(BOOL)hash
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

    _cancel   = calloc(1, sizeof(cancel_token_t));
    _self_ref = self;  /* broken in windowWillClose: */

    panel.delegate = self;
    [self build_views:dest hash_validate:hash];
    [panel center];
    return self;
}

/*
 * build_views:hash_validate: — lay out all subviews in the panel content view.
 *
 * All existing subviews carry NSViewMinYMargin so they stay pinned to the top
 * when the window expands downward to reveal the transfer log panel.
 *
 * Inputs:
 *   dest — destination directory URL (shown in first label)
 *   hash — unused; retained for call-site symmetry
 */
- (void)
build_views:(NSURL *)dest hash_validate:(BOOL)hash
{
    (void)hash;
    NSView *cv = self.window.contentView;
    CGFloat w  = cv.bounds.size.width;
    CGFloat y  = cv.bounds.size.height - 10;

    /* Status line */
    y -= 14;
    self.status_label = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Copying to \"%@\"...",
         dest.lastPathComponent]];
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

    /* Speed + ETA + Transfer Log toggle row.
     * label_top = graph_bottom - 8 gap -> label_origin = y - 8 - 14. */
    CGFloat label_y = y - 8 - 14;

    /* Transfer Log toggle — left edge aligned with graph, same row as speed/ETA */
    self.log_toggle = [NSButton buttonWithTitle:@"▶  Transfer Log"
                                         target:self
                                         action:@selector(toggle_log:)];
    self.log_toggle.frame            = NSMakeRect(12, label_y - 1, 103, 16);
    self.log_toggle.bordered         = NO;
    self.log_toggle.font             = [NSFont systemFontOfSize:11.0];
    self.log_toggle.autoresizingMask = NSViewMinYMargin;
    [cv addSubview:self.log_toggle];

    /* ETA label */
    self.eta_label = [NSTextField labelWithString:@""];
    self.eta_label.frame             = NSMakeRect(220, label_y, w - 232, 14);
    self.eta_label.font              = [NSFont systemFontOfSize:11.0];
    self.eta_label.textColor         = NSColor.secondaryLabelColor;
    self.eta_label.alignment         = NSTextAlignmentRight;
    self.eta_label.autoresizingMask  = NSViewWidthSizable | NSViewMinXMargin | NSViewMinYMargin;
    [cv addSubview:self.eta_label];

    /* Cancel button — pinned to bottom-right of base window area */
    self.cancel_button = [NSButton buttonWithTitle:@"Cancel"
                                            target:self
                                            action:@selector(cancel_clicked:)];
    self.cancel_button.frame             = NSMakeRect(w - 100, 10, 88, 22);
    self.cancel_button.autoresizingMask  = NSViewMinXMargin | NSViewMinYMargin;
    self.cancel_button.keyEquivalent     = @"\033"; /* Escape */
    [cv addSubview:self.cancel_button];

    /* Transfer log scroll view — sits at the bottom, hidden until expanded */
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(12, 4, w - 24, LOG_HEIGHT)];
    sv.hasVerticalScroller   = YES;
    sv.hasHorizontalScroller = NO;
    sv.borderType            = NSBezelBorder;
    sv.autohidesScrollers    = YES;
    sv.hidden                = YES;
    sv.autoresizingMask      = NSViewWidthSizable;
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
    sv.documentView = tv;
    self.log_text   = tv;
}

/*
 * toggle_log: — expand or collapse the transfer log panel.
 *
 * Grows the window downward by LOG_HEIGHT + 8 when expanding; shrinks it when
 * collapsing.  The scroll view is shown before expansion and hidden after
 * collapse so it is never visible while the window is at its base height.
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

    CGFloat delta = LOG_HEIGHT + 8.0;
    NSRect  wf    = self.window.frame;

    if (_log_expanded) {
        wf.origin.y    -= delta;
        wf.size.height += delta;
        self.log_scroll.hidden = NO;
        [self.window setFrame:wf display:YES animate:YES];
    } else {
        wf.origin.y    += delta;
        wf.size.height -= delta;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.2;
            [self.window.animator setFrame:wf display:YES];
        } completionHandler:^{
            self.log_scroll.hidden = YES;
        }];
    }
}

/*
 * append_log: — append a timestamped line to the transfer log text view.
 *
 * Must be called on the main thread.
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
    NSRange        end = NSMakeRange(ts.length, 0);
    [ts replaceCharactersInRange:end
                     withString:[NSString stringWithFormat:@"%@[%@] %@",
                                 sep, [fmt stringFromDate:NSDate.date], line]];
    [self.log_text scrollToEndOfDocument:nil];
}

/*
 * mark_done_with_success:bytes: — update panel state after the copy finishes.
 * Stops the progress bar animation, fills it to 100%, and shows avg speed and
 * elapsed time.
 *
 * Inputs:
 *   ok    — YES on a clean copy, NO if any file failed
 *   bytes — total bytes transferred during the operation
 */
- (void)
mark_done_with_success:(BOOL)ok bytes:(int64_t)bytes
{
    self.cancel_button.title         = @"Close";
    self.cancel_button.action        = @selector(close_clicked:);
    self.cancel_button.enabled       = YES;
    self.cancel_button.keyEquivalent = @"\r";

    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - _start_time;
    if (elapsed < 0.001) elapsed = 0.001;

    double avg_bps = (bytes > 0) ? (double)bytes / elapsed : 0.0;

    [self append_log:ok
        ? [NSString stringWithFormat:@"✓ Done — avg %@/s, %.1f sec total",
           format_bytes((int64_t)avg_bps), elapsed]
        : @"✗ Copy failed"];

    /* Add one final sample at the average so the graph shows something
     * for small files that complete in a single chunk. */
    [self.speed_graph add_sample:avg_bps average:avg_bps];


    if (elapsed < 1.0) {
        self.eta_label.stringValue =
            [NSString stringWithFormat:@"Completed in %.2f sec", elapsed];
    } else if (elapsed < 60.0) {
        self.eta_label.stringValue =
            [NSString stringWithFormat:@"Completed in %.1f sec", elapsed];
    } else {
        int64_t s = (int64_t)elapsed;
        self.eta_label.stringValue =
            [NSString stringWithFormat:@"Completed in %lld min %lld sec",
             s / 60, s % 60];
    }
}

/*
 * is_cancelled — returns YES if the cancel flag has been set.
 */
- (BOOL)
is_cancelled
{
    return _cancel && _cancel->flag != 0;
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
 * immediately (indeterminate bar) so Cancel is available from the start, then
 * pre-scans total size on a background queue before starting the actual copy.
 *
 * Inputs:
 *   srcs          — source URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = move sources after copying
 *   hash_validate — YES = SHA-256 verify each file
 *   completion    — called on main queue when done
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

    FilesCopyProgress *panel =
        [[FilesCopyProgress alloc] init_with_dest:dest hash_validate:hash_validate];
    [panel showWindow:nil];
    [panel start_copy:srcs to:dest is_cut:is_cut
        hash_validate:hash_validate completion:completion];
}

/* ── Instance copy driver ───────────────────────────────────────────────── */

/*
 * start_copy:to:is_cut:hash_validate:completion: — kick off the copy using
 * the FilesFileOps engine, piping progress events into the panel.
 *
 * Inputs:
 *   srcs          — source URLs
 *   dest          — destination directory URL
 *   is_cut        — YES = move
 *   hash_validate — YES = verify hashes
 *   completion    — forwarded to caller after panel actions
 */
- (void)
start_copy:(NSArray<NSURL *> *)srcs
        to:(NSURL *)dest
    is_cut:(BOOL)is_cut
hash_validate:(BOOL)hash_validate
completion:(void (^)(NSError *))completion
{
    cancel_token_t *cancel     = _cancel;
    __block NSString *cur_name = @"";
    __block int64_t total_xfer = 0;  /* running total for avg speed at completion */

    /* Speed ring — heap-allocated; blocks capture the pointer, not an array */
    speed_ring_t *spd_ring      = calloc(1, sizeof(speed_ring_t));
    __block speed_ring_t *spd   = spd_ring;

    /* Strong capture keeps _cancel alive until the copy completes.
     * NSWindow.windowController is unsafe_unretained; without this the
     * panel (and its cancel token) can be freed while the copy runs. */
    FilesCopyProgress *alive = self;
    __weak FilesCopyProgress *weak_self = self;

    _start_time = CFAbsoluteTimeGetCurrent();

    {
        NSString *src_desc = srcs.count == 1
            ? [NSString stringWithFormat:@"\"%@\"", srcs.firstObject.lastPathComponent]
            : [NSString stringWithFormat:@"%lu files", (unsigned long)srcs.count];
        [self append_log:[NSString stringWithFormat:@"Copying %@ -> %@%@",
            src_desc, dest.lastPathComponent,
            hash_validate ? @" (SHA256)" : @""]];
    }

    FileCopyProgressBlock progress = ^(NSString *name, int64_t f_done, int64_t f_total,
                                       int64_t t_done, int64_t t_total, double raw_bps)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesCopyProgress *p = weak_self;
            if (!p) return;

            /* Track bytes for avg speed computation at completion */
            total_xfer = t_done;

            /* Update status label when filename changes */
            if (![name isEqualToString:cur_name]) {
                cur_name = name;
                p.status_label.stringValue = [NSString stringWithFormat:
                    @"Copying \"%@\" to %@", name, dest.lastPathComponent];
                if (name.length) {
                    NSString *sz = f_total > 0 ? format_bytes(f_total) : nil;
                    [p append_log:sz
                        ? [NSString stringWithFormat:@"-> %@ (%@)", name, sz]
                        : [NSString stringWithFormat:@"-> %@", name]];
                }
            }

            /* Speed via sliding window */
            CFTimeInterval now       = CFAbsoluteTimeGetCurrent();
            spd->samples[spd->head] = (speed_sample_t){now, t_done};
            spd->head               = (spd->head + 1) % SPEED_RING;
            if (spd->count < SPEED_RING) spd->count++;

            double bps = 0;
            if (spd->count >= 2) {
                int oldest = (spd->head - spd->count + SPEED_RING) % SPEED_RING;
                int newest = (spd->head - 1 + SPEED_RING) % SPEED_RING;
                CFTimeInterval dt = spd->samples[newest].timestamp
                                  - spd->samples[oldest].timestamp;
                int64_t        db = spd->samples[newest].total_done
                                  - spd->samples[oldest].total_done;
                if (dt > 0.01) bps = (double)db / dt;
            }

            /* Running average: total bytes transferred / elapsed wall time */
            CFTimeInterval elapsed = now - p->_start_time;
            double avg_bps = (elapsed > 0.001 && t_done > 0)
                           ? (double)t_done / elapsed : 0.0;

            [p.speed_graph add_sample:bps average:avg_bps];

            /* ETA */
            if (bps > 0 && t_total > t_done) {
                int64_t remaining = t_total - t_done;
                int64_t secs      = (int64_t)(remaining / bps);
                if (secs < 60) {
                    p.eta_label.stringValue =
                        [NSString stringWithFormat:@"About %lld sec remaining", secs];
                } else {
                    p.eta_label.stringValue =
                        [NSString stringWithFormat:@"About %lld min %lld sec remaining",
                            secs / 60, secs % 60];
                }
            }
        });
    };

    [FilesFileOps run_copy_srcs:srcs to:dest is_cut:is_cut
                  hash_validate:hash_validate conflict:[self make_conflict_block]
                    cancel_flag:&cancel->flag progress:progress
                      completion:^(NSError *err, NSDictionary<NSURL *, NSNumber *> *hash_results)
    {
        /* Called on main queue. alive keeps _cancel valid until here. */
        (void)alive;
        FilesCopyProgress *p = weak_self;

        /* Release the heap-allocated speed ring */
        free(spd);
        spd = NULL;

        if (completion) completion(err);

        if (p) {
            if (err && err.code == NSUserCancelledError) {
                [p close];
            } else {
                BOOL all_ok = (err == nil);
                if (all_ok && hash_results) {
                    for (NSNumber *v in hash_results.allValues) {
                        if (!v.boolValue) { all_ok = NO; break; }
                    }
                }
                if (err)
                    [p append_log:[NSString stringWithFormat:@"✗ %@",
                        err.localizedDescription]];
                for (NSURL *url in hash_results) {
                    BOOL match = [hash_results[url] boolValue];
                    [p append_log:[NSString stringWithFormat:@"%@ SHA256 Validation: %@ [%@]",
                        match ? @"✓" : @"✗", url.lastPathComponent,
                        match ? @"PASSED" : @"FAILED"]];
                }
                p.status_label.stringValue = all_ok
                    ? [NSString stringWithFormat:@"Copied \"%@\" to %@",
                       cur_name.length ? cur_name : @"files", dest.lastPathComponent]
                    : @"Copy failed.";
                [p mark_done_with_success:all_ok bytes:total_xfer];
            }
        }
    }];
}

/* ── Conflict resolution ────────────────────────────────────────────────── */

/*
 * make_conflict_block — returns a block that presents a conflict sheet when a
 * destination file already exists. Blocks the calling (background) thread via a
 * semaphore until the user dismisses the sheet.
 *
 * Output: block returning FilesConflictKeepBoth, FilesConflictOverwrite, or
 *         FilesConflictCancel if the panel is gone.
 */
- (FilesConflictBlock)
make_conflict_block
{
    __weak FilesCopyProgress *weak_self = self;
    return ^FilesConflictResolution(NSURL *src, NSURL *dst) {
        __block FilesConflictResolution result = FilesConflictKeepBoth;
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
    if (_cancel) {
        OSAtomicCompareAndSwap32(0, 1, &_cancel->flag);
    }
    self.cancel_button.enabled    = NO;
    self.status_label.stringValue = @"Cancelling...";
}

/*
 * dealloc — free the heap-allocated cancel token.
 */
- (void)
dealloc
{
    free(_cancel);
}

/*
 * windowWillClose: — set cancel flag so any in-flight copy drains cleanly.
 *
 * Inputs:
 *   n — NSWindowWillCloseNotification
 */
- (void)
windowWillClose:(NSNotification *)n
{
    if (_cancel) {
        OSAtomicCompareAndSwap32(0, 1, &_cancel->flag);
    }
    _self_ref = nil;
}

@end
