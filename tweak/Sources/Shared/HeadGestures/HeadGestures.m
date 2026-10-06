// HeadGestures.h says what this is.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/HeadMotion/SGHeadMotion.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Haptics/Haptics.h"
#import "SGHeadGestureDetector.h"
#import "HeadGestures.h"

static id sg_token;
// The head queue's own.
static SGHeadGestureDetector sg_detector;

static NSString *actionName(SGHeadGestureAction action) {
    switch (action) {
        case SGHeadGestureActionNothing: return @"nothing";
        case SGHeadGestureActionPlayPause: return @"play/pause";
        case SGHeadGestureActionNext: return @"next";
        case SGHeadGestureActionPrevious: return @"previous";
        case SGHeadGestureActionRestart: return @"restart";
    }
    return @"?";
}

// Main thread. Only Play/pause answers while nothing plays: a skip nobody hears is a skip by accident.
static void run(SGHeadGestureAction action) {
    if (action == SGHeadGestureActionNothing) return;
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = SGPlayerState();
    if (!player || !state.track) {
        SGLog(@"airpods gestures: %@, but there is no player or track", actionName(action));
        return;
    }
    BOOL paused = [state respondsToSelector:@selector(isPaused)] ? state.isPaused : NO;
    if (paused && action != SGHeadGestureActionPlayPause) return;
    id result = nil;
    switch (action) {
        case SGHeadGestureActionPlayPause: {
            SEL command = paused ? @selector(resume:) : @selector(pause:);
            if (![player respondsToSelector:command]) break;
            result = paused ? [player resume:nil] : [player pause:nil];
            SGPlayFeedback(paused ? SGFeedbackPlay : SGFeedbackPause);
            break;
        }
        case SGHeadGestureActionNext:
            if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) result = [player skipToNextTrackWithOptions:nil];
            SGPlayFeedback(SGFeedbackSkip);
            break;
        case SGHeadGestureActionPrevious:
            if ([player respondsToSelector:@selector(skipToPreviousTrackWithOptions:)]) result = [player skipToPreviousTrackWithOptions:nil];
            SGPlayFeedback(SGFeedbackSkip);
            break;
        case SGHeadGestureActionRestart:
            if ([player respondsToSelector:@selector(seekTo:)]) [player seekTo:0];
            SGPlayFeedback(SGFeedbackSkip);
            break;
        default:
            break;
    }
    SGLog(@"airpods gestures: %@ -> %@", actionName(action), result);
}

static void feed(CMDeviceMotion *motion) {
    SGHeadGesture gesture = SGHeadGestureFeed(&sg_detector, motion.timestamp, motion.attitude.pitch, motion.attitude.yaw);
    if (gesture == SGHeadGestureNone) return;
    SGHeadGestureAction action = gesture == SGHeadGestureNod
        ? (SGHeadGestureAction)SGInt(SGKeyHeadGestureNod, SGHeadGestureActionPlayPause)
        : (SGHeadGestureAction)SGInt(SGKeyHeadGestureShake, SGHeadGestureActionNext);
    SGLog(@"airpods gestures: %@", gesture == SGHeadGestureNod ? @"nod" : @"shake");
    dispatch_async(dispatch_get_main_queue(), ^{ run(action); });
}

void SGHeadGesturesApply(void) {
    BOOL wanted = SGFlag(SGKeyHeadGestures, NO) && SGHeadMotionSupported();
    if (wanted && !sg_token) {
        // Reset on the head queue's side of the token: no reading has come in yet.
        SGHeadGestureReset(&sg_detector);
        sg_token = SGHeadMotionAddObserver(^(CMDeviceMotion *motion) { feed(motion); });
        SGLog(@"airpods gestures: following the head");
    } else if (!wanted && sg_token) {
        SGHeadMotionRemoveObserver(sg_token);
        sg_token = nil;
        SGLog(@"airpods gestures: stopped");
    }
}

NSString *SGHeadGesturesSummary(void) {
    return SGFlag(SGKeyHeadGestures, NO) ? @"On" : @"Off";
}
