import Accelerate
import AVFoundation
import CryptoKit
import Foundation

/// The stems of a whole song that Muskey Player plays, separated once in the background and kept on disk, so that a
/// seek or karaoke's start over plays the stems of the new place at once, instead of separating them again as the song
/// plays.
///
/// The file is a header of 64 bytes, then the left and the right channel of each stem one after the other, as 16-bit
/// samples at the model's sample rate. That is about 1.2 MB for each second of song, half of what floats would take,
/// with the noise of the samples about 90 dB under full scale. The scale in the header leaves room for a stem that goes
/// past full scale where it cancels out in the song. The file is mapped into memory and read only by the thread that
/// writes the stems for the output, never by the IOProc, which would stall on a page that isn't in memory.
final class StemsCache: @unchecked Sendable {
    static let rate = StemModel.sampleRate
    static let planes = Stem.allCases.count * 2
    static let headerSize = 64
    private static let magic = Array("MSKSTEMS".utf8)
    /// Changes whenever the samples or the stems change, so that older files are made again.
    static let version: UInt32 = 1
    /// A sample of 32767 is 2.0.
    static let scale: Float = 2.0 / 32767
    /// The most that the folder keeps, the songs played longest ago going first.
    static let limit = 2_000_000_000

    /// `--stems-cache-dir DIR` keeps the stems elsewhere, for testing.
    static var folder: URL {
        if let dir = TestFlags.value("--stems-cache-dir") { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Stems")
    }

    let url: URL
    let frames: Int
    let scale: Float
    private let base: UnsafeMutableRawPointer
    private let length: Int

    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw SaveError(message: "The stems can't be opened") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Int(info.st_size) >= Self.headerSize else { throw SaveError(message: "The stems are cut short") }
        length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), mapped != MAP_FAILED else {
            throw SaveError(message: "The stems can't be mapped")
        }
        base = mapped
        self.url = url
        let header = UnsafeRawBufferPointer(start: mapped, count: Self.headerSize)
        let frames = Int(header.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        self.frames = frames
        scale = header.loadUnaligned(fromByteOffset: 28, as: Float.self)
        guard Array(header[0 ..< 8]) == Self.magic, header.loadUnaligned(fromByteOffset: 8, as: UInt32.self) == Self.version,
              header.loadUnaligned(fromByteOffset: 12, as: UInt32.self) == UInt32(Self.rate),
              header.loadUnaligned(fromByteOffset: 24, as: UInt32.self) == UInt32(Self.planes),
              length == Self.headerSize + Self.planes * frames * 2
        else {
            munmap(mapped, length)
            throw SaveError(message: "The stems were made by another version")
        }
    }

    deinit { munmap(base, length) }

    /// Plane `p`: the left channel of stem `p / 2` for an even `p`, the right one for an odd `p`.
    func plane(_ p: Int) -> UnsafePointer<Int16> {
        UnsafePointer((base + Self.headerSize).assumingMemoryBound(to: Int16.self) + p * frames)
    }

    /// Converts the samples of `planes` from frame `from` on into floats, `count` of each, plane after plane, with
    /// silence before the song's start and after its end.
    func copy(_ planes: [Int], from: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        var scale = self.scale
        for (index, p) in planes.enumerated() {
            let target = out + index * count
            target.initialize(repeating: 0, count: count)
            let lower = max(from, 0), upper = min(from + count, frames)
            guard upper > lower else { continue }
            vDSP_vflt16(plane(p) + lower, 1, target + (lower - from), 1, vDSP_Length(upper - lower))
            vDSP_vsmul(target + (lower - from), 1, &scale, target + (lower - from), 1, vDSP_Length(upper - lower))
        }
    }

    /// The name of the file of the song at `path`: its path, size and date, and the models installed now, since stems
    /// separated by other models don't match the stems of the live separation.
    static func url(for path: String) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, let date = attributes[.modificationDate] as? Date
        else { return nil }
        let models = StemModel.Kind.allCases.filter { StemModel.isInstalled($0) }.map { kind -> String in
            let file = StemModel.url(kind).appending(path: "coremldata.bin").path
            let changed = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
            return "\(kind.file)@\(changed?.timeIntervalSince1970 ?? 0)"
        }
        let identity = ["\(version)", path, "\(size)", "\(date.timeIntervalSince1970)"] + models
        let digest = SHA256.hash(data: Data(identity.joined(separator: "|").utf8))
        return folder.appending(path: digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".stems")
    }

    /// The stems of the song at `path`, when they were separated whole with the models installed now.
    static func open(for path: String) -> StemsCache? {
        guard let url = url(for: path), FileManager.default.fileExists(atPath: url.path), let cache = try? StemsCache(url: url) else { return nil }
        // Used again, so it is the newest for the limit.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return cache
    }

    /// Deletes the stems of the songs that weren't played for `age`, except the ones at `kept`. A build in progress
    /// writes its partial file all the time, so it is never that old.
    static func sweep(olderThan age: TimeInterval, keeping kept: Set<String>) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let deadline = Date().addingTimeInterval(-age)
        var removed = 0
        for file in files where ["stems", "partial"].contains(file.pathExtension) && !kept.contains(file.path) {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < deadline else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes the songs played longest ago until the folder is under its limit, and files that a build left behind.
    static func trim(keeping kept: URL? = nil) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let sized = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            let date = values.contentModificationDate ?? .distantPast
            // A partial file that is a day old belongs to a build that never finished.
            if file.pathExtension == "partial" {
                if date < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: file) }
                return nil
            }
            return file.pathExtension == "stems" ? (file, values.fileSize ?? 0, date) : nil
        }.sorted { $0.2 < $1.2 }
        var total = sized.reduce(0) { $0 + $1.1 }
        for (file, size, _) in sized where total > limit && file != kept {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}

