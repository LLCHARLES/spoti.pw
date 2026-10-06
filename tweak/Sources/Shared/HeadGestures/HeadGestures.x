// AirPods gestures start at launch when switched on (HeadGestures.h).
#import "Core/SGCore.h"
#import "HeadGestures.h"

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ SGHeadGesturesApply(); });
}
