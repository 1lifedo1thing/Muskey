#include "pitch.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <memory>
#include <atomic>
#include <cmath>
#include <vector>

#include "rubberband/RubberBandStretcher.h"

using RubberBand::RubberBandStretcher;

namespace {

constexpr size_t maxChunk = 4096;

// Rubber Band's R3 engine in real-time mode, as `rubberband -3 -R` runs it.
constexpr RubberBandStretcher::Options options =
    RubberBandStretcher::OptionProcessRealTime | RubberBandStretcher::OptionEngineFiner;

bool silent(const float *samples, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (samples[i] != 0.0f) return false;
    }
    return true;
}

// A stereo FIFO of interleaved frames, used on one thread only.
struct Fifo {
    std::vector<float> data;
    size_t capacity;
    uint64_t written = 0, read = 0;

    explicit Fifo(size_t frames) : data(frames * 2), capacity(frames) {}

    size_t fill() const { return size_t(written - read); }

    void write(const float *left, const float *right, size_t frames, size_t stride) {
        size_t n = std::min(frames, capacity - fill());
        for (size_t i = 0; i < n; i++) {
            size_t index = size_t((written + i) % capacity) * 2;
            data[index] = left[i * stride];
            data[index + 1] = right[i * stride];
        }
        written += n;
    }

    void readInto(float *left, float *right, size_t frames) {
        for (size_t i = 0; i < frames; i++) {
            size_t index = size_t((read + i) % capacity) * 2;
            left[i] = data[index];
            right[i] = data[index + 1];
        }
        read += frames;
    }
};

// Planar channels shared by the IOProc and the separation thread, one writer and one reader. The writer never
// waits: a reader that falls a whole buffer behind finds the oldest frames overwritten, and skips ahead.
struct SharedFrames {
    std::vector<std::vector<float>> planes;
    size_t capacity;
    std::atomic<uint64_t> written{0}, consumed{0};

    // Positions start far from zero, so a position some way before another never wraps around.
    SharedFrames(size_t channels, size_t frames) : planes(channels, std::vector<float>(frames)), capacity(frames) {
        written.store(uint64_t(1) << 40);
    }

    // `sources` holds one pointer per plane, each read every `stride` floats.
    void write(const float *const *sources, size_t frames, size_t stride) {
        uint64_t at = written.load(std::memory_order_relaxed);
        for (size_t p = 0; p < planes.size(); p++) {
            float *plane = planes[p].data();
            const float *source = sources[p];
            for (size_t i = 0; i < frames; i++) plane[(at + i) % capacity] = source[i * stride];
        }
        written.store(at + frames, std::memory_order_release);
    }
};

// A stereo-linked look-ahead peak limiter. Shifting a song can raise its peaks, so one mastered near full scale
// would clip at the speakers. The signal is delayed by the look-ahead, and
// the gain starts falling that much before a peak, so no sample leaves above the ceiling.
struct Limiter {
    static constexpr float ceiling = 0.891f; // −1 dBFS
    size_t lookahead;
    std::vector<float> delayed;  // interleaved stereo, `lookahead` frames
    std::vector<float> required; // gain each recent frame needs, `lookahead + 1` frames
    std::vector<float> released; // the held gain after release, `lookahead` frames, averaged into the applied gain
    double releasedSum;
    size_t position = 0;
    float gain = 1;
    float releaseStep;

    Limiter(double rate)
        : lookahead(size_t(rate * 0.002)), delayed(lookahead * 2), required(lookahead + 1, 1.0f),
          released(lookahead, 1.0f), releasedSum(double(lookahead)),
          releaseStep(float(1 - std::exp(-1 / (rate * 0.15)))) {}

    void process(float *left, float *right, size_t frames) {
        for (size_t f = 0; f < frames; f++) {
            float peak = std::max(std::abs(left[f]), std::abs(right[f]));
            required[position % required.size()] = peak > ceiling ? ceiling / peak : 1.0f;

            // The lowest gain that any frame in the look-ahead window needs, held, then released over 150 ms.
            float held = 1.0f;
            for (float g : required) held = std::min(held, g);
            gain = held < gain ? held : gain + (held - gain) * releaseStep;

            // Averaging the held gain over the look-ahead turns the drop into a ramp that ends at the peak.
            size_t slot = position % lookahead;
            releasedSum += gain - released[slot];
            released[slot] = gain;
            float applied = float(releasedSum / double(lookahead));

            float outL = delayed[slot * 2] * applied, outR = delayed[slot * 2 + 1] * applied;
            delayed[slot * 2] = left[f];
            delayed[slot * 2 + 1] = right[f];
            left[f] = outL;
            right[f] = outR;
            position++;
        }
    }
};

// One Rubber Band stretcher and the shifted audio it handed back, waiting to be played.
struct Voice {
    RubberBandStretcher stretcher;
    Fifo output;
    float semitones = 0;
    uint64_t start = 0; // frames fed to the voices before this one started
    bool priming = true;

    explicit Voice(double rate) : stretcher(size_t(rate), 2, options), output(size_t(rate) * 2) {
        stretcher.setMaxProcessSize(maxChunk);
    }

    void setSemitones(float value) {
        stretcher.setPitchScale(std::pow(2.0, value / 12.0));
        semitones = value;
    }

    // Starts over at another pitch with frame `at` of the shared input; nothing it played before is kept.
    void restart(float value, uint64_t at) {
        stretcher.reset();
        setSemitones(value);
        output.written = output.read = 0;
        start = at;
        priming = true;
    }

    // `scratch` holds one chunk per channel and is overwritten.
    void feed(const float *const *input, size_t n, float *const *scratch) {
        stretcher.process(input, n, false);
        // Each retrieve takes at most a chunk, and `available` shrinks with every one, so this ends; the bound is a
        // guard against a stretcher that keeps reporting audio it doesn't hand over.
        for (int guard = 0; guard < 64; guard++) {
            int available = stretcher.available();
            if (available <= 0) break;
            size_t got = stretcher.retrieve(scratch, std::min(size_t(available), maxChunk));
            if (got == 0) break;
            output.write(scratch[0], scratch[1], got, 1);
        }
    }

    // The input frame that the next frame played from this voice was made from, give or take a constant that is
    // the same for every voice. Rubber Band's output runs behind its input by the start delay less the start pad,
    // so voices that started at different times can be lined up with this.
    int64_t playing() {
        int64_t lag = int64_t(stretcher.getStartDelay()) - int64_t(stretcher.getPreferredStartPad());
        return int64_t(start) + int64_t(output.read) - lag;
    }

    // Plays `n` frames into left and right, and returns false if it ran dry. After running dry it waits for
    // `cushion` frames on top of a chunk, so the output doesn't stutter frame by frame.
    bool play(float *left, float *right, size_t n, size_t cushion) {
        size_t fill = output.fill();
        if (priming && fill >= cushion + n) priming = false;
        size_t got = priming ? 0 : std::min(n, fill);
        output.readInto(left, right, got);
        std::fill(left + got, left + n, 0.0f);
        std::fill(right + got, right + n, 0.0f);
        if (priming || got == n) return true;
        priming = true;
        return false;
    }
};

// A song from another player, slowed down. The player plays at its own speed, so the tap's audio waits in a backlog,
// and this reads it back slower with a windowed-sinc resampler, the way a record played slower sounds: lower too, and
// the voices raise it back by the correction that the app sets. The backlog grows while the song plays; the app moves
// the player back now and then, finds where the audio that the player plays again matches what the backlog holds, and
// the reader steps from the old audio to the new at that moment of the song, so nothing is heard twice.
struct Slower {
    static constexpr int taps = 32, half = taps / 2, phases = 512;
    // Frames that the reader keeps behind the newest audio, for the resampler's look-ahead.
    static constexpr size_t cushion = half + 8;
    static constexpr size_t maxFrames = 16384;
    double rate;
    std::vector<float> kernel; // (phases + 1) rows of `taps` weights
    std::unique_ptr<SharedFrames> owned;
    std::atomic<SharedFrames *> backlog{nullptr};
    std::atomic<bool> wanted{false};
    std::atomic<double> speed{1.0};
    std::atomic<uint32_t> flushesAsked{0};
    uint32_t flushesTaken = 0;
    std::atomic<uint64_t> spliceFrom{0}, spliceTo{0}, spliceBefore{0};
    std::atomic<uint32_t> splicesAsked{0};
    uint32_t splicesTaken = 0;

    // Read by the app.
    std::atomic<bool> engagedOut{false};
    std::atomic<uint64_t> readingOut{0};
    std::atomic<double> clockOut{0};
    std::atomic<uint32_t> splicesDone{0}, splicesMissed{0}, flushesDone{0};

    // The audio thread's own state.
    bool on = false;
    float mix = 0; // 0 plays the tap as it is, 1 the reader
    uint64_t at = 0;
    double frac = 0, clock = 0;
    bool pending = false;
    uint64_t pendingFrom = 0, pendingTo = 0, pendingBefore = 0;
    // A step in progress, from `at` to `at + jump`: a splice (the same audio, so a short linear crossfade) or a flush
    // (other audio, so an equal-power one).
    size_t stepLeft = 0, stepTotal = 0;
    uint64_t jump = 0;
    bool stepIsFlush = false;
    // Paused: the reader holds where it is, after fading out, and the silence of the pause isn't written.
    float holdGain = 1;
    bool wasPaused = false, awaitingSound = false;
    size_t awaitingFrames = 0;
    std::vector<float> left, right;

