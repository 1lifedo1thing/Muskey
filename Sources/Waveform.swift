import Accelerate
import AVFoundation
import CryptoKit
import Foundation

/// How loud a song is over its whole length, for the waveform in the HUD.
///
/// The levels are kept 50 times a second, which is fine enough for the close-up that a zoom shows and small enough
/// to keep on disk: four minutes take 12 KB. Each level is one byte: 0 for a moment that wasn't heard yet, and 1 to
/// 255 for a heard one, from silence to loud. The scale is a square root of the RMS, which shows quiet parts better
/// than a linear one.
struct SongWaveform: Codable, Equatable {
    static let rate = 50.0

    var duration: Double
    var levels: Data
    /// One row of levels per stem, by the stem's raw value, from stems separated for the whole song.
    var stems: [Int: Data]?

    init(duration: Double, levels: Data, stems: [Int: Data]? = nil) {
        self.duration = duration
        self.levels = levels
        self.stems = stems
    }

    init(duration: Double) {
        self.init(duration: duration, levels: Data(count: Self.slots(for: duration)))
    }

    static func slots(for duration: Double) -> Int { max(1, Int((duration * rate).rounded(.up))) }

    /// The byte for an RMS level: 1 for silence, 255 for a full-scale sine and louder.
    static func byte(rms: Float) -> UInt8 {
        UInt8(1 + (min(1, (rms / 0.7).squareRoot()) * 254).rounded())
    }

