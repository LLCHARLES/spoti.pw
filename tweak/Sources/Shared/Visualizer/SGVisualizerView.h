// The ring itself (Visualizer.h). It draws round its own centre, from `innerRadius` out to the edge of
// whichever of its sides is shorter, and asks for the sound only while it is on screen.
#import <UIKit/UIKit.h>

@interface SGVisualizerView : UIView
// Where the bars start: just outside what sits in the middle (the cover), which the host moves as the
// cover shrinks and grows; the bars follow from the next frame.
@property (nonatomic) CGFloat innerRadius;
// The colour the Accent choice draws in; white when nil.
@property (nonatomic, strong) UIColor *accent;
@end
