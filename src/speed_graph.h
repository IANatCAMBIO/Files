#import <Cocoa/Cocoa.h>

/*
 * FilesSpeedGraph — NSView that draws a transfer speed graph.
 *
 * Draws a filled green area for instantaneous speed and a horizontal
 * reference line marking the running average.  All recorded data is always
 * shown; axes scale dynamically.
 *
 * Call add_sample:average: on the main thread each time a new measurement arrives.
 * The view redraws automatically after each sample.
 */
@interface FilesSpeedGraph : NSView

/*
 * add_sample:average: — append a new speed pair to the rolling buffers.
 *
 * Inputs:
 *   bps     — instantaneous bytes per second (sliding window)
 *   avg_bps — running average bytes per second since copy started
 */
- (void)add_sample:(double)bps average:(double)avg_bps;

/*
 * current_bps — the most recently added instantaneous sample value.
 *
 * Output: bytes per second, or 0 if no samples recorded yet.
 */
@property (nonatomic, readonly) double current_bps;

@end