    /// The share of the song that was heard, from 0 to 1.
    var heard: Double {
        guard !levels.isEmpty else { return 0 }
        return Double(levels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / Double(levels.count)
    }

    var complete: Bool { heard >= 0.97 }

    /// The levels that each stem's bars stretch between. A stem stretches over its own loud parts, but never over less
    /// than half of the loudest stem's, so a stem that is barely in the song stays low instead of filling its lane.
    /// The bleed of other instruments that separation leaves under a stem stays under the quiet end and reads as
    /// silence.
    func stemRanges() -> [Stem: (low: Float, high: Float)] {
        guard let stems else { return [:] }
        let own = stems.compactMap { raw, data in Stem(rawValue: raw).map { ($0, Self.range(of: data)) } }
        let loudest = own.map(\.1.1).max() ?? 255
        return Dictionary(uniqueKeysWithValues: own.map { stem, range in
            let low = max(range.0, Self.bleed)
            return (stem, (low, max(range.1, loudest * 0.5, low + 24)))
        })
    }

    /// The level under which a stem counts as silent: separation leaves a little of the other instruments in each stem.
    static let bleed: Float = 18

    /// `count` bars between `from` and `to` seconds, from 0 to 1, or -1 where nothing was heard. A bar is the average
    /// level under it, stretched between the quiet and the loud parts of the song: songs are mastered loud, and
    /// their loudest moments under each bar would make an even block.
    func bars(_ count: Int, from: Double = 0, to: Double? = nil, stem: Stem? = nil, range: (low: Float, high: Float)? = nil) -> [Float] {
        let data = stem.flatMap { stems?[$0.rawValue] } ?? levels
        guard count > 0, !data.isEmpty else { return [] }
        let to = to ?? duration
        let (low, high) = range ?? (stem == nil ? Self.range(of: data) : stemRanges()[stem!] ?? Self.range(of: data))
        // A stem goes down to nothing where it is silent, and the whole song keeps a little height everywhere.
        let floor: Float = stem == nil ? 0.06 : 0
        return data.withUnsafeBytes { raw -> [Float] in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (0 ..< count).map { i in
                let a = Int(((from + (to - from) * Double(i) / Double(count)) * Self.rate).rounded(.down))
                let b = max(a + 1, Int(((from + (to - from) * Double(i + 1) / Double(count)) * Self.rate).rounded(.down)))
                guard a < bytes.count, b > 0 else { return -1 }
                var sum = 0, heard = 0, loudest: UInt8 = 0
                for j in max(0, a) ..< min(b, bytes.count) where bytes[j] > 0 {
                    sum += Int(bytes[j])
                    heard += 1
                    loudest = max(loudest, bytes[j])
                }
                guard heard > 0 else { return -1 }
                // Mostly the average, with a little of the loudest moment, so a short hit still shows.
                let level = 0.8 * Float(sum) / Float(heard) + 0.2 * Float(loudest)
                let stretched = min(1, max(0, (level - low) / max(1, high - low)))
                return floor + (1 - floor) * pow(stretched, 1.25)
            }
        }
    }

    /// The quiet and the loud ends of the heard levels: the 3rd and the 99.5th percentile.
    private static func range(of data: Data) -> (Float, Float) {
        var histogram = [Int](repeating: 0, count: 256)
        var heard = 0
        for byte in data where byte > 0 {
            histogram[Int(byte)] += 1
            heard += 1
        }
        guard heard > 0 else { return (1, 255) }
        func percentile(_ p: Double) -> Float {
            let target = Int(Double(heard) * p)
            var seen = 0
            for (level, n) in histogram.enumerated() {
                seen += n
                if seen > target { return Float(level) }
            }
            return 255
        }
        let low = percentile(0.03), high = percentile(0.995)
        // A song that is almost one level throughout keeps some height instead of a stretch of noise.
        return (min(low, high - 24), high)
    }
}

/// Reads the waveform of a file, and of its stems once they were separated for the whole song.
enum WaveformReader {
    /// The levels of the audio in `url`, read at 11 kHz mono, which is enough for 20 ms levels and quick: a
    /// four-minute song reads in a fraction of a second.
    static func read(_ url: URL) async -> SongWaveform? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let length = try? await asset.load(.duration), length.seconds.isFinite, length.seconds > 0,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let rate = 11025.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var accumulator = LevelAccumulator(duration: length.seconds, sampleRate: rate)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var size = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &size, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: size / 4) { accumulator.add($0, count: size / 4) }
        }
        guard reader.status == .completed else { return nil }
        return accumulator.finish()
    }

    /// The levels of each stem in the stems of a whole song, from both channels.
    static func stems(_ cache: StemsCache) -> [Int: Data] {
        let per = Double(StemsCache.rate) / SongWaveform.rate
        let slots = Int((Double(cache.frames) / per).rounded(.up))
        var rows: [Int: Data] = [:]
        var buffer = [Float](repeating: 0, count: Int(per.rounded(.up)) * 2 + 2)
        for stem in Stem.allCases {
            var row = Data(count: slots)
            row.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: UInt8.self)
                for slot in 0 ..< slots {
                    let a = Int(Double(slot) * per), b = min(cache.frames, Int(Double(slot + 1) * per))
                    guard b > a else { out[slot] = 1; continue }
                    let count = b - a
                    buffer.withUnsafeMutableBufferPointer { cache.copy([stem.rawValue * 2, stem.rawValue * 2 + 1], from: a, count: count, into: $0.baseAddress!) }
                    var squares: Float = 0
                    vDSP_svesq(buffer, 1, &squares, vDSP_Length(count * 2))
                    out[slot] = SongWaveform.byte(rms: (squares / Float(count * 2)).squareRoot())
                }
            }
            rows[stem.rawValue] = row
        }
        return rows
    }
}

/// Turns samples into 20 ms levels.
struct LevelAccumulator {
    private(set) var waveform: SongWaveform
    private let perSlot: Double
    private var slot = 0
    private var filled = 0
    private var squares: Float = 0

    init(duration: Double, sampleRate: Double) {
        waveform = SongWaveform(duration: duration)
        perSlot = sampleRate / SongWaveform.rate
    }

    mutating func add(_ samples: UnsafePointer<Float>, count: Int) {
        var offset = 0
        let slots = waveform.levels.count
        while offset < count, slot < slots {
            let take = min(count - offset, Int(perSlot) - filled)
            var sum: Float = 0
            vDSP_svesq(samples + offset, 1, &sum, vDSP_Length(take))
            squares += sum
            filled += take
            offset += take
            if filled >= Int(perSlot) {
                waveform.levels[slot] = SongWaveform.byte(rms: (squares / Float(filled)).squareRoot())
                slot += 1
                filled = 0
                squares = 0
            }
        }
    }

