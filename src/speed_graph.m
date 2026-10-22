#import "speed_graph.h"
#import "util.h"

/* Fixed number of interval slots; a power of two so pair-merging halves it evenly. */
enum { slot_capacity = 512 };

static const double y_floor_bps = 1e6;  /* minimum Y scale: 1 MB/s */

/* Each plotted rate averages at least this much time, evening out the
 * bursts in how progress is reported. */
static const double smooth_secs = 1.0;

/* The Y axis' zero label, shown whether or not any data has arrived. */
static NSString *const zero_label = @"0 MB/s";

@implementation FilesSpeedGraph {
    double     _bytes[slot_capacity];  /* bytes moved in each slot */
    double     _secs[slot_capacity];   /* seconds each slot covers */
    NSUInteger _count;                 /* slots in use */
    NSUInteger _stride;                /* intervals merged into each slot (1, 2, 4, …) */
    NSUInteger _last_fill;             /* intervals merged into the last slot so far */
    double     _total_bytes;           /* sums over every interval: the average */
    double     _total_secs;
}

/*
 * initWithFrame: — initialize an empty graph.
 *
 * Inputs:
 *   frame_rect — initial frame
 *
 * Output: configured view.
 */
- (instancetype)
initWithFrame:(NSRect)frame_rect
{
    self = [super initWithFrame:frame_rect];
    if (!self) return nil;
    _stride = 1;
    return self;
}

/*
 * decimate — halve the buffer by merging adjacent slot pairs (bytes and
 * seconds summed, so each merged slot's rate is the true rate over its
 * time). Each slot then covers twice as many intervals as before. Called
 * only when the buffer is full, so every slot (including the last) is
 * complete afterwards.
 */
- (void)
decimate
{
    for (NSUInteger i = 0; i < slot_capacity / 2; i++) {
        _bytes[i] = _bytes[2 * i] + _bytes[2 * i + 1];
        _secs[i]  = _secs[2 * i]  + _secs[2 * i + 1];
    }
    _count     = slot_capacity / 2;
    _stride   *= 2;
    _last_fill = _stride;
}

/*
 * add_bytes:seconds: — add one interval, merging into the last slot until
 * that slot holds _stride intervals; decimates when the buffer is full.
 * Inputs/output are documented in speed_graph.h.
 */
- (void)
add_bytes:(int64_t)bytes seconds:(double)seconds
{
    if (seconds <= 0.0) return;
    double b = bytes > 0 ? (double)bytes : 0.0;
    if (b == 0.0 && _total_bytes == 0.0) return;  /* the plot starts at the first byte */
    _total_bytes += b;
    _total_secs  += seconds;

    if (_count > 0 && _last_fill < _stride) {
        _bytes[_count - 1] += b;
        _secs[_count - 1]  += seconds;
        _last_fill++;
    } else {
        if (_count == slot_capacity) [self decimate];
        _bytes[_count] = b;
        _secs[_count]  = seconds;
        _count++;
        _last_fill = 1;
    }
    [self setNeedsDisplay:YES];
}

/*
 * average_bps — bytes recorded over seconds recorded; see speed_graph.h.
 */
- (double)
average_bps
{
    return _total_secs > 0.0 ? _total_bytes / _total_secs : 0.0;
}

/*
 * bucket_rate:end: — the transfer rate around slots [start, end): the range
 * is widened evenly on both sides until it covers at least smooth_secs (or
 * all the slots), then its bytes are divided by its seconds, so the height
 * is a true rate over that time.
 *
 * Inputs:
 *   start, end — slot range, start < end ≤ _count
 *
 * Output: bytes per second (0 if the slots cover no time).
 */
- (double)
bucket_rate:(NSUInteger)start end:(NSUInteger)end
{
    double b = 0.0, t = 0.0;
    for (NSUInteger k = start; k < end; k++) {
        b += _bytes[k];
        t += _secs[k];
    }
    while (t < smooth_secs && (start > 0 || end < _count)) {
        if (start > 0) {
            start--;
            b += _bytes[start];
            t += _secs[start];
        }
        if (end < _count) {
            b += _bytes[end];
            t += _secs[end];
            end++;
        }
    }
    return t > 0.0 ? b / t : 0.0;
}