/// Writes the stems of a song into a temporary file next to the cache, a block at a time, which takes the cache's place
/// once it is whole.
final class StemsCacheFile {
    private let url: URL
    private let partial: URL
    private let handle: FileHandle
    let frames: Int
    private var samples: [Int16] = []

    init(url: URL, frames: Int) throws {
        self.url = url
        self.frames = frames
        partial = url.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw SaveError(message: "The stems can't be written") }
        handle = try FileHandle(forWritingTo: partial)
        var header = Data(count: StemsCache.headerSize)
        header.withUnsafeMutableBytes { raw in
            raw.copyBytes(from: Array("MSKSTEMS".utf8))
            raw.storeBytes(of: StemsCache.version, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(StemsCache.rate), toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: UInt64(frames), toByteOffset: 16, as: UInt64.self)
            raw.storeBytes(of: UInt32(StemsCache.planes), toByteOffset: 24, as: UInt32.self)
            raw.storeBytes(of: StemsCache.scale, toByteOffset: 28, as: Float.self)
        }
        try handle.write(contentsOf: header)
        try handle.truncate(atOffset: UInt64(StemsCache.headerSize + StemsCache.planes * frames * 2))
    }

    /// Writes a block of stems, as [stem][channel][frame], from frame `at` of the song on.
    func write(_ block: [[[Float]]], at: Int) throws {
        for (s, stem) in block.enumerated() where s < Stem.allCases.count {
            for (c, channel) in stem.prefix(2).enumerated() {
                let count = min(channel.count, frames - at)
                guard count > 0 else { continue }
                if samples.count < count { samples = [Int16](repeating: 0, count: count) }
                var scale = 1 / StemsCache.scale, low: Float = -32767, high: Float = 32767
                var scaled = [Float](repeating: 0, count: count)
                vDSP_vsmul(channel, 1, &scale, &scaled, 1, vDSP_Length(count))
                vDSP_vclip(scaled, 1, &low, &high, &scaled, 1, vDSP_Length(count))
                vDSP_vfixr16(scaled, 1, &samples, 1, vDSP_Length(count))
                try handle.seek(toOffset: UInt64(StemsCache.headerSize + ((s * 2 + c) * frames + at) * 2))
                try samples.withUnsafeBytes { try handle.write(contentsOf: Data(bytes: $0.baseAddress!, count: count * 2)) }
            }
        }
    }

    func finish() throws {
        try handle.close()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: partial)
    }
}

/// Reads a signal at places between its samples with a Kaiser-windowed sinc, like the one that slows songs from other
/// players down. Above a step of 1 the cutoff falls with the step, so a song read faster than its rate doesn't alias, and
/// the kernel grows with it to keep the same slope.
struct SincReader {
    let step: Double
    let half: Int
    private static let phases = 256
    private let table: [Float]

    var taps: Int { half * 2 }

