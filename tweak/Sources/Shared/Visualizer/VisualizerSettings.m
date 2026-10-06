// The visualizer's rows (Visualizer.h): the same strength and choice of what to follow as Music Haptics, or
// Music Haptics' own with a switch, then how many bars, their style and colour, and the mirror. Each row
// applies at once and tells every ring.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Haptics/Haptics.h"
#import "Visualizer.h"

NSNotificationName const SGVisualizerSettingsDidChangeNotification = @"spotifyglass.visualizerChanged";

static NSArray<NSNumber *> *counts(void) { return @[@48, @64, @96, @128]; }

NSInteger SGVisualizerBarCount(void) {
    NSArray<NSNumber *> *list = counts();
    NSInteger index = SGInt(SGKeyVisualizerBars, 1);
    return list[(NSUInteger)MAX(0, MIN((NSInteger)list.count - 1, index))].integerValue;
}

static void changed(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGVisualizerSettingsDidChangeNotification object:nil];
}

NSArray<SGModRow *> *SGVisualizerRows(BOOL (^shown)(void)) {
    BOOL (^own)(void) = ^BOOL { return (!shown || shown()) && !SGFlag(SGKeyVisualizerLikeHaptics, NO); };
    SGModRow *likeHaptics = SGOptionRow(@"Same as Music Haptics", @"Its strength and what it follows", SGKeyVisualizerLikeHaptics);
    likeHaptics.changed = ^(BOOL on) { changed(); };
    SGModRow *strength = SGSliderRow(@"Strength", nil, SGMusicStrengthMin, SGMusicStrengthMax, SGStrengthStep,
        ^double { return SGInt(SGKeyVisualizerStrength, 100); },
        ^(double value) { SGSetInt(SGKeyVisualizerStrength, (NSInteger)lround(value)); changed(); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld %%", lround(value)]; });
    strength.visible = own;
    SGModRow *follows = SGChoiceRow(@"Follows", nil, SGKeyVisualizerFollows, @[@"Everything", @"Beat", @"Bass"], SGMusicFollowsEverything);
    follows.choiceNotes = @[@"Every band at its level", @"The drums jump out of the rest", @"The low end, all the way round"];
    follows.chosen = ^(NSInteger index) { changed(); };
    follows.visible = own;
    SGModRow *bars = SGChoiceRow(@"Bars", nil, SGKeyVisualizerBars, @[@"48", @"64", @"96", @"128"], 1);
    bars.chosen = ^(NSInteger index) { changed(); };
    SGModRow *style = SGChoiceRow(@"Style", nil, SGKeyVisualizerStyle, @[@"Bars", @"Wave", @"Dots"], SGVisualizerStyleBars);
    style.chosen = ^(NSInteger index) { changed(); };
    SGModRow *color = SGChoiceRow(@"Colour", nil, SGKeyVisualizerColor, @[@"Accent", @"White", @"Spectrum"], SGVisualizerColorAccent);
    color.chosen = ^(NSInteger index) { changed(); };
    SGModRow *mirror = SGSwitchRow(@"Mirror", @"Each side the other's reflection", SGKeyVisualizerMirror);
    mirror.changed = ^(BOOL on) { changed(); };
    NSArray<SGModRow *> *rows = @[likeHaptics, strength, follows, bars, style, color, mirror];
    for (SGModRow *row in rows) {
        if (row.visible || !shown) continue;
        row.visible = shown;
    }
    return rows;
}