    explicit Slower(double rate) : rate(rate), kernel(size_t(phases + 1) * taps), left(maxFrames), right(maxFrames) {
        // A Kaiser-windowed sinc a little under the Nyquist frequency, so reading slightly faster than 1 doesn't alias.
        constexpr double cutoff = 0.97, beta = 8.0;
        auto bessel = [](double x) {
            double sum = 1, term = 1;
            for (int k = 1; k < 30; k++) {
                term *= (x / (2 * k)) * (x / (2 * k));
                sum += term;
            }
            return sum;
        };
        for (int p = 0; p <= phases; p++) {
            double f = double(p) / phases;
            for (int t = 0; t < taps; t++) {
                // Tap t weighs frame `at + t - half + 1`, at distance x from the point that is read.
                double x = double(t - half + 1) - f;
                double sinc = std::abs(x) < 1e-9 ? cutoff : std::sin(M_PI * cutoff * x) / (M_PI * x);
                double w = std::abs(x) >= half ? 0 : bessel(beta * std::sqrt(1 - (x / half) * (x / half))) / bessel(beta);
                kernel[size_t(p) * taps + t] = float(sinc * w);
            }
        }
        // At phase 0 the read lands on a frame, which then comes out unchanged.
        for (int t = 0; t < taps; t++) kernel[t] = t == half - 1 ? 1.0f : 0.0f;
        for (int t = 0; t < taps; t++) kernel[size_t(phases) * taps + t] = t == half ? 1.0f : 0.0f;
    }

    // The song at frame `i` plus `f` of the next one, from the backlog.
    void sample(const SharedFrames &b, uint64_t i, double f, float &l, float &r) const {
        double scaled = f * phases;
        int p = std::min(phases - 1, int(scaled));
        float mixPhase = float(scaled - p);
        const float *k0 = &kernel[size_t(p) * taps], *k1 = &kernel[size_t(p + 1) * taps];
        const float *pl = b.planes[0].data(), *pr = b.planes[1].data();
        uint64_t first = i + 1 - half;
        float sl = 0, sr = 0;
        for (int t = 0; t < taps; t++) {
            float w = k0[t] + (k1[t] - k0[t]) * mixPhase;
            size_t index = size_t((first + t) % b.capacity);
            sl += pl[index] * w;
            sr += pr[index] * w;
        }
        l = sl;
        r = sr;
    }

    // Takes the tap's `frames` and, while slowing, leaves as many frames of the slowed song in left and right.
    // Returns false while the tap should play as it is.
    bool process(const float *tapLeft, const float *tapRight, size_t frames, size_t stride, bool quiet, bool paused) {
        SharedFrames *b = backlog.load(std::memory_order_acquire);
        if (!b || frames > maxFrames) {
            engagedOut.store(false, std::memory_order_relaxed);
            return false;
        }
        bool want = wanted.load(std::memory_order_relaxed);

        // The backlog is written while it isn't read too, so the reader starts with the moment before it. The silence
        // of a pause, and of the moment before the song plays again, isn't the song's.
        if (wasPaused && !paused) {
            awaitingSound = true;
            awaitingFrames = 0;
        }
        wasPaused = paused;
        if (!quiet || awaitingFrames > size_t(rate)) awaitingSound = false;
        if (awaitingSound) awaitingFrames += frames;
        const float *planes[2] = {tapLeft, tapRight};
        if (!(quiet && (paused || awaitingSound))) b->write(planes, frames, stride);
        uint64_t written = b->written.load(std::memory_order_relaxed);
        if (!want && !on) {
            engagedOut.store(false, std::memory_order_relaxed);
            return false;
        }

        if (want && !on) {
            // Starts just behind the newest audio, and crossfades in from the tap as it plays.
            on = true;
            at = written - frames - cushion;
            frac = 0;
            pending = false;
            stepLeft = 0;
            holdGain = paused ? 0 : 1;
            splicesTaken = splicesAsked.load(std::memory_order_acquire);
            flushesTaken = flushesAsked.load(std::memory_order_relaxed);
        }
        uint32_t flushes = flushesAsked.load(std::memory_order_relaxed);
        if (flushes != flushesTaken) {
            flushesTaken = flushes;
            pending = false;
            uint64_t newest = written - frames - cushion;
            if (newest > at) {
                jump = newest - at;
                stepTotal = stepLeft = size_t(rate * 0.01);
                stepIsFlush = true;
            }
            flushesDone.fetch_add(1, std::memory_order_relaxed);
        }
        uint32_t splices = splicesAsked.load(std::memory_order_acquire);
        if (splices != splicesTaken) {
            splicesTaken = splices;
            pending = true;
            pendingFrom = spliceFrom.load(std::memory_order_relaxed);
            pendingTo = spliceTo.load(std::memory_order_relaxed);
            pendingBefore = spliceBefore.load(std::memory_order_relaxed);
        }

        double step = std::clamp(speed.load(std::memory_order_relaxed), 0.25, 2.0);
        const float holdStep = float(1.0 / (rate * 0.01)), mixStep = float(1.0 / (rate * 0.005));
        float target = want ? 1.0f : 0.0f;
        for (size_t f = 0; f < frames; f++) {
            float tl = tapLeft[f * stride], tr = tapRight[f * stride];
            float l = 0, r = 0;
            holdGain += std::clamp((paused ? 0.0f : 1.0f) - holdGain, -holdStep, holdStep);
            bool held = paused && holdGain <= 0;
            if (!held) {
                if (pending && stepLeft == 0 && at >= pendingFrom) {
                    pending = false;
                    if (at < pendingBefore && pendingTo > pendingFrom) {
                        jump = pendingTo - pendingFrom;
                        stepTotal = stepLeft = size_t(rate * 0.005);
                        stepIsFlush = false;
                    } else {
                        splicesMissed.fetch_add(1, std::memory_order_relaxed);
                    }
                }
                // Never past the newest audio, which would read frames that aren't written yet.
                if (at + half + 1 < written) sample(*b, at, frac, l, r);
                if (stepLeft > 0) {
                    float nl = 0, nr = 0;
                    if (at + jump + half + 1 < written) sample(*b, at + jump, frac, nl, nr);
                    float x = 1 - float(stepLeft) / float(stepTotal);
                    float out = stepIsFlush ? std::cos(x * float(M_PI / 2)) : 1 - x;
                    float in = stepIsFlush ? std::sin(x * float(M_PI / 2)) : x;
                    l = l * out + nl * in;
                    r = r * out + nr * in;
                    if (--stepLeft == 0) {
                        at += jump;
                        // Counted once the reader is past it, so the app never reads where it was before the step.
                        if (!stepIsFlush) splicesDone.fetch_add(1, std::memory_order_relaxed);
                    }
                }
                l *= holdGain;
                r *= holdGain;
                // The reader moves on, slower or faster than the song, but stays within the audio written.
                double next = frac + step;
                uint64_t whole = uint64_t(next);
                if (at + whole + half + 1 < written) {
                    at += whole;
                    frac = next - double(whole);
                    clock += step;
                }
            }
            mix += std::clamp(target - mix, -mixStep, mixStep);
            left[f] = tl * (1 - mix) + l * mix;
            right[f] = tr * (1 - mix) + r * mix;
        }
        if (!want && mix <= 0) on = false;
        engagedOut.store(on, std::memory_order_relaxed);
        readingOut.store(at, std::memory_order_relaxed);
        clockOut.store(clock, std::memory_order_relaxed);
        return true;
    }
};

} // namespace

struct PSShifter {
    bool planar;
    std::atomic<float> semitones{0};

    // A key change crossfades between two voices. The playing voice keeps its pitch for its whole life, and the
    // other one starts over at the new pitch: it hears the same input until it has enough history behind the
    // moment the playing voice is at, joins at that moment, and takes over during the fade. Only then is it the
    // playing voice, so two stretchers run only while a change is under way.
    Voice voices[2];
    int active = 0;
    enum class Phase { steady, warming, fading } phase = Phase::steady;
    uint64_t fed = 0, warmed = 0;
    size_t faded = 0, fadeFrames, maxWarmFrames;
    std::atomic<float> playingSemitones{0};

    // Tap input waits here until the output side reads it. Both sides run in the same IOProc, so the FIFOs are
    // plain; only the counters are read from another thread.
    Fifo input;
    std::atomic<uint64_t> heard{0};
    size_t primeFrames, maxLatencyFrames, targetLatencyFrames;
    bool inputPriming = true;

    // The stretcher hands back audio a hop at a time, not a callback at a time, so each voice collects it and
    // plays once there is a cushion that covers the largest hop.
    size_t cushionFrames;
    std::atomic<uint64_t> underruns{0};

    Limiter limiter;

    // Slows the tap's audio down before anything else hears it, while the app asks for it.
    Slower slower;

