#import <Cocoa/Cocoa.h>

/*
 * FilesSpeedGraph — NSView that draws a transfer speed graph.
 *
 * Draws a filled green area for the transfer rate over time and a
 * horizontal line, labelled on the right, at the average rate. Both come
 * from the same data — the bytes moved in each sampling interval — so the
 * average line is exactly the time-weighted mean of the plotted area and
 * always lies within it. The Y axis scales to the largest plotted rate.
 *
 * The whole transfer stays visible with bounded memory: intervals go into
 * a fixed-capacity buffer, and when it fills, adjacent pairs are merged
 * (bytes and seconds summed) so each slot covers twice as much time as
 * before. Long transfers therefore lose time resolution, never history.
 *
 * The plot starts at the first byte: intervals before any data has moved
 * are dropped, so a slow start (waiting on iCloud) leaves no blank lead-in
 * and the average covers only the time data was flowing.
 *
 * Call add_bytes:seconds: on the main thread once per sampling interval;
 * the view redraws after each.
 */
@interface FilesSpeedGraph : NSView

/*
 * average_bps — the average rate the graph's line shows: bytes recorded
 * over the seconds recorded (so excluding any lead-in before the first
 * byte). 0 until data has arrived.
 */
@property (nonatomic, readonly) double average_bps;

/*
 * add_bytes:seconds: — record one sampling interval.
 *
 * Inputs:
 *   bytes   — bytes transferred during the interval (≥ 0)
 *   seconds — length of the interval; ignored unless > 0
 *
 * Intervals with no bytes are ignored until the first one with data.
 */
- (void)add_bytes:(int64_t)bytes seconds:(double)seconds;

@end
