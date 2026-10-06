// The visualizer's ear (Visualizer.h): the last moments of what Spotify plays, as bars. Plain C with no
// allocation after it is set up, so the tap (VisualizerTap.x) can feed it from Core Audio's render thread
// and the view read it once a frame on the main one; tested on the Mac or Linux against harness/visualizer/.
//
// The tap writes mono samples into SGSpectrumRing, a single writer and a single reader, the reader taking
// the newest SGSpectrumWindow of them whenever it likes: a frame drawn from a window the writer moved on
// from halfway through is one 120th of a second of a slightly smeared picture, never a crash.
//
// SGSpectrumAnalyzer turns a window into `count` bars, each 0...1: a Hann window, a radix-2 FFT, the bins
// summed into bands spaced evenly on a log scale over what is followed, each band's level in decibels
// against the loudest the music has been lately (falling slowly, so a quiet song still moves), then the
// strength, and a fast rise and a slower fall. Follows, as Music Haptics has it (Shared/Haptics):
//     Everything  40 Hz to 14 kHz, every band at its level
//     Beat        the same bands, each lifted by how fast it just rose, so the drums jump out
//     Bass        25 Hz to 250 Hz across the whole ring
#pragma once
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

enum {
    SGSpectrumWindow = 2048,
    SGSpectrumRingSize = 16384,   // a power of two, several windows at 48 kHz
    SGSpectrumMaxBands = 128,
};

typedef enum { SGSpectrumEverything = 0, SGSpectrumBeat, SGSpectrumBass } SGSpectrumFollows;

typedef struct {
    float samples[SGSpectrumRingSize];
    atomic_uint written;   // samples written so far, wrapping
} SGSpectrumRing;

void SGSpectrumRingWrite(SGSpectrumRing *ring, const float *mono, uint32_t count);
// The newest SGSpectrumWindow samples, oldest first; false until that many were written.
bool SGSpectrumRingRead(SGSpectrumRing *ring, float *window);

typedef struct {
    int count;
    double sampleRate;
    SGSpectrumFollows follows;
    float lowHz, highHz;
    float window[SGSpectrumWindow];   // the Hann window
    float real[SGSpectrumWindow], imaginary[SGSpectrumWindow];
    int first[SGSpectrumMaxBands + 1];   // each band's first bin, and the end of the last
    float level[SGSpectrumMaxBands];     // the band's last level, 0...1, before the strength
    float slow[SGSpectrumMaxBands];      // its slow average, which Beat measures a rise against
    float shown[SGSpectrumMaxBands];     // what the bars show, smoothed
    float peakDb;                        // the loudest band lately
} SGSpectrumAnalyzer;

// Before the first window, and whenever the bar count, the rate or what is followed changes.
void SGSpectrumReset(SGSpectrumAnalyzer *analyzer, int count, double sampleRate, SGSpectrumFollows follows);
// One frame: `window` from SGSpectrumRingRead (or silence), `elapsed` the seconds since the last frame,
// `strength` 0.2...2 (1 as it ships). Writes `count` bars into `bars`.
void SGSpectrumProcess(SGSpectrumAnalyzer *analyzer, const float *window, float elapsed, float strength, float *bars);
// The frame's bars fall to nothing when the music stops, at the speed they would anyway.
void SGSpectrumDecay(SGSpectrumAnalyzer *analyzer, float elapsed, float *bars);