    // Stems: while they are on, the tap's audio also goes to `captured` for the separation thread, which writes each
    // stem back to `stems` a few seconds later. Until the first block is separated, the song keeps playing as it
    // is; then the output crossfades into the stems that are on, mixed, from the moment the stems were turned on.
    // Each start of the stems is a new generation: the IOProc picks the captured frame that the stems start at, and
    // the separation thread writes the stems of that generation from there.
    static constexpr int stemCount = PS_STEMS;
    std::atomic<bool> stemsOn{false};
    bool stemsWasOn = false, stemsPlaying = false, stemsPriming = false;
    // The first block is there, and the stems play (or fade in or out). Read by the main thread for the delay.
    std::atomic<bool> stemsStarted{false};
    // The captured frame at which the first block was there: the output waits `stemsLead` more before switching.
    uint64_t stemsFirstReady = 0;
    SharedFrames captured, stems;
    std::atomic<uint64_t> stemsGeneration{0}, stemsStart{0}, stemsWriting{0};
    // The stems are separated a block of a few seconds at a time. The output switches to them this long after the
    // first block is there, which gives every later block that much time to spare, and after a gap it waits for
    // that much again.
    size_t stemsCushion, stemsLead;
    // What the output keeps in hand when the delay ends and it moves forward: a window of separation and then some.
    size_t stemsMargin;
    double rate;
    std::atomic<float> stemGain[stemCount];
    float stemGainNow[stemCount];
    // The volume of each stem that a scroll over it sets, apart from the gain that mutes it.
    std::atomic<float> stemVolume[stemCount];
    float stemVolumeNow[stemCount];
    // How long the next mute or unmute of a stem takes: 20 ms for the keys and the clicks, which play in time with
    // the song, and longer for the vocals that karaoke mutes, which fade.
    std::atomic<float> stemFadeSeconds{0.02f};
    std::atomic<float> stemLevel[stemCount];
    std::atomic<uint64_t> stemsPlayed{0};
    // How much of the output is the stems rather than the song as it plays: 0 to 1, glided over 300 ms. The two
    // sides are seconds apart in the song, so the crossfade keeps their power rather than their sum, and it lasts
    // long enough for the step back to sound like a crossfade instead of a cut.
    std::atomic<float> stemsMix{0};
    // The player paused the song. The stems play seconds behind it, so without this they would go on for those
    // seconds after a pause, and after the song plays again the silence of the pause would play for as long. Once
    // the tap goes silent as well, the IOProc holds the stems where they are and stops capturing, and both carry on
    // from there when the song plays again: the pause and the resume are heard at once.
    std::atomic<bool> paused{false};
    // A song changed or moved during a pause: the stems start over, as when they are turned on.
    std::atomic<bool> restartStems{false};
    bool holding = false, wasPaused = false;
    // After the player plays again, the hold lasts until its first sound, for up to a second, so the stems carry on
    // with that sound rather than with the silence before it.
    bool awaitingSound = false;
    size_t awaitingFrames = 0;
    // Silent frames captured in a row. The pause is often reported after the song went silent, and that silence,
    // up to a second of it, is jumped over by the stems, which also go back by as much: the pause then costs
    // neither a dropout after the resume nor any of the stems' delay, and the moment before it is heard again.
    uint64_t silentRun = 0, skipFrom = 0, skipTo = 0, rewindPending = 0;
    // The stems fade out over 10 ms when they are held and back in when they carry on, so neither clicks. A jump of
    // the play position fades out and back in the same way.
    float holdGain = 1;
    // The pause also fades out what the shifter still holds of the song, its latency of about 100 ms, and whatever the
    // player still sends after Space paused it: some players stop half a second later, and the stems play seconds
    // behind until the tap goes silent and holds them. The output stays faded out until the tap has been silent for
    // 250 ms, so the sound of a pause never comes back, while a song that plays again before its report arrives is
    // still heard. It ends as soon as the song plays again.
    float pauseGain = 1;
    bool pauseMuted = false;
    bool pauseCutWas = false;
    // The tap hears every app, so another sound during the pause can keep it from going silent: the fade ends after
    // 1.5 seconds at most, and that sound is heard.
    size_t pauseMutedFrames = 0;
    // Frames in a row of digital silence from the tap.
    size_t quietFrames = 0;
    bool jumpPending = false;
    uint64_t jumpTarget = 0;
    // A backspin whenever the output steps back in the song: when the stems take over seconds behind it, and when
    // the lyrics delay goes back 30 seconds. What was heard plays backwards, pulled back fast and slowing to a stop,
    // like a record pulled back by hand, and the timeline that starts earlier in the song comes in after it.
    size_t spinLeft = 0, spinTotal = 0;
    double spinAt = 0;
    float spinLowLeft = 0, spinLowRight = 0;
    std::atomic<uint32_t> spins{0};
    // How the output steps back in the song: a backspin, or a fade out of what plays and a fade in of the earlier
    // moment. A jump of the play position fades out and back in over 10 ms, or over the fade of a step back.
    std::atomic<bool> fadeSteps{false};
    size_t fadeLeft = 0, fadeTotal = 0;
    bool slowHold = false;
    // Karaoke that starts the song over: the output dips while the player moves the song to its start. 1 while the
    // move is awaited, when the song fades out and the stems may not start, for 15 seconds at most. 2 once the
    // timeline starts over at the song's start: a quarter second more of silence, for the last of the old moment to
    // pass, then the song fades in from its start as it plays, until the stems of the start step back to it.
    std::atomic<int> seekDip{0};
    float leadGain = 1;
    size_t leadFrames = 0;
    // Frames before the moment that plays that the next restart starts from: the song started over a moment before
    // the player reported it.
    std::atomic<uint64_t> restartBack{0};
    // A restart while the stems play waits for them to fade out over 10 ms, for a few callbacks at most.
    bool restartFading = false;
    int restartWaits = 0;
    std::vector<float> stemLeft, stemRight, rawLeft, rawRight;

    // Stems from a cache of the whole song: the writer has the stems of every moment, so it writes them ahead of the
    // song, lined up with the captured frames, and the output plays them at the moment that plays rather than seconds
    // behind it. The generation that the writer feeds that way, and the IOProc's view of it once per callback.
    std::atomic<uint64_t> cachedGeneration{0};
    bool cachedNow = false;
    // The captured frame of the first frame that pullLive handed out in this chunk: the song as it plays.
    uint64_t liveFrame = 0;
    // The output plays the cached stems at the moment that plays, within a couple of chunks. Their crossfades with the
    // song are then linear, since both are the same moment and add up, and turning the stems off reads on through the
    // stems written ahead while the song comes back.
    bool aligned = false;
    // How far ahead the cached stems have to be written before they take over.
    size_t cachedLead;
    // The delay ended while cached stems play: the jump goes to the moment that plays.
    bool jumpToLive = false;
    // The app moved the song: the output stays silent from the move until the writer has the stems of the new place,
    // from frame `seekFrom` on, and for 3 seconds at most.
    std::atomic<uint32_t> seeksAsked{0}, seeksAnswered{0};
    std::atomic<uint64_t> seekFrom{0};
    uint32_t seeksHeard = 0, seeksSeen = 0;
    size_t seekWaitFrames = 0;
    // A pause held the captured song: from skipTo on, the song carries on from skipFrom, so the cached stems written
    // ahead are of the wrong moment there. The writer writes them again, and until it has, the output reads none of them.
    std::atomic<uint32_t> skipsMade{0}, skipsMapped{0};
    std::atomic<uint64_t> skipMadeFrom{0}, skipMadeTo{0};
    // The tap has been digitally silent for 25 ms while aligned cached stems play: the player stopped, and the stems
    // written ahead of it fade out rather than play the song on until the pause is reported.
    bool tapGone = false;

    // The song can also play a fixed time behind itself, while lyrics are written by ear, so each line is written
    // before it is heard. The stems and the delay share one timeline of captured frames and one play position: the
    // output plays the stems where they are separated, and the captured song otherwise. Raising the delay leaves the
    // output as it is until that much more is captured, and then the output steps back to the moment the delay was
    // raised, where the lyrics start.
    std::atomic<uint64_t> delayFrames{0};
    std::atomic<bool> anchorPending{false};
    std::atomic<uint64_t> anchor{0};
    bool engagedWas = false, delayWas = false;
    // The output plays the delayed timeline because the delay stepped back, rather than at the stems' own lag.
    bool delayed = false;
    // Where the current timeline starts in the captured frames.
    uint64_t timelineStart = 0;
    // The stems are there at the play position and play in place of the captured song. A gap after that is silence.
    bool stemsLive = false;
    // The captured song (0) and the stems (1), crossfaded over 20 ms when the stems take over or stop.
    float sourceMix = 0;

    std::vector<float> inLeft, inRight, outLeft, outRight, nextLeft, nextRight;

    std::vector<float> recording; // (input, output) pairs
    std::atomic<size_t> recorded{0};

    PSShifter(double rate, bool planar, double recordSeconds)
        : planar(planar), voices{Voice(rate), Voice(rate)}, fadeFrames(size_t(rate * 0.2)),
          maxWarmFrames(size_t(rate * 0.5)), input(size_t(rate) * 2),
          // The tap writes and the output reads in the same IOProc, so the input cushion only has to cover the few
          // frames that drift compensation adds or drops per callback. The output cushion covers Rubber Band's hops,
          // with room to spare at every buffer size that the self-test plays.
          primeFrames(size_t(rate * 0.003)), maxLatencyFrames(size_t(rate * 0.25)),
          targetLatencyFrames(size_t(rate * 0.03)), cushionFrames(size_t(rate * 0.01)), limiter(rate), slower(rate),
          inLeft(maxChunk), inRight(maxChunk), outLeft(maxChunk), outRight(maxChunk), nextLeft(maxChunk),
          nextRight(maxChunk), recording(size_t(std::max(0.0, recordSeconds) * rate) * 2),
          // The stems hold the 30 seconds of the lyrics delay, and cached stems a second written ahead of the song on top.
          captured(2, size_t(rate * 60)), stems(2 * stemCount, size_t(rate * 32)), stemsCushion(size_t(rate * 0.25)), stemsLead(size_t(rate * 0.75)), stemsMargin(size_t(rate * 6)), rate(rate),
          stemLeft(maxChunk), stemRight(maxChunk), rawLeft(maxChunk), rawRight(maxChunk), cachedLead(size_t(rate * 0.25)) {
        for (int i = 0; i < stemCount; i++) {
            stemGain[i].store(1.0f);
            stemGainNow[i] = 1.0f;
            stemVolume[i].store(1.0f);
            stemVolumeNow[i] = 1.0f;
            stemLevel[i].store(0.0f);
        }
    }

    // Whether the writer feeds the current generation from a cache, once per callback.
    void updateCached() {
        uint64_t generation = stemsGeneration.load(std::memory_order_relaxed);
        cachedNow = generation != 0 && cachedGeneration.load(std::memory_order_acquire) == generation
            && stemsWriting.load(std::memory_order_acquire) == generation;
    }

    // Starts the separation of a new generation of stems at captured frame `from`.
    void beginStems(uint64_t from) {
        stemsLive = false;
        stemsPriming = false;
        stemsFirstReady = 0;
        stemsStart.store(from, std::memory_order_relaxed);
        stemsGeneration.fetch_add(1, std::memory_order_release);
    }

