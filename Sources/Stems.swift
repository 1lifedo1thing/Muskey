import Accelerate
import AVFoundation
import CoreML
import Foundation

/// The parts of a song that the separation model gives back, in the model's order, then the winds that the winds
/// model finds in the song.
enum Stem: Int, CaseIterable, Sendable {
    case bass, drums, other, vocals, guitar, piano, winds

    var name: String {
        switch self {
        case .bass: "Bass"
        case .drums: "Drums"
        case .other: "Other"
        case .vocals: "Vocals"
        case .guitar: "Guitar"
        case .piano: "Piano"
        case .winds: "Winds"
        }
    }

    /// The order of the stems in the HUD. Winds are there while the winds model is installed.
    static var shown: [Stem] {
        StemModel.isInstalled(.winds) ? [.vocals, .drums, .bass, .guitar, .piano, .winds, .other]
            : [.vocals, .drums, .bass, .guitar, .piano, .other]
    }
}

/// STFT and inverse STFT the way `torch.stft` and `torch.istft` work with `center=True`: the signal is padded by
/// half a window on each side with its reflection, and each frame goes through a periodic Hann window.
struct Spectrogram {
    static let size = 2048
    static let hop = 512
    static let bins = size / 2 + 1

    private let window: [Float]
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup

    init() {
        window = (0 ..< Self.size).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(Self.size)) }
        forwardSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)!
        inverseSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .INVERSE)!
    }

    static func frames(for samples: Int) -> Int { 1 + samples / hop }

    /// The bins of each frame of `signal`, real and imaginary parts, frame after frame.
    func forward(_ signal: [Float]) -> (real: [Float], imaginary: [Float]) {
        let n = Self.size, half = n / 2, count = signal.count
        var padded = [Float](repeating: 0, count: count + n)
        for i in 0 ..< count { padded[half + i] = signal[i] }
        for i in 0 ..< half {
            padded[half - 1 - i] = signal[min(count - 1, i + 1)]
            padded[half + count + i] = signal[max(0, count - 2 - i)]
        }
        let frames = Self.frames(for: count)
        var real = [Float](repeating: 0, count: frames * Self.bins)
        var imaginary = [Float](repeating: 0, count: frames * Self.bins)
        var inReal = [Float](repeating: 0, count: n), inImaginary = [Float](repeating: 0, count: n)
        var outReal = [Float](repeating: 0, count: n), outImaginary = [Float](repeating: 0, count: n)
        for frame in 0 ..< frames {
            padded.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + frame * Self.hop, 1, window, 1, &inReal, 1, vDSP_Length(n))
            }
            vDSP_DFT_Execute(forwardSetup, inReal, inImaginary, &outReal, &outImaginary)
            real.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: frame * Self.bins).update(from: outReal, count: Self.bins) }
            imaginary.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: frame * Self.bins).update(from: outImaginary, count: Self.bins) }
        }
        return (real, imaginary)
    }

    /// The signal of `length` samples back from its bins, as `torch.istft` does: the windowed frames overlap and add,
    /// divided by the sum of the squared windows.
    func inverse(real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>, frames: Int, length: Int) -> [Float] {
        let n = Self.size, half = n / 2, bins = Self.bins
        var sum = [Float](repeating: 0, count: (frames - 1) * Self.hop + n)
        var envelope = [Float](repeating: 0, count: sum.count)
        var inReal = [Float](repeating: 0, count: n), inImaginary = [Float](repeating: 0, count: n)
        var outReal = [Float](repeating: 0, count: n), outImaginary = [Float](repeating: 0, count: n)
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(window, 1, &squared, 1, vDSP_Length(n))
        var scale = 1 / Float(n)
        for frame in 0 ..< frames {
            let re = real + frame * bins, im = imaginary + frame * bins
            for k in 0 ..< bins {
                inReal[k] = re[k]
                inImaginary[k] = im[k]
            }
            // A real signal's spectrum mirrors itself, and the first and last bins carry no imaginary part.
            inImaginary[0] = 0
            inImaginary[half] = 0
            for k in 1 ..< half {
                inReal[n - k] = re[k]
                inImaginary[n - k] = -im[k]
            }
            vDSP_DFT_Execute(inverseSetup, inReal, inImaginary, &outReal, &outImaginary)
            vDSP_vsmul(outReal, 1, &scale, &outReal, 1, vDSP_Length(n))
            vDSP_vmul(outReal, 1, window, 1, &outReal, 1, vDSP_Length(n))
            sum.withUnsafeMutableBufferPointer { s in
                let at = s.baseAddress! + frame * Self.hop
                vDSP_vadd(at, 1, outReal, 1, at, 1, vDSP_Length(n))
            }
            envelope.withUnsafeMutableBufferPointer { e in
                let at = e.baseAddress! + frame * Self.hop
                vDSP_vadd(at, 1, squared, 1, at, 1, vDSP_Length(n))
            }
        }
        var signal = [Float](repeating: 0, count: length)
        for i in 0 ..< length where half + i < sum.count {
            let e = envelope[half + i]
            signal[i] = e > 1e-11 ? sum[half + i] / e : sum[half + i]
        }
        return signal
    }
}

