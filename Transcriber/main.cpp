// muskey-transcribe: turns an audio file into notes with MuScriptor, through muscriptor.cpp on ggml.
//
// It is an executable of its own, not code in the app, because the app links whisper.cpp with its own copy of ggml,
// and two copies of ggml in one binary clash.
//
//     muskey-transcribe --model muscriptor-medium-f16.gguf [--instrument electric_bass] song.wav
//
// stdout gets one JSON object per note, as each note is finished:
//     {"start":12.340,"end":12.800,"pitch":40,"program":33,"drum":false}
// The notes come out in the order they close, which is not quite the order they start in.
// stderr gets `device <backend> <name>` once the model is loaded, `progress <0..1>` after every 5 s chunk, and
// `error: <reason>` on a failure, which also exits with a status other than 0.

#include "muscriptor/muscriptor.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace
{

constexpr double kSampleRate = msl::Transcriber::SAMPLE_RATE;

[[noreturn]] void fail(const std::string& reason, int status = 1)
{
    std::fprintf(stderr, "error: %s\n", reason.c_str());
    std::exit(status);
}

void usage(FILE* out)
{
    std::fprintf(out,
                 "usage: muskey-transcribe --model MODEL.gguf [--instrument NAME[,NAME...]] [--device auto|cpu|gpu]\n"
                 "                         [--gain DB] [--threads N] [--no-silence-gate] AUDIO\n"
                 "       muskey-transcribe --list-instruments\n"
                 "\n"
                 "Prints one JSON object per note on stdout, and progress lines such as `progress 0.42` on stderr.\n"
                 "The --instrument option limits the notes to those instrument groups. Without it, any instrument\n"
                 "can appear. The --gain option adds decibels to the audio before the model hears it.\n");
}

std::string osStatus(OSStatus status)
{
    // Core Audio errors are often four printable characters.
    const UInt32 big = CFSwapInt32HostToBig(static_cast<UInt32>(status));
    char code[5] = {};
    std::memcpy(code, &big, 4);
    bool printable = true;
    for (char c : std::string_view(code, 4)) {
        printable = printable && c >= 32 && c < 127;
    }
    return printable ? "'" + std::string(code) + "'" : std::to_string(status);
}

// Reads any file Core Audio can open (WAV, AIFF, CAF, MP3, M4A, FLAC...) as 16 kHz mono float. The channels are
// averaged here, so that the mix doesn't depend on how the converter maps channels. The sample rate converter runs at
// its best quality, because the model's mel spectrogram is sensitive enough to the resampling filter that a cheap one
// moves onsets.
std::vector<float> decode(const char* path)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, reinterpret_cast<const UInt8*>(path), static_cast<CFIndex>(std::strlen(path)), false);
    ExtAudioFileRef file = nullptr;
    OSStatus status = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (status != noErr) {
        fail("can't open " + std::string(path) + " as audio (" + osStatus(status) + ")");
    }

    AudioStreamBasicDescription source {};
    UInt32 size = sizeof(source);
    status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source);
    if (status != noErr || source.mChannelsPerFrame == 0) {
        fail("can't read the format of " + std::string(path));
    }

    const UInt32 channels = source.mChannelsPerFrame;
    AudioStreamBasicDescription client {};
    client.mSampleRate = kSampleRate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    client.mBitsPerChannel = 32;
    client.mChannelsPerFrame = channels;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = 4 * channels;
    client.mBytesPerPacket = client.mBytesPerFrame;
    status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (status != noErr) {
        fail("can't convert " + std::string(path) + " to 16 kHz (" + osStatus(status) + ")");
    }

    AudioConverterRef converter = nullptr;
    size = sizeof(converter);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr && converter) {
        UInt32 quality = kAudioConverterQuality_Max;
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);
        UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity, sizeof(complexity), &complexity);
        // The converter picks up changed properties only after its configuration is set again.
        CFArrayRef config = nullptr;
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, sizeof(config), &config);
    }

    std::vector<float> mono;
    SInt64 frames = 0;
    size = sizeof(frames);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr && frames > 0
        && source.mSampleRate > 0) {
        mono.reserve(static_cast<size_t>(static_cast<double>(frames) * kSampleRate / source.mSampleRate) + 4096);
    }

    constexpr UInt32 chunk = 16384;
    std::vector<float> buffer(static_cast<size_t>(chunk) * channels);
    for (;;) {
        AudioBufferList list {};
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = channels;
        list.mBuffers[0].mDataByteSize = static_cast<UInt32>(buffer.size() * sizeof(float));
        list.mBuffers[0].mData = buffer.data();
        UInt32 read = chunk;
        status = ExtAudioFileRead(file, &read, &list);
        if (status != noErr) {
            fail("can't decode " + std::string(path) + " (" + osStatus(status) + ")");
        }
        if (read == 0) {
            break;
        }
        for (UInt32 i = 0; i < read; i++) {
            float sum = 0;
            for (UInt32 c = 0; c < channels; c++) {
                sum += buffer[static_cast<size_t>(i) * channels + c];
            }
            mono.push_back(sum / static_cast<float>(channels));
        }
    }
    ExtAudioFileDispose(file);
    return mono;
}