    // Follows the stems and the delay being turned on and off, once per callback, before the input is captured.
    void updateTimeline(bool stemsWanted, uint64_t delay, bool restart) {
        bool engaged = stemsWanted || delay > 0;
        uint64_t now = captured.written.load(std::memory_order_relaxed);
        uint64_t back = restart ? restartBack.exchange(0, std::memory_order_relaxed) : 0;
        if (engaged && (!engagedWas || restart)) {
            // A new timeline, even while the last one still fades out: the song plays as it is until the stems or the
            // delay are ready, and they start from this moment, or from a moment before it within this timeline.
            uint64_t start = engagedWas ? now - std::min(back, now - std::min(now, timelineStart)) : now;
            skipFrom = skipTo = rewindPending = 0;
            jumpPending = jumpToLive = false;
            tapGone = false;
            spinLeft = fadeLeft = 0;
            slowHold = false;
            stemsPlaying = true;
            stemsStarted.store(false, std::memory_order_relaxed);
            delayed = false;
            sourceMix = 0;
            timelineStart = start;
            stemsPlayed.store(start, std::memory_order_relaxed);
            anchor.store(start, std::memory_order_relaxed);
            anchorPending.store(delay > 0, std::memory_order_relaxed);
            if (restart && seekDip.load(std::memory_order_relaxed) == 1) {
                // The song started over. Stems that played faded out before the restart, and the song mustn't come in
                // under them as they cross back; a song that plays as it is finishes its fade out.
                seekDip.store(2, std::memory_order_relaxed);
                leadFrames = 0;
                if (stemsMix.load(std::memory_order_relaxed) > 0) leadGain = 0;
            }
            if (stemsWanted) beginStems(start);
            else stemsLive = false;
        } else if (engaged) {
            bool started = stemsStarted.load(std::memory_order_relaxed);
            if (delay > 0 && !delayWas) {
                anchor.store(now, std::memory_order_relaxed);
                anchorPending.store(true, std::memory_order_relaxed);
            }
            if (delay == 0 && delayWas) {
                anchorPending.store(false, std::memory_order_relaxed);
                if (cachedNow && stemsWanted && stemsLive && started) {
                    // Cached stems are there for the moment that plays, which is where they play without the delay.
                    delayed = false;
                    jumpPending = jumpToLive = true;
                } else if (delayed || !started) {
                    delayed = false;
                    uint64_t ready = stems.written.load(std::memory_order_acquire);
                    uint64_t keep = stemsLead + stemsMargin;
                    if (stemsWanted && stemsLive && ready > stemsPlayed.load(std::memory_order_relaxed) + keep) {
                        // Forward to about the stems' own lag, which is all the delay they need, with a whole window
                        // in hand, since the next one is written seconds later.
                        jumpPending = true;
                        jumpTarget = ready - keep;
                    } else if (stemsWanted && stemsLive) {
                        // Already that close behind: the stems play on from where they are.
                    } else if (stemsWanted) {
                        // Back to the song as it plays, until the stems of this moment are separated.
                        stemsStarted.store(false, std::memory_order_relaxed);
                        stemsPlayed.store(now, std::memory_order_relaxed);
                        beginStems(now);
                    }
                }
            }
            if (stemsWanted && !stemsWasOn) {
                // Separated from where the output is going to play them: the moment the delay steps back to, or the
                // moment that plays now.
                bool pending = anchorPending.load(std::memory_order_relaxed);
                uint64_t from = pending ? anchor.load(std::memory_order_relaxed) : started ? stemsPlayed.load(std::memory_order_relaxed) : now;
                if (!started && !pending) stemsPlayed.store(from, std::memory_order_relaxed);
                beginStems(from);
            }
            // The captured song takes over at the same moment, and every stem plays again with no jump.
            if (!stemsWanted && stemsWasOn) stemsLive = false;
        }
        engagedWas = engaged;
        stemsWasOn = stemsWanted;
        delayWas = delay > 0;
    }

    // Fills `n` frames of stemLeft/stemRight with what the delayed timeline plays: the stems that are on, mixed, or
    // the captured song where the stems aren't separated yet. Returns false while there is nothing to play yet:
    // before the first block or the delay, and after a gap in the stems until the margin is back.
    bool readStems(size_t n) {
        bool stemsWanted = stemsOn.load(std::memory_order_relaxed);
        bool current = stemsWriting.load(std::memory_order_acquire) == stemsGeneration.load(std::memory_order_relaxed);
        uint64_t ready = stems.written.load(std::memory_order_acquire);
        uint64_t now = captured.written.load(std::memory_order_relaxed);
        uint64_t delay = delayFrames.load(std::memory_order_relaxed);
        bool started = stemsStarted.load(std::memory_order_relaxed);
        std::fill(stemLeft.begin(), stemLeft.begin() + n, 0.0f);
        std::fill(stemRight.begin(), stemRight.begin() + n, 0.0f);
        auto quiet = [&] {
            for (int i = 0; i < stemCount; i++) stemLevel[i].store(stemLevel[i].load(std::memory_order_relaxed) * 0.8f, std::memory_order_relaxed);
            return false;
        };
        if (anchorPending.load(std::memory_order_relaxed) && now >= anchor.load(std::memory_order_relaxed) + delay) {
            // The delay steps back to the moment it was raised: from the song as it plays with a crossfade, or from
            // the stems with a fade out and in.
            anchorPending.store(false, std::memory_order_relaxed);
            delayed = true;
            uint64_t back = anchor.load(std::memory_order_relaxed);
            if (started) {
                jumpPending = true;
                jumpTarget = back;
                if (fadeSteps.load(std::memory_order_relaxed)) {
                    // The stems fade out, jump and fade back in, each over the fade of a step back.
                    slowHold = true;
                    spins.fetch_add(1, std::memory_order_relaxed);
                } else {
                    startSpin(stemsPlayed.load(std::memory_order_relaxed));
                }
            } else {
                stemsPlayed.store(back, std::memory_order_relaxed);
                stemsStarted.store(true, std::memory_order_relaxed);
                started = true;
                stepBack(now);
            }
        }
        if (!started) {
            if (anchorPending.load(std::memory_order_relaxed) || !stemsWanted) return quiet();
            // Karaoke that starts the song over waits for the player to move the song to its start.
            if (seekDip.load(std::memory_order_relaxed) == 1) return quiet();
            if (cachedNow) {
                // Cached stems take over once they are written a little past the moment that plays, and after a move of
                // the song once they are of the new place: at that moment, with no step back.
                uint32_t asked = seeksAsked.load(std::memory_order_acquire);
                bool answered = seeksHeard == asked || seeksAnswered.load(std::memory_order_acquire) == asked;
                if (!current || !answered || liveFrame < stemsStart.load(std::memory_order_relaxed) || ready < liveFrame + n + cachedLead)
                    return quiet();
                stemsStarted.store(true, std::memory_order_relaxed);
                stemsLive = true;
                stemsPriming = false;
                sourceMix = 1;
                settleStemGains();
                stemsPlayed.store(liveFrame, std::memory_order_relaxed);
                // After a silent wait for a move, the stems fade in from silence rather than cross the song that waited.
                if (leadGain < 1) {
                    stemsMix.store(1, std::memory_order_relaxed);
                    holdGain = 0;
                }
            } else {
                // The song plays as it is until the first block is there and the margin after it has passed.
                if (!current || ready <= stemsStart.load(std::memory_order_relaxed)) return quiet();
                if (stemsFirstReady == 0) stemsFirstReady = now;
                if (now < stemsFirstReady + stemsLead) return quiet();
                stemsStarted.store(true, std::memory_order_relaxed);
                stemsLive = true;
                settleStemGains();
                // The stems start seconds before the moment that plays.
                stepBack(now);
            }
        }
        uint64_t at = stemsPlayed.load(std::memory_order_relaxed);
        if (skipTo > skipFrom && at >= skipFrom && at < skipTo) at = skipTo;
        // Cached stems past a pause are of the wrong moment until the writer has written them again.
        if (cachedNow && skipsMapped.load(std::memory_order_acquire) != skipsMade.load(std::memory_order_relaxed)
            && at + n > skipMadeTo.load(std::memory_order_relaxed))
            return holdQuiet(n);
        uint64_t from = stemsStart.load(std::memory_order_relaxed);
        // Read on for the crossfade after the stems are turned off, while they are still in their buffer.
        uint64_t available = current && ready > at && at >= from ? ready - at : 0;
        if (stemsWanted && !stemsLive && available >= stemsLead + n) {
            stemsLive = true;
            stemsPriming = false;
            settleStemGains();
        }
        bool readsStems = stemsLive || sourceMix > 0;
        bool readsRaw = !stemsLive || sourceMix < 1;
        if (stemsLive) {
            if (stemsPriming && available >= stemsLead + n) stemsPriming = false;
            if (stemsPriming || available < n) {
                // A gap in the stems after they started playing counts with the gaps of the output.
                if (!stemsPriming) underruns.fetch_add(1, std::memory_order_relaxed);
                stemsPriming = true;
                return quiet();
            }
            // The separation thread may have lapped the reader after a stall: skip to what is still there.
            if (available > stems.capacity - n) at = ready - stemsCushion;
        }
        if (readsStems && (stemsLive || available >= n)) {
            // A stem muted or played again glides along an S curve, over 20 ms for a key or a click, so it doesn't
            // click, and over the longer fade that karaoke asks for when it mutes the vocals.
            const float step = float(1.0 / (std::max(0.005f, stemFadeSeconds.load(std::memory_order_relaxed)) * rate));
            // A volume follows the scroll that sets it closely, without the steps of each event.
            const float glide = float(1.0 - std::exp(-1.0 / (0.015 * rate)));
            for (int i = 0; i < stemCount; i++) {
                const float *left = stems.planes[i * 2].data(), *right = stems.planes[i * 2 + 1].data();
                float target = stemGain[i].load(std::memory_order_relaxed), gain = stemGainNow[i], energy = 0;
                float volumeTarget = stemVolume[i].load(std::memory_order_relaxed), volume = stemVolumeNow[i];
                for (size_t f = 0; f < n; f++) {
                    size_t index = size_t((at + f) % stems.capacity);
                    float l = left[index], r = right[index];
                    energy += l * l + r * r;
                    gain += std::clamp(target - gain, -step, step);
                    volume += (volumeTarget - volume) * glide;
                    float curve = gain * gain * (3 - 2 * gain) * volume;
                    stemLeft[f] += l * curve;
                    stemRight[f] += r * curve;
                }
                stemGainNow[i] = gain;
                stemVolumeNow[i] = volume;
                // The level of each stem as it plays, on or off, for the meters in the HUD.
                float rms = std::sqrt(energy / float(2 * n));
                float last = stemLevel[i].load(std::memory_order_relaxed);
                stemLevel[i].store(rms > last ? rms : last * 0.9f + rms * 0.1f, std::memory_order_relaxed);
            }
        } else {
            quiet();
        }
        if (readsRaw) {
            // The captured song at the same moment, while it is still in the buffer.
            bool kept = now >= at + n && now - at <= captured.capacity;
            const float *left = captured.planes[0].data(), *right = captured.planes[1].data();
            for (size_t f = 0; f < n; f++) {
                size_t index = size_t((at + f) % captured.capacity);
                rawLeft[f] = kept ? left[index] : 0.0f;
                rawRight[f] = kept ? right[index] : 0.0f;
            }
            const float step = 1.0f / (0.02f * float(rate));
            float target = stemsLive ? 1.0f : 0.0f;
            for (size_t f = 0; f < n; f++) {
                sourceMix += std::clamp(target - sourceMix, -step, step);
                stemLeft[f] = rawLeft[f] * (1 - sourceMix) + stemLeft[f] * sourceMix;
                stemRight[f] = rawRight[f] * (1 - sourceMix) + stemRight[f] * sourceMix;
            }
        } else {
            sourceMix = 1;
        }
        stemsPlayed.store(at + n, std::memory_order_relaxed);
        return true;
    }