/// A stem separation model, converted to Core ML, which gives stems of a stereo song at 44.1 kHz. Muskey doesn't come
/// with them; they are downloaded on demand into Application Support.
/// - `stems`: BS-Roformer-SW, which gives bass, drums, other, vocals, guitar and piano.
/// - `winds`: the woodwind and brass heads of MVSep's 53-stem BS-RoFormer, which find the winds in the song.
final class StemModel: @unchecked Sendable {
    enum Kind: CaseIterable, Sendable {
        case stems, winds

        var file: String {
            switch self {
            case .stems: "BSRoformerSW-388"
            case .winds: "BSRoformerWinds-388"
            }
        }
    }

    static let sampleRate = 44100.0
    /// The models run on a fixed number of frames: about 4.5 seconds.
    static let frames = 388
    static let chunk = (frames - 1) * Spectrogram.hop

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Muskey/Models")
    }

    static func url(_ kind: Kind) -> URL { folder.appending(path: "\(kind.file).mlmodelc") }
    static func isInstalled(_ kind: Kind) -> Bool { FileManager.default.fileExists(atPath: url(kind).appending(path: "coremldata.bin").path) }
    static var url: URL { url(.stems) }
    static var installed: Bool { isInstalled(.stems) }

    let kind: Kind
    private let model: MLModel
    private let spectrogram = Spectrogram()
    /// Where a window that had to be separated again is told of.
    nonisolated(unsafe) static var log: (String) -> Void = { _ in }

    private static let cacheLock = NSLock()
    private static var cached: [Kind: StemModel] = [:]
    private static var warming = false
    private static var ran: Set<Kind> = []

    static var chunkSeconds: Double { Double(chunk) / sampleRate }

    /// Core ML has run each installed model once since it was loaded, so the next window takes its usual time.
    static var prepared: Bool {
        let wanted = Kind.allCases.filter { isInstalled($0) }
        return cacheLock.withLock { wanted.allSatisfy { ran.contains($0) && cached[$0] != nil } }
    }

    /// The model, loaded once and kept until `unload()`. Core ML prepares the GPU on the first run, which takes a few
    /// seconds, so the stems would start that much later without `warmUp()`.
    static func shared(_ kind: Kind = .stems) throws -> StemModel {
        if let model = cacheLock.withLock({ cached[kind] }) { return model }
        // Loading takes seconds, and the main thread reads `prepared` under `cacheLock` many times a second, so the
        // load holds a lock of its own: one load at a time, and nobody else waits for it.
        return try loadLock.withLock {
            if let model = cacheLock.withLock({ cached[kind] }) { return model }
            let model = try StemModel(kind)
            cacheLock.withLock { cached[kind] = model }
            return model
        }
    }

    private static let loadLock = NSLock()

    /// The winds model when it is installed and loads, which finds the winds in the song.
    static func sharedWinds() -> StemModel? {
        isInstalled(.winds) ? try? shared(.winds) : nil
    }

    /// Loads the installed models and runs each once on silence, in the background, while the HUD shows the stems.
    static func warmUp() {
        let kinds = Kind.allCases.filter { isInstalled($0) }
        guard kinds.contains(.stems), cacheLock.withLock({ kinds.contains { cached[$0] == nil } && !warming }) else { return }
        cacheLock.withLock { warming = true }
        DispatchQueue.global(qos: .utility).async {
            defer { cacheLock.withLock { warming = false } }
            let silence = [Float](repeating: 0, count: chunk)
            for kind in kinds {
                guard let model = try? shared(kind) else { continue }
                _ = try? model.separate([silence, silence])
            }
        }
    }

    /// Frees the 335 MB of the stems model and the 98 MB of the winds model while nothing plays the stems. A
    /// separator that runs keeps its own references.
    static func unload() {
        cacheLock.withLock {
            cached = [:]
            ran = []
        }
    }

    init(_ kind: Kind = .stems) throws {
        self.kind = kind
        let configuration = MLModelConfiguration()
        // The GPU runs it fastest; the Neural Engine is slower and less exact with it.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: Self.url(kind), configuration: configuration)
    }

    /// The stems of `Self.chunk` frames of stereo audio, as [stem][channel][frame], in the order of the model's heads.
    func separate(_ channels: [[Float]]) throws -> [[[Float]]] {
        let frames = Self.frames, bins = Spectrogram.bins, width = bins * 4
        let spectra = channels.map { spectrogram.forward($0) }
        let input = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: width)], dataType: .float32)
        input.withUnsafeMutableBytes { raw, _ in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            for (c, spectrum) in spectra.enumerated() {
                for i in 0 ..< frames * bins {
                    p[i * 4 + c * 2] = spectrum.real[i]
                    p[i * 4 + c * 2 + 1] = spectrum.imaginary[i]
                }
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: input)])
        var masks: MLMultiArray?
        // Masks that are all zero or not numbers, which a virtual GPU gives back now and then, would write silence over
        // the window: it is separated once more, and a window that fails again fails the separation.
        for attempt in 0 ..< 2 {
            let output = try model.prediction(from: features)
            masks = output.featureValue(for: "masks")?.multiArrayValue
            if let masks, Self.usable(masks) { break }
            Self.log("stems: the model gave back \(masks == nil ? "no masks" : "empty masks") for a window\(attempt == 0 ? ", separating it again" : "")")
            masks = nil
        }
        Self.cacheLock.withLock { _ = Self.ran.insert(kind) }
        guard let masks else { throw StemError.noOutput }

        let strides = masks.strides.map(\.intValue)
        var stems: [[[Float]]] = []
        var real = [Float](repeating: 0, count: frames * bins), imaginary = [Float](repeating: 0, count: frames * bins)
        try masks.withUnsafeBufferPointer(ofType: Float.self) { m in
            guard let base = m.baseAddress else { throw StemError.noOutput }
            for stem in 0 ..< masks.shape[1].intValue {
                var stemChannels: [[Float]] = []
                for (c, spectrum) in spectra.enumerated() {
                    for t in 0 ..< frames {
                        let row = base + stem * strides[1] + t * strides[2]
                        for f in 0 ..< bins {
                            let i = t * bins + f
                            let mr = row[(f * 4 + c * 2) * strides[3]], mi = row[(f * 4 + c * 2 + 1) * strides[3]]
                            let xr = spectrum.real[i], xi = spectrum.imaginary[i]
                            real[i] = xr * mr - xi * mi
                            imaginary[i] = xr * mi + xi * mr
                        }
                    }
                    stemChannels.append(spectrogram.inverse(real: real, imaginary: imaginary, frames: frames, length: Self.chunk))
                }
                stems.append(stemChannels)
            }
        }
        return stems
    }
}