std::optional<msl::InstrumentGroup> group(std::string_view name)
{
    for (const msl::InstrumentGroup g : msl::allInstrumentGroups()) {
        if (msl::instrumentName(g) == name) {
            return g;
        }
    }
    return std::nullopt;
}

std::vector<msl::InstrumentGroup> groups(std::string_view list)
{
    std::vector<msl::InstrumentGroup> result;
    while (!list.empty()) {
        const size_t comma = list.find(',');
        const std::string_view name = list.substr(0, comma);
        if (!name.empty()) {
            const auto found = group(name);
            if (!found) {
                fail("unknown instrument " + std::string(name) + " (see --list-instruments)", 2);
            }
            result.push_back(*found);
        }
        list = comma == std::string_view::npos ? std::string_view {} : list.substr(comma + 1);
    }
    return result;
}

void print(const msl::Note& note)
{
    std::printf("{\"start\":%.3f,\"end\":%.3f,\"pitch\":%d,\"program\":%d,\"drum\":%s}\n", note.onset, note.offset,
                note.pitch, note.program, note.is_drum ? "true" : "false");
}

} // namespace

int main(int argc, char** argv)
{
    const char* model = nullptr;
    const char* audio = nullptr;
    std::string_view device = "auto";
    double gain = 0;
    msl::TranscribeOptions options;

    for (int i = 1; i < argc; i++) {
        const std::string_view arg = argv[i];
        auto value = [&]() -> const char* {
            if (i + 1 >= argc) {
                fail(std::string(arg) + " needs a value", 2);
            }
            return argv[++i];
        };
        if (arg == "--model") {
            model = value();
        } else if (arg == "--instrument" || arg == "--instruments") {
            const auto more = groups(value());
            options.instruments.insert(options.instruments.end(), more.begin(), more.end());
        } else if (arg == "--device") {
            device = value();
        } else if (arg == "--threads") {
            options.n_threads = std::atoi(value());
        } else if (arg == "--gain") {
            gain = std::atof(value());
        } else if (arg == "--no-silence-gate") {
            options.silence_gate.enabled = false;
        } else if (arg == "--list-instruments") {
            for (const msl::InstrumentGroup g : msl::allInstrumentGroups()) {
                std::printf("%.*s\n", static_cast<int>(msl::instrumentName(g).size()), msl::instrumentName(g).data());
            }
            return 0;
        } else if (arg == "-h" || arg == "--help") {
            usage(stdout);
            return 0;
        } else if (arg.starts_with("--")) {
            fail("unknown option " + std::string(arg), 2);
        } else if (!audio) {
            audio = argv[i];
        } else {
            fail("more than one audio file", 2);
        }
    }
    if (!model || !audio) {
        usage(stderr);
        return 2;
    }

    // The library is silent by default; its own reason for a failure is worth passing on.
    msl::setLogCallback(
        [](msl::LogLevel, std::string_view text) {
            std::fprintf(stderr, "log %.*s", static_cast<int>(text.size()), text.data());
            if (!text.ends_with('\n')) {
                std::fputc('\n', stderr);
            }
        },
        msl::LogLevel::Error);

    std::vector<float> samples = decode(audio);
    // How many notes the model finds depends on the level of the audio, and a stem keeps the level it had in the mix.
    // The gain lets the host choose the level instead of the helper guessing one.
    if (gain != 0) {
        const float factor = static_cast<float>(std::pow(10.0, gain / 20));
        for (float& sample : samples) {
            sample *= factor;
        }
    }

    msl::LoadOptions load;
    if (device != "auto") {
        // Metal lists one device, the system GPU, and the CPU is always last.
        const auto devices = msl::availableDevices();
        if (device == "cpu") {
            load.device = devices.size() - 1;
        } else if (device == "gpu" && devices.size() > 1) {
            load.device = 0;
        } else {
            fail("no device " + std::string(device), 2);
        }
    }
    auto transcriber = msl::Transcriber::load(model, load);
    if (!transcriber) {
        fail("can't load " + std::string(model) + ": " + std::string(msl::describe(transcriber.error())));
    }
    // The fallback to the CPU is silent and several times slower, so the host can tell from this line.
    const msl::Device& running = transcriber->device();
    std::fprintf(stderr, "device %s %s\n", running.backend.c_str(), running.name.c_str());
    std::fprintf(stderr, "progress 0.000\n");

    // Notes are printed as each chunk finishes them, so the host can show them while the rest is transcribed.
    const auto notes = transcriber->transcribe(samples, options, [](const msl::TranscriptionUpdate& update) {
        for (const msl::Note& note : update.new_notes) {
            print(note);
        }
        std::fflush(stdout);
        std::fprintf(stderr, "progress %.3f\n", static_cast<double>(update.progress));
        return true;
    });
    if (!notes) {
        fail("transcription failed: " + std::string(msl::describe(notes.error())));
    }
    return 0;
}
