// The visualizer: a ring of bars that moves with what Spotify plays, NCS style, drawn around the cover
// (the redesign's player puts it there, Redesigned/Player/PlayerArtwork.x, and turns the cover into a
// circle inside it). Under either look the sound is read the same way:
//
//     VisualizerTap.x    the finished sound, after speed, pitch, audio effects and Sing, off the last of
//                        Audio/SGAudioPipeline's stages into SGSpectrum's ring, only while a ring shows
//     SGSpectrum.m       the bars out of the sound, plain C (harness/visualizer/)
//     SGVisualizerView.m the ring, drawn on a display link the way the lyrics are: 60 to 120 Hz, put down
//                        while the player animates and whenever the app or the view is not on screen
//     VisualizerSettings.m  its rows, set the same way as Music Haptics: a strength and what it follows
//
// Everything applies at once.
#import <UIKit/UIKit.h>

// How strongly the bars move, a percentage, and what they follow (an SGMusicFollows: everything, the beat
// or the bass), the same two settings as Music Haptics, and the switch that takes Music Haptics' own.
#define SGKeyVisualizerStrength @"spotifyglass.visualizer.strength"   // 20...200, 100 unset
#define SGKeyVisualizerFollows @"spotifyglass.visualizer.follows"
#define SGKeyVisualizerLikeHaptics @"spotifyglass.visualizer.likeHaptics"   // off until switched on
#define SGKeyVisualizerBars @"spotifyglass.visualizer.bars"           // an index into the counts below
#define SGKeyVisualizerStyle @"spotifyglass.visualizer.style"         // an SGVisualizerStyle
#define SGKeyVisualizerColor @"spotifyglass.visualizer.color"         // an SGVisualizerColor
#define SGKeyVisualizerMirror @"spotifyglass.visualizer.mirror"       // on until switched off

typedef NS_ENUM(NSInteger, SGVisualizerStyle) {
    SGVisualizerStyleBars = 0,   // a bar out from the ring per band, rounded at the end
    SGVisualizerStyleWave,       // one closed line pushed out by the bands
    SGVisualizerStyleDots,       // a dot per band, riding out on its level
};

typedef NS_ENUM(NSInteger, SGVisualizerColor) {
    SGVisualizerColorAccent = 0,   // the look's accent, or what the host hands the view
    SGVisualizerColorWhite,
    SGVisualizerColorSpectrum,     // a hue all the way round
};

// Posted on the main queue when a setting changes, so every ring takes it at once.
extern NSNotificationName const SGVisualizerSettingsDidChangeNotification;

NSInteger SGVisualizerBarCount(void);

// VisualizerTap.x: the tap reads the sound only while at least one ring is on screen.
void SGVisualizerSetListening(BOOL listening);
// The newest bars, `count` of them, for a frame `elapsed` seconds after the last; NO when there is no sound
// to read yet (the bars then fall, which this does too).
BOOL SGVisualizerReadBars(float *bars, NSInteger count, float elapsed);

@class SGModRow;
// VisualizerSettings.m: the rows that set it up, for the page of whoever shows a ring.
NSArray<SGModRow *> *SGVisualizerRows(BOOL (^shown)(void));