extension StemModel {
    /// Masks with a value that isn't zero, and no value that isn't a number.
    static func usable(_ masks: MLMultiArray) -> Bool {
        masks.withUnsafeBufferPointer(ofType: Float.self) { m -> Bool in
            guard !m.isEmpty else { return false }
            let squares = vDSP.sumOfSquares(m)
            return squares.isFinite && squares > 0
        }
    }
}

enum StemError: Error {
    case noOutput
    /// The downloaded model isn't the one that Muskey expects.
    case checksum
    case unpack
}

/// Separates a stream of stereo audio at 44.1 kHz in overlapping windows of the model's length. Each window gives
/// back the stems of all but its last second, which is crossfaded with the start of the next window.
final class StemStream {
    static let overlap = 86 * Spectrogram.hop
    static let step = StemModel.chunk - overlap

    private let model: StemModel
    private let winds: StemModel?
    private var pending: [[Float]] = [[], []]
    private var tail: [[[Float]]]?

    /// `winds` finds the woodwinds and the brass in each window, which play together as the Winds stem. Without it,
    /// that stem is silent.
    init(model: StemModel, winds: StemModel? = nil) {
        self.model = model
        self.winds = winds
    }

    func reset() {
        pending = [[], []]
        tail = nil
    }

    /// Adds audio, and returns the stems of every step that is done, as [stem][channel][frame].
    func push(_ left: ArraySlice<Float>, _ right: ArraySlice<Float>) throws -> [[[[Float]]]] {
        pending[0] += left
        pending[1] += right
        var blocks: [[[[Float]]]] = []
        let chunk = StemModel.chunk, step = Self.step, overlap = Self.overlap
        while pending[0].count >= chunk {
            let window = pending.map { Array($0.prefix(chunk)) }
            let peak = window.map { vDSP.maximumMagnitude($0) }.max() ?? 0
            // A pause in the song skips the model.
            let out = peak < 1e-5 ? Array(repeating: Self.silence, count: Stem.allCases.count) : try separate(window)
            var block: [[[Float]]] = []
            for (s, stem) in out.enumerated() {
                block.append(stem.enumerated().map { c, samples in
                    var part = Array(samples.prefix(step))
                    if let tail {
                        for i in 0 ..< overlap {
                            let fade = sin(Float.pi / 2 * (Float(i) + 0.5) / Float(overlap))
                            part[i] = tail[s][c][i] * (1 - fade * fade) + samples[i] * fade * fade
                        }
                    }
                    return part
                })
            }
            tail = out.map { $0.map { Array($0.suffix(overlap)) } }
            pending = pending.map { Array($0.dropFirst(step)) }
            blocks.append(block)
        }
        return blocks
    }