/*
 * draw_speed_area:columns:y_max: — fill the area under the plotted rates.
 *
 * The slots are grouped into n_cols buckets, each drawn at its
 * bucket_rate:end: at the middle of the time it covers: the X axis is
 * time, so a short interval (the last, partial one) is narrow and the
 * area is proportional to the bytes moved — which makes the average line
 * its mean height. The outline runs flat from the plot's left edge to the
 * first bucket and from the last bucket to the right edge.
 *
 * Inputs:
 *   plot   — plot area rectangle in view coordinates
 *   n_cols — number of buckets (≥ 1, ≤ _count)
 *   y_max  — value that maps to the top of the plot area
 */
- (void)
draw_speed_area:(NSRect)plot columns:(NSUInteger)n_cols y_max:(double)y_max
{
    CGFloat left   = NSMinX(plot);
    CGFloat bottom = NSMinY(plot);
    CGFloat plot_w = NSWidth(plot);
    CGFloat plot_h = NSHeight(plot);

    NSBezierPath *area = [NSBezierPath bezierPath];
    [area moveToPoint:NSMakePoint(left, bottom)];
    double elapsed = 0.0;  /* seconds before the current bucket */
    CGFloat y = bottom;
    for (NSUInteger p = 0; p < n_cols; p++) {
        NSUInteger s = p * _count / n_cols, e = (p + 1) * _count / n_cols;
        double secs = 0.0;
        for (NSUInteger k = s; k < e; k++) secs += _secs[k];

        y = bottom + (CGFloat)([self bucket_rate:s end:e] / y_max) * plot_h;
        CGFloat x = left + (CGFloat)((elapsed + secs / 2.0) / _total_secs) * plot_w;
        if (p == 0) [area lineToPoint:NSMakePoint(left, y)];
        [area lineToPoint:NSMakePoint(x, y)];
        elapsed += secs;
    }
    [area lineToPoint:NSMakePoint(left + plot_w, y)];
    [area lineToPoint:NSMakePoint(left + plot_w, bottom)];
    [area closePath];
    [[NSColor.systemGreenColor colorWithAlphaComponent:0.25] setFill];
    [area fill];
}

/*
 * drawRect: — render Y gridlines and the 0 label, the rate area, the average-rate line with
 * its label, plot border, and dark grey view border.
 *
 * Inputs:
 *   dirty — ignored; always full redraw.
 */
