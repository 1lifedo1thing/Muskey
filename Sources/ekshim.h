#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int pitchClass;  // 0 = C .. 11 = B, -1 when nothing was found
    int minor;
    float strength;  // correlation with the key profile
} EKResult;

// Runs Essentia's KeyExtractor over mono samples. `profile` is an Essentia profileType such as "shaath".
EKResult ek_key(const float *samples, unsigned int count, double rate, const char *profile);

typedef struct {
    float bpm;         // 0 when no beat was found
    float confidence;  // 0 to 5.32 for "multifeature", always 0 for the other methods
} EKTempo;

// Estimates the tempo of mono samples at 44.1 kHz. `method` is "multifeature" or "degara" for Essentia's
// RhythmExtractor2013, or "percival" for PercivalBpmEstimator.
EKTempo ek_tempo(const float *samples, unsigned int count, const char *method);

// The beats that RhythmExtractor2013 ("multifeature") finds in mono samples at 44.1 kHz, in seconds from the first
// sample, at most `capacity` of them. Returns how many it wrote, and sets `bpm`.
int ek_beats(const float *samples, unsigned int count, float *ticks, int capacity, float *bpm);

// The attacks that OnsetRate finds in mono samples at 44.1 kHz, in seconds from the first sample, at most `capacity`.
int ek_onsets(const float *samples, unsigned int count, float *onsets, int capacity);

// The chord between each two beats of `ticks` in mono samples at 44.1 kHz, from Essentia's HPCP and ChordsDetectionBeats:
// its root (0 = C .. 11 = B, -1 when none was found), whether it is minor, and how sure the detection is. Chord `i`
// lasts from `ticks[i]` to `ticks[i + 1]`. Returns how many it wrote, at most `capacity`.
int ek_chords(const float *samples, unsigned int count, const float *ticks, int nticks, int *roots, int *minors, float *strengths, int capacity);

#ifdef __cplusplus
}
#endif
