#import "speed_graph.h"
#import "util.h"

/* Fixed number of sample slots; a power of two so pair-merging halves it evenly. */
enum { sample_capacity = 512 };

static const double ema_alpha   = 0.7;  /* EMA weight on the previous smoothed value */
static const double y_floor_bps = 1e6;  /* minimum Y scale: 1 MB/s */

@implementation FilesSpeedGraph {
    double     _samples[sample_capacity]; /* per-slot max of smoothed speed */
    NSUInteger _count;          /* slots in use */
    NSUInteger _stride;         /* samples merged into each slot (1, 2, 4, …) */
    NSUInteger _last_fill;      /* samples merged into the last slot so far */
    double     _last_smoothed;  /* most recent EMA value (EMA input for next sample) */
    double     _y_max;          /* maximum of all stored samples */
    double     _avg_bps;        /* latest running-average bps from the caller */
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
    _y_max  = 1.0;
    return self;
}

/*
 * decimate — halve the buffer by merging adjacent slot pairs, keeping the
 * larger value of each pair so peaks survive. Each slot then covers twice as
 * many samples as before. Called only when the buffer is full, so every slot
 * (including the last) is complete afterwards.
 */
- (void)
decimate
{
    for (NSUInteger i = 0; i < sample_capacity / 2; i++) {
        _samples[i] = fmax(_samples[2 * i], _samples[2 * i + 1]);
    }
    _count     = sample_capacity / 2;
    _stride   *= 2;
    _last_fill = _stride;
}

/*
 * add_sample:average: — smooth bps and store it, merging into the last slot
 * until that slot holds _stride samples; decimates when the buffer is full.
 *
 * The stored value is an exponential moving average (ema_alpha) of bps so the
 * graph is smooth. avg_bps is drawn as the reference line.
 *
 * Inputs:
 *   bps     — raw instantaneous bytes per second
 *   avg_bps — running average bytes per second since the copy started
 */
- (void)
add_sample:(double)bps average:(double)avg_bps
{
    _avg_bps = avg_bps;

    double smoothed = (_count > 0)
        ? ema_alpha * _last_smoothed + (1.0 - ema_alpha) * bps
        : bps;
    _last_smoothed = smoothed;

    if (_count > 0 && _last_fill < _stride) {
        _samples[_count - 1] = fmax(_samples[_count - 1], smoothed);
        _last_fill++;
    } else {
        if (_count == sample_capacity) [self decimate];
        _samples[_count++] = smoothed;
        _last_fill = 1;
    }

    if (smoothed > _y_max) _y_max = smoothed;

    [self setNeedsDisplay:YES];
}

/*
 * draw_speed_area:y_max: — fill the area under the stored samples.
 *
 * Samples are spread across the plot width. When there are more samples than
 * pixel columns, each column shows the maximum of its bucket (preserves
 * spikes). Needs at least two samples; draws nothing otherwise.
 *
 * Inputs:
 *   plot  — plot area rectangle in view coordinates
 *   y_max — value that maps to the top of the plot area
 */
- (void)
draw_speed_area:(NSRect)plot y_max:(double)y_max
{
    if (_count < 2) return;

    CGFloat    left   = NSMinX(plot);
    CGFloat    bottom = NSMinY(plot);
    CGFloat    plot_w = NSWidth(plot);
    CGFloat    plot_h = NSHeight(plot);
    NSUInteger n_pts  = (NSUInteger)plot_w;  /* one output point per pixel column */
    if (n_pts < 2) n_pts = 2;
    if (n_pts > _count) n_pts = _count;

    NSBezierPath *area = [NSBezierPath bezierPath];
    for (NSUInteger p = 0; p < n_pts; p++) {
        NSUInteger s = p * _count / n_pts;
        NSUInteger e = (p + 1) * _count / n_pts;
        double     v = 0.0;
        for (NSUInteger k = s; k < e; k++) {
            if (_samples[k] > v) v = _samples[k];
        }
        NSPoint pt = NSMakePoint(left + (CGFloat)p / (CGFloat)(n_pts - 1) * plot_w,
                                 bottom + (CGFloat)(v / y_max) * plot_h);
        if (p == 0) [area moveToPoint:pt];
        else        [area lineToPoint:pt];
    }
    [area lineToPoint:NSMakePoint(left + plot_w, bottom)];
    [area lineToPoint:NSMakePoint(left,          bottom)];
    [area closePath];
    [[NSColor.systemGreenColor colorWithAlphaComponent:0.25] setFill];
    [area fill];
}

/*
 * drawRect: — render Y gridlines, EMA-smoothed filled area, average speed
 * reference line with label, plot border, and dark grey view border.
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

    if (_count == 0) return;

    double y_max = _y_max * 1.1;
    if (y_max < y_floor_bps) y_max = y_floor_bps;

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

    CGFloat left_margin   = ceil(label_w) + 2.0 * label_pad;
    CGFloat bottom_margin = 4.0;
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

    /* ── Speed area ────────────────────────────────────────────────────────── */

    [self draw_speed_area:plot y_max:y_max];

    /* ── Average speed reference line + label ────────────────────────────── */

    if (_avg_bps > 0.0) {
        CGFloat y_avg = NSMinY(plot) + (CGFloat)(_avg_bps / y_max) * NSHeight(plot);

        NSBezierPath *avg_line = [NSBezierPath bezierPath];
        [avg_line moveToPoint:NSMakePoint(NSMinX(plot), y_avg)];
        [avg_line lineToPoint:NSMakePoint(NSMaxX(plot), y_avg)];
        avg_line.lineWidth = 1.0;
        [NSColor.secondaryLabelColor setStroke];
        [avg_line stroke];

        NSString     *avg_str   = files_format_rate(_avg_bps);
        NSDictionary *avg_attrs = @{
            NSFontAttributeName:            [NSFont systemFontOfSize:9.0],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        };
        NSSize asz = [avg_str sizeWithAttributes:avg_attrs];
        [avg_str drawAtPoint:NSMakePoint(NSMaxX(plot) - asz.width - 3.0, y_avg + 2.0)
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
