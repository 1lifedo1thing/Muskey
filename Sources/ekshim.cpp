#include "ekshim.h"

#include <essentia/algorithmfactory.h>
#include <essentia/essentia.h>

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

EKResult ek_key(const float *samples, unsigned int count, double rate, const char *profile) {
    EKResult result = {-1, 0, 0};
    if (!essentia::isInitialized()) {
        essentia::infoLevelActive = false;
        essentia::warningLevelActive = false;
        essentia::init();
    }

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