    init(step: Double) {
        self.step = step
        let scale = min(1, 1 / step)
        half = Int((16 / scale).rounded(.up))
        let taps = half * 2, phases = Self.phases
        let cutoff = 0.97 * scale, beta = 8.0
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1 ..< 30 {
                term *= (x / Double(2 * k)) * (x / Double(2 * k))
                sum += term
            }
            return sum
        }
        var table = [Float](repeating: 0, count: (phases + 1) * taps)
        let width = Double(half)
        for p in 0 ... phases {
            let f = Double(p) / Double(phases)
            for t in 0 ..< taps {
                // Tap t weighs sample `i + t - half + 1` for a read at `i + f`, at distance x from it.
                let x = Double(t - half + 1) - f
                let sinc = abs(x) < 1e-9 ? cutoff : sin(Double.pi * cutoff * x) / (Double.pi * x)
                let window = abs(x) >= width ? 0 : bessel(beta * (1 - (x / width) * (x / width)).squareRoot()) / bessel(beta)
                table[p * taps + t] = Float(sinc * window)
            }
        }
        self.table = table
    }

    /// The first sample that a read from `position` on, `count` values long, weighs, and how many follow it.
    func span(from position: Double, count: Int) -> (first: Int, length: Int) {
        let first = Int(position.rounded(.down)) + 1 - half
        let last = Int((position + Double(max(0, count - 1)) * step).rounded(.down)) + half
        return (first, last - first + 1)
    }

    /// `count` values of each source, from `position` on and `step` apart. Source `s` holds the samples from `origin` on,
    /// `length` of them, and `outs[s]` gets its values.
    func read(_ sources: [UnsafePointer<Float>], origin: Int, length: Int, from position: Double, count: Int,
              into outs: [UnsafeMutablePointer<Float>]) {
        let taps = self.taps, phases = Self.phases
        var weights = [Float](repeating: 0, count: taps)
        table.withUnsafeBufferPointer { kernel in
            weights.withUnsafeMutableBufferPointer { w in
                for j in 0 ..< count {
                    let x = position + Double(j) * step
                    let whole = x.rounded(.down)
                    let scaled = (x - whole) * Double(phases)
                    let p = min(phases - 1, Int(scaled))
                    let mix = Float(scaled - Double(p))
                    let k0 = kernel.baseAddress! + p * taps, k1 = k0 + taps
                    for t in 0 ..< taps { w[t] = k0[t] + (k1[t] - k0[t]) * mix }
                    let first = Int(whole) + 1 - half - origin
                    for (s, source) in sources.enumerated() {
                        var sum: Float = 0
                        if first >= 0, first + taps <= length {
                            vDSP_dotpr(source + first, 1, w.baseAddress!, 1, &sum, vDSP_Length(taps))
                        } else {
                            for t in 0 ..< taps where first + t >= 0 && first + t < length { sum += source[first + t] * w[t] }
                        }
                        outs[s][j] = sum
                    }
                }
            }
        }
    }
}

/// Finds a stretch of the captured song in the song as the cache has it, by normalized correlation: first at an eighth
/// of the rate, then at the full rate around the best few peaks. A song that repeats a bar matches it equally well a bar
/// apart, so a match within a hair of the best that lies nearer to where the song is expected wins.
enum StemsAlign {
    struct Match {
        /// Where the reference starts in the region, between two of its values when the peak of the scores lies there.
        var offset: Double
        var score: Float
    }

    static func find(_ reference: [Float], in region: [Float], prior: Int, threshold: Float) -> Match? {
        let n = reference.count
        guard n > 256, region.count >= n else { return nil }
        let step = 8
        let small = decimate(reference, by: step), wide = decimate(region, by: step)
        guard wide.count >= small.count, let coarse = scores(small, in: wide) else { return nil }
        // The highest peaks of the coarse scores, each a local maximum, a few windows apart.
        let best = coarse.max() ?? 0
        guard best > 0.5 else { return nil }
        var peaks: [Int] = []
        for i in coarse.indices where coarse[i] >= best - 0.15 && (i == 0 || coarse[i] >= coarse[i - 1]) && (i == coarse.count - 1 || coarse[i] >= coarse[i + 1]) {
            peaks.append(i)
        }
        peaks = Array(peaks.sorted { coarse[$0] > coarse[$1] }.prefix(8))
        var matches: [Match] = []
        let radius = step * 3
        for peak in peaks {
            let center = peak * step
            let lower = max(0, center - radius), upper = min(region.count - n, center + radius)
            guard upper >= lower, let fine = scores(reference, in: Array(region[lower ..< upper + n])),
                  let index = fine.indices.max(by: { fine[$0] < fine[$1] }) else { continue }
            // A parabola through the peak and its neighbours places it between two values: a sample of the tap is 20
            // microseconds, which the highest notes of a song turn by a good part of their period.
            var between = 0.0
            if index > 0, index < fine.count - 1 {
                let a = Double(fine[index - 1]), b = Double(fine[index]), c = Double(fine[index + 1])
                let curve = a - 2 * b + c
                if curve < 0 { between = max(-0.5, min(0.5, 0.5 * (a - c) / curve)) }
            }
            matches.append(Match(offset: Double(lower + index) + between, score: fine[index]))
        }
        guard let top = matches.map(\.score).max(), top >= threshold else { return nil }
        return matches.filter { $0.score >= top - 0.003 }.min { abs($0.offset - Double(prior)) < abs($1.offset - Double(prior)) }
    }

    /// The normalized correlation of `reference` with each window of `region`, nil for a silent reference. Windows 40 dB
    /// quieter than the reference score 0.
    private static func scores(_ reference: [Float], in region: [Float]) -> [Float]? {
        let n = reference.count, count = region.count - n + 1
        guard count > 0 else { return nil }
        let energy = Double(vDSP.sumOfSquares(reference))
        guard energy / Double(n) > 1e-8 else { return nil }
        var correlation = [Float](repeating: 0, count: count)
        vDSP_conv(region, 1, reference, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(n))
        var squares = [Float](repeating: 0, count: region.count)
        vDSP_vsq(region, 1, &squares, 1, vDSP_Length(region.count))
        var window = squares[0 ..< n].reduce(0.0) { $0 + Double($1) }
        var out = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            if i > 0 { window += Double(squares[i + n - 1]) - Double(squares[i - 1]) }
            if window > energy * 1e-4 { out[i] = Float(Double(correlation[i]) / (window * energy).squareRoot()) }
        }
        return out
    }

    private static func decimate(_ samples: [Float], by step: Int) -> [Float] {
        let count = samples.count / step
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { s in
            for i in 0 ..< count {
                var sum: Float = 0
                vDSP_sve(s.baseAddress! + i * step, 1, &sum, vDSP_Length(step))
                out[i] = sum / Float(step)
            }
        }
        return out
    }
}

