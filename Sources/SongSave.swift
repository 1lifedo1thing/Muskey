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
    /// The region loop that the save keeps, in seconds of the original song. Nil keeps the whole song. A region alone
    /// changes nothing, so it doesn't make a song worth saving.
    var range: ClosedRange<Double>?

    var isEmpty: Bool { semitones == 0 && abs(speed - 1) < 0.001 && stemGains == nil }
}

/// The title, artist, album and cover that a saved M4A or MP3 carries. WAV keeps only the audio.
struct SongTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    /// The cover as JPEG, at most 1000 pixels on its longer side.
    var cover: Data?

    var isEmpty: Bool { [title, artist, album].allSatisfy { $0?.isEmpty ?? true } && cover == nil }

    static func jpeg(_ image: NSImage?) -> Data? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1000 / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// The tags as an ID3v2.3 tag for the start of an MP3: text in UTF-16, the cover as the front cover. LAME writes
    /// ID3v2.4 with the cover frame's size in the wrong encoding, which ffmpeg and the players built on it skip.
    var id3: [UInt8] {
        func size(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + size(body.count) + [0, 0] + body }
        func text(_ id: String, _ value: String?) -> [UInt8] {
            guard let value, !value.isEmpty else { return [] }
            return frame(id, [1, 0xFF, 0xFE] + value.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        }
        var frames = text("TIT2", title) + text("TPE1", artist) + text("TALB", album)
        if let cover { frames += frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3, 0] + [UInt8](cover)) }
        // The tag's own size is syncsafe: seven bits in each byte.
        let n = frames.count
        return Array("ID3".utf8) + [3, 0, 0] + [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + frames
    }

    /// The tags as AVFoundation writes them into an M4A.
    var metadata: [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?) -> AVMetadataItem? {
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if identifier == .commonIdentifierArtwork { item.dataType = kCMMetadataBaseDataType_JPEG as String }
            return item
        }
        return [
            item(.commonIdentifierTitle, title.flatMap { $0.isEmpty ? nil : $0 as NSString }),
            item(.commonIdentifierArtist, artist.flatMap { $0.isEmpty ? nil : $0 as NSString }),
            item(.commonIdentifierAlbumName, album.flatMap { $0.isEmpty ? nil : $0 as NSString }),
            item(.commonIdentifierArtwork, cover as NSData?),
        ].compactMap { $0 }
    }
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
        // MPEG-4 audio's extension is mp4, so the save panel gave a typed name .mp4.
        case .m4a: UTType("com.apple.m4a-audio") ?? UTType(filenameExtension: "m4a", conformingTo: .audio) ?? .mpeg4Audio
        case .mp3: .mp3
        case .wav: .wav
        }
    }
}

/// What saving a song from another player takes, under the save panel's Format row.
enum SaveCaveat {
    static let recorded = "Muskey plays the song from its start to its end and records it. A pause saves the part recorded until then. Seeking or another song stops the save."
    static let recordedWithOthers = recorded + " Other sounds playing at the same time are recorded too."
}

/// The Format row under the save panel, and what saving takes for a song from another player.
struct SaveAccessory: View {
    @State var format: SaveFormat
    let caveat: String?
    let picked: (SaveFormat) -> Void

