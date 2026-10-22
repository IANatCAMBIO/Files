#import "copy_progress.h"
#import "tool_panel.h"
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

@property (nonatomic, strong) NSTextField     *status_label;
@property (nonatomic, strong) FilesSpeedGraph *speed_graph;
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
    NSString          *_only_name;    /* the one item being copied; nil for several */
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
    BOOL               _engine_downloading;  /* it was downloading from iCloud */
    int64_t            _engine_dl_done;      /* bytes of that download so far */
    int64_t            _engine_dl_total;     /* bytes that download needs */
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
        initWithContentRect:NSMakeRect(0, 0, 460, 188)
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
 * The graph and status line are pinned to the top; the
 * Cancel/Close button is pinned to the bottom-right corner (button_margin
 * from both edges) and the Transfer Log toggle to the bottom-left on the
 * same row. When the window grows downward to reveal the transfer
 * log, the log fills the space between the status line and the button.
 * Uses _dest_name for the initial status text.
 */
- (void)
build_views
{
    NSView *cv = self.window.contentView;
    CGFloat w  = cv.bounds.size.width;
    CGFloat y  = cv.bounds.size.height - 10;

    /* Speed graph */
    CGFloat graph_h = 110.0;
    y -= graph_h;
    self.speed_graph = [[FilesSpeedGraph alloc]
        initWithFrame:NSMakeRect(12, y, w - 24, graph_h)];
    self.speed_graph.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:self.speed_graph];

    /* Status line */
    y -= 8 + 14;
    self.status_label = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%@ to \"%@\"...", _ing, _dest_name]];
    self.status_label.frame            = NSMakeRect(12, y, w - 24, 14);
    self.status_label.font             = [NSFont systemFontOfSize:12.0];
    self.status_label.lineBreakMode    = NSLineBreakByTruncatingMiddle;
    self.status_label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:self.status_label];

    /* Cancel/Close button — fixed distance from the bottom and right edges */
    self.cancel_button = [NSButton buttonWithTitle:@"Cancel"
                                            target:self
                                            action:@selector(cancel_clicked:)];
    self.cancel_button.frame             = NSMakeRect(w - button_margin - 88, button_margin, 88, 22);
    self.cancel_button.autoresizingMask  = NSViewMinXMargin | NSViewMaxYMargin;
    self.cancel_button.keyEquivalent     = @"\033"; /* Escape */
    [cv addSubview:self.cancel_button];

    /* Transfer Log toggle — on the button's row, left edge aligned with the
     * graph and vertically centred on the button */
    self.log_toggle = [NSButton buttonWithTitle:@"▶  Transfer Log"
                                         target:self
                                         action:@selector(toggle_log:)];
    self.log_toggle.frame            = NSMakeRect(12, button_margin + (22 - 16) / 2.0, 103, 16);
    self.log_toggle.bordered         = NO;
    self.log_toggle.font             = [NSFont systemFontOfSize:11.0];
    self.log_toggle.autoresizingMask = NSViewMaxYMargin;
    [cv addSubview:self.log_toggle];

    /* Transfer log scroll view — hidden until expanded; toggle_log: places it
     * between the status line and the button. */
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
 * toggle_log: — expand or collapse the transfer log panel.
 *
 * Grows the window downward by log_height + log_gap when expanding, then
 * places the log between the status line and the Cancel/Close button
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
        CGFloat top    = NSMinY(self.status_label.frame) - log_gap;
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
 * engine_progress:file_done:file_total:total_done:downloading: — records
 * the engine's latest progress report. Called on the copy thread for
 * every report; the panel shows it on its next tick (take_engine_updates).
 *
 * Inputs:
 *   name        — file being copied (or downloaded)
 *   file_done   — while downloading: bytes of the download so far
 *   file_total  — while downloading: bytes the download needs
 *   total_done  — bytes copied (and downloaded) across all files so far
 *   downloading — YES while the engine downloads from iCloud
 */