    private static let silence = [[Float]](repeating: [Float](repeating: 0, count: StemModel.chunk), count: 2)

    /// Every stem of a window: the six of the stems model, then the winds. The winds model runs on the whole window,
    /// because it finds the winds better in the song than in the Other stem, and its woodwinds and brass play as one
    /// stem. The winds are taken out of the Other stem, so the stems still add up to the song.
    private func separate(_ window: [[Float]]) throws -> [[[Float]]] {
        var stems = try model.separate(window)
        guard let winds else { return stems + [Self.silence] }
        let heads = try winds.separate(window)
        guard heads.count == 2 else { return stems + [Self.silence] }
        let wind = (0 ..< 2).map { c in vDSP.add(heads[0][c], heads[1][c]) }
        let other = stems[Stem.other.rawValue]
        stems[Stem.other.rawValue] = (0 ..< 2).map { c in vDSP.subtract(other[c], wind[c]) }
        return stems + [wind]
    }
}

/// Separates the song while the pitch change plays it: reads what the tap captured, separates it on its own
/// thread, and hands the stems back to the IOProc, which plays them a few seconds behind the song. A song that Muskey
/// Player plays, with its stems in the cache, gets them from there instead, at the moment that plays.
final class StemSeparator: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let done = DispatchSemaphore(value: 0)
    private var _feed: StemsFeed?

    /// The cache of the song that Muskey Player plays, which each generation that starts at the moment that plays
    /// takes its stems from, unless the cache didn't line up with the song before.
    var feed: StemsFeed? {
        get { lock.withLock { _feed } }
        set { lock.withLock { _feed = newValue } }
    }

    /// Runs on the separation thread when the model fails to load, or fails on two windows in a row.
    var onFailure: (Error) -> Void = { _ in }
    /// Runs on the separation thread with the time that the windows take, after the first one and then every 20.
    var log: (String) -> Void = { _ in }

    private var finished = false

    /// The thread has stopped reading the shifter.
    var stopped: Bool { lock.withLock { finished } }

    /// Set while the model separates the song as it plays, which a separation of a whole song leaves the GPU to.
    var separating: SharedFlag?

    func start(shifter: OpaquePointer, rate: Double) {
        let thread = Thread { [self] in
            run(shifter: shifter, rate: rate)
            lock.withLock { finished = true }
            done.signal()
        }
        thread.name = "Muskey stems"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.withLock { cancelled = true }
    }

    /// Waits for the window being separated, at most a few seconds, before the shifter goes away.
    func waitUntilStopped() {
        guard !stopped else { return }
        _ = done.wait(timeout: .now() + 3)
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func run(shifter: OpaquePointer, rate: Double) {
        // The model loads with the first generation that separates the song as it plays: cached stems need none.
        var stream: StemStream?
        let read = Int(rate / 4)
        var left = [Float](repeating: 0, count: read), right = [Float](repeating: 0, count: read)
        var generation: UInt64 = 0
        var position: UInt64 = 0
        var input: Resampler?, outputs: [Resampler] = []
        var windows = 0, spent = 0.0, slowest = 0.0
        var failures = 0
        var cached: CachedStemsWriter?

        while !isCancelled {
            var start: UInt64 = 0
            let current = ps_stems_generation(shifter, &start)
            if current != generation, current != 0 {
                generation = current
                position = start
                // Cached stems for a generation that starts at the moment that plays. One that starts in the past, for
                // the lyrics delay, is separated as the song plays, since the song may have paused or moved since.
                if let feed, !feed.lost, start + UInt64(rate) > ps_captured_written(shifter) {
                    let writer = CachedStemsWriter(shifter: shifter, rate: rate, feed: feed, generation: generation, start: start)
                    writer.log = log
                    cached = writer
                    ps_stems_begin_cached(shifter, generation, start)
                    log("stems: from the cache")
                } else {
                    cached = nil
                    if stream == nil {
                        do {
                            let winds = StemModel.sharedWinds()
                            stream = StemStream(model: try StemModel.shared(), winds: winds)
                            log("stems: \(winds == nil ? "6 stems" : "7 stems, with winds")")
                        } catch {
                            onFailure(error)
                            return
                        }
                    }
                    stream?.reset()
                    input = rate == StemModel.sampleRate ? nil : Resampler(from: rate, to: StemModel.sampleRate)
                    outputs = rate == StemModel.sampleRate ? [] : Stem.allCases.map { _ in Resampler(from: StemModel.sampleRate, to: rate) }
                    ps_stems_begin(shifter, generation, start)
                }
            }
            guard generation != 0 else {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            separating?.value = cached == nil && stream != nil
            if let writer = cached {
                if writer.step() == .lost {
                    // Separated as the song plays from here on, in a generation of its own.
                    feed?.markLost()
                    cached = nil
                    ps_stems_restart(shifter)
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            // A move asked for while the song is separated as it plays has nothing to wait for.
            var answered: UInt32 = 0
            let asked = ps_stems_seeks(shifter, &answered)
            if asked != answered { ps_stems_seek_answer(shifter, asked, 0) }
            guard let stream else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            // With the song playing far behind for the lyrics, the separation waits for the output to catch up.
            let room = ps_stems_room(shifter, position)
            let n = room > 0 ? ps_captured_read(shifter, &position, &left, &right, min(read, room)) : 0
            guard n > 0 else {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            let resampled = input.map { $0.convert(left[..<n], right[..<n]) } ?? [Array(left[..<n]), Array(right[..<n])]
            do {
                let began = CACurrentMediaTime()
                let blocks = try stream.push(resampled[0][...], resampled[1][...])
                if !blocks.isEmpty {
                    let took = (CACurrentMediaTime() - began) * 1000
                    windows += 1
                    spent += took
                    slowest = max(slowest, took)
                    if windows <= 3 || windows % 20 == 0 {
                        log(String(format: "stems: %d windows, %.0f ms each, slowest %.0f ms", windows, spent / Double(windows), slowest))
                    }
                }
                for block in blocks {
                    let planes: [[Float]] = outputs.isEmpty
                        ? block.flatMap { $0 }
                        : zip(block, outputs).flatMap { stem, resampler in resampler.convert(stem[0][...], stem[1][...]) }
                    let frames = planes.map(\.count).min() ?? 0
                    guard frames > 0, !isCancelled else { continue }
                    var flat = [Float](repeating: 0, count: planes.count * frames)
                    for (p, plane) in planes.enumerated() { flat.replaceSubrange(p * frames ..< (p + 1) * frames, with: plane.prefix(frames)) }
                    flat.withUnsafeBufferPointer { buffer in
                        let pointers: [UnsafePointer<Float>?] = (0 ..< planes.count).map { buffer.baseAddress! + $0 * frames }
                        pointers.withUnsafeBufferPointer { ps_stems_write(shifter, $0.baseAddress!, frames) }
                    }
                }
                failures = 0
            } catch {
                // One bad window is skipped. A model that fails again would leave the Mac silent behind a spinner,
                // so the separation stops and every stem plays again.
                failures += 1
                stream.reset()
                if failures >= 2 {
                    onFailure(error)
                    return
                }
            }
        }
    }
}

/// A flag that one thread sets and others read.
final class SharedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// A stereo sample rate converter that keeps its state from one call to the next.
final class Resampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat

    init(from: Double, to: Double) {
        input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 2, interleaved: false)!
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 2, interleaved: false)!
        converter = AVAudioConverter(from: input, to: output)!
        converter.sampleRateConverterQuality = .max
    }

    func convert(_ left: ArraySlice<Float>, _ right: ArraySlice<Float>) -> [[Float]] {
        let count = left.count
        guard count > 0, let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count)) else { return [[], []] }
        source.frameLength = AVAudioFrameCount(count)
        left.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
        right.withUnsafeBufferPointer { source.floatChannelData![1].update(from: $0.baseAddress!, count: count) }
        let capacity = AVAudioFrameCount(Double(count) * output.sampleRate / input.sampleRate) + 64
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [[], []] }
        var given = false
        converter.convert(to: target, error: nil) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return source
        }
        let frames = Int(target.frameLength)
        return (0 ..< 2).map { Array(UnsafeBufferPointer(start: target.floatChannelData![$0], count: frames)) }
    }
}

