// The Player page's Visualizer card (Player.h): the switch that rings the cover with bars, the spin, and
// under them the ring's own settings (Shared/Visualizer), all applying at once.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Visualizer/Visualizer.h"
#import "Player.h"

NSArray<SGModSection *> *SGRPlayerVisualizerSections(void) {
    void (^tell)(BOOL) = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGVisualizerSettingsDidChangeNotification object:nil];
    };
    SGModRow *on = SGWithSymbol(SGOptionRow(@"Visualizer", @"Bars round the cover, moving with the music", SGRKeyPlayerVisualizer),
                                @"circle.dotted.circle");
    on.changed = tell;
    BOOL (^shown)(void) = ^BOOL { return SGFlag(SGRKeyPlayerVisualizer, NO); };
    SGModRow *spin = SGSwitchRow(@"Spin the cover", @"Slowly, while the song plays", SGRKeyPlayerVisualizerSpin);
    spin.changed = tell;
    spin.visible = shown;
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:on, spin, nil];
    [rows addObjectsFromArray:SGVisualizerRows(shown)];
    return @[SGNotedSection(@"Visualizer", rows,
        @"The cover becomes a circle with the bars round it, like an NCS video. It listens to what you hear, after speed, "
         "pitch and audio effects, only while the player is on screen. Strength and Follows work as Music Haptics' do.")];
}
