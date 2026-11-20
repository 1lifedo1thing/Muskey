#include "ekshim.h"

#include <essentia/algorithmfactory.h>
#include <essentia/essentia.h>

#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace essentia;
using namespace essentia::standard;

static const std::map<std::string, int> pitchClasses = {
    {"C", 0}, {"C#", 1}, {"Db", 1}, {"D", 2}, {"D#", 3}, {"Eb", 3}, {"E", 4}, {"F", 5}, {"F#", 6},
    {"Gb", 6}, {"G", 7}, {"G#", 8}, {"Ab", 8}, {"A", 9}, {"A#", 10}, {"Bb", 10}, {"B", 11},
};

static void initEssentia() {
    if (essentia::isInitialized()) return;
    essentia::infoLevelActive = false;
    essentia::warningLevelActive = false;
    essentia::init();
}

EKResult ek_key(const float *samples, unsigned int count, double rate, const char *profile) {
    EKResult result = {-1, 0, 0};
    initEssentia();

    std::vector<Real> audio(samples, samples + count);
    std::string key, scale;
    Real strength = 0;
    try {
        std::unique_ptr<Algorithm> extractor(AlgorithmFactory::create(
            "KeyExtractor", "profileType", std::string(profile), "sampleRate", Real(rate)));
        extractor->input("audio").set(audio);
        extractor->output("key").set(key);
        extractor->output("scale").set(scale);
        extractor->output("strength").set(strength);
        extractor->compute();
    } catch (const std::exception &) {
        return result;
    }

    auto found = pitchClasses.find(key);
    if (found == pitchClasses.end() || strength <= 0) return result;
    result.pitchClass = found->second;
    result.minor = scale == "minor";
    result.strength = strength;
    return result;
}

EKTempo ek_tempo(const float *samples, unsigned int count, const char *method) {
    EKTempo result = {0, 0};
    initEssentia();

    std::vector<Real> audio(samples, samples + count);
    Real bpm = 0, confidence = 0;
    try {
        if (std::string(method) == "percival") {
            std::unique_ptr<Algorithm> estimator(AlgorithmFactory::create("PercivalBpmEstimator", "sampleRate", 44100));
            estimator->input("signal").set(audio);
            estimator->output("bpm").set(bpm);
            estimator->compute();
        } else {
            std::vector<Real> ticks, estimates, intervals;
            std::unique_ptr<Algorithm> extractor(AlgorithmFactory::create("RhythmExtractor2013", "method", std::string(method)));
            extractor->input("signal").set(audio);
            extractor->output("bpm").set(bpm);
            extractor->output("ticks").set(ticks);
            extractor->output("confidence").set(confidence);
            extractor->output("estimates").set(estimates);
            extractor->output("bpmIntervals").set(intervals);
            extractor->compute();
        }
    } catch (const std::exception &) {
        return result;
    }
    if (!(bpm > 0) || !std::isfinite(bpm)) return result;
    result.bpm = bpm;
    result.confidence = std::isfinite(confidence) ? confidence : 0;
    return result;
}

int ek_beats(const float *samples, unsigned int count, float *ticks, int capacity, float *bpm) {
    initEssentia();
    *bpm = 0;
    std::vector<Real> audio(samples, samples + count), found, estimates, intervals;
    Real tempo = 0, confidence = 0;
    try {
        std::unique_ptr<Algorithm> extractor(AlgorithmFactory::create("RhythmExtractor2013", "method", std::string("multifeature")));
        extractor->input("signal").set(audio);
        extractor->output("bpm").set(tempo);
        extractor->output("ticks").set(found);
        extractor->output("confidence").set(confidence);
        extractor->output("estimates").set(estimates);
        extractor->output("bpmIntervals").set(intervals);
        extractor->compute();
    } catch (const std::exception &) {
        return 0;
    }
    if (std::isfinite(tempo)) *bpm = tempo;
    int n = 0;
    for (Real t : found) {
        if (n >= capacity) break;
        if (std::isfinite(t)) ticks[n++] = t;
    }
    return n;
}

int ek_onsets(const float *samples, unsigned int count, float *onsets, int capacity) {
    initEssentia();
    std::vector<Real> audio(samples, samples + count), found;
    Real rate = 0;
    try {
        std::unique_ptr<Algorithm> detector(AlgorithmFactory::create("OnsetRate"));
        detector->input("signal").set(audio);
        detector->output("onsets").set(found);
        detector->output("onsetRate").set(rate);
        detector->compute();
    } catch (const std::exception &) {
        return 0;
    }
    int n = 0;
    for (Real t : found) {
        if (n >= capacity) break;
        if (std::isfinite(t)) onsets[n++] = t;
    }
    return n;
}