/// `--stems-file PATH` separates an audio file the way the live stems do, writes each stem to a WAV in the folder
/// that `--stems-out` names, prints how long the model took per window, and quits.
enum StemFileTest {
    static func run(_ path: String, to folder: String) {
        DispatchQueue.global().async {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                let format = file.processingFormat
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { exit(1) }
                try file.read(into: buffer)
                let count = Int(buffer.frameLength)
                let channels = (0 ..< 2).map { c in
                    Array(UnsafeBufferPointer(start: buffer.floatChannelData![min(c, Int(format.channelCount) - 1)], count: count))
                }
                let audio = format.sampleRate == StemModel.sampleRate ? channels
                    : Resampler(from: format.sampleRate, to: StemModel.sampleRate).convert(channels[0][...], channels[1][...])
                var started = Date()
                let model = try StemModel()
                let winds = StemModel.isInstalled(.winds) ? try StemModel(.winds) : nil
                print(String(format: "%@ loaded in %.1fs", winds == nil ? "model" : "models", Date().timeIntervalSince(started)))
                let stream = StemStream(model: model, winds: winds)
                var stems = Array(repeating: [[Float]](repeating: [], count: 2), count: Stem.allCases.count)
                var windows = 0
                started = Date()
                let tail = [Float](repeating: 0, count: StemModel.chunk)
                for blocks in [try stream.push(audio[0][...], audio[1][...]), try stream.push(tail[...], tail[...])] {
                    for block in blocks {
                        windows += 1
                        for s in block.indices { for c in 0 ..< 2 { stems[s][c] += block[s][c] } }
                    }
                }
                let took = Date().timeIntervalSince(started)
                print(String(format: "%d windows in %.1fs, %.0f ms each, %.1fx faster than the song plays", windows, took, took / Double(windows) * 1000,
                             Double(audio[0].count) / StemModel.sampleRate / took))
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                for stem in Stem.allCases {
                    let pair = stems[stem.rawValue]
                    let frames = min(audio[0].count, pair[0].count)
                    var interleaved = [Float](repeating: 0, count: frames * 2)
                    for i in 0 ..< frames {
                        interleaved[i * 2] = pair[0][i]
                        interleaved[i * 2 + 1] = pair[1][i]
                    }
                    writeWAV(interleaved, rate: UInt32(StemModel.sampleRate), channels: 2, to: "\(folder)/\(stem.name.lowercased()).wav")
                }
                print("wrote \(folder)")
                exit(0)
            } catch {
                print("stems failed: \(error)")
                exit(1)
            }
        }
    }
}
