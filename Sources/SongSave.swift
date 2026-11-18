import AVFoundation
import Accelerate
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    /// The formats that Muskey can write.
    static let available: [SaveFormat] = [.m4a, .mp3, .wav]

    var name: String {
        switch self {
        case .m4a: "M4A"
        case .mp3: "MP3"
        case .wav: "WAV"
        }
    }

    var type: UTType {
        switch self {
        case .m4a: .mpeg4Audio
        case .mp3: .mp3
        case .wav: .wav
        }
    }
}

/// The Format row under the save panel.
struct SaveAccessory: View {
    @State var format: SaveFormat
    let picked: (SaveFormat) -> Void

    var body: some View {
        LabeledContent("Format") {
            Picker("Format", selection: $format) {
                ForEach(SaveFormat.available, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onChange(of: format) { picked(format) }
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
            try writeMP3(audio, to: url, progress: progress)
        }
    }

    /// MP3 through LAME, at a constant 320 kbit/s, with the LAME tag that tells players how much padding the encoder
    /// added at the ends.
    private static func writeMP3(_ audio: StereoAudio, to url: URL, progress: (Double) -> Bool) throws {
        guard let lame = lame_init() else { throw SaveError(message: "The MP3 encoder didn't start") }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(audio.rate))
        lame_set_num_channels(lame, 2)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, 320)
        lame_set_quality(lame, 2)
        lame_set_bWriteVbrTag(lame, 1)
        lame_set_write_id3tag_automatic(lame, 0)
        guard lame_init_params(lame) >= 0 else { throw SaveError(message: "The MP3 encoder refused the song's sample rate") }

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw SaveError(message: "The file can't be written") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let block = 8192
        // LAME asks for 1.25 times the samples plus 7200 bytes, the most that one call can write.
        var buffer = [UInt8](repeating: 0, count: block * 5 / 4 + 7200)
        for start in stride(from: 0, to: audio.frames, by: block) {
            let n = min(block, audio.frames - start)
            let written = audio.left.withUnsafeBufferPointer { left in
                audio.right.withUnsafeBufferPointer { right in
                    lame_encode_buffer_ieee_float(lame, left.baseAddress! + start, right.baseAddress! + start, Int32(n), &buffer, Int32(buffer.count))
                }
            }
            guard written >= 0 else { throw SaveError(message: "The MP3 encoder failed (\(written))") }
            try handle.write(contentsOf: buffer[0 ..< Int(written)])
            guard progress(Double(start + n) / Double(audio.frames)) else { throw CancellationError() }
        }
        let flushed = lame_encode_flush(lame, &buffer, Int32(buffer.count))
        if flushed > 0 { try handle.write(contentsOf: buffer[0 ..< Int(flushed)]) }
        // The first frame was left empty for the LAME tag, which is known only now.
        let tag = lame_get_lametag_frame(lame, &buffer, buffer.count)
        if tag > 0, tag <= buffer.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: buffer[0 ..< tag])
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

/// `--render-song PATH` renders a song the way Save Song does, with `--render-semitones N`, `--render-speed S` and
/// `--render-mute vocals,drums`, writes it to `--render-out` (M4A, WAV or MP3 by its extension), prints how long each
/// part took, and quits.
enum SaveTest {
    static func run(_ path: String, to out: String, semitones: Int, speed: Double, mute: [String]) {
        DispatchQueue.global().async {
            do {
                let format = SaveFormat(rawValue: (out as NSString).pathExtension.lowercased()) ?? .m4a
                var changes = SongChanges(semitones: semitones, speed: speed)
                if !mute.isEmpty {
                    changes.stemGains = Stem.allCases.map { mute.contains($0.name.lowercased()) ? 0 : 1 }
                }
                var started = Date()
                let audio = try SongRender.read(URL(fileURLWithPath: path))
                print(String(format: "read %.1f s of song in %.1f s", audio.seconds, Date().timeIntervalSince(started)))
                started = Date()
                var last = -1
                let rendered = try SongRender.render(audio, changes: changes) { part in
                    let tenth = Int(part * 10)
                    if tenth != last {
                        last = tenth
                        print("rendering \(tenth * 10)%")
                    }
                    return true
                }
                print(String(format: "rendered %.1f s at %.0f Hz in %.1f s", rendered.seconds, rendered.rate, Date().timeIntervalSince(started)))
                started = Date()
                try SongRender.write(rendered, as: format, to: URL(fileURLWithPath: out))
                print(String(format: "wrote %@ in %.1f s", out, Date().timeIntervalSince(started)))
                exit(0)
            } catch {
                print("render failed: \(error)")
                exit(1)
            }
        }
    }
}
