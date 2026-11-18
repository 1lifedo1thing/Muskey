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

#ifdef __cplusplus
}
#endif