/// What the app tells the writer of cached stems about the song that Muskey Player plays: its cache, its speed, where
/// the player says it is, and where the app moved it. Any thread.
final class StemsFeed: @unchecked Sendable {
    let cache: StemsCache
    let path: String
    private let lock = NSLock()
    private var _speed: Double
    private var _hint: (() -> Double?)?
    private var _seekTarget: Double?
    private var seekAsked = -Double.infinity
    private var _lost = false
    /// Seconds since 1970, the clock of the player's reports; a self-test runs its own.
    private let clock: () -> Double
    /// Where the player last said the song was, at a moment, moving on at a rate: its report, or a move that it made
    /// since, which Now Playing may report seconds later.
    private var place: (seconds: Double, at: Double, rate: Double)?
    private var rate = 0.0

    init(cache: StemsCache, path: String, speed: Double, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.cache = cache
        self.path = path
        self.clock = clock
        _speed = speed
    }

    /// The speed that Muskey Player plays the song at.
    var speed: Double {
        get { lock.withLock { _speed } }
        set { lock.withLock { _speed = newValue } }
    }

    /// Seconds into the song that the player is at now, for finding the song in the cache: from the player's last
    /// report or move, or from `hint` when a self-test sets it.
    var hint: () -> Double? {
        get {
            lock.withLock {
                if let _hint { return _hint }
                let place = place, clock = clock
                return { place.map { $0.seconds + (clock() - $0.at) * $0.rate } }
            }
        }
        set { lock.withLock { _hint = newValue } }
    }

    /// The player's report of the song: where it was, when, and at what rate. A report from before the player's last
    /// move is older than the move.
    func report(elapsed: Double?, timestamp: Double?, rate: Double?) {
        guard let elapsed else { return }
        lock.withLock {
            let at = timestamp ?? clock()
            self.rate = rate ?? 0
            if let place, place.at > at { return }
            self.place = (elapsed, at, self.rate)
        }
    }

    /// The player moved the song to `seconds`, now.
    func moved(to seconds: Double) {
        lock.withLock { place = (seconds, clock(), rate) }
    }

    /// The place that the app moved the song to last, in seconds, set before the move is asked of the shifter.
    var seekTarget: Double? {
        get { lock.withLock { _seekTarget } }
        set {
            lock.withLock {
                _seekTarget = newValue
                seekAsked = clock()
            }
        }
    }

    /// The app asked for a move to `seconds` a moment ago, which the player's own word of the move repeats.
    func asked(_ seconds: Double) -> Bool {
        lock.withLock { _seekTarget.map { abs($0 - seconds) < 0.05 } == true && clock() - seekAsked < 1 }
    }

    /// The cache didn't line up with what the player plays, and the stems are separated as the song plays again.
    var lost: Bool { lock.withLock { _lost } }
    func markLost() { lock.withLock { _lost = true } }
}

/// Writes the stems of one generation from the cache, ahead of the song and lined up with the captured frames. It finds
/// where the song is in the cache by correlation, first around where the player says it is or where the app moved it,
/// then checks every half second that the song is still where it expects. It answers the moves that the app asks for,
/// writes the stems again after a pause, and gives up when the song can't be found for 3 seconds. `step()` runs one
/// round, on the separation thread, or in a self-test between two calls of the IOProc.
final class CachedStemsWriter {
    enum Outcome { case going, lost }

    /// Captured frame `frame` is at `position` in the cache, in frames of the cache, and each captured frame moves it on
    /// by `step`.
    struct Mapping {
        var frame: UInt64
        var position: Double
        var step: Double

        func position(of other: UInt64) -> Double {
            position + (other >= frame ? Double(other - frame) : -Double(frame - other)) * step
        }
    }

    /// A mapping that holds from captured frame `from` on, crossfaded over `fade` frames from the one before.
    private struct Span {
        var from: UInt64
        var mapping: Mapping
        var fade: Int
    }

    let generation: UInt64
    let start: UInt64
    private let shifter: OpaquePointer
    private let rate: Double
    private let feed: StemsFeed
    private var spans: [Span] = []
    private var written: UInt64
    private var skipsSeen: UInt32
    private var seeksSeen: UInt32
    private var seek: (number: UInt32, target: Double?, since: UInt64)?
    private var speed: Double
    private var speedSince: UInt64?
    private var nextCheck: UInt64 = 0
    private var lastTried: UInt64 = 0
    private var unmatchedSince: UInt64?
    private var readers: [Double: SincReader] = [:]
    /// The answer to a move, given once the stems of the new place are written.
    private var answer: (number: UInt32, from: UInt64)?
    /// The pauses mapped so far, told to the shifter once the stems from where the song carries on are written.
    private var mapped: (skips: UInt32, from: UInt64)?
    var log: (String) -> Void = { _ in }

