#import <Cocoa/Cocoa.h>

/*
 * FilesSpeedGraph — NSView that draws a transfer speed graph.
 *
 * Draws a filled green area for the (EMA-smoothed) instantaneous speed and a
 * horizontal reference line marking the running average; the Y axis scales
 * to the largest sample.
 *
 * The whole transfer stays visible with bounded memory: samples go into a
 * fixed-capacity buffer, and when it fills, adjacent pairs are merged (keeping
 * the larger value) so each slot covers twice as many samples as before.
 * Long transfers therefore lose time resolution, never history or peaks.
 *
 * Call add_sample:average: on the main thread each time a new measurement
 * arrives. The view redraws automatically after each sample.
 */
@interface FilesSpeedGraph : NSView

/*
 * add_sample:average: — record a new speed measurement.
 *
 * Inputs:
 *   bps     — instantaneous bytes per second (sliding window)
 *   avg_bps — running average bytes per second since copy started
 */
- (void)add_sample:(double)bps average:(double)avg_bps;

@end