    // A stem muted before its stems play is muted from their first frame, with no fade that nobody would hear.
    void settleStemGains() {
        for (int i = 0; i < stemCount; i++) {
            stemGainNow[i] = stemGain[i].load(std::memory_order_relaxed);
            stemVolumeNow[i] = stemVolume[i].load(std::memory_order_relaxed);
        }
    }

    // Steps back from the song as it plays to the timeline that starts earlier in the song, with a backspin or a fade.
    void stepBack(uint64_t heardAt) {
        if (!fadeSteps.load(std::memory_order_relaxed)) return startSpin(heardAt);
        fadeTotal = fadeLeft = size_t(rate * 0.8);
        spins.fetch_add(1, std::memory_order_relaxed);
    }

    // Fades out the song as it plays over 0.4 seconds, then fades in the timeline over 0.4 seconds. The timeline moves
    // on meanwhile, as under a backspin, so the delay stays what it was set to.
    void renderFade(size_t n, bool playing) {
        double total = double(fadeTotal);
        for (size_t f = 0; f < n; f++) {
            if (fadeLeft == 0) {
                inLeft[f] = playing ? stemLeft[f] : 0.0f;
                inRight[f] = playing ? stemRight[f] : 0.0f;
                continue;
            }
            double x = 1 - double(fadeLeft) / total;
            float out = x < 0.5 ? float(std::cos(M_PI / 2 * x / 0.5)) * leadGain : 0.0f;
            float in = x >= 0.5 && playing ? float(std::sin(M_PI / 2 * (x - 0.5) / 0.5)) : 0.0f;
            inLeft[f] = inLeft[f] * out + stemLeft[f] * in;
            inRight[f] = inRight[f] * out + stemRight[f] * in;
            if (--fadeLeft == 0) {
                holdGain = playing ? 1 : 0;
                stemsMix.store(1, std::memory_order_relaxed);
            }
        }
    }

    void startSpin(uint64_t heardAt) {
        spinTotal = spinLeft = size_t(rate * 0.9);
        // The frame before the one that was heard last, which is written already.
        spinAt = double(heardAt) - 2;
        spinLowLeft = spinLowRight = 0;
        // The stems or the earlier moment fade in after the spin, and a pending jump happens at once under it.
        holdGain = 0;
        spins.fetch_add(1, std::memory_order_relaxed);
    }

    // Plays the backspin into the input of the shifter, in place of the song and the stems. The timeline, which
    // `playing` says is there, comes in under the last quarter of the spin as the spin fades out: the spin slows to a
    // standstill that is nearly silent, and a timeline that came in only after it was heard as a gap and then a hard
    // restart of the song.
    void renderSpin(size_t n, bool playing) {
        const float *left = captured.planes[0].data(), *right = captured.planes[1].data();
        uint64_t capacity = captured.capacity, written = captured.written.load(std::memory_order_relaxed);
        // The captured song is overwritten from its oldest frames, so the spin stays a second clear of them.
        double oldest = written > capacity ? double(written - capacity) + rate : 0;
        double total = double(spinTotal);
        constexpr double top = 6;
        for (size_t f = 0; f < n; f++) {
            if (spinLeft == 0) {
                // The rest of the block after the spin carries on with the timeline.
                inLeft[f] = playing ? stemLeft[f] : 0.0f;
                inRight[f] = playing ? stemRight[f] : 0.0f;
                continue;
            }
            double x = 1 - double(spinLeft) / total;
            // Up to six times the speed within the first tenth, then slowing to a stop.
            double speed = x < 0.1 ? top * std::sin(M_PI / 2 * x / 0.1) : top * std::pow(1 - (x - 0.1) / 0.9, 1.7);
            spinAt = std::max(oldest, spinAt - speed);
            uint64_t i = uint64_t(spinAt);
            float frac = float(spinAt - double(i));
            float l = left[i % capacity] * (1 - frac) + left[(i + 1) % capacity] * frac;
            float r = right[i % capacity] * (1 - frac) + right[(i + 1) % capacity] * frac;
            // The faster it goes, the higher the song sounds; a low-pass that follows the speed keeps the top of it
            // from turning into hiss.
            float cut = float(std::min(1.0, 2 * M_PI * 6000 / std::max(1.0, speed) / rate));
            spinLowLeft += cut * (l - spinLowLeft);
            spinLowRight += cut * (r - spinLowRight);
            // An equal-power crossfade over the last 225 ms, so the level holds while the spin hands over.
            double t = x > 0.75 ? (x - 0.75) / 0.25 : 0;
            float gain = float(std::min(1.0, x / 0.02) * std::cos(M_PI / 2 * t));
            float timeline = playing ? float(std::sin(M_PI / 2 * t)) : 0.0f;
            inLeft[f] = spinLowLeft * gain + stemLeft[f] * timeline;
            inRight[f] = spinLowRight * gain + stemRight[f] * timeline;
            if (--spinLeft == 0) {
                // The stems or the earlier moment are at full level already, unless they are held.
                holdGain = playing ? 1 : 0;
                stemsMix.store(1, std::memory_order_relaxed);
            }
        }
    }

    // While the stems are on, the output goes from the song as it plays to the stems, once they are there, and
    // crossfades back when they are turned off. Going in steps back to the moment the stems were turned on, with a
    // backspin, and coming out skips ahead.
    void mixStems(size_t n) {
        bool on = stemsOn.load(std::memory_order_relaxed) || delayFrames.load(std::memory_order_relaxed) > 0;
        // Turning the stems and the delay off ends a backspin or a fade, which then has nothing to step back to.
        if (!on) spinLeft = fadeLeft = 0;
        // Held and faded out: the stems stay where they are, and the meters fall.
        bool held = holding && holdGain <= 0;
        if (held && rewindPending) {
            // No further back than the stems or the captured song of this timeline go.
            uint64_t at = stemsPlayed.load(std::memory_order_relaxed);
            uint64_t start = stemsLive ? stemsStart.load(std::memory_order_relaxed) : timelineStart;
            stemsPlayed.store(at - std::min(rewindPending, at > start ? at - start : 0), std::memory_order_relaxed);
            rewindPending = 0;
        }
        // A jump waits until the output has faded out.
        if (jumpPending && holdGain <= 0) {
            stemsPlayed.store(jumpToLive ? liveFrame : jumpTarget, std::memory_order_relaxed);
            skipFrom = skipTo = 0;
            jumpPending = jumpToLive = false;
        }
        // A move of the song while cached stems play: silent until the stems of the new place play, or for 3 seconds
        // of the song playing, since a move made during a pause is found once the song plays again.
        uint32_t asked = seeksAsked.load(std::memory_order_acquire);
        if (asked != seeksSeen) {
            seeksSeen = asked;
            seekWaitFrames = 0;
        }
        bool waiting = seeksHeard != asked;
        if (waiting) {
            bool answered = seeksAnswered.load(std::memory_order_acquire) == asked;
            if (!holding) seekWaitFrames += n;
            if ((answered && stemsPlayed.load(std::memory_order_relaxed) >= seekFrom.load(std::memory_order_relaxed))
                || seekWaitFrames > size_t(rate * 3)) {
                seeksHeard = asked;
                waiting = false;
            }
        }
        bool playing = held ? holdQuiet(n) : readStems(n);
        bool started = stemsStarted.load(std::memory_order_relaxed);
        // Cached stems that play at the moment that plays, give or take two chunks. Nothing is captured once the stems
        // are off, so they count as where they were until the song is back.
        uint64_t played = stemsPlayed.load(std::memory_order_relaxed);
        if (on) aligned = cachedNow && stemsLive && started && played + 2 * maxChunk >= liveFrame + n && played <= liveFrame + n + 2 * maxChunk;
        else if (!started) aligned = false;
        tapGone = on && aligned && quietFrames >= size_t(rate * 0.025);
        // The timeline moves on under the backspin, so the delay stays what it was set to.
        if (spinLeft > 0) return renderSpin(n, playing);
        if (fadeLeft > 0) return renderFade(n, playing);
        if (playing) {
            const float holdStep = 1.0f / ((slowHold ? 0.4f : 0.01f) * float(rate));
            float target = holding || jumpPending || restartFading || waiting || tapGone ? 0.0f : 1.0f;
            for (size_t f = 0; f < n; f++) {
                holdGain += std::clamp(target - holdGain, -holdStep, holdStep);
                stemLeft[f] *= holdGain;
                stemRight[f] *= holdGain;
            }
            if (slowHold && !jumpPending && holdGain >= 1) slowHold = false;
        }
        float target = on && started ? 1.0f : 0.0f;
        // The dip while karaoke moves the song to its start: until the move, for 15 seconds at most, and a quarter
        // second after it. A pause holds the stems, and the player is silent then anyway, so it doesn't count.
        int dip = seekDip.load(std::memory_order_relaxed);
        bool quiet = on && !started && dip != 0;
        if (!quiet) {
            if (dip == 0) leadFrames = 0;
        } else if (!holding && (leadFrames += n) > size_t(rate * (dip == 2 ? 0.25 : 15))) {
            int expected = dip;
            seekDip.compare_exchange_strong(expected, 0, std::memory_order_relaxed);
            quiet = false;
        }
        // The song waits in silence for the cached stems of the place it moved to.
        bool hushed = on && !started && waiting;
        float mix = stemsMix.load(std::memory_order_relaxed);
        // Cached stems at the moment that plays are the song itself, so they cross it linearly, over the fade of the
        // stem that changed: at once for a key, slowly for karaoke's vocals. The stems seconds behind are another moment,
        // which keeps its power over 300 ms.
        const float fade = std::max(0.03f, stemFadeSeconds.load(std::memory_order_relaxed));
        const float step = 1.0f / ((aligned ? fade : 0.3f) * float(rate));
        const float leadStep = 1.0f / ((hushed ? 0.01f : 0.2f) * float(rate));
        constexpr float quarter = float(M_PI / 2);
        for (size_t f = 0; f < n; f++) {
            mix += std::clamp(target - mix, -step, step);
            leadGain += std::clamp((quiet || hushed ? 0.0f : 1.0f) - leadGain, -leadStep, leadStep);
            float song = (mix <= 0 ? 1.0f : mix >= 1 ? 0.0f : aligned ? 1 - mix : std::cos(mix * quarter)) * leadGain;
            float timeline = mix <= 0 ? 0.0f : mix >= 1 ? 1.0f : aligned ? mix : std::sin(mix * quarter);
            // A gap in the stems plays silence rather than the song seconds ahead.
            float stemL = playing ? stemLeft[f] : 0.0f, stemR = playing ? stemRight[f] : 0.0f;
            inLeft[f] = inLeft[f] * song + stemL * timeline;
            inRight[f] = inRight[f] * song + stemR * timeline;
        }
        stemsMix.store(mix, std::memory_order_relaxed);
        // The song fades back in after the silence before the output stops mixing.
        if (!on && mix <= 0 && leadGain >= 1) {
            stemsPlaying = false;
            stemsStarted.store(false, std::memory_order_relaxed);
        }
    }

