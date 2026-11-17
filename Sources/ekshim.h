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

#ifdef __cplusplus
}
#endif
