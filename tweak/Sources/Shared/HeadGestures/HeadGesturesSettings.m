// Mod Settings > AirPods gestures: the switch and what a nod and a shake do, all applying at once.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/HeadMotion/SGHeadMotion.h"
#import "HeadGestures.h"

static NSArray<NSString *> *actions(void) {
    return @[@"Nothing", @"Play or pause", @"Next track", @"Previous track", @"Start the track over"];
}

UIViewController *SGHeadGesturesSettingsPage(void) {
    SGModRow *on = SGOptionRow(@"AirPods gestures", @"Nod or shake your head to control playback", SGKeyHeadGestures);
    on.changed = ^(BOOL value) { SGHeadGesturesApply(); };
    BOOL (^shown)(void) = ^BOOL { return SGFlag(SGKeyHeadGestures, NO); };
    SGModRow *nod = SGChoiceRow(@"Nod twice", nil, SGKeyHeadGestureNod, actions(), SGHeadGestureActionPlayPause);
    nod.visible = shown;
    SGModRow *shake = SGChoiceRow(@"Shake your head", nil, SGKeyHeadGestureShake, actions(), SGHeadGestureActionNext);
    shake.visible = shown;
    NSString *footer = SGHeadMotionSupported()
        ? @"Works with AirPods Pro, AirPods Max, AirPods (3rd generation) or later, and Beats with head tracking. "
          "Nod twice, or shake your head, quickly and then hold still; nodding along to a song is left alone. "
          "Skips only happen while something plays. Head tracking asks for Motion & Fitness access the first time."
        : @"Needs head tracking, from iOS 14.";
    SGModSection *section = SGNotedSection(nil, @[on, nod, shake], footer);
    return [[SGModPage alloc] initWithTitle:@"AirPods gestures" intro:nil sections:@[section] footer:nil];
}