    bool holdQuiet(size_t n) {
        std::fill(stemLeft.begin(), stemLeft.begin() + n, 0.0f);
        std::fill(stemRight.begin(), stemRight.begin() + n, 0.0f);
        for (int i = 0; i < stemCount; i++) stemLevel[i].store(stemLevel[i].load(std::memory_order_relaxed) * 0.8f, std::memory_order_relaxed);
        return false;
    }

    // Captures the tap's audio while the stems or the delay are on, for the separation thread and the delayed song,
    // except while the song is paused.
    void capture(const float *const *planes, size_t frames, size_t stride, bool quiet, bool stemsOn) {
        bool nowPaused = paused.load(std::memory_order_relaxed);
        if (wasPaused && !nowPaused) {
            awaitingSound = true;
            awaitingFrames = 0;
        }
        wasPaused = nowPaused;
        if (!quiet || awaitingFrames > size_t(rate)) awaitingSound = false;
        if (awaitingSound) awaitingFrames += frames;
        bool hold = (nowPaused || awaitingSound) && quiet;
        if (hold && !holding && stemsOn) {
            uint64_t at = captured.written.load(std::memory_order_relaxed);
            uint64_t run = std::min<uint64_t>(silentRun, uint64_t(rate));
            skipFrom = at - run;
            skipTo = at;
            rewindPending = run;
            skipMadeFrom.store(skipFrom, std::memory_order_relaxed);
            skipMadeTo.store(skipTo, std::memory_order_relaxed);
            skipsMade.fetch_add(1, std::memory_order_release);
        }
        if (!hold && holding && cachedNow && aligned) {
            // Cached stems in line with the song carry on in line with it: the output read on into the stems of the
            // song to come while it faded out, and the song carries on from where it stopped.
            jumpPending = jumpToLive = true;
        }
        holding = hold;
        quietFrames = quiet ? quietFrames + frames : 0;
        if (!quiet) silentRun = 0;
        else if (!holding) silentRun += frames;
        if (stemsOn && !holding) captured.write(planes, frames, stride);
    }

    // Fades the output out over 10 ms when the song is paused, until the tap has been silent for 250 ms: longer than
    // the shifter's latency, and after the player really stopped.
    void cutPauseTail(size_t n) {
        bool nowPaused = paused.load(std::memory_order_relaxed);
        if (nowPaused && !pauseCutWas) {
            pauseMuted = true;
            pauseMutedFrames = 0;
        }
        if (pauseMuted) pauseMutedFrames += n;
        if (!nowPaused || quietFrames >= size_t(rate * 0.25) || pauseMutedFrames >= size_t(rate * 1.5)) pauseMuted = false;
        pauseCutWas = nowPaused;
        if (!pauseMuted && pauseGain >= 1) return;
        float step = float(1.0 / (rate * 0.01));
        float target = pauseMuted ? 0.0f : 1.0f;
        for (size_t f = 0; f < n; f++) {
            pauseGain += std::clamp(target - pauseGain, -step, step);
            outLeft[f] *= pauseGain;
            outRight[f] *= pauseGain;
        }
    }

    void write(const float *left, const float *right, size_t frames, size_t stride) {
        input.write(left, right, frames, stride);
        heard.fetch_add(frames, std::memory_order_relaxed);
    }

    // Fills `n` frames of inLeft/inRight from the input FIFO, padding with silence, and mixes in the stems while
    // they play. The stretchers are fed silence during an underrun too, so their delay stays constant.
    void pull(size_t n) {
        pullLive(n);
        if (stemsPlaying) mixStems(n);
        // A move asked for while nothing plays the stems has nothing to wait for.
        else seeksHeard = seeksAsked.load(std::memory_order_relaxed);
    }

    void pullLive(size_t n) {
        size_t fill = input.fill();
        if (fill > maxLatencyFrames) {
            input.read += fill - targetLatencyFrames;
            fill = targetLatencyFrames;
        }
        // The input holds the newest frames that were captured, so the first one handed out is this far back.
        liveFrame = captured.written.load(std::memory_order_relaxed) - fill;
        // After an underrun, wait for a small cushion so the output doesn't stutter frame by frame.
        if (inputPriming && fill >= primeFrames + n) inputPriming = false;
        size_t got = 0;
        if (!inputPriming) {
            got = std::min(n, fill);
            input.readInto(inLeft.data(), inRight.data(), got);
            if (got < n) inputPriming = true;
        }
        std::fill(inLeft.begin() + got, inLeft.begin() + n, 0.0f);
        std::fill(inRight.begin() + got, inRight.begin() + n, 0.0f);
    }

    // A new target starts the other voice. A target changed while that voice warms up starts it over, and one
    // changed during the fade waits for the fade to end.
    void retarget(float target) {
        Voice &now = voices[active], &next = voices[1 - active];
        if (phase == Phase::steady && target != now.semitones) {
            next.restart(target, fed);
            warmed = 0;
            phase = Phase::warming;
        } else if (phase == Phase::warming && target != next.semitones) {
            if (target == now.semitones) {
                phase = Phase::steady;
            } else {
                next.restart(target, fed);
                warmed = 0;
            }
        }
    }

    // The incoming voice joins at the moment the playing voice is at, once that moment lies a full analysis
    // window past its start. Rubber Band runs further behind the bigger the shift, so a voice with a bigger shift
    // may not have that moment ready with a cushion after it, and one with a smaller shift has more than it needs. The skip is kept to between one and two
    // cushions of frames left over, and the timing moves by the difference, during the fade.
    bool join(size_t n) {
        Voice &now = voices[active], &next = voices[1 - active];
        int64_t fill = int64_t(next.output.fill());
        int64_t need = int64_t(n + cushionFrames);
        int64_t skip = std::clamp(now.playing() - next.playing(), fill - need - int64_t(cushionFrames), fill - need);
        bool settled = next.playing() + skip >= int64_t(next.start + next.stretcher.getPreferredStartPad());
        if (skip < 0 || !settled) {
            // Never stuck warming: join as close to that moment as the frames allow.
            if (warmed < maxWarmFrames || fill < int64_t(n)) return false;
            skip = std::max<int64_t>(0, std::min(skip, fill - int64_t(n)));
        }
        next.output.read += uint64_t(skip);
        next.priming = false;
        faded = 0;
        phase = Phase::fading;
        return true;
    }

    // Runs `n` frames through the voices and leaves `n` frames to play in outLeft/outRight.
    void shift(size_t n) {
        const float *ins[2] = {inLeft.data(), inRight.data()};
        float *scratch[2] = {nextLeft.data(), nextRight.data()};
        Voice &now = voices[active], &next = voices[1 - active];

        now.feed(ins, n, scratch);
        if (phase != Phase::steady) next.feed(ins, n, scratch);
        fed += n;
        if (phase == Phase::warming) {
            warmed += n;
            join(n);
        }

        if (!now.play(outLeft.data(), outRight.data(), n, cushionFrames))
            underruns.fetch_add(1, std::memory_order_relaxed);
        if (phase != Phase::fading) return;

        // Equal power: the two keys share little, so their powers add.
        next.play(nextLeft.data(), nextRight.data(), n, 0);
        constexpr float quarter = float(M_PI / 2);
        for (size_t f = 0; f < n; f++) {
            float x = std::min(1.0f, float(faded + f) / float(fadeFrames));
            float in = std::sin(x * quarter), out = std::cos(x * quarter);
            outLeft[f] = outLeft[f] * out + nextLeft[f] * in;
            outRight[f] = outRight[f] * out + nextRight[f] * in;
        }
        faded += n;
        if (faded >= fadeFrames) {
            active = 1 - active;
            phase = Phase::steady;
        }
    }

    // Starts with the first sound heard, so the recording isn't all silence when nothing played yet.
    void record(size_t n) {
        if (heard.load(std::memory_order_relaxed) == 0) return;
        size_t done = recorded.load(std::memory_order_relaxed);
        size_t room = recording.size() / 2 - done;
        size_t count = std::min(n, room);
        for (size_t i = 0; i < count; i++) {
            recording[(done + i) * 2] = inLeft[i];
            recording[(done + i) * 2 + 1] = outLeft[i];
        }
        if (count) recorded.store(done + count, std::memory_order_release);
    }
};

