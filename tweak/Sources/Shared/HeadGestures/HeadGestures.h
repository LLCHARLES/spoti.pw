// AirPods gestures (Mod Settings > AirPods gestures), under either look: with head tracking AirPods in,
// nodding twice or shaking the head runs a player command of the user's picking, so a song can be
// skipped or paused with both hands full. The head is read through Shared/HeadMotion and told apart
// from nodding along by SGHeadGestureDetector (plain C, harness/headgestures/). The commands are the
// ones the mini player sends (SPTPlayer.h). The switch and the choices apply at once.
//
//     HeadGestures.m          follows the head while the switch is on, runs the command
//     HeadGesturesSettings.m  its page
//     HeadGestures.x          starts it at launch
#import <UIKit/UIKit.h>

#define SGKeyHeadGestures @"spotifyglass.headGestures"            // off until switched on
#define SGKeyHeadGestureNod @"spotifyglass.headGestures.nod"      // an SGHeadGestureAction, Play/pause unset
#define SGKeyHeadGestureShake @"spotifyglass.headGestures.shake"  // an SGHeadGestureAction, Next track unset

typedef NS_ENUM(NSInteger, SGHeadGestureAction) {
    SGHeadGestureActionNothing = 0,
    SGHeadGestureActionPlayPause,
    SGHeadGestureActionNext,
    SGHeadGestureActionPrevious,
    SGHeadGestureActionRestart,
};

// Reads the switch and starts or stops following the head. Main thread.
void SGHeadGesturesApply(void);
UIViewController *SGHeadGesturesSettingsPage(void);
// Beside the row on Mod Settings' main page: Off, or On.
NSString *SGHeadGesturesSummary(void);