- (void)
drawRect:(NSRect)dirty
{
    NSRect b = self.bounds;

    [NSColor.controlBackgroundColor setFill];
    NSRectFill(b);

    /* About one bucket per pixel column. The scale is the largest bucket
     * rate; the average, a time-weighted mean of the same buckets, can
     * never exceed it. */
    NSUInteger n_cols = (NSUInteger)NSWidth(b);
    if (n_cols < 1)      n_cols = 1;
    if (n_cols > _count) n_cols = _count;  /* none yet: only the axes are drawn */
    double peak = 0.0;
    for (NSUInteger p = 0; p < n_cols; p++) {
        peak = fmax(peak, [self bucket_rate:p * _count / n_cols end:(p + 1) * _count / n_cols]);
    }
    double y_max = peak * 1.1;
    if (y_max < y_floor_bps) y_max = y_floor_bps;
    double avg_bps = self.average_bps;

    NSDictionary *label_attrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:10.0],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };

    /* The left gutter is sized to the widest Y label (plus label_pad on each
     * side), so labels never cross the view border whatever the scale. */
    static const CGFloat label_pad = 4.0;
    static const double  grid_fracs[] = { 0.25, 0.50, 0.75 };
    NSString *labels[3];
    CGFloat   label_w = 0.0;
    for (int i = 0; i < 3; i++) {
        labels[i] = files_format_rate(grid_fracs[i] * y_max);
        label_w   = MAX(label_w, [labels[i] sizeWithAttributes:label_attrs].width);
    }
    NSSize zero_size = [zero_label sizeWithAttributes:label_attrs];
    label_w = MAX(label_w, zero_size.width);

    CGFloat left_margin   = ceil(label_w) + 2.0 * label_pad;
    CGFloat bottom_margin = ceil(zero_size.height / 2.0) + 1.0;  /* room for the 0 label */
    NSRect  plot = NSMakeRect(left_margin, bottom_margin,
                              b.size.width  - left_margin - 4.0,
                              b.size.height - bottom_margin - 4.0);

    /* ── Y gridlines + labels ──────────────────────────────────────────────── */

    CGFloat dash[2] = {3.0, 3.0};

    for (int i = 0; i < 3; i++) {
        CGFloat y = NSMinY(plot) + (CGFloat)grid_fracs[i] * NSHeight(plot);

        NSBezierPath *grid = [NSBezierPath bezierPath];
        [grid moveToPoint:NSMakePoint(NSMinX(plot), y)];
        [grid lineToPoint:NSMakePoint(NSMaxX(plot), y)];
        [grid setLineDash:dash count:2 phase:0];
        grid.lineWidth = 0.5;
        [NSColor.separatorColor setStroke];
        [grid stroke];

        NSSize ls = [labels[i] sizeWithAttributes:label_attrs];
        [labels[i] drawAtPoint:NSMakePoint(left_margin - ls.width - label_pad,
                                           y - ls.height / 2.0)
                withAttributes:label_attrs];
    }

    [zero_label drawAtPoint:NSMakePoint(left_margin - zero_size.width - label_pad,
                                        NSMinY(plot) - zero_size.height / 2.0)
             withAttributes:label_attrs];

    /* ── Speed area ────────────────────────────────────────────────────────── */

    if (n_cols > 0) [self draw_speed_area:plot columns:n_cols y_max:y_max];

    /* ── Average speed reference line + label ────────────────────────────── */

    if (avg_bps > 0.0) {
        CGFloat y_avg = NSMinY(plot) + (CGFloat)(avg_bps / y_max) * NSHeight(plot);

        NSBezierPath *avg_line = [NSBezierPath bezierPath];
        [avg_line moveToPoint:NSMakePoint(NSMinX(plot), y_avg)];
        [avg_line lineToPoint:NSMakePoint(NSMaxX(plot), y_avg)];
        avg_line.lineWidth = 1.0;
        [NSColor.secondaryLabelColor setStroke];
        [avg_line stroke];

        NSString     *avg_str   = files_format_rate(avg_bps);
        NSDictionary *avg_attrs = @{
            NSFontAttributeName:            [NSFont systemFontOfSize:9.0],
            NSForegroundColorAttributeName: NSColor.labelColor
        };
        /* Right end of the line, above it — or below when the top of the
         * plot leaves no room — so the label stays inside the plot. */
        NSSize  asz = [avg_str sizeWithAttributes:avg_attrs];
        CGFloat ay  = (y_avg + 2.0 + asz.height <= NSMaxY(plot))
                      ? y_avg + 2.0 : y_avg - 2.0 - asz.height;
        [avg_str drawAtPoint:NSMakePoint(NSMaxX(plot) - asz.width - 3.0, ay)
              withAttributes:avg_attrs];
    }

    /* ── Plot border ───────────────────────────────────────────────────────── */

    NSBezierPath *border = [NSBezierPath bezierPathWithRect:plot];
    border.lineWidth = 0.5;
    [NSColor.separatorColor setStroke];
    [border stroke];

    /* ── Dark grey border around the entire view ───────────────────────────── */

    NSBezierPath *view_border = [NSBezierPath bezierPathWithRect:
        NSInsetRect(b, 0.5, 0.5)];
    view_border.lineWidth = 1.0;
    [[NSColor colorWithWhite:0.55 alpha:1.0] setStroke];
    [view_border stroke];
}

@end