    /// How much of the song a search compares, how far ahead the stems are written, and how often they are checked.
    private let reference: Int, ahead: UInt64, refill: UInt64, checkEvery: UInt64

    init(shifter: OpaquePointer, rate: Double, feed: StemsFeed, generation: UInt64, start: UInt64) {
        self.shifter = shifter
        self.rate = rate
        self.feed = feed
        self.generation = generation
        self.start = start
        written = start
        speed = feed.speed
        reference = Int(rate * 0.1)
        ahead = UInt64(rate * 1.0)
        refill = UInt64(rate * 0.6)
        checkEvery = UInt64(rate * 0.5)
        var from: UInt64 = 0, to: UInt64 = 0
        skipsSeen = ps_stems_skips(shifter, &from, &to)
        // A move asked for before this generation began is still to be found.
        var answered: UInt32 = 0
        _ = ps_stems_seeks(shifter, &answered)
        seeksSeen = answered
    }

    /// Where captured frame `frame` is in the cache, once the song was found.
    func position(of frame: UInt64) -> Double? { span(at: frame)?.mapping.position(of: frame) }

    var locked: Bool { !spans.isEmpty }

    private var cacheStep: Double { speed * StemsCache.rate / rate }

    func step() -> Outcome {
        let now = ps_captured_written(shifter)
        takeSkips()
        takeSeeks(now)
        if feed.speed != speed {
            speed = feed.speed
            speedSince = now
        }
        if align(now) == .lost { return .lost }
        writeAhead(now)
        // The output reads the stems of the new place once they are written, and not before.
        if let answer, written > answer.from {
            ps_stems_seek_answer(shifter, answer.number, answer.from)
            self.answer = nil
        }
        if let mapped, written > mapped.from {
            ps_stems_skip_mapped(shifter, mapped.skips)
            self.mapped = nil
        }
        return .going
    }

    // MARK: Following the song

    /// A pause left out the silence of the captured song, and the song carries on from where it stopped: the stems
    /// written for after it are written again, and the output may read them once they are.
    private func takeSkips() {
        var from: UInt64 = 0, to: UInt64 = 0
        let skips = ps_stems_skips(shifter, &from, &to)
        guard skips != skipsSeen else { return }
        let next = skips == skipsSeen &+ 1
        skipsSeen = skips
        // Nothing to write again: the output may read on at once, or once the stems of a pause before are written.
        var mappedNow = true
        defer {
            if mappedNow {
                if mapped == nil { ps_stems_skip_mapped(shifter, skips) } else { mapped?.skips = skips }
            }
        }
        // A pause that started with the song's silence left nothing out.
        guard let span = span(at: from), to != from || !next else { return }
        guard next, to > from else {
            // Pauses came faster than they were read, so where the song carries on is found again in silence.
            log("cached stems: pauses came too fast, finding the song again")
            seek = (ps_stems_seek(shifter), nil, ps_captured_written(shifter))
            return
        }
        let mapping = Mapping(frame: to, position: span.mapping.position(of: from), step: span.mapping.step)
        let at = ps_stems_rewrite(shifter, generation, to, 0)
        guard at > 0 else { return }
        place(Span(from: to, mapping: mapping, fade: 0), writingFrom: at)
        mapped = (skips, to)
        mappedNow = false
    }

    private func takeSeeks(_ now: UInt64) {
        var answered: UInt32 = 0
        let asked = ps_stems_seeks(shifter, &answered)
        guard asked != seeksSeen, asked != seek?.number else { return }
        // The player takes the move after it was asked for, a moment before this round at most.
        seek = (asked, feed.seekTarget, now - min(now, UInt64(rate * 0.05)))
    }

    private enum Found { case none, going, lost }

