#import "speed_graph.h"

#define INITIAL_CAP  256    /* starting buffer capacity (doubles as needed) */
#define EMA_ALPHA    0.7    /* exponential moving average weight on previous sample */

@implementation FilesSpeedGraph {
    double     *_samples;    /* EMA-smoothed instantaneous speed, linear array */
    NSUInteger  _count;      /* samples recorded so far */
    NSUInteger  _capacity;   /* allocated slots in _samples */
    double      _current_bps;
    double      _y_max;      /* running maximum of stored samples */
    double      _avg_bps;    /* latest running-average bps from the caller */
}

/*
 * initWithFrame: — allocate the initial sample buffers.
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
    _capacity    = INITIAL_CAP;
    _samples     = calloc(_capacity, sizeof(double));
    _count       = 0;
    _current_bps = 0;
    _y_max       = 1.0;
    return self;
}

/*
 * dealloc — free the heap-allocated sample buffers.
 */
- (void)
dealloc
{
    free(_samples);
}

/*
 * add_sample:average: — append a smoothed sample; grow the buffer if needed.
 *
 * Applies an exponential moving average (EMA_ALPHA) to the stored value so the
 * graph line is smooth while _current_bps retains the raw measurement for labels.
 * avg_bps is accepted for API compatibility but not stored.
 *
 * Inputs:
 *   bps     — raw instantaneous bytes per second
 *   avg_bps — running average bytes per second since the copy started
 */
- (void)
add_sample:(double)bps average:(double)avg_bps
{
    _current_bps = bps;
    _avg_bps     = avg_bps;

    double smoothed = (_count > 0)
        ? EMA_ALPHA * _samples[_count - 1] + (1.0 - EMA_ALPHA) * bps
        : bps;

    if (_count == _capacity) {
        _capacity *= 2;
        _samples   = realloc(_samples, _capacity * sizeof(double));
    }
    _samples[_count] = smoothed;
    _count++;

    if (smoothed > _y_max) _y_max = smoothed;

    [self setNeedsDisplay:YES];
}

- (double)current_bps { return _current_bps; }

/*
 * sample_path:count:y_max:plot_w:plot_h:left_margin:bottom_margin: —
 * build an NSBezierPath tracing the top edge of a data series.
 *
 * All samples are mapped into the available plot width, so the x-axis
 * resolution adjusts automatically as the copy runs.  When the sample
 * count exceeds the pixel width, each output pixel column shows the
 * maximum value in its sample bucket (preserves spikes).
 *
 * Inputs:
 *   buf           — linear array of bps values, length ≥ count
 *   count         — number of valid samples
 *   y_max         — value that maps to the top of the plot area
 *   plot_w/plot_h — plot area dimensions in points
 *   left_margin   — left offset of the plot area
 *   bottom_margin — bottom offset of the plot area
 *
 * Output: open path suitable for stroke or for closing to the baseline.
 */
- (NSBezierPath *)
sample_path:(double *)buf
       count:(NSUInteger)count
       y_max:(double)y_max
      plot_w:(CGFloat)plot_w
      plot_h:(CGFloat)plot_h
 left_margin:(CGFloat)left_margin
bottom_margin:(CGFloat)bottom_margin
{
    NSBezierPath *path = [NSBezierPath bezierPath];
    if (count == 0) return path;
    if (count == 1) {
        CGFloat y = bottom_margin + (CGFloat)(_samples[0] / y_max) * plot_h;
        [path moveToPoint:NSMakePoint(left_margin, y)];
        [path lineToPoint:NSMakePoint(left_margin + plot_w, y)];
        return path;
    }

    NSUInteger n_pts = (NSUInteger)plot_w;  /* one output point per pixel column */
    if (n_pts < 2) n_pts = 2;

    if (count <= n_pts) {
        /* Fewer samples than pixels: plot each sample directly. */
        for (NSUInteger i = 0; i < count; i++) {
            CGFloat x = left_margin
                      + (CGFloat)i / (CGFloat)(count - 1) * plot_w;
            CGFloat y = bottom_margin
                      + (CGFloat)(buf[i] / y_max) * plot_h;
            if (i == 0) [path moveToPoint:NSMakePoint(x, y)];
            else        [path lineToPoint:NSMakePoint(x, y)];
        }
    } else {
        /* More samples than pixels: max-per-bucket downsampling. */
        for (NSUInteger p = 0; p < n_pts; p++) {
            NSUInteger s = (NSUInteger)((double)p       * count / n_pts);
            NSUInteger e = (NSUInteger)((double)(p + 1) * count / n_pts);
            if (e > count) e = count;
            double v = 0.0;
            for (NSUInteger k = s; k < e; k++) {
                if (buf[k] > v) v = buf[k];
            }
            CGFloat x = left_margin
                      + (CGFloat)p / (CGFloat)(n_pts - 1) * plot_w;
            CGFloat y = bottom_margin + (CGFloat)(v / y_max) * plot_h;
            if (p == 0) [path moveToPoint:NSMakePoint(x, y)];
            else        [path lineToPoint:NSMakePoint(x, y)];
        }
    }
    return path;
}