PSShifter *ps_create(double sampleRate, int tapIsPlanar, double recordSeconds) {
    return new PSShifter(sampleRate, tapIsPlanar != 0, recordSeconds);
}

void ps_destroy(PSShifter *shifter) {
    delete shifter;
}

void ps_set_semitones(PSShifter *shifter, float semitones) {
    shifter->semitones.store(semitones, std::memory_order_relaxed);
}

uint64_t ps_frames_heard(PSShifter *shifter) {
    return shifter->heard.load(std::memory_order_relaxed);
}

uint64_t ps_underruns(PSShifter *shifter) {
    return shifter->underruns.load(std::memory_order_relaxed);
}

float ps_playing_semitones(PSShifter *shifter) {
    return shifter->playingSemitones.load(std::memory_order_relaxed);
}

void ps_stems_enable(PSShifter *s, int on) {
    s->stemsOn.store(on != 0, std::memory_order_relaxed);
}

uint64_t ps_stems_generation(PSShifter *s, uint64_t *start) {
    uint64_t generation = s->stemsGeneration.load(std::memory_order_acquire);
    *start = s->stemsStart.load(std::memory_order_relaxed);
    return generation;
}

void ps_stems_begin(PSShifter *s, uint64_t generation, uint64_t start) {
    s->stems.written.store(start, std::memory_order_relaxed);
    s->stemsWriting.store(generation, std::memory_order_release);
}

size_t ps_captured_read(PSShifter *s, uint64_t *position, float *left, float *right, size_t max) {
    uint64_t written = s->captured.written.load(std::memory_order_acquire);
    // Frames older than the buffer were overwritten.
    if (written - *position > s->captured.capacity) *position = written - s->captured.capacity / 2;
    size_t n = size_t(std::min<uint64_t>(max, written - *position));
    const float *l = s->captured.planes[0].data(), *r = s->captured.planes[1].data();
    for (size_t i = 0; i < n; i++) {
        size_t index = size_t((*position + i) % s->captured.capacity);
        left[i] = l[index];
        right[i] = r[index];
    }
    *position += n;
    return n;
}

void ps_stems_write(PSShifter *s, const float *const *planes, size_t frames) {
    s->stems.write(planes, frames, 1);
}

uint64_t ps_captured_written(PSShifter *s) { return s->captured.written.load(std::memory_order_acquire); }

uint64_t ps_stems_played(PSShifter *s) { return s->stemsPlayed.load(std::memory_order_relaxed); }

void ps_stems_begin_cached(PSShifter *s, uint64_t generation, uint64_t start) {
    // Pauses before this generation are behind its start, and its writer maps only the ones after it.
    s->skipsMapped.store(s->skipsMade.load(std::memory_order_acquire), std::memory_order_release);
    s->cachedGeneration.store(generation, std::memory_order_release);
    ps_stems_begin(s, generation, start);
}

int ps_stems_cached(PSShifter *s) {
    uint64_t generation = s->stemsGeneration.load(std::memory_order_relaxed);
    return generation != 0 && s->stemsOn.load(std::memory_order_relaxed) && s->cachedGeneration.load(std::memory_order_acquire) == generation ? 1 : 0;
}

uint64_t ps_stems_rewrite(PSShifter *s, uint64_t generation, uint64_t from, uint64_t guard) {
    if (s->stemsWriting.load(std::memory_order_acquire) != generation) return 0;
    uint64_t written = s->stems.written.load(std::memory_order_relaxed);
    uint64_t at = std::max(from, s->stemsPlayed.load(std::memory_order_relaxed) + guard);
    // Nothing is written there yet: the writer carries on from where it is.
    if (at >= written) return written;
    s->stems.written.store(at, std::memory_order_release);
    return at;
}

uint32_t ps_stems_seek(PSShifter *s) { return s->seeksAsked.fetch_add(1, std::memory_order_acq_rel) + 1; }

uint32_t ps_stems_seeks(PSShifter *s, uint32_t *answered) {
    *answered = s->seeksAnswered.load(std::memory_order_acquire);
    return s->seeksAsked.load(std::memory_order_acquire);
}

void ps_stems_seek_answer(PSShifter *s, uint32_t seek, uint64_t from) {
    // A move asked with a restart is for the next generation's writer to find, and the output waits in silence until
    // then: the stems separated as the song plays would answer it at once, and the song would play with every stem.
    if (s->restartStems.load(std::memory_order_acquire)
        || s->stemsWriting.load(std::memory_order_acquire) != s->stemsGeneration.load(std::memory_order_acquire)) return;
    s->seekFrom.store(from, std::memory_order_relaxed);
    s->seeksAnswered.store(seek, std::memory_order_release);
}

uint32_t ps_stems_skips(PSShifter *s, uint64_t *from, uint64_t *to) {
    // Read again when another pause came while reading.
    for (;;) {
        uint32_t skips = s->skipsMade.load(std::memory_order_acquire);
        *from = s->skipMadeFrom.load(std::memory_order_relaxed);
        *to = s->skipMadeTo.load(std::memory_order_relaxed);
        if (s->skipsMade.load(std::memory_order_acquire) == skips) return skips;
    }
}

void ps_stems_skip_mapped(PSShifter *s, uint32_t skips) { s->skipsMapped.store(skips, std::memory_order_release); }

void ps_set_paused(PSShifter *s, int paused) {
    s->paused.store(paused != 0, std::memory_order_relaxed);
}

void ps_stems_restart(PSShifter *s) {
    s->restartStems.store(true, std::memory_order_relaxed);
}

void ps_stems_restart_back(PSShifter *s, double seconds) {
    s->restartBack.store(uint64_t(std::max(0.0, seconds) * s->rate), std::memory_order_relaxed);
    s->restartStems.store(true, std::memory_order_release);
}

void ps_stems_await_seek(PSShifter *s, int on) {
    s->seekDip.store(on ? 1 : 0, std::memory_order_relaxed);
}

void ps_set_step_fade(PSShifter *s, int fade) {
    s->fadeSteps.store(fade != 0, std::memory_order_relaxed);
}

void ps_stems_set_gain(PSShifter *s, int stem, float gain) {
    if (stem >= 0 && stem < PSShifter::stemCount) s->stemGain[stem].store(gain, std::memory_order_relaxed);
}

void ps_stems_set_volume(PSShifter *s, int stem, float volume) {
    if (stem >= 0 && stem < PSShifter::stemCount) s->stemVolume[stem].store(std::clamp(volume, 0.0f, 1.5f), std::memory_order_relaxed);
}

float ps_stems_level(PSShifter *s, int stem) {
    return stem >= 0 && stem < PSShifter::stemCount ? s->stemLevel[stem].load(std::memory_order_relaxed) : 0;
}

double ps_stems_delay(PSShifter *s) {
    // The song plays as it is until the output is mostly the stems.
    if (s->stemsMix.load(std::memory_order_relaxed) < 0.5f) return 0;
    uint64_t captured = s->captured.written.load(std::memory_order_relaxed);
    uint64_t played = s->stemsPlayed.load(std::memory_order_relaxed);
    return captured > played ? double(captured - played) / s->rate : 0;
}

void ps_set_delay(PSShifter *s, double seconds) {
    s->delayFrames.store(uint64_t(std::max(0.0, seconds) * s->rate), std::memory_order_relaxed);
}

void ps_stems_set_fade(PSShifter *s, double seconds) {
    s->stemFadeSeconds.store(float(seconds), std::memory_order_relaxed);
}

uint32_t ps_spins(PSShifter *s) { return s->spins.load(std::memory_order_relaxed); }

double ps_delay_waiting(PSShifter *s) {
    if (!s->anchorPending.load(std::memory_order_relaxed)) return -1;
    uint64_t target = s->anchor.load(std::memory_order_relaxed) + s->delayFrames.load(std::memory_order_relaxed);
    uint64_t captured = s->captured.written.load(std::memory_order_relaxed);
    return target > captured ? double(target - captured) / s->rate : 0;
}

size_t ps_stems_room(PSShifter *s, uint64_t position) {
    // The stems that the output has yet to play stay in their buffer, with a second to spare.
    uint64_t reader = s->stemsPlayed.load(std::memory_order_relaxed);
    if (s->anchorPending.load(std::memory_order_relaxed)) reader = std::min(reader, s->anchor.load(std::memory_order_relaxed));
    uint64_t limit = reader + s->stems.capacity - uint64_t(s->rate);
    return limit > position ? size_t(limit - position) : 0;
}

int ps_stems_started(PSShifter *s) {
    return s->stemsOn.load(std::memory_order_relaxed) && s->stemsStarted.load(std::memory_order_relaxed) ? 1 : 0;
}

double ps_stems_waiting(PSShifter *s) {
    if (!s->stemsOn.load(std::memory_order_relaxed) || s->stemsStarted.load(std::memory_order_relaxed)) return -1;
    // Cached stems take over in a moment, with nothing to count down.
    uint64_t generation = s->stemsGeneration.load(std::memory_order_relaxed);
    if (generation != 0 && s->cachedGeneration.load(std::memory_order_acquire) == generation) return -1;
    // While the delay waits, the lyrics count down instead.
    if (s->anchorPending.load(std::memory_order_relaxed)) return -1;
    uint64_t captured = s->captured.written.load(std::memory_order_relaxed);
    uint64_t start = s->stemsStart.load(std::memory_order_relaxed);
    return captured > start ? double(captured - start) / s->rate : 0;
}

void ps_slow_prepare(PSShifter *s, double seconds) {
    if (s->slower.owned) return;
    s->slower.owned = std::make_unique<SharedFrames>(2, size_t(std::max(1.0, seconds) * s->rate));
    s->slower.backlog.store(s->slower.owned.get(), std::memory_order_release);
}

void ps_slow_enable(PSShifter *s, int on) {
    s->slower.wanted.store(on != 0, std::memory_order_relaxed);
}

void ps_slow_set_speed(PSShifter *s, double speed) {
    s->slower.speed.store(speed, std::memory_order_relaxed);
}

void ps_slow_flush(PSShifter *s) {
    s->slower.flushesAsked.fetch_add(1, std::memory_order_relaxed);
}