    private func align(_ now: UInt64) -> Found {
        let due = spans.isEmpty || seek != nil || speedSince != nil || now >= nextCheck
        let length = UInt64(reference)
        // A search that keeps failing runs every 50 ms rather than with every callback, since its region grows with
        // the time that a move takes.
        let gap = unmatchedSince.map { now - $0 > UInt64(rate * 0.5) } == true ? UInt64(rate * 0.05) : 1
        guard due, now >= lastTried + gap, now >= start + length else { return .none }
        lastTried = now
        let from = now - length
        guard let heard = captured(from: from) else { return .none }

        if let pending = seek {
            let elapsed = Double(from - min(from, pending.since))
            if let target = pending.target {
                // The move lands after it was asked for: the stretch heard starts at the target at the earliest, and
                // later by as long as the player took.
                let at = target * StemsCache.rate
                if let found = search(heard, from: at - 0.05 * StemsCache.rate, to: at + elapsed * cacheStep + 0.05 * StemsCache.rate,
                                      prior: at, step: cacheStep, threshold: 0.97) {
                    moved(to: Mapping(frame: from, position: found, step: cacheStep), now: now, seek: pending.number)
                    return .going
                }
            }
            // A player that took no move, or no target: where the player says it is.
            if pending.target == nil || elapsed > rate * 2.5, let found = searchHint(heard, now: now) {
                moved(to: Mapping(frame: from, position: found, step: cacheStep), now: now, seek: pending.number)
                return .going
            }
            return unmatched(from, now: now)
        }
        guard let span = span(at: from) else {
            guard let found = searchHint(heard, now: now) else { return unmatched(from, now: now) }
            log(String(format: "cached stems: the song is %.2f s in", found / StemsCache.rate))
            let mapping = Mapping(frame: from, position: found, step: cacheStep)
            let at = ps_stems_rewrite(shifter, generation, start, 0)
            guard at > 0 else { return .none }
            spans = []
            place(Span(from: start, mapping: mapping, fade: 0), writingFrom: at)
            nextCheck = now + checkEvery
            unmatchedSince = nil
            return .going
        }

        // A check where the song is expected, at the speed that it plays now.
        let expected = span.mapping.position(of: from)
        let step = speedSince == nil ? span.mapping.step : cacheStep
        let radius = 0.06 * StemsCache.rate
        guard let found = search(heard, from: expected - radius, to: expected + radius, prior: expected, step: step, threshold: 0.9) else {
            // The player may not play at the new speed yet.
            if let since = speedSince, now - since > UInt64(rate) { speedSince = nil }
            // The song moved without the app asking, as with Control Center's scrubber: the player says where to.
            guard let moved = searchHint(heard, now: now) else { return unmatched(from, now: now) }
            let mapping = Mapping(frame: from, position: moved, step: cacheStep)
            if abs(moved - expected) > 0.25 * StemsCache.rate {
                self.moved(to: mapping, now: now, seek: ps_stems_seek(shifter))
            } else {
                log(String(format: "cached stems: %.0f ms off", (moved - expected) / StemsCache.rate * 1000))
                let at = ps_stems_rewrite(shifter, generation, from, UInt64(rate * 0.15))
                if at > 0 { place(Span(from: at, mapping: mapping, fade: Int(rate * 0.01)), writingFrom: at) }
                unmatchedSince = nil
                nextCheck = now + checkEvery
            }
            return .going
        }
        unmatchedSince = nil
        nextCheck = now + checkEvery
        if let since = speedSince, step != span.mapping.step || now - since > UInt64(rate) { speedSince = nil }
        let drift = found - expected
        guard abs(drift) > 2 * step || step != span.mapping.step else { return .going }
        // Off by a little: the tap dropped some audio, the player drifted, or it plays at another speed now. The stems
        // cross over to where the song is, a little ahead of the output.
        log(String(format: "cached stems: %.1f ms off, at %.0f%% speed", drift / StemsCache.rate * 1000, step / (StemsCache.rate / rate) * 100))
        let mapping = Mapping(frame: from, position: found, step: step)
        let at = ps_stems_rewrite(shifter, generation, from, UInt64(rate * 0.15))
        if at > 0 { place(Span(from: at, mapping: mapping, fade: Int(rate * 0.01)), writingFrom: at) }
        return .going
    }

    /// The song was found where the app moved it: the stems of the new place are written from just ahead of the output,
    /// which stays silent until it gets there.
    private func moved(to mapping: Mapping, now: UInt64, seek number: UInt32) {
        log(String(format: "cached stems: moved to %.2f s", mapping.position / StemsCache.rate))
        seek = nil
        seeksSeen = number
        unmatchedSince = nil
        nextCheck = now + checkEvery
        guard !spans.isEmpty, ps_stems_started(shifter) != 0 else {
            // Nothing plays yet: the stems start at the moment that plays, once they are written past it.
            let at = ps_stems_rewrite(shifter, generation, start, 0)
            guard at > 0 else { return }
            spans = []
            place(Span(from: start, mapping: mapping, fade: 0), writingFrom: at)
            answer = (number, max(start, now))
            return
        }
        // The output is silent until it gets there, so it may read on through the stems taken back meanwhile.
        let at = ps_stems_rewrite(shifter, generation, mapping.frame, UInt64(rate * 0.01))
        guard at > 0 else { return }
        place(Span(from: at, mapping: mapping, fade: 0), writingFrom: at)
        answer = (number, at)
    }

    /// Nothing matched. Silence and other sounds can hide the song for a while, but after 3 seconds the cache counts as
    /// not lining up with what the player plays.
    private func unmatched(_ from: UInt64, now: UInt64) -> Found {
        let since = unmatchedSince ?? from
        unmatchedSince = since
        guard now - since > UInt64(rate * 3) else { return .none }
        log("cached stems: the song isn't where the cache has it, separating it as it plays")
        return .lost
    }