- (void)
engine_progress:(NSString *)name
      file_done:(int64_t)file_done
     file_total:(int64_t)file_total
     total_done:(int64_t)total_done
    downloading:(BOOL)downloading
{
    os_unfair_lock_lock(&_engine_lock);
    _engine_name        = name;
    _engine_done        = total_done;
    _engine_downloading = downloading;
    _engine_dl_done     = file_done;
    _engine_dl_total    = file_total;
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
 * it) and updates the status line — every call while downloading from
 * iCloud ("Downloading "name" from iCloud — 312 MB of 731 MB", or "Waiting
 * for iCloud to start downloading "name"…" until the first byte), otherwise
 * when the file changed. Main thread only.
 */
- (void)
take_engine_updates
{
    os_unfair_lock_lock(&_engine_lock);
    NSArray<NSString *> *lines = _engine_log.count ? [_engine_log copy] : nil;
    [_engine_log removeAllObjects];
    NSString *name        = _engine_name;
    int64_t   done        = _engine_done;
    BOOL      downloading = _engine_downloading;
    int64_t   dl_done     = _engine_dl_done;
    int64_t   dl_total    = _engine_dl_total;
    os_unfair_lock_unlock(&_engine_lock);

    if (lines) [self append_log_lines:lines];
    _total_done = done;
    if (downloading) {
        _cur_name = @"";  /* the copy that follows sets the status line again */
        self.status_label.stringValue = dl_done > 0
            ? [NSString stringWithFormat:
                @"Downloading \"%@\" from iCloud — %@ of %@", name,
                files_format_bytes(dl_done), files_format_bytes(dl_total)]
            : [NSString stringWithFormat:
                @"Waiting for iCloud to start downloading \"%@\"…", name];
    } else if (name && ![name isEqualToString:_cur_name]) {
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
 * elapsed_text — a duration as the final status line shows it.
 *
 * Inputs:
 *   elapsed — seconds, > 0
 *
 * Output: "0.35 sec" below a second, "12.3 sec" below a minute, otherwise
 * "2 min 5 sec".
 */
static NSString *
elapsed_text(CFTimeInterval elapsed)
{
    if (elapsed < 1.0)  return [NSString stringWithFormat:@"%.2f sec", elapsed];
    if (elapsed < 60.0) return [NSString stringWithFormat:@"%.1f sec", elapsed];
    int64_t s = (int64_t)elapsed;
    return [NSString stringWithFormat:@"%lld min %lld sec", s / 60, s % 60];
}

/*
 * finish_with_error: — show the final state after the copy ends: feeds the
 * graph its last interval (taking the engine's last updates), logs the
 * error, sets the title ("Copied"/"Moved", or "Copy Failed"/"Move Failed")
 * and the status line (with the elapsed time), switches the button to
 * "Close". The status line is set after the last feed, which would otherwise
 * put back "Copying …" for a file reported since the previous tick. (The
 * engine logged each digest; a failed validation arrives as err.)
 *
 * Inputs:
 *   err — engine error, or nil on success
 */
- (void)
finish_with_error:(NSError *)err
{
    [self stop_graph_timer];
    [self feed_graph];

    BOOL all_ok = (err == nil);
    if (err) {
        [self append_log:[NSString stringWithFormat:@"✗ %@", err.localizedDescription]];
    }
    self.window.title = all_ok
        ? _ed
        : [NSString stringWithFormat:@"%@ Failed", _noun.capitalizedString];

    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - _start_time;
    if (elapsed < 0.001) elapsed = 0.001;
    self.status_label.stringValue = all_ok
        ? [NSString stringWithFormat:@"%@ %@ to %@ in %@", _ed,
           _only_name ? [NSString stringWithFormat:@"\"%@\"", _only_name]
                      : @"selected files",
           _dest_name, elapsed_text(elapsed)]
        : [NSString stringWithFormat:@"%@ failed.", _noun.capitalizedString];
    self.cancel_button.title         = @"Close";
    self.cancel_button.action        = @selector(close_clicked:);
    self.cancel_button.enabled       = YES;
    self.cancel_button.keyEquivalent = @"\r";

    double avg_bps = self.speed_graph.average_bps;  /* the graph's average line */

    /* A move by rename or a clone copies no data, so it has no speed to report. */
    NSString *rate = avg_bps > 0.0
        ? [NSString stringWithFormat:@"avg %@, ", files_format_rate(avg_bps)] : @"";
    [self append_log:all_ok
        ? [NSString stringWithFormat:@"✓ Done — %@%.1f sec total", rate, elapsed]
        : [NSString stringWithFormat:@"✗ %@ failed", _noun.capitalizedString]];
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
 * thread and only record what they are given (engine_progress:file_done:…,
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

    _only_name   = srcs.count == 1 ? srcs.firstObject.lastPathComponent : nil;
    _start_time  = CFAbsoluteTimeGetCurrent();
    _graph_time  = _start_time;
    _graph_bytes = 0;
    _graph_timer = [NSTimer timerWithTimeInterval:graph_interval repeats:YES
                                            block:^(NSTimer *t) { [weak_self feed_graph]; }];
    [NSRunLoop.mainRunLoop addTimer:_graph_timer forMode:NSRunLoopCommonModes];

    NSString *src_desc = srcs.count == 1
        ? [NSString stringWithFormat:@"\"%@\"", srcs.firstObject.lastPathComponent]
        : [NSString stringWithFormat:@"%lu files", (unsigned long)srcs.count];
    [self append_log:[NSString stringWithFormat:@"Starting %@ job %@ -> %@%@",
        _noun, src_desc, _dest_name, hash_validate ? @" (SHA256)" : @""]];

    FileCopyProgressBlock progress = ^(NSString *name, int64_t f_done, int64_t f_total,
                                       int64_t t_done, BOOL downloading)
    {
        [alive engine_progress:name file_done:f_done file_total:f_total
                    total_done:t_done downloading:downloading];
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
            [FilesToolPanel show_message:[NSString stringWithFormat:
                                             @"\"%@\" already exists in this location.",
                                             dst.lastPathComponent]
                                 message:[NSString stringWithFormat:
                                             @"Keep both files, replace the existing one, "
                                             @"or stop the %@?", p->_noun]
                                  symbol:@"doc.on.doc"
                                 buttons:@[@"Keep Both", @"Replace", @"Cancel"]
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
