import AVFoundation
import Accelerate
import Foundation

/// What a saved song changes from the original, as it was when Save was pressed: the key, the tempo and the stems.
struct SongChanges: Equatable {
    /// Semitones from the song's key.
    var semitones = 0
    /// The speed of a song in Muskey Player, 1 for its own tempo.
    var speed = 1.0
    /// The level of each stem by `Stem.rawValue`: 0 for a muted one, the scroll's volume otherwise. Nil while every
    /// stem plays as it is, which needs no separation.
    var stemGains: [Float]?

    var isEmpty: Bool { semitones == 0 && abs(speed - 1) < 0.001 && stemGains == nil }
}

/// The formats a song is saved in.
enum SaveFormat: String, CaseIterable {
    case m4a, mp3, wav

    var name: String {
        switch self {
        case .m4a: "M4A"
        case .mp3: "MP3"
        case .wav: "WAV"
        }
    }
}

/// Stereo audio as two planes, left and right, at a sample rate.
struct StereoAudio {
    var left: [Float]
    var right: [Float]
    var rate: Double

    var frames: Int { left.count }
    var seconds: Double { Double(frames) / rate }
}

struct SaveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Renders a song with its changes offline, from the original audio: the stems separated and mixed by their levels,
/// then the tempo and the key changed by Rubber Band and the peaks limited, as the live output does it.
enum SongRender {
    /// Reads an audio file as stereo at its own sample rate. A mono file plays on both sides.
    static func read(_ url: URL) throws -> StereoAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SaveError(message: "The song is empty")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw SaveError(message: "The song can't be read as samples") }
        let frames = Int(buffer.frameLength), channels = Int(format.channelCount)
        let left = Array(UnsafeBufferPointer(start: data[0], count: frames))
        let right = channels > 1 ? Array(UnsafeBufferPointer(start: data[1], count: frames)) : left
        return StereoAudio(left: left, right: right, rate: format.sampleRate)
    }

    /// The song with its changes. `progress` gets the part done, from 0 to 1, and stops the render when it returns
    /// false. `live` is true while the stems are separated for the output too, which the separation here then leaves
    /// half of the time to.
    static func render(_ audio: StereoAudio, changes: SongChanges, live: @escaping () -> Bool = { false },
                       progress: @escaping (Double) -> Bool) throws -> StereoAudio {
        var audio = audio
        // The stems take most of the time, when there are any to mix.
        let stemsPart = changes.stemGains == nil ? 0.0 : 0.8
        if let gains = changes.stemGains {
            audio = try mixStems(audio, gains: gains, live: live) { progress($0 * stemsPart) }
        }
        let pitchScale = pow(2, Double(changes.semitones) / 12)
        return try stretch(audio, timeRatio: 1 / changes.speed, pitchScale: pitchScale) { progress(stemsPart + $0 * (1 - stemsPart)) }
    }

    /// Changes the tempo by `timeRatio` (1.25 is a quarter longer) and the pitch by `pitchScale`, and limits the peaks.
    static func stretch(_ audio: StereoAudio, timeRatio: Double, pitchScale: Double, progress: @escaping (Double) -> Bool) throws -> StereoAudio {
        final class Box {
            let progress: (Double) -> Bool
            init(_ progress: @escaping (Double) -> Bool) { self.progress = progress }
        }
        let box = Box(progress)
        var outLeft: UnsafeMutablePointer<Float>?, outRight: UnsafeMutablePointer<Float>?
        let frames = audio.left.withUnsafeBufferPointer { left in
            audio.right.withUnsafeBufferPointer { right in
                withExtendedLifetime(box) {
                    ps_render(left.baseAddress, right.baseAddress, audio.left.count, audio.rate, timeRatio, pitchScale, &outLeft, &outRight, { context, done in
                        Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue().progress(done) ? 1 : 0
                    }, Unmanaged.passUnretained(box).toOpaque())
                }
            }
        }
        defer {
            ps_render_free(outLeft)
            ps_render_free(outRight)
        }
        guard frames > 0, let outLeft, let outRight else { throw CancellationError() }
        return StereoAudio(left: Array(UnsafeBufferPointer(start: outLeft, count: frames)),
                           right: Array(UnsafeBufferPointer(start: outRight, count: frames)), rate: audio.rate)
    }

    /// Separates the whole song into its stems with the model of the live stems, and mixes them by `gains`, at the
    /// model's sample rate.
    static func mixStems(_ audio: StereoAudio, gains: [Float], live: @escaping () -> Bool, progress: @escaping (Double) -> Bool) throws -> StereoAudio {
        let model = try StemModel.shared()
        let stream = StemStream(model: model, winds: StemModel.sharedWinds())
        let input = audio.rate == StemModel.sampleRate ? [audio.left, audio.right]
            : Resampler(from: audio.rate, to: StemModel.sampleRate).convert(audio.left[...], audio.right[...])
        let frames = input[0].count
        var left = [Float](), right = [Float]()
        left.reserveCapacity(frames + StemModel.chunk)
        right.reserveCapacity(frames + StemModel.chunk)
        // The song goes in a window at a time, so each block comes back as soon as it is separated.
        var at = 0
        let tail = [Float](repeating: 0, count: StemModel.chunk)
        while left.count < frames {
            let began = CACurrentMediaTime()
            let blocks: [[[[Float]]]]
            if at < frames {
                let end = min(frames, at + StemStream.step)
                blocks = try stream.push(input[0][at ..< end], input[1][at ..< end])
                at = end
            } else {
                blocks = try stream.push(tail[...], tail[...])
            }
            for block in blocks {
                let count = block[0][0].count
                var mixLeft = [Float](repeating: 0, count: count), mixRight = mixLeft
                for (s, stem) in block.enumerated() where s < gains.count && gains[s] > 0 {
                    vDSP.add(multiplication: (stem[0], gains[s]), mixLeft, result: &mixLeft)
                    vDSP.add(multiplication: (stem[1], gains[s]), mixRight, result: &mixRight)
                }
                left += mixLeft
                right += mixRight
            }
            guard progress(min(1, Double(left.count) / Double(frames))) else { throw CancellationError() }
            // The live stems come first: with them running, this separation waits as long as its last window took.
            if !blocks.isEmpty, live() { Thread.sleep(forTimeInterval: CACurrentMediaTime() - began) }
        }
        return StereoAudio(left: Array(left.prefix(frames)), right: Array(right.prefix(frames)), rate: StemModel.sampleRate)
    }

    /// Writes the song in `format`. WAV is 16-bit, M4A is AAC at 256 kbit/s, and MP3 is 320 kbit/s.
    static func write(_ audio: StereoAudio, as format: SaveFormat, to url: URL, progress: @escaping (Double) -> Bool = { _ in true }) throws {
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .wav:
            try writeAV(audio, to: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], progress: progress)
        case .m4a:
            try writeAV(audio, to: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
            ], progress: progress)
        case .mp3:
            throw SaveError(message: "MP3 isn't available yet")
        }
    }

    private static func writeAV(_ audio: StereoAudio, to url: URL, settings: [String: Any], progress: (Double) -> Bool) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let channels = buffer.floatChannelData
        else { throw SaveError(message: "The file can't be written") }
        for start in stride(from: 0, to: audio.frames, by: block) {
            let n = min(block, audio.frames - start)
            audio.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress! + start, count: n) }
            audio.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress! + start, count: n) }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            guard progress(Double(start + n) / Double(audio.frames)) else { throw CancellationError() }
        }
    }
}