    /// Adds a span, and carries on writing from `at`, where the shifter's stems were taken back to.
    private func place(_ span: Span, writingFrom at: UInt64) {
        spans.removeAll { $0.from >= span.from }
        spans.append(span)
        written = at
        // Spans that the output left behind long ago aren't needed for a pause or a crossfade.
        let played = ps_stems_played(shifter)
        while spans.count > 2, spans[1].from + UInt64(rate * 5) < played { spans.removeFirst() }
    }

    private func span(at frame: UInt64) -> Span? {
        spans.last { $0.from <= frame } ?? spans.first
    }

    // MARK: Searching

    private func searchHint(_ heard: [Float], now: UInt64) -> Double? {
        guard let hint = feed.hint() else { return nil }
        // The hint is the moment that plays, and the stretch heard ends there.
        let at = hint * StemsCache.rate - Double(reference) * cacheStep
        let radius = 1.5 * StemsCache.rate
        return search(heard, from: at - radius, to: at + radius, prior: at, step: cacheStep, threshold: 0.97)
    }

    /// Where in the cache, between `from` and `to`, the stretch `heard` starts, read at `step`.
    private func search(_ heard: [Float], from: Double, to: Double, prior: Double, step: Double, threshold: Float) -> Double? {
        let lower = max(from, -Double(reference) * step), upper = min(to, Double(feed.cache.frames))
        guard upper > lower else { return nil }
        let count = Int((upper - lower) / step) + heard.count + 1
        let region = render(mixFrom: lower, step: step, count: count)
        guard let match = StemsAlign.find(heard, in: region, prior: Int(((prior - lower) / step).rounded()), threshold: threshold) else { return nil }
        return lower + match.offset * step
    }

    /// The captured song from `from` on, as long as the reference, both channels averaged; nil when any quarter of it is
    /// silent. A stretch that is mostly the silence of a move or a pause matches the start of any note that follows a
    /// quiet moment, all through the song.
    private func captured(from: UInt64) -> [Float]? {
        var left = [Float](repeating: 0, count: reference), right = left
        var at = from
        let got = ps_captured_read(shifter, &at, &left, &right, reference)
        guard got == reference, at == from + UInt64(reference) else { return nil }
        var mono = [Float](repeating: 0, count: reference)
        vDSP_vasm(left, 1, right, 1, [0.5], &mono, 1, vDSP_Length(reference))
        let quarter = reference / 4
        for part in 0 ..< 4 where vDSP.sumOfSquares(mono[part * quarter ..< (part + 1) * quarter]) / Float(quarter) < 1e-7 { return nil }
        return mono
    }

    private func reader(_ step: Double) -> SincReader {
        if let reader = readers[step] { return reader }
        let reader = SincReader(step: step)
        readers[step] = reader
        return reader
    }

    /// The whole song as the cache has it, both channels of every stem added up and averaged, `count` values from
    /// `position` on, `step` apart.
    private func render(mixFrom position: Double, step: Double, count: Int) -> [Float] {
        let reader = reader(step)
        let span = reader.span(from: position, count: count)
        let planes = Array(0 ..< StemsCache.planes)
        var samples = [Float](repeating: 0, count: span.length * planes.count)
        var mono = [Float](repeating: 0, count: span.length)
        samples.withUnsafeMutableBufferPointer { s in
            feed.cache.copy(planes, from: span.first, count: span.length, into: s.baseAddress!)
            for p in planes { vDSP_vadd(mono, 1, s.baseAddress! + p * span.length, 1, &mono, 1, vDSP_Length(span.length)) }
        }
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(span.length))
        var out = [Float](repeating: 0, count: count)
        mono.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                reader.read([m.baseAddress!], origin: span.first, length: span.length, from: position, count: count, into: [o.baseAddress!])
            }
        }
        return out
    }

    // MARK: Writing

    /// Keeps the stems written about a second ahead of the song, as far as the output leaves room.
    private func writeAhead(_ now: UInt64) {
        guard !spans.isEmpty, written < now + refill else { return }
        let room = UInt64(ps_stems_room(shifter, written))
        let target = min(now + ahead, written + room)
        let block = 4096
        while written < target {
            let count = Int(min(UInt64(block), target - written))
            let planes = renderStems(from: written, count: count)
            planes.withUnsafeBufferPointer { buffer in
                let pointers: [UnsafePointer<Float>?] = (0 ..< StemsCache.planes).map { buffer.baseAddress! + $0 * count }
                pointers.withUnsafeBufferPointer { ps_stems_write(shifter, $0.baseAddress!, count) }
            }
            written += UInt64(count)
        }
    }

    /// The stems of captured frames `from` to `from + count`, plane after plane, each from the span that holds it, and
    /// crossfaded from the span before over the start of a span that fades in.
    private func renderStems(from: UInt64, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * StemsCache.planes)
        var done = 0
        while done < count {
            let frame = from + UInt64(done)
            guard let index = spans.lastIndex(where: { $0.from <= frame }) ?? (spans.isEmpty ? nil : 0) else { break }
            let span = spans[index]
            // Up to the next span.
            let end = index + 1 < spans.count ? min(count, Int(spans[index + 1].from - from)) : count
            let length = max(1, end - done)
            let part = stems(span.mapping, from: frame, count: length)
            let fading = index > 0 && span.fade > 0 && frame < span.from + UInt64(span.fade)
            let before = fading ? stems(spans[index - 1].mapping, from: frame, count: length) : []
            for p in 0 ..< StemsCache.planes {
                for j in 0 ..< length {
                    var value = part[p * length + j]
                    if fading {
                        let x = min(1, Float(frame + UInt64(j) - span.from) / Float(span.fade))
                        value = before[p * length + j] * (1 - x) + value * x
                    }
                    out[p * count + done + j] = value
                }
            }
            done += length
        }
        return out
    }

    private func stems(_ mapping: Mapping, from frame: UInt64, count: Int) -> [Float] {
        let reader = reader(mapping.step)
        let position = mapping.position(of: frame)
        let span = reader.span(from: position, count: count)
        let planes = Array(0 ..< StemsCache.planes)
        var samples = [Float](repeating: 0, count: span.length * planes.count)
        var out = [Float](repeating: 0, count: count * planes.count)
        samples.withUnsafeMutableBufferPointer { s in
            feed.cache.copy(planes, from: span.first, count: span.length, into: s.baseAddress!)
            out.withUnsafeMutableBufferPointer { o in
                reader.read(planes.map { UnsafePointer(s.baseAddress! + $0 * span.length) }, origin: span.first, length: span.length,
                            from: position, count: count, into: planes.map { o.baseAddress! + $0 * count })
            }
        }
        return out
    }
}

