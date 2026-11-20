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

int ek_chords(const float *samples, unsigned int count, const float *ticks, int nticks, int *roots, int *minors, float *strengths, int capacity) {
    initEssentia();
    const int frameSize = 8192, hop = 2048;
    const Real rate = 44100;
    std::vector<Real> audio(samples, samples + count), frame, windowed, spectrum, frequencies, magnitudes, chroma;
    std::vector<std::vector<Real>> pcp;
    std::vector<std::string> labels;
    std::vector<Real> strength, beats(ticks, ticks + nticks);
    try {
        std::unique_ptr<Algorithm> cutter(AlgorithmFactory::create("FrameCutter", "frameSize", frameSize, "hopSize", hop, "startFromZero", true));
        std::unique_ptr<Algorithm> window(AlgorithmFactory::create("Windowing", "type", std::string("blackmanharris62")));
        std::unique_ptr<Algorithm> fft(AlgorithmFactory::create("Spectrum", "size", frameSize));
        std::unique_ptr<Algorithm> peaks(AlgorithmFactory::create("SpectralPeaks"));
        ParameterMap peakParameters;
        peakParameters.add("orderBy", Parameter(std::string("magnitude")));
        peakParameters.add("magnitudeThreshold", Parameter((Real)0.00001));
        peakParameters.add("minFrequency", Parameter((Real)40));
        peakParameters.add("maxFrequency", Parameter((Real)5000));
        peakParameters.add("maxPeaks", Parameter(60));
        peakParameters.add("sampleRate", Parameter(rate));
        peaks->configure(peakParameters);
        std::unique_ptr<Algorithm> hpcp(AlgorithmFactory::create("HPCP"));
        ParameterMap hpcpParameters;
        hpcpParameters.add("size", Parameter(36));
        hpcpParameters.add("referenceFrequency", Parameter((Real)440));
        hpcpParameters.add("harmonics", Parameter(8));
        hpcpParameters.add("bandPreset", Parameter(true));
        hpcpParameters.add("minFrequency", Parameter((Real)40));
        hpcpParameters.add("maxFrequency", Parameter((Real)5000));
        hpcpParameters.add("weightType", Parameter(std::string("cosine")));
        hpcpParameters.add("nonLinear", Parameter(false));
        hpcpParameters.add("windowSize", Parameter((Real)1));
        hpcpParameters.add("sampleRate", Parameter(rate));
        hpcp->configure(hpcpParameters);
        cutter->input("signal").set(audio);
        cutter->output("frame").set(frame);
        window->input("frame").set(frame);
        window->output("frame").set(windowed);
        fft->input("frame").set(windowed);
        fft->output("spectrum").set(spectrum);
        peaks->input("spectrum").set(spectrum);
        peaks->output("frequencies").set(frequencies);
        peaks->output("magnitudes").set(magnitudes);
        hpcp->input("frequencies").set(frequencies);
        hpcp->input("magnitudes").set(magnitudes);
        hpcp->output("hpcp").set(chroma);
        while (true) {
            cutter->compute();
            if (frame.empty()) break;
            window->compute();
            fft->compute();
            peaks->compute();
            hpcp->compute();
            pcp.push_back(chroma);
        }
        if (pcp.empty() || beats.size() < 2) return 0;
        std::unique_ptr<Algorithm> chords(AlgorithmFactory::create("ChordsDetectionBeats", "sampleRate", rate, "hopSize", hop));
        chords->input("pcp").set(pcp);
        chords->input("ticks").set(beats);
        chords->output("chords").set(labels);
        chords->output("strength").set(strength);
        chords->compute();
    } catch (const std::exception &) {
        return 0;
    }
    int n = 0;
    for (size_t i = 0; i < labels.size() && n < capacity; i++) {
        std::string label = labels[i];
        bool minor = label.size() > 1 && label.back() == 'm';
        if (minor) label.pop_back();
        auto found = pitchClasses.find(label);
        roots[n] = found == pitchClasses.end() ? -1 : found->second;
        minors[n] = minor ? 1 : 0;
        strengths[n] = i < strength.size() && std::isfinite(strength[i]) ? strength[i] : 0;
        n++;
    }
    return n;
}