/*
 * draw_area_fill:color:count:y_max:plot_w:plot_h:left_margin:bottom_margin: —
 * fill the area under a data series.
 *
 * Inputs:
 *   buf   — linear bps array
 *   color — fill color
 *   remaining args forwarded to sample_path:
 */
- (void)
draw_area_fill:(double *)buf
          color:(NSColor *)color
          count:(NSUInteger)count
          y_max:(double)y_max
         plot_w:(CGFloat)plot_w
         plot_h:(CGFloat)plot_h
    left_margin:(CGFloat)left_margin
  bottom_margin:(CGFloat)bottom_margin
{
    if (count < 2) return;
    NSBezierPath *area = [self sample_path:buf count:count y_max:y_max
                                   plot_w:plot_w plot_h:plot_h
                               left_margin:left_margin bottom_margin:bottom_margin];
    [area lineToPoint:NSMakePoint(left_margin + plot_w, bottom_margin)];
    [area lineToPoint:NSMakePoint(left_margin,           bottom_margin)];
    [area closePath];
    [color setFill];
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

    double y_max   = _y_max * 1.1;
    double y_floor = 1024.0 * 1024.0;  /* minimum Y scale: 1 MB/s */
    if (y_max < y_floor) y_max = y_floor;

    CGFloat left_margin   = 52.0;
    CGFloat bottom_margin = 4.0;
    CGFloat plot_w = b.size.width  - left_margin - 4.0;
    CGFloat plot_h = b.size.height - bottom_margin - 4.0;

    NSDictionary *label_attrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:10.0],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };

    /* ── Y gridlines + labels ──────────────────────────────────────────────── */

    NSArray<NSNumber *> *grid_fracs = @[@0.25, @0.50, @0.75];
    CGFloat dash[2] = {3.0, 3.0};

    for (NSNumber *frac in grid_fracs) {
        CGFloat f  = frac.doubleValue;
        CGFloat y  = bottom_margin + f * plot_h;
        double bps = f * y_max;

        NSBezierPath *grid = [NSBezierPath bezierPath];
        [grid moveToPoint:NSMakePoint(left_margin, y)];
        [grid lineToPoint:NSMakePoint(left_margin + plot_w, y)];
        [grid setLineDash:dash count:2 phase:0];
        grid.lineWidth = 0.5;
        [NSColor.separatorColor setStroke];
        [grid stroke];

        NSString *label;
        if (bps >= 1024.0 * 1024.0 * 1024.0) {
            label = [NSString stringWithFormat:@"%.1f GB/s",
                     bps / (1024.0 * 1024.0 * 1024.0)];
        } else if (bps >= 1024.0 * 1024.0) {
            label = [NSString stringWithFormat:@"%.0f MB/s",
                     bps / (1024.0 * 1024.0)];
        } else {
            label = [NSString stringWithFormat:@"%.0f KB/s", bps / 1024.0];
        }
        NSSize  ls  = [label sizeWithAttributes:label_attrs];
        NSPoint lpt = NSMakePoint(left_margin - ls.width - 4.0,
                                  y - ls.height / 2.0);
        [label drawAtPoint:lpt withAttributes:label_attrs];
    }

    /* ── Speed lines ───────────────────────────────────────────────────────── */

    [self draw_area_fill:_samples
                  color:[NSColor.systemGreenColor colorWithAlphaComponent:0.25]
                  count:_count
                  y_max:y_max
                 plot_w:plot_w
                 plot_h:plot_h
            left_margin:left_margin
          bottom_margin:bottom_margin];

    /* ── Average speed reference line + label ────────────────────────────── */

    if (_avg_bps > 0.0) {
        CGFloat y_avg = bottom_margin + (CGFloat)(_avg_bps / y_max) * plot_h;

        NSBezierPath *avg_line = [NSBezierPath bezierPath];
        [avg_line moveToPoint:NSMakePoint(left_margin,          y_avg)];
        [avg_line lineToPoint:NSMakePoint(left_margin + plot_w, y_avg)];
        avg_line.lineWidth = 1.0;
        [NSColor.secondaryLabelColor setStroke];
        [avg_line stroke];

        NSString *avg_str;
        if (_avg_bps >= 1024.0 * 1024.0 * 1024.0)
            avg_str = [NSString stringWithFormat:@"%.1f GB/s",
                       _avg_bps / (1024.0 * 1024.0 * 1024.0)];
        else if (_avg_bps >= 1024.0 * 1024.0)
            avg_str = [NSString stringWithFormat:@"%.1f MB/s",
                       _avg_bps / (1024.0 * 1024.0)];
        else
            avg_str = [NSString stringWithFormat:@"%.0f KB/s",
                       _avg_bps / 1024.0];

        NSDictionary *avg_attrs = @{
            NSFontAttributeName:            [NSFont systemFontOfSize:9.0],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        };
        NSSize  asz = [avg_str sizeWithAttributes:avg_attrs];
        CGFloat ax  = left_margin + plot_w - asz.width - 3.0;
        CGFloat ay  = y_avg + 2.0;
        [avg_str drawAtPoint:NSMakePoint(ax, ay) withAttributes:avg_attrs];
    }

    /* ── Plot border ───────────────────────────────────────────────────────── */

    NSBezierPath *border = [NSBezierPath bezierPathWithRect:
        NSMakeRect(left_margin, bottom_margin, plot_w, plot_h)];
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