    mutating func finish() -> SongWaveform {
        if filled > 0, slot < waveform.levels.count { waveform.levels[slot] = SongWaveform.byte(rms: (squares / Float(filled)).squareRoot()) }
        // The file can end a little before the length that its header gives: the slots after its end are silent.
        for i in slot ..< waveform.levels.count where waveform.levels[i] == 0 { waveform.levels[i] = 1 }
        return waveform
    }
}

/// Draws the waveform of a song from another player while it plays, from the audio that Muskey hears. Each moment
/// lands at the place that the player reports for it, so a seek or a pause leaves the rest of the song as it was.
/// Thread safe: samples arrive on the tap's queue, and the main thread reads what was drawn.
final class WaveformRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var waveform: SongWaveform
    private var position: (seconds: Double, at: Double, rate: Double, playing: Bool)?
    private var tap: AudioTapping?
    private var changed = false
    /// The last 20 seconds heard, for snapping the ends of the region loop, and the song's place at its newest sample.
    private var ring: [Float] = []
    private var ringNext = 0
    private var ringFilled = 0
    private var ringEnd: (seconds: Double, rate: Double, sampleRate: Double)?
    /// The song as heard since the recorder started, mono and 16-bit at the tap's rate, each moment at its place in the
    /// song, for transcribing its notes. It stays in memory, and what wasn't heard stays silent.
    private var capture: [Int16] = []
    private var captureRate = 0.0
    /// The slots of the waveform that the capture holds.
    private var captured: [Bool] = []
    private var capturedCount = 0
    /// Longer songs aren't kept, since the capture of an hour would take hundreds of megabytes.
    static let captureLimit = 20 * 60.0
    let song: [String?]
    /// Where the waveform is kept between plays.
    let key: String
    var running: Bool { tap != nil }

    init(song: [String?], key: String, waveform: SongWaveform) {
        self.song = song
        self.key = key
        self.waveform = waveform
    }

    /// The player's last report: where the song was at `at` (seconds since 1970), and how fast it moves.
    func report(_ track: NowPlaying.Track) {
        lock.withLock {
            if let elapsed = track.elapsed {
                position = (elapsed, track.timestamp ?? Date().timeIntervalSince1970, track.rate ?? 0, track.playing)
            }
        }
    }

    func start(_ tap: AudioTapping) throws {
        try tap.prepare()
        let rate = tap.sampleRate
        try tap.start { [weak self] samples in self?.add(samples, sampleRate: rate) }
        self.tap = tap
    }

    func stop() {
        tap?.stop()
        tap = nil
    }

    private func keep(_ samples: [Float], end: Double, rate: Double, sampleRate: Double) {
        if ring.isEmpty { ring = [Float](repeating: 0, count: Int(sampleRate * 20)) }
        // A jump in the song, from a seek or a skip, starts the excerpt over, so it never mixes two places.
        if let last = ringEnd, abs(end - Double(samples.count) / sampleRate * rate - last.seconds) > 0.25 { ringFilled = 0 }
        for sample in samples {
            ring[ringNext] = sample
            ringNext = (ringNext + 1) % ring.count
        }
        ringFilled = min(ring.count, ringFilled + samples.count)
        ringEnd = (end, rate, sampleRate)
    }

    /// The audio heard from `from` to `to` seconds of the song, mono at 44.1 kHz, with the song time of its first
    /// sample. What wasn't heard is left out, so the excerpt can start later and end sooner than asked.
    func excerpt(from: Double, to: Double) -> (samples: [Float], start: Double)? {
        let (copied, start, sampleRate) = lock.withLock { () -> ([Float], Double, Double)? in
            guard let end = ringEnd, ringFilled > 0, end.rate > 0 else { return nil }
            let first = end.seconds - Double(ringFilled) / end.sampleRate * end.rate
            let a = max(from, first), b = min(to, end.seconds)
            guard b > a else { return nil }
            let count = Int((b - a) / end.rate * end.sampleRate)
            let back = Int((end.seconds - a) / end.rate * end.sampleRate)
            var out = [Float](repeating: 0, count: count)
            for i in 0 ..< count { out[i] = ring[((ringNext - back + i) % ring.count + ring.count) % ring.count] }
            return (out, a, end.sampleRate / end.rate)
        } ?? ([], 0, 0)
        guard !copied.isEmpty else { return nil }
        return (TempoDetector.resample(copied, from: sampleRate, to: LoopSnap.rate), start)
    }

    /// The song's length, from its waveform.
    var duration: Double { lock.withLock { waveform.duration } }

    /// The capture can hold this song.
    var captures: Bool { duration > 0 && duration <= Self.captureLimit }

    /// The seconds of the song in the capture.
    var capturedSeconds: Double { lock.withLock { Double(capturedCount) / SongWaveform.rate } }

    /// The share of the song in the capture, from 0 to 1.
    var capturedShare: Double { lock.withLock { captured.isEmpty ? 0 : Double(capturedCount) / Double(captured.count) } }

    /// The start of the first moment of the song that the capture doesn't hold, or nil when it holds all of it.
    var firstGap: Double? {
        lock.withLock {
            guard !captured.isEmpty else { return 0 }
            // A few slots missed between two buffers aren't a gap worth playing again.
            var run = 0
            for (slot, held) in captured.enumerated() {
                run = held ? 0 : run + 1
                if run == 10 { return Double(slot - 9) / SongWaveform.rate }
            }
            return nil
        }
    }

    /// Writes the capture to a 16-bit mono WAV file.
    func writeCapture(to url: URL) throws {
        let (samples, rate) = lock.withLock { (capture, captureRate) }
        guard !samples.isEmpty, rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false)
        else { throw SaveError(message: "Nothing of the song was heard") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let part = 1 << 16
        var at = 0
        while at < samples.count {
            let count = min(part, samples.count - at)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.int16ChannelData![0].update(from: source.baseAddress! + at, count: count)
            }
            try file.write(from: buffer)
            at += count
        }
    }

    /// Puts what was heard at its place in the capture. Only a song that plays at its own speed is kept, since a faster
    /// or slower one would land stretched.
    private func keepWhole(_ samples: [Float], start: Double, end: Double, rate: Double, sampleRate: Double) {
        guard abs(rate - 1) < 0.02, waveform.duration > 0, waveform.duration <= Self.captureLimit else { return }
        if capture.isEmpty || captureRate != sampleRate {
            captureRate = sampleRate
            capture = [Int16](repeating: 0, count: Int((waveform.duration * sampleRate).rounded(.up)))
            captured = [Bool](repeating: false, count: waveform.levels.count)
            capturedCount = 0
        }
        let first = Int((start * sampleRate).rounded())
        let from = max(0, -first), to = min(samples.count, capture.count - first)
        guard to > from else { return }
        for i in from ..< to { capture[first + i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        // A slot counts once the capture has the moment in its middle, which falls in exactly one buffer.
        let lowest = max(0, Int((start * SongWaveform.rate - 0.5).rounded(.up)))
        let highest = min(captured.count - 1, Int((end * SongWaveform.rate - 0.5).rounded(.up)) - 1)
        if lowest <= highest {
            for slot in lowest ... highest where !captured[slot] {
                captured[slot] = true
                capturedCount += 1
            }
        }
    }

    /// The slot that the level of the stems was last written to, so that the readings between two slots fill them.
    private var lastStemSlot: Int?

    /// The level of each stem as the stems of the song play, written where the song is heard: the player's place less
    /// the delay of the stems. The levels come 20 times a second and the waveform has 50 slots a second, so the slots
    /// since the last reading get this one, unless the song jumped.
    func addStems(_ levels: [Float], delay: Double) {
        lock.withLock {
            guard let position, position.playing, position.rate > 0 else { return lastStemSlot = nil }
            let now = Date().timeIntervalSince1970
            let heard = position.seconds + (now - position.at - delay) * position.rate
            let count = waveform.levels.count
            let slot = Int((heard * SongWaveform.rate).rounded(.down))
            guard slot >= 0, slot < count else { return lastStemSlot = nil }
            var stems = waveform.stems ?? Dictionary(uniqueKeysWithValues: Stem.allCases.map { ($0.rawValue, Data(count: count)) })
            let from = lastStemSlot.flatMap { ($0 ..< slot).contains($0) && slot - $0 <= 6 ? $0 + 1 : nil } ?? slot
            for stem in Stem.allCases where stem.rawValue < levels.count {
                let byte = SongWaveform.byte(rms: levels[stem.rawValue])
                if stems[stem.rawValue]?.count != count { stems[stem.rawValue] = Data(count: count) }
                stems[stem.rawValue]!.withUnsafeMutableBytes { raw in
                    for i in from ... slot { raw[i] = byte }
                }
            }
            waveform.stems = stems
            lastStemSlot = slot
            changed = true
        }
    }

    /// What was drawn so far, and whether anything changed since the last call.
    func take() -> (waveform: SongWaveform, changed: Bool) {
        lock.withLock {
            defer { changed = false }
            return (waveform, changed)
        }
    }

    private func add(_ samples: [Float], sampleRate: Double) {
        lock.withLock {
            guard let position, position.playing, position.rate > 0, !samples.isEmpty else { return }
            // The samples end now, so they started their length before now, at the song's rate.
            let now = Date().timeIntervalSince1970
            let end = position.seconds + (now - position.at) * position.rate
            let start = end - Double(samples.count) / sampleRate * position.rate
            keep(samples, end: end, rate: position.rate, sampleRate: sampleRate)
            keepWhole(samples, start: start, end: end, rate: position.rate, sampleRate: sampleRate)
            let perSlot = sampleRate / SongWaveform.rate / position.rate
            let slots = waveform.levels.count
            var first = Int((max(0, start) * SongWaveform.rate).rounded(.down))
            var offset = Int(((Double(first) / SongWaveform.rate - start) * sampleRate / position.rate).rounded())
            samples.withUnsafeBufferPointer { buffer in
                while first < slots, offset < buffer.count {
                    let a = max(0, offset), b = min(buffer.count, offset + Int(perSlot))
                    // A slot only partly in this buffer is drawn from what is here, which is close enough at 20 ms.
                    if b - a >= Int(perSlot / 3) {
                        var sum: Float = 0
                        vDSP_svesq(buffer.baseAddress! + a, 1, &sum, vDSP_Length(b - a))
                        let level = SongWaveform.byte(rms: (sum / Float(b - a)).squareRoot())
                        if waveform.levels[first] != level {
                            waveform.levels[first] = level
                            changed = true
                        }
                    }
                    first += 1
                    offset += Int(perSlot)
                }
            }
        }
    }
}

/// Keeps waveforms between plays in `~/Library/Caches/Muskey/Waveforms`: a file's under its path, size and date,
/// and a song from another player under its title, artist, album and length.
enum WaveformStore {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Waveforms")
    }

    static func key(file path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, let date = attributes[.modificationDate] as? Date
        else { return nil }
        return digest(["file", path, "\(size)", "\(date.timeIntervalSince1970)"])
    }

    static func key(song: [String?], duration: Double) -> String {
        digest(["song"] + song.map { $0 ?? "" } + ["\(Int(duration.rounded()))"])
    }

    private static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> SongWaveform? {
        guard let data = try? Data(contentsOf: folder.appending(path: key + ".json")) else { return nil }
        return try? JSONDecoder().decode(SongWaveform.self, from: data)
    }

    static func save(_ waveform: SongWaveform, as key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(waveform) else { return }
        try? data.write(to: folder.appending(path: key + ".json"), options: .atomic)
        trim()
    }

    /// Keeps the 2000 waveforms used most recently, about 25 MB.
    private static func trim() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)), files.count > 2000 else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }.sorted { $0.1 > $1.1 }
        for (file, _) in dated.dropFirst(2000) { try? FileManager.default.removeItem(at: file) }
    }
}
