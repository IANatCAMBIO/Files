#import "copy_progress.h"
#import "file_ops.h"
#import "speed_graph.h"
#import "util.h"
#include <os/lock.h>

/* The panel picks up the engine's progress and log lines, and the speed
 * graph gets one interval (bytes moved, time taken), this often. */
static const CFTimeInterval graph_interval = 0.25;

static const CGFloat log_height    = 160.0; /* extra window height for the transfer log */
static const CGFloat log_gap       = 8.0;   /* space above and below the log */
static const CGFloat button_margin = 12.0;  /* Cancel/Close inset from bottom and right */

/* The transfer log keeps at most log_max_lines lines; once log_trim_batch
 * extra lines have accumulated, the oldest are dropped in one edit. */
static const NSUInteger log_max_lines  = 1000;
static const NSUInteger log_trim_batch = 100;

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
    NSTimer           *_graph_timer;  /* feeds the speed graph every graph_interval */
    int64_t            _graph_bytes;  /* _total_done when the graph was last fed */
    CFAbsoluteTime     _graph_time;   /* when the graph was last fed */
    NSString          *_dest_name;    /* destination folder name for labels */
    NSString          *_ing;          /* "Copying" or "Moving", for the panel's text */
    NSString          *_ed;           /* "Copied" or "Moved" */
    NSString          *_noun;         /* "copy" or "move" */
    NSString          *_cur_name;     /* file name shown in the status line */
    int64_t            _total_done;   /* bytes copied so far across all files */
    CFAbsoluteTime     _start_time;   /* set when the copy is started */
    FilesCopyProgress *_self_ref;     /* retains self while window is on screen */
    NSUInteger         _log_lines;    /* lines currently in the transfer log */
    BOOL               _log_expanded; /* YES when the transfer log panel is open */

    /* Written by the engine on the copy thread, taken by take_engine_updates
     * on the main thread; all guarded by _engine_lock. */
    os_unfair_lock     _engine_lock;
    NSMutableArray<NSString *> *_engine_log;  /* timestamped lines not yet shown */
    NSString          *_engine_name;  /* file the engine reported last */
    int64_t            _engine_done;  /* bytes the engine reported last */
}

/* ── Panel construction ─────────────────────────────────────────────────── */

/*
 * init_with_dest:is_cut: — build the progress panel. Its text says
 * "Moving"/"Moved"/"move" for a move and "Copying"/"Copied"/"copy"
 * otherwise.
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
    NSString *ing = is_cut ? @"Moving" : @"Copying";
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 460, 210)
                  styleMask:NSWindowStyleMaskTitled
                           | NSWindowStyleMaskClosable
                           | NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title                  = [ing stringByAppendingString:@"..."];
    panel.worksWhenModal         = YES;
    panel.becomesKeyOnlyIfNeeded = YES;

    self = [super initWithWindow:panel];
    if (!self) return nil;

    atomic_init(&_cancel, 0);
    _dest_name = dest.lastPathComponent;
    _ing       = ing;
    _ed        = is_cut ? @"Moved" : @"Copied";
    _noun      = is_cut ? @"move"  : @"copy";
    _cur_name  = @"";
    _self_ref  = self;  /* broken in windowWillClose: */
    _engine_lock = OS_UNFAIR_LOCK_INIT;
    _engine_log  = [NSMutableArray array];

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
        [NSString stringWithFormat:@"%@ to \"%@\"...", _ing, _dest_name]];
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
 * stamped — line prefixed with the current time, as the log shows it.
 *
 * Inputs:
 *   line — log text
 *
 * Output: "[HH:mm:ss] line".
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

    [ts beginEditing];
    [ts replaceCharactersInRange:NSMakeRange(ts.length, 0)
                      withString:[sep stringByAppendingString:
                                  [lines componentsJoinedByString:@"\n"]]];
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
 * append_log: — append one line to the transfer log now, timestamped,
 * after any engine lines still waiting. Main thread only.
 *
 * Inputs:
 *   line — text to append (no trailing newline needed)
 */
- (void)
append_log:(NSString *)line
{
    [self take_engine_updates];  /* keep engine lines that arrived earlier in order */
    [self append_log_lines:@[stamped(line)]];
}

/*
 * engine_progress:total_done: — records the engine's latest progress report.
 * Called on the copy thread for every report; the panel shows it on its
 * next tick (take_engine_updates).
 *
 * Inputs:
 *   name       — file being copied
 *   total_done — bytes copied across all files so far
 */