    var body: some View {
        VStack(spacing: 10) {
            LabeledContent("Format") {
                Picker("Format", selection: $format) {
                    ForEach(SaveFormat.available, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let caveat {
                Text(caveat)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// The part from `start` to `end` seconds, kept inside the audio.
    func cut(_ start: Double, _ end: Double) -> StereoAudio {
        let from = min(frames, max(0, Int((start * rate).rounded()))), to = min(frames, max(from, Int((end * rate).rounded())))
        return StereoAudio(left: Array(left[from ..< to]), right: Array(right[from ..< to]), rate: rate)
    }

    /// Without the silence at its end, which a recording has after the song was paused or stopped.
    func trimmingSilentEnd(below threshold: Float = 0.0001) -> StereoAudio {
        let end = left.indices.last { abs(left[$0]) >= threshold || abs(right[$0]) >= threshold }.map { $0 + 1 } ?? 0
        return StereoAudio(left: Array(left.prefix(end)), right: Array(right.prefix(end)), rate: rate)
    }
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
    /// half of the time to. `path` is the file of the song, whose stems may be in the cache already.
    static func render(_ audio: StereoAudio, changes: SongChanges, path: String? = nil, live: @escaping () -> Bool = { false },
                       progress: @escaping (Double) -> Bool) throws -> StereoAudio {
        var audio = audio
        var path = path
        // Where the audio starts in the song, once a region is cut out of it.
        var offset = 0.0
        // The stems take most of the time, when there are any to mix.
        let stemsPart = changes.stemGains == nil ? 0.0 : 0.8
        if let gains = changes.stemGains {
            // The cache keeps the stems of the whole song, which are mixed whole and cut after. Without them, only the
            // region is separated, from a little before it, so that the model hears what leads into it.
            if let range = changes.range, path.flatMap(StemsCache.open(for:)) == nil {
                offset = max(0, range.lowerBound - regionContext)
                audio = audio.cut(offset, range.upperBound + regionContext)
                path = nil
            }
            audio = try mixStems(audio, gains: gains, path: path, live: live) { progress($0 * stemsPart) }
        }
        if let range = changes.range { audio = audio.cut(range.lowerBound - offset, range.upperBound - offset) }
        let pitchScale = pow(2, Double(changes.semitones) / 12)
        return try stretch(audio, timeRatio: 1 / changes.speed, pitchScale: pitchScale) { progress(stemsPart + $0 * (1 - stemsPart)) }
    }

    /// The seconds of song separated before and after a region, which the save then cuts off.
    static let regionContext = 2.0

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
    /// model's sample rate. The stems that the cache keeps of the song at `path` are mixed instead, when it has them.
    static func mixStems(_ audio: StereoAudio, gains: [Float], path: String? = nil, live: @escaping () -> Bool,
                         progress: @escaping (Double) -> Bool) throws -> StereoAudio {
        let input = audio.rate == StemModel.sampleRate ? [audio.left, audio.right]
            : Resampler(from: audio.rate, to: StemModel.sampleRate).convert(audio.left[...], audio.right[...])
        let frames = input[0].count
        var left = [Float](), right = [Float]()
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        func mix(_ block: [[[Float]]]) {
            let count = block[0][0].count
            var mixLeft = [Float](repeating: 0, count: count), mixRight = mixLeft
            for (s, stem) in block.enumerated() where s < gains.count && gains[s] > 0 {
                vDSP.add(multiplication: (stem[0], gains[s]), mixLeft, result: &mixLeft)
                vDSP.add(multiplication: (stem[1], gains[s]), mixRight, result: &mixRight)
            }
            left += mixLeft
            right += mixRight
        }
        // A resampled song can come out a few frames shorter at its end, which the cache's silence fills in.
        if let path, let cache = StemsCache.open(for: path), abs(cache.frames - frames) < Int(StemModel.sampleRate * 0.05) {
            let block = 65536
            var samples = [Float](repeating: 0, count: block * StemsCache.planes)
            for at in stride(from: 0, to: frames, by: block) {
                let count = min(block, frames - at)
                samples.withUnsafeMutableBufferPointer { cache.copy(Array(0 ..< StemsCache.planes), from: at, count: count, into: $0.baseAddress!) }
                mix(Stem.allCases.map { stem in (0 ..< 2).map { c in Array(samples[(stem.rawValue * 2 + c) * count ..< (stem.rawValue * 2 + c + 1) * count]) } })
                guard progress(Double(at + count) / Double(frames)) else { throw CancellationError() }
            }
        } else {
            var at = 0
            try separate(frames: frames, read: { count in
                guard at < frames else { return nil }
                let end = min(frames, at + count)
                defer { at = end }
                return [Array(input[0][at ..< end]), Array(input[1][at ..< end])]
            }, live: live, progress: progress, take: mix)
        }
        return StereoAudio(left: Array(left.prefix(frames)), right: Array(right.prefix(frames)), rate: StemModel.sampleRate)
    }

    /// Separates a whole song with the model of the live stems, a window at a time, and hands each block of stems to
    /// `take` in order from the song's start, as [stem][channel][frame] at the model's sample rate, `frames` in all.
    /// `read` gives the next frames of the song at the model's rate, as many as asked for or fewer, and nil at its end.
    /// The live stems come first: while `live` is true, this waits as long as each window took.
    static func separate(frames: Int, read: (Int) throws -> [[Float]]?, live: () -> Bool, progress: (Double) -> Bool,
                         take: ([[[Float]]]) throws -> Void) throws {
        let model = try StemModel.shared()
        let stream = StemStream(model: model, winds: StemModel.sharedWinds())
        // The song goes in a window at a time, so each block comes back as soon as it is separated.
        let tail = [Float](repeating: 0, count: StemModel.chunk)
        var done = 0, ended = false
        while done < frames {
            let began = CACurrentMediaTime()
            let blocks: [[[[Float]]]]
            if !ended, let next = try read(StemStream.step), let first = next.first, !first.isEmpty {
                blocks = try stream.push(next[0][...], next[1][...])
            } else {
                ended = true
                blocks = try stream.push(tail[...], tail[...])
            }
            for block in blocks where done < frames {
                let count = min(block[0][0].count, frames - done)
                try take(count == block[0][0].count ? block : block.map { $0.map { Array($0.prefix(count)) } })
                done += count
            }
            guard progress(min(1, Double(done) / Double(frames))) else { throw CancellationError() }
            if !blocks.isEmpty, live() { Thread.sleep(forTimeInterval: CACurrentMediaTime() - began) }
        }
    }

    /// Writes the song in `format`. WAV is 16-bit, M4A is AAC at 256 kbit/s, and MP3 is 320 kbit/s. M4A and MP3 carry
    /// the tags and the cover.
    static func write(_ audio: StereoAudio, as format: SaveFormat, to url: URL, tags: SongTags = SongTags(),
                      progress: @escaping (Double) -> Bool = { _ in true }) throws {
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .wav:
            try writeAV(audio, to: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], progress: progress)
        case .m4a:
            // AVAudioFile writes no tags, so the tagged file is a copy of its audio that a passthrough export makes.
            let plain = tags.isEmpty ? url : url.deletingLastPathComponent().appending(path: "untagged \(UUID().uuidString).m4a")
            defer { if plain != url { try? FileManager.default.removeItem(at: plain) } }
            try writeAV(audio, to: plain, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
            ], progress: progress)
            if plain != url { try tagM4A(plain, to: url, tags: tags) }
        case .mp3:
            try writeMP3(audio, to: url, tags: tags, progress: progress)
        }
    }

    private static func tagM4A(_ source: URL, to url: URL, tags: SongTags) throws {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw SaveError(message: "The tags can't be written")
        }
        export.metadata = tags.metadata
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome(), done = DispatchSemaphore(value: 0)
        Task {
            do { try await export.export(to: url, as: .m4a) } catch { outcome.error = error }
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw SaveError(message: "The tags can't be written: \(error.localizedDescription)") }
    }

    /// MP3 through LAME, at a constant 320 kbit/s, with the LAME tag that tells players how much padding the encoder
    /// added at the ends.
    private static func writeMP3(_ audio: StereoAudio, to url: URL, tags: SongTags, progress: (Double) -> Bool) throws {
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
        // The ID3 tag goes first, and the LAME tag right after it.
        let id3 = tags.isEmpty ? [] : tags.id3
        if !id3.isEmpty { try handle.write(contentsOf: id3) }
        let tagEnd = id3.count
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
            try handle.seek(toOffset: UInt64(tagEnd))
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
    static func run(_ path: String, to out: String, semitones: Int, speed: Double, mute: [String], range: ClosedRange<Double>? = nil,
                    tags: SongTags = SongTags()) {
        DispatchQueue.global().async {
            do {
                let format = SaveFormat(rawValue: (out as NSString).pathExtension.lowercased()) ?? .m4a
                var changes = SongChanges(semitones: semitones, speed: speed, range: range)
                if !mute.isEmpty {
                    changes.stemGains = Stem.allCases.map { mute.contains($0.name.lowercased()) ? 0 : 1 }
                }
                var started = Date()
                let audio = try SongRender.read(URL(fileURLWithPath: path))
                print(String(format: "read %.1f s of song in %.1f s", audio.seconds, Date().timeIntervalSince(started)))
                started = Date()
                var last = -1
                let rendered = try SongRender.render(audio, changes: changes, path: path) { part in
                    let tenth = Int(part * 10)
                    if tenth != last {
                        last = tenth
                        print("rendering \(tenth * 10)%")
                    }
                    return true
                }
                print(String(format: "rendered %.1f s at %.0f Hz in %.1f s", rendered.seconds, rendered.rate, Date().timeIntervalSince(started)))
                started = Date()
                try SongRender.write(rendered, as: format, to: URL(fileURLWithPath: out), tags: tags)
                print(String(format: "wrote %@ in %.1f s", out, Date().timeIntervalSince(started)))
                exit(0)
            } catch {
                print("render failed: \(error)")
                exit(1)
            }
        }
    }
}

/// A save in progress, as the HUD shows it: the part rendered, or the time left of a recording.
struct SavingState: Equatable {
    let name: String
    let progress: Double?
    /// The time left of a song recorded from another player, which Stop and Save ends early.
    let left: String?
}

/// The HUD while a song is saved, compact like the card: the record, turning while the song is rendered or plays for
/// the recording, inside a ring that fills with the part done, and under it the save, with Cancel, and with Stop and
/// Save while a song from another player is recorded.
struct SavingCard: View {
    let saving: SavingState
    let track: NowPlaying.Track?
    let artwork: NSImage?
    let spinning: Bool
    let palette: Palette
    let cancel: () -> Void
    let stop: () -> Void

    private var recording: Bool { saving.left != nil }
    private static let red = Color(red: 0.93, green: 0.33, blue: 0.3)
    private static let record: CGFloat = 150

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if let track {
                    RecordDisc(track: track, artwork: artwork, spinning: spinning, side: Self.record, controls: false)
                } else {
                    EmptyPlatter(side: Self.record)
                }
                Circle()
                    .stroke(palette.ink.opacity(0.08), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.01, saving.progress ?? 0))
                    .stroke(recording ? Self.red : palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: saving.progress)
            }
            .frame(width: Self.record + 18, height: Self.record + 18)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if recording {
                        Circle().fill(Self.red).frame(width: 8, height: 8)
                            .symbolEffect(.pulse, isActive: true)
                    }
                    Text(recording ? "Recording" : "Saving")
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
                Text(saving.name)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(saving.left ?? "\(Int(((saving.progress ?? 0) * 100).rounded(.down)))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .padding(.top, 2)
            }
            HStack(spacing: 8) {
                CoverButton(title: "Cancel", tint: palette.ink, filled: false, action: cancel)
                    .help("Stop saving without writing a file")
                if recording {
                    CoverButton(title: "Stop and Save", tint: Self.red, filled: true, action: stop)
                        .help("Save the part recorded so far")
                }
            }
        }
        .padding(.top, 34)
        .padding(.bottom, 22)
        .padding(.horizontal, 28)
        .frame(width: 300)
    }

    private struct CoverButton: View {
        let title: String
        let tint: Color
        let filled: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(filled ? .white : tint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(filled ? tint.opacity(hovering ? 1 : 0.88) : tint.opacity(hovering ? 0.14 : 0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
