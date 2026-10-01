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
 * Call add_bytes:seconds: on the main thread once per sampling interval;
 * the view redraws after each.
 */
@interface FilesSpeedGraph : NSView

/*
 * add_bytes:seconds: — record one sampling interval.
 *
 * Inputs:
 *   bytes   — bytes transferred during the interval (≥ 0)
 *   seconds — length of the interval; ignored unless > 0
 */
- (void)add_bytes:(int64_t)bytes seconds:(double)seconds;

@end