void ps_slow_splice(PSShifter *s, uint64_t from, uint64_t to, uint64_t before) {
    s->slower.spliceFrom.store(from, std::memory_order_relaxed);
    s->slower.spliceTo.store(to, std::memory_order_relaxed);
    s->slower.spliceBefore.store(before, std::memory_order_relaxed);
    s->slower.splicesAsked.fetch_add(1, std::memory_order_release);
}

PSSlowState ps_slow_state(PSShifter *s) {
    PSSlowState state{};
    Slower &w = s->slower;
    SharedFrames *b = w.backlog.load(std::memory_order_acquire);
    state.engaged = w.engagedOut.load(std::memory_order_relaxed) ? 1 : 0;
    state.written = b ? b->written.load(std::memory_order_acquire) : 0;
    state.reading = w.readingOut.load(std::memory_order_relaxed);
    state.clock = w.clockOut.load(std::memory_order_relaxed);
    state.splices = w.splicesDone.load(std::memory_order_relaxed);
    state.missed = w.splicesMissed.load(std::memory_order_relaxed);
    state.flushes = w.flushesDone.load(std::memory_order_relaxed);
    return state;
}

size_t ps_slow_read(PSShifter *s, uint64_t *position, float *left, float *right, size_t max) {
    SharedFrames *b = s->slower.backlog.load(std::memory_order_acquire);
    if (!b) return 0;
    uint64_t written = b->written.load(std::memory_order_acquire);
    // Frames older than the buffer were overwritten, and so may be the oldest ones that remain while this copies.
    uint64_t oldest = written > b->capacity ? written - b->capacity + uint64_t(s->rate) : 0;
    if (*position < oldest) *position = oldest;
    if (*position >= written) return 0;
    size_t n = size_t(std::min<uint64_t>(max, written - *position));
    const float *pl = b->planes[0].data(), *pr = b->planes[1].data();
    for (size_t i = 0; i < n; i++) {
        size_t index = size_t((*position + i) % b->capacity);
        left[i] = pl[index];
        right[i] = pr[index];
    }
    *position += n;
    return n;
}

size_t ps_recording(PSShifter *shifter, const float **pairs) {
    *pairs = shifter->recording.data();
    return shifter->recorded.load(std::memory_order_acquire);
}

void ps_process(PSShifter *s, const AudioBufferList *input, AudioBufferList *output) {
    // Turning the stems or the delay on starts a new timeline, and so does a song that changed during a pause or that
    // karaoke started over. Stems that play fade out first, so they don't stop with a click.
    bool restart = s->restartStems.load(std::memory_order_acquire);
    if (restart && s->stemsStarted.load(std::memory_order_relaxed) && s->stemsMix.load(std::memory_order_relaxed) > 0 && s->holdGain > 0 && s->restartWaits < 8) {
        s->restartFading = true;
        s->restartWaits++;
        restart = false;
    } else if (restart) {
        restart = s->restartStems.exchange(false, std::memory_order_acquire);
        s->restartFading = false;
        s->restartWaits = 0;
    }
    uint64_t delay = s->delayFrames.load(std::memory_order_relaxed);
    s->updateCached();
    s->updateTimeline(s->stemsOn.load(std::memory_order_relaxed), delay, restart);
    s->updateCached();
    bool stems = s->stemsOn.load(std::memory_order_relaxed) || delay > 0;

    // Input: the tap's stream(s) come after any input streams of the output device.
    UInt32 buffers = input ? input->mNumberBuffers : 0;
    const float *l = nullptr, *r = nullptr;
    size_t tapFrames = 0, stride = 1;
    bool quiet = true;
    if (s->planar && buffers >= 2) {
        const AudioBuffer &left = input->mBuffers[buffers - 2], &right = input->mBuffers[buffers - 1];
        if (left.mData && right.mData) {
            tapFrames = std::min(left.mDataByteSize, right.mDataByteSize) / sizeof(float);
            l = static_cast<const float *>(left.mData);
            r = static_cast<const float *>(right.mData);
            quiet = silent(l, tapFrames) && silent(r, tapFrames);
        }
    } else if (buffers >= 1) {
        const AudioBuffer &last = input->mBuffers[buffers - 1];
        if (last.mData) {
            stride = std::max<UInt32>(1, last.mNumberChannels);
            tapFrames = last.mDataByteSize / (sizeof(float) * stride);
            l = static_cast<const float *>(last.mData);
            r = stride > 1 ? l + 1 : l;
            quiet = silent(l, tapFrames * stride);
        }
    }
    if (l && tapFrames > 0) {
        // A slowed song takes the tap's place from here on.
        if (s->slower.process(l, r, tapFrames, stride, quiet, s->paused.load(std::memory_order_relaxed))) {
            l = s->slower.left.data();
            r = s->slower.right.data();
            stride = 1;
            quiet = silent(l, tapFrames) && silent(r, tapFrames);
        }
        // Digital silence is skipped, so the heard counter only moves while something plays. The stems get every
        // frame, silent or not, so they stay in time with the song, except while the song is paused.
        if (!quiet) s->write(l, r, tapFrames, stride);
        const float *planes[2] = {l, r};
        s->capture(planes, tapFrames, stride, quiet, stems);
    }

    if (!output || output->mNumberBuffers == 0) return;
    size_t firstChannels = std::max<UInt32>(1, output->mBuffers[0].mNumberChannels);
    size_t frames = output->mBuffers[0].mDataByteSize / (sizeof(float) * firstChannels);
    size_t totalChannels = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) totalChannels += output->mBuffers[b].mNumberChannels;

    s->retarget(s->semitones.load(std::memory_order_relaxed));

    for (size_t done = 0; done < frames;) {
        size_t n = std::min(frames - done, maxChunk);
        s->pull(n);
        s->shift(n);
        s->limiter.process(s->outLeft.data(), s->outRight.data(), n);
        s->cutPauseTail(n);
        if (!s->recording.empty()) s->record(n);

        // Spread left and right over the output device's channels, interleaved within each buffer.
        size_t channelBase = 0;
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            AudioBuffer &buffer = output->mBuffers[b];
            size_t channels = buffer.mNumberChannels;
            if (auto *out = static_cast<float *>(buffer.mData)) {
                size_t available = buffer.mDataByteSize / (sizeof(float) * std::max<size_t>(1, channels));
                for (size_t c = 0; c < channels; c++) {
                    size_t channel = channelBase + c;
                    for (size_t f = 0; f < n && done + f < available; f++) {
                        float sample = totalChannels == 1 ? 0.5f * (s->outLeft[f] + s->outRight[f])
                            : channel == 0                ? s->outLeft[f]
                            : channel == 1                ? s->outRight[f]
                                                          : 0.0f;
                        out[(done + f) * channels + c] = sample;
                    }
                }
            }
            channelBase += channels;
        }
        done += n;
    }
    float playing = s->phase == PSShifter::Phase::steady ? s->voices[s->active].semitones : NAN;
    s->playingSemitones.store(playing, std::memory_order_relaxed);
}

size_t ps_render(const float *left, const float *right, size_t frames, double rate, double timeRatio, double pitchScale,
                 float **outLeft, float **outRight, int (*progress)(void *context, double done), void *context) {
    *outLeft = nullptr;
    *outRight = nullptr;
    std::vector<float> resultLeft, resultRight;
    resultLeft.reserve(size_t(double(frames) * timeRatio) + 8192);
    resultRight.reserve(resultLeft.capacity());

    if (timeRatio == 1.0 && pitchScale == 1.0) {
        resultLeft.assign(left, left + frames);
        resultRight.assign(right, right + frames);
    } else {
        // The offline mode reads the whole song first, which gives the exact length and no warm-up at the start.
        RubberBandStretcher stretcher(size_t(rate), 2, RubberBandStretcher::OptionProcessOffline | RubberBandStretcher::OptionEngineFiner,
                                      timeRatio, pitchScale);
        constexpr size_t block = 16384;
        stretcher.setExpectedInputDuration(frames);
        stretcher.setMaxProcessSize(block);
        for (size_t at = 0; at < frames; at += block) {
            size_t n = std::min(block, frames - at);
            const float *planes[2] = {left + at, right + at};
            stretcher.study(planes, n, at + n >= frames);
            if (progress && !progress(context, 0.2 * double(at + n) / double(frames))) return 0;
        }
        std::vector<float> takenLeft(block), takenRight(block);
        auto take = [&] {
            for (int available; (available = stretcher.available()) > 0;) {
                size_t n = stretcher.retrieve(std::array<float *, 2>{takenLeft.data(), takenRight.data()}.data(),
                                              std::min(size_t(available), block));
                resultLeft.insert(resultLeft.end(), takenLeft.begin(), takenLeft.begin() + long(n));
                resultRight.insert(resultRight.end(), takenRight.begin(), takenRight.begin() + long(n));
            }
        };
        for (size_t at = 0; at < frames; at += block) {
            size_t n = std::min(block, frames - at);
            const float *planes[2] = {left + at, right + at};
            stretcher.process(planes, n, at + n >= frames);
            take();
            if (progress && !progress(context, 0.2 + 0.8 * double(at + n) / double(frames))) return 0;
        }
        while (stretcher.available() >= 0) {
            take();
            if (stretcher.available() == 0) break;
        }
    }

    // The same limiter as the live output, run past the end by its look-ahead, which it delays the song by.
    Limiter limiter(rate);
    size_t count = resultLeft.size();
    resultLeft.resize(count + limiter.lookahead, 0.0f);
    resultRight.resize(count + limiter.lookahead, 0.0f);
    limiter.process(resultLeft.data(), resultRight.data(), resultLeft.size());

    *outLeft = static_cast<float *>(malloc(sizeof(float) * std::max<size_t>(1, count)));
    *outRight = static_cast<float *>(malloc(sizeof(float) * std::max<size_t>(1, count)));
    std::copy(resultLeft.begin() + long(limiter.lookahead), resultLeft.end(), *outLeft);
    std::copy(resultRight.begin() + long(limiter.lookahead), resultRight.end(), *outRight);
    return count;
}

void ps_render_free(float *samples) { free(samples); }