/// Separates the whole song that Muskey Player plays into the cache, in the background and one song at a time, the first
/// time that its stems are used. Main thread only, apart from the separation itself.
final class StemsCacheBuilder {
    var log: (String) -> Void = { _ in }
    /// The stems are separated for the output too, and come first: any thread.
    var live: () -> Bool = { false }
    /// The song at the path has its stems in the cache, or they couldn't be separated.
    var onDone: (String, Bool) -> Void = { _, _ in }
    /// The part of the song separated so far, from 0 to 1: any thread.
    var progress: (Double) -> Void = { _ in }
    /// The song being separated.
    private(set) var path: String?
    private var job: Job?

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var cancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }

    func start(_ path: String) {
        guard self.path != path, let url = StemsCache.url(for: path) else { return }
        cancel()
        self.path = path
        let job = Job()
        self.job = job
        let live = live, log = log, progress = progress
        log("stems cache: separating the whole song")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let began = Date()
            var ok = false
            do {
                try Self.build(path, to: url, live: live, progress: progress) { !job.cancelled }
                ok = true
                log(String(format: "stems cache: the whole song separated in %.1f s", Date().timeIntervalSince(began)))
            } catch is CancellationError {
                log("stems cache: stopped")
            } catch {
                log("stems cache: separating the whole song failed: \(error)")
            }
            DispatchQueue.main.async {
                guard let self, self.job === job else { return }
                self.job = nil
                self.path = nil
                self.onDone(path, ok)
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        path = nil
    }

    /// Reads the song a part at a time, at the model's rate, separates it, and writes its stems to the cache.
    static func build(_ path: String, to url: URL, live: () -> Bool, progress: (Double) -> Void = { _ in }, going: () -> Bool) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let frames = Int((Double(file.length) * StemsCache.rate / format.sampleRate).rounded())
        let part: AVAudioFrameCount = 65536
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: part) else {
            throw SaveError(message: "The song is empty")
        }
        let resampler = format.sampleRate == StemsCache.rate ? nil : Resampler(from: format.sampleRate, to: StemsCache.rate)
        let out = try StemsCacheFile(url: url, frames: frames)
        var pending: [[Float]] = [[], []]
        var at = 0
        do {
            try SongRender.separate(frames: frames, read: { count in
                while pending[0].count < count, file.framePosition < file.length {
                    try file.read(into: buffer, frameCount: part)
                    let n = Int(buffer.frameLength)
                    guard n > 0, let data = buffer.floatChannelData else { break }
                    let left = Array(UnsafeBufferPointer(start: data[0], count: n))
                    let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : left
                    let converted = resampler?.convert(left[...], right[...]) ?? [left, right]
                    pending[0] += converted[0]
                    pending[1] += converted[1]
                }
                guard !pending[0].isEmpty else { return nil }
                let n = min(count, pending[0].count)
                defer { pending = pending.map { Array($0.dropFirst(n)) } }
                return pending.map { Array($0.prefix(n)) }
            }, live: live, progress: { fraction in
                progress(fraction)
                return going()
            }, take: { block in
                try out.write(block, at: at)
                at += block[0][0].count
            })
            try out.finish()
        } catch {
            out.discard()
            throw error
        }
        StemsCache.trim(keeping: url)
    }
}