- (void)
engine_progress:(NSString *)name total_done:(int64_t)total_done
{
    os_unfair_lock_lock(&_engine_lock);
    _engine_name = name;
    _engine_done = total_done;
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
 * take_engine_updates — shows what the engine reported since the last
 * call: appends its log lines, records the byte count (feed_graph reads
 * it) and updates the status line when the file changed. Main thread only.
 */
- (void)
take_engine_updates
{
    os_unfair_lock_lock(&_engine_lock);
    NSArray<NSString *> *lines = _engine_log.count ? [_engine_log copy] : nil;
    [_engine_log removeAllObjects];
    NSString *name = _engine_name;
    int64_t   done = _engine_done;
    os_unfair_lock_unlock(&_engine_lock);

    if (lines) [self append_log_lines:lines];
    _total_done = done;
    if (name && ![name isEqualToString:_cur_name]) {
        _cur_name = name;
        self.status_label.stringValue = [NSString stringWithFormat:
            @"%@ \"%@\" to %@", _ing, name, _dest_name];
    }
}

/*
 * feed_graph — takes the engine's updates (take_engine_updates), then gives
 * the speed graph the interval since it was last fed: the bytes copied in
 * it and its length.
 * Called every graph_interval while copying, and once more when the copy
 * ends, so the graph's intervals add up to the whole copy and its average
 * line equals total bytes / elapsed.
 */
- (void)
feed_graph
{
    [self take_engine_updates];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [self.speed_graph add_bytes:_total_done - _graph_bytes seconds:now - _graph_time];
    _graph_bytes = _total_done;
    _graph_time  = now;
}

/*
 * stop_graph_timer — stops feeding the speed graph.
 */
- (void)
stop_graph_timer
{
    [_graph_timer invalidate];
    _graph_timer = nil;
}

/*
 * finish_with_error: — show the final state after the copy ends: logs the
 * error, sets the status line, switches the button to "Close", feeds the
 * graph its last interval and shows elapsed time. (The engine logged each
 * digest; a failed validation arrives as err.)
 *
 * Inputs:
 *   err — engine error, or nil on success
 */
- (void)
finish_with_error:(NSError *)err
{
    BOOL all_ok = (err == nil);
    if (err) {
        [self append_log:[NSString stringWithFormat:@"✗ %@", err.localizedDescription]];
    }
    self.status_label.stringValue = all_ok
        ? [NSString stringWithFormat:@"%@ \"%@\" to %@", _ed,
           _cur_name.length ? _cur_name : @"files", _dest_name]
        : [NSString stringWithFormat:@"%@ failed.", _noun.capitalizedString];

    self.cancel_button.title         = @"Close";
    self.cancel_button.action        = @selector(close_clicked:);
    self.cancel_button.enabled       = YES;
    self.cancel_button.keyEquivalent = @"\r";

    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - _start_time;
    if (elapsed < 0.001) elapsed = 0.001;

    double avg_bps = (_total_done > 0) ? (double)_total_done / elapsed : 0.0;

    /* A move by rename copies no data, so it has no speed to report. */
    NSString *rate = _total_done > 0
        ? [NSString stringWithFormat:@"avg %@, ", files_format_rate(avg_bps)] : @"";
    [self append_log:all_ok
        ? [NSString stringWithFormat:@"✓ Done — %@%.1f sec total", rate, elapsed]
        : [NSString stringWithFormat:@"✗ %@ failed", _noun.capitalizedString]];

    [self stop_graph_timer];
    [self feed_graph];

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

    FilesCopyProgress *panel = [[FilesCopyProgress alloc] init_with_dest:dest is_cut:is_cut];
    [panel showWindow:nil];
    [panel start_copy:srcs to:dest is_cut:is_cut
        hash_validate:hash_validate completion:completion];
}

/* ── Instance copy driver ───────────────────────────────────────────────── */

/*
 * start_copy:to:is_cut:hash_validate:completion: — kick off the copy using
 * the FilesFileOps engine. Its progress and log blocks run on the copy
 * thread and only record what they are given (engine_progress:total_done:,
 * engine_log:); the graph timer shows it every graph_interval.
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

    _start_time  = CFAbsoluteTimeGetCurrent();
    _graph_time  = _start_time;
    _graph_bytes = 0;
    _graph_timer = [NSTimer timerWithTimeInterval:graph_interval repeats:YES
                                            block:^(NSTimer *t) { [weak_self feed_graph]; }];
    [NSRunLoop.mainRunLoop addTimer:_graph_timer forMode:NSRunLoopCommonModes];

    NSString *src_desc = srcs.count == 1
        ? [NSString stringWithFormat:@"\"%@\"", srcs.firstObject.lastPathComponent]
        : [NSString stringWithFormat:@"%lu files", (unsigned long)srcs.count];
    [self append_log:[NSString stringWithFormat:@"%@ %@ -> %@%@",
        _ing, src_desc, _dest_name, hash_validate ? @" (SHA256)" : @""]];

    FileCopyProgressBlock progress = ^(NSString *name, int64_t f_done, int64_t f_total,
                                       int64_t t_done)
    {
        [alive engine_progress:name total_done:t_done];
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
            NSAlert *alert = files_new_alert();
            alert.messageText =
                [NSString stringWithFormat:@"\"%@\" already exists in this location.",
                 dst.lastPathComponent];
            alert.informativeText =
                [NSString stringWithFormat:@"Keep both files, replace the existing one, "
                                           @"or stop the %@?", p->_noun];
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
 * stop feeding the graph, and drop the self-reference that kept the panel
 * alive while on screen.
 *
 * Inputs:
 *   n — NSWindowWillCloseNotification
 */
- (void)
windowWillClose:(NSNotification *)n
{
    atomic_store(&_cancel, 1);
    [self stop_graph_timer];
    _self_ref = nil;
}

@end
