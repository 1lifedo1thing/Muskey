import Accelerate
import AVFoundation
import CoreML

/// A note that the transcriber heard: when it starts and ends, in seconds from the start of the audio, its MIDI pitch,
/// and the General MIDI program it gets in MIDI and MusicXML files. Dettato hears no velocity.
struct TranscribedNote: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let pitch: Int
    let program: Int
    let drum: Bool
}

struct TranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Dettato's transcriber (kobimusic/dettato, Apache-2.0) on the Mac. `Scripts/dettato-model/convert.py` cuts its network
/// at its three GRUs into four Core ML models, since Core ML runs those GRUs much slower than Accelerate does, and
/// the GRUs run here between them. The spectrogram before the network and the peak picking after it are written here the
/// way Dettato's Python does them.
///
/// The network hears 8 seconds at 16 kHz at a time. Windows start every 2 seconds, and each 20 ms frame of the song gets
/// the mean of the windows over it, weighted by a Hann taper, before notes are picked from the six maps: onset, frame
/// and offset, for a first and a second voice on each key.
enum Dettato {
    static let rate = 16000.0
    static let hop = 160
    static let windowSamples = 128_000
    static let frames = 800
    static let mapFrames = 400
    static let frameSeconds = 0.02
    static let keys = 88
    static let lowestPitch = 21
    static let bins = 288
    static let channels = 9
    static let step = 32000

    static var folder: URL { StemModel.folder.appending(path: "Dettato") }
    static var installed: Bool {
        (1 ... 4).allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: "Part\($0).mlmodelc").path) }
            && FileManager.default.fileExists(atPath: folder.appending(path: "gru.bin").path)
    }

    /// The thresholds in the config.json of kobimusic/dettato.
    enum Threshold {
        static let onset: Float = 0.25
        static let offset: Float = 0.3
        static let frame: Float = 0.4
        static let lowFrames = 2
        static let onsetSpacing = 3
        static let secondVoice: Float = 0.3
        static let shortest = 0.02
        static let offsetAfter = 2
    }

    private nonisolated(unsafe) static var loaded: DettatoNetwork?
    private static let loading = NSLock()

    static func network() throws -> DettatoNetwork {
        try loading.withLock {
            if let loaded { return loaded }
            let network = try DettatoNetwork(folder: folder)
            loaded = network
            return network
        }
    }

    static func unload() { loading.withLock { loaded = nil } }

    /// Mono samples at `rate` resampled to 16 kHz.
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != Self.rate, !samples.isEmpty else { return samples }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(samples.count) * Self.rate / rate) + 1024)
        else { return [] }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var fed = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        return Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
    }

    /// The notes in `samples`, mono at 16 kHz. `progress` gets the part of the song done, from 0 to 1, after each window.
    /// `partial` gets the notes found so far every 16 seconds of song, without the ones that may still go on.
    static func transcribe(_ samples: [Float], program: Int, progress: @escaping @Sendable (Double) -> Void = { _ in },
                           partial: (@Sendable ([TranscribedNote]) -> Void)? = nil) throws -> [TranscribedNote]
    {
        let network = try network()
        let front = DettatoFrontEnd()
        let count = samples.count
        let total = Int((Double(count) / rate / frameSeconds).rounded(.up))
        guard total > 0 else { return [] }
        let pad = windowSamples / 2
        let framePad = Int((Double(pad) / rate / frameSeconds).rounded())
        var padded = [Float](repeating: 0, count: pad + count + pad + windowSamples)
        padded.replaceSubrange(pad ..< pad + count, with: samples)
        let starts = Array(stride(from: 0, to: count + pad, by: step))
        // np.hanning(402)[1:-1]
        let taper = (1 ... mapFrames).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(mapFrames + 1))) }
        var maps = [[Float]](repeating: [Float](repeating: 0, count: total * keys), count: 6)
        var weights = [Float](repeating: 0, count: total)
        let input = try MLMultiArray(shape: [1, NSNumber(value: channels), NSNumber(value: frames), NSNumber(value: bins)], dataType: .float32)
        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            padded.withUnsafeBufferPointer { buffer in
                front.spectrogram(buffer.baseAddress! + start, into: input.dataPointer.assumingMemoryBound(to: Float.self))
            }
            let output = try network.maps(input)
            let first = Int((Double(start) / rate / frameSeconds).rounded()) - framePad
            let from = max(0, first), to = min(total, first + mapFrames)
            guard to > from else { continue }
            let strides = output.strides.map(\.intValue)
            output.withUnsafeBufferPointer(ofType: Float.self) { values in
                for head in 0 ..< 6 {
                    for frame in from ..< to {
                        let local = frame - first
                        let weight = taper[local]
                        let base = head * strides[1] + local * strides[2]
                        for key in 0 ..< keys {
                            let logit = values[base + key * strides[3]]
                            maps[head][frame * keys + key] += weight / (1 + exp(-logit))
                        }
                    }
                }
            }
            for frame in from ..< to { weights[frame] += taper[frame - first] }
            progress(Double(index + 1) / Double(starts.count))
            // The frames before the next window's first are final: no window after this one reaches them.
            if let partial, (index + 1) % 8 == 0, index + 1 < starts.count {
                let final = min(total, Int((Double(starts[index + 1]) / rate / frameSeconds).rounded()) - framePad)
                if final > 0 {
                    let cut = Double(final) * frameSeconds - 0.5
                    partial(notes(maps, weights, frames: final, program: program).filter { $0.end < cut })
                }
            }
        }
        return notes(maps, weights, frames: total, program: program)
    }

    /// The notes of both voices in the first `frames` frames of the summed maps.
    private static func notes(_ maps: [[Float]], _ weights: [Float], frames: Int, program: Int) -> [TranscribedNote] {
        let averaged = maps.map { map in
            var out = [Float](repeating: 0, count: frames * keys)
            for frame in 0 ..< frames {
                let weight = max(weights[frame], 1e-6)
                for key in 0 ..< keys { out[frame * keys + key] = map[frame * keys + key] / weight }
            }
            return out
        }
        var notes: [TranscribedNote] = []
        for (slot, threshold) in [(0, Threshold.onset), (1, Threshold.secondVoice)] {
            let found = decode(onset: averaged[slot * 3], frame: averaged[slot * 3 + 1], offset: averaged[slot * 3 + 2], frames: frames, onsetThreshold: threshold)
            notes += found.map { TranscribedNote(start: $0.start, end: $0.end, pitch: $0.pitch, program: program, drum: false) }
        }
        return notes.sorted { ($0.start, $0.end, $0.pitch) < ($1.start, $1.end, $1.pitch) }
    }

    /// The notes of one voice from its maps, (frames × 88) each, as `decode` in Dettato's transcriber/decode.py does it: a
    /// note starts at every onset peak over the threshold, and ends at the first offset peak, at the frame map staying low
    /// for two frames, or at the next onset on the same key.
    static func decode(onset: [Float], frame: [Float], offset: [Float], frames total: Int, onsetThreshold: Float) -> [(start: Double, end: Double, pitch: Int)] {
        func at(_ map: [Float], _ t: Int, _ key: Int) -> Float { map[t * keys + key] }
        func peaks(_ map: [Float], _ key: Int, _ threshold: Float) -> [Int] {
            (0 ..< total).filter { t in
                let value = at(map, t, key)
                let left: Float = t > 0 ? at(map, t - 1, key) : -1
                let right: Float = t + 1 < total ? at(map, t + 1, key) : -1
                return value >= threshold && value > left && value >= right
            }
        }
        func refine(_ map: [Float], _ t: Int, _ key: Int) -> Double {
            let center = at(map, t, key)
            let a = t > 0 ? at(map, t - 1, key) : center
            let b = t + 1 < total ? at(map, t + 1, key) : center
            let denominator = 2 * (center - min(a, b))
            guard denominator > 1e-6 else { return 0 }
            return Double(max(-0.5, min(0.5, (b - a) / denominator)))
        }
        var notes: [(start: Double, end: Double, pitch: Int)] = []
        for key in 0 ..< keys {
            var onsets = peaks(onset, key, onsetThreshold)
            guard !onsets.isEmpty else { continue }
            if Threshold.onsetSpacing > 0, onsets.count > 1 {
                var keep = [Bool](repeating: true, count: onsets.count)
                for index in onsets.indices.sorted(by: { at(onset, onsets[$0], key) > at(onset, onsets[$1], key) }) where keep[index] {
                    for other in onsets.indices where other != index && abs(onsets[other] - onsets[index]) <= Threshold.onsetSpacing {
                        keep[other] = false
                    }
                }
                onsets = onsets.indices.filter { keep[$0] }.map { onsets[$0] }
            }
            let offsets = peaks(offset, key, Threshold.offset)
            // Frames where the frame map stays under its threshold for `lowFrames` frames in a row.
            let lows = (0 ..< total).filter { t in
                (0 ..< Threshold.lowFrames).allSatisfy { t + $0 >= total || at(frame, t + $0, key) < Threshold.frame }
            }
            for (index, t0) in onsets.enumerated() {
                let start = Double(t0) + refine(onset, t0, key)
                let next = index + 1 < onsets.count ? onsets[index + 1] : total
                let lowEnd = lows.first { $0 >= t0 + 1 } ?? total
                let offsetEnd = offsets.first { $0 >= t0 + Threshold.offsetAfter } ?? total
                let end: Double = if offsetEnd < total, offsetEnd <= min(lowEnd, next) {
                    Double(offsetEnd) + refine(offset, offsetEnd, key)
                } else if lowEnd <= next {
                    Double(lowEnd) - 0.5
                } else {
                    Double(next) + (next < total ? refine(onset, next, key) : 0)
                }
                let startSeconds = start * frameSeconds
                notes.append((startSeconds, max(end * frameSeconds, startSeconds + Threshold.shortest), lowestPitch + key))
            }
        }
        return notes.sorted { ($0.start, $0.end, $0.pitch) < ($1.start, $1.end, $1.pitch) }
    }
}

/// Dettato's harmonic spectrogram: the power of a 2048-point STFT on a grid of 3 bins a semitone from A0, once for each
/// harmonic shift (½ to 7), and a 512-point STFT on the same grid for sharper onsets, as log power. 10 ms frames.
final class DettatoFrontEnd {
    private static let harmonics: [Double] = [0.5, 1, 2, 3, 4, 5, 6, 7]
    private static let shifts = harmonics.map { Int((36 * log2($0)).rounded()) }
    private static let low = min(0, shifts.min()!)
    private static let high = max(0, shifts.max()!)
    private static let longBins = Dettato.bins + high - low
    private static let epsilon: Float = 1e-5

    private let long: STFT
    private let short: STFT
    private let longBank: [Float]
    private let shortBank: [Float]
    private var longPower: [Float]
    private var shortPower: [Float]
    private var longLog: [Float]
    private var shortLog: [Float]

    init() {
        long = STFT(size: 2048)
        short = STFT(size: 512)
        longBank = Self.filterbank(bins: Self.longBins, size: 2048, lowest: 27.5 * pow(2, Double(Self.low) / 36))
        shortBank = Self.filterbank(bins: Dettato.bins, size: 512, lowest: 27.5)
        longPower = [Float](repeating: 0, count: Dettato.frames * 1025)
        shortPower = [Float](repeating: 0, count: Dettato.frames * 257)
        longLog = [Float](repeating: 0, count: Dettato.frames * Self.longBins)
        shortLog = [Float](repeating: 0, count: Dettato.frames * Dettato.bins)
    }

    /// `logfreq_filterbank` from Dettato's frontend.py: triangles on a log-frequency grid, each summing to 1. Row-major,
    /// one row of `size / 2 + 1` weights for each bin.
    static func filterbank(bins: Int, size: Int, lowest: Double) -> [Float] {
        let columns = size / 2 + 1
        var bank = [Float](repeating: 0, count: bins * columns)
        let nyquist = Dettato.rate / 2
        for bin in 0 ..< bins {
            let center = lowest * pow(2, Double(bin) / 36)
            let width = max(center * pow(2, 1.0 / 36) - center * pow(2, -1.0 / 36), 2 * Dettato.rate / Double(size))
            let low = center - width / 2, high = center + width / 2
            var row = [Double](repeating: 0, count: columns)
            for column in 0 ..< columns {
                let frequency = Double(column) * nyquist / Double(columns - 1)
                let up = (frequency - low) / max(center - low, 1e-9)
                let down = (high - frequency) / max(high - center, 1e-9)
                row[column] = max(0, min(up, down))
            }
            let sum = row.reduce(0, +)
            guard sum > 0 else { continue }
            for column in 0 ..< columns { bank[bin * columns + column] = Float(row[column] / sum) }
        }
        return bank
    }

    /// Fills `out` (9 × 800 × 288) with the spectrogram of the 128 000 samples at `audio`.
    func spectrogram(_ audio: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let frames = Dettato.frames, bins = Dettato.bins
        long.power(audio, count: Dettato.windowSamples, frames: frames, into: &longPower)
        short.power(audio, count: Dettato.windowSamples, frames: frames, into: &shortPower)
        Self.project(longPower, bank: longBank, bins: Self.longBins, columns: 1025, frames: frames, into: &longLog)
        Self.project(shortPower, bank: shortBank, bins: bins, columns: 257, frames: frames, into: &shortLog)
        longLog.withUnsafeBufferPointer { log in
            for (channel, shift) in Self.shifts.enumerated() {
                let offset = shift - Self.low
                for frame in 0 ..< frames {
                    (out + (channel * frames + frame) * bins).update(from: log.baseAddress! + frame * Self.longBins + offset, count: bins)
                }
            }
        }
        shortLog.withUnsafeBufferPointer { log in
            (out + Self.harmonics.count * frames * bins).update(from: log.baseAddress!, count: frames * bins)
        }
    }

    /// log(power × bankᵀ + ε): (frames × columns) by (bins × columns)ᵀ.
    private static func project(_ power: [Float], bank: [Float], bins: Int, columns: Int, frames: Int, into out: inout [Float]) {
        power.withUnsafeBufferPointer { p in
            bank.withUnsafeBufferPointer { b in
                out.withUnsafeMutableBufferPointer { o in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(bins), Int32(columns), 1,
                                p.baseAddress, Int32(columns), b.baseAddress, Int32(columns), 0, o.baseAddress, Int32(bins))
                }
            }
        }
        var add = epsilon
        var count = Int32(out.count)
        out.withUnsafeMutableBufferPointer { o in
            vDSP_vsadd(o.baseAddress!, 1, &add, o.baseAddress!, 1, vDSP_Length(o.count))
            vvlogf(o.baseAddress!, o.baseAddress!, &count)
        }
    }
}

/// The power spectrum of `torch.stft(center=True, pad_mode="constant")` with a periodic Hann window and a hop of 160.
private final class STFT {
    let size: Int
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private var frame: [Float]
    private var evens: [Float], odds: [Float], real: [Float], imaginary: [Float]

    init(size: Int) {
        self.size = size
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        window = (0 ..< size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        frame = [Float](repeating: 0, count: size)
        evens = [Float](repeating: 0, count: size / 2)
        odds = evens
        real = evens
        imaginary = evens
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// (frames × (size / 2 + 1)) power, frame `t` centred on sample `t × 160`, with zeros outside the samples.
    func power(_ audio: UnsafePointer<Float>, count: Int, frames: Int, into out: inout [Float]) {
        let columns = size / 2 + 1, half = size / 2
        for t in 0 ..< frames {
            let first = t * Dettato.hop - half
            for n in 0 ..< size {
                let index = first + n
                frame[n] = index >= 0 && index < count ? audio[index] * window[n] : 0
            }
            for n in 0 ..< half {
                evens[n] = frame[2 * n]
                odds[n] = frame[2 * n + 1]
            }
            vDSP_DFT_Execute(setup, evens, odds, &real, &imaginary)
            // vDSP's real DFT returns twice the DFT, with the Nyquist bin in the imaginary part of bin 0.
            let base = t * columns
            out[base] = (real[0] * 0.5) * (real[0] * 0.5)
            out[base + half] = (imaginary[0] * 0.5) * (imaginary[0] * 0.5)
            for k in 1 ..< half {
                let r = real[k] * 0.5, i = imaginary[k] * 0.5
                out[base + k] = r * r + i * i
            }
        }
    }
}

/// The four Core ML parts of the network, with the three bidirectional GRUs between them.
final class DettatoNetwork {
    private let parts: [MLModel]
    private let grus: [DettatoGRU]
    private let output: MLMultiArray

    init(folder: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        parts = try (1 ... 4).map { try MLModel(contentsOf: folder.appending(path: "Part\($0).mlmodelc"), configuration: configuration) }
        let data = try Data(contentsOf: folder.appending(path: "gru.bin"), options: .mappedIfSafe)
        var offset = 0
        grus = try (0 ..< 3).map { _ in try DettatoGRU(data, offset: &offset) }
        output = try MLMultiArray(shape: [88, 200, 384], dataType: .float32)
    }

    /// The six maps of logits (1 × 6 × 400 × 88) of a window, from its spectrogram.
    func maps(_ spectrogram: MLMultiArray) throws -> MLMultiArray {
        func run(_ part: Int, _ inputs: [String: MLMultiArray]) throws -> MLFeatureProvider {
            try parts[part].prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        }
        var result = try run(0, ["spectrogram": spectrogram])
        for (index, gru) in grus.enumerated() {
            guard let sequence = result.featureValue(for: "sequence")?.multiArrayValue, let next = result.featureValue(for: "next")?.multiArrayValue
            else { throw TranscriptionError(message: "Dettato's part \(index + 1) returned nothing") }
            gru.run(sequence, into: output)
            result = index < 2 ? try run(index + 1, ["x": next, "output": output])
                : try run(3, ["x": next, "output": output, "spectrogram": spectrogram])
        }
        guard let maps = result.featureValue(for: "maps")?.multiArrayValue else { throw TranscriptionError(message: "Dettato returned no maps") }
        return maps
    }
}

/// A bidirectional GRU with PyTorch's equations, on 88 sequences (one for each key) of 200 steps: the input projection of
/// every step in one matrix product, then the steps one after another, each a product with the hidden state and a few
/// vector operations. The two directions run at the same time.
final class DettatoGRU {
    static let size = 368, hidden = 192, sequences = 88, steps = 200

    private struct Direction {
        let inputWeights: [Float]   // (576 × 368)
        let hiddenWeights: [Float]  // (576 × 192)
        let inputBias: [Float]
        let hiddenBias: [Float]
    }

    private let directions: [Direction]

    init(_ data: Data, offset: inout Int) throws {
        func read(_ count: Int) throws -> [Float] {
            guard offset + count * 4 <= data.count else { throw TranscriptionError(message: "Dettato's GRU weights are cut short") }
            let values = data.withUnsafeBytes { bytes in
                (0 ..< count).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self))) }
            }
            offset += count * 4
            return values
        }
        let gates = 3 * Self.hidden
        directions = try (0 ..< 2).map { _ in
            try Direction(inputWeights: read(gates * Self.size), hiddenWeights: read(gates * Self.hidden), inputBias: read(gates), hiddenBias: read(gates))
        }
    }

    /// Runs over `sequence` (88 × 200 × 368) and writes both directions' hidden states into `output` (88 × 200 × 384).
    func run(_ sequence: MLMultiArray, into output: MLMultiArray) {
        let n = Self.sequences, t = Self.steps, c = Self.size, h = Self.hidden
        var input = [Float](repeating: 0, count: n * t * c)
        Self.copy(sequence, into: &input)
        let out = output.dataPointer.assumingMemoryBound(to: Float.self)
        input.withUnsafeBufferPointer { seq in
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                Self.direction(directions[index], reverse: index == 1, sequence: seq.baseAddress!, output: out + index * h, n: n, t: t, c: c, h: h)
            }
        }
    }

    /// A Core ML array copied in row-major order, whatever its strides.
    static func copy(_ array: MLMultiArray, into out: inout [Float]) {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let contiguous = strides == shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
        array.withUnsafeBufferPointer(ofType: Float.self) { values in
            if contiguous {
                out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: values.baseAddress!, count: min($0.count, values.count)) }
                return
            }
            var index = 0
            for a in 0 ..< shape[0] {
                for b in 0 ..< shape[1] {
                    for k in 0 ..< shape[2] {
                        out[index] = values[a * strides[0] + b * strides[1] + k * strides[2]]
                        index += 1
                    }
                }
            }
        }
    }

    private static func direction(_ weights: Direction, reverse: Bool, sequence: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>,
                                  n: Int, t: Int, c: Int, h: Int)
    {
        let gates = 3 * h, rows = n * t
        // Each gate's input projection, with its input bias: (n·t × h).
        var projected = [[Float]](repeating: [Float](repeating: 0, count: rows * h), count: 3)
        for gate in 0 ..< 3 {
            projected[gate].withUnsafeMutableBufferPointer { p in
                for row in 0 ..< rows { (p.baseAddress! + row * h).update(from: weights.inputBias.withUnsafeBufferPointer { $0.baseAddress! + gate * h }, count: h) }
                weights.inputWeights.withUnsafeBufferPointer { w in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(h), Int32(c), 1, sequence, Int32(c),
                                w.baseAddress! + gate * h * c, Int32(c), 1, p.baseAddress!, Int32(h))
                }
            }
        }
        var state = [Float](repeating: 0, count: n * h)
        var recurrent = [Float](repeating: 0, count: n * gates)
        var tiledBias = [Float](repeating: 0, count: n * gates)
        for row in 0 ..< n { tiledBias.replaceSubrange(row * gates ..< (row + 1) * gates, with: weights.hiddenBias) }
        var reset = [Float](repeating: 0, count: n * h), update = reset, candidate = reset, recurrentPart = reset, scratch = reset
        let count = vDSP_Length(n * h)
        var length = Int32(n * h)
        var one: Float = 1
        for step in reverse ? Array((0 ..< t).reversed()) : Array(0 ..< t) {
            // recurrent = state · Whhᵀ + bhh
            recurrent = tiledBias
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(gates), Int32(h), 1, state, Int32(h),
                        weights.hiddenWeights, Int32(h), 1, &recurrent, Int32(gates))
            // The three gates of this step, gathered from rows that sit `t` steps apart.
            projected[0].withUnsafeBufferPointer { vDSP_mmov($0.baseAddress! + step * h, &reset, vDSP_Length(h), vDSP_Length(n), vDSP_Length(t * h), vDSP_Length(h)) }
            projected[1].withUnsafeBufferPointer { vDSP_mmov($0.baseAddress! + step * h, &update, vDSP_Length(h), vDSP_Length(n), vDSP_Length(t * h), vDSP_Length(h)) }
            projected[2].withUnsafeBufferPointer { vDSP_mmov($0.baseAddress! + step * h, &candidate, vDSP_Length(h), vDSP_Length(n), vDSP_Length(t * h), vDSP_Length(h)) }
            recurrent.withUnsafeBufferPointer { r in
                // r = σ(x_r + h_r), z = σ(x_z + h_z)
                vDSP_mmov(r.baseAddress!, &scratch, vDSP_Length(h), vDSP_Length(n), vDSP_Length(gates), vDSP_Length(h))
                vDSP_vadd(reset, 1, scratch, 1, &reset, 1, count)
                vDSP_mmov(r.baseAddress! + h, &scratch, vDSP_Length(h), vDSP_Length(n), vDSP_Length(gates), vDSP_Length(h))
                vDSP_vadd(update, 1, scratch, 1, &update, 1, count)
                vDSP_mmov(r.baseAddress! + 2 * h, &recurrentPart, vDSP_Length(h), vDSP_Length(n), vDSP_Length(gates), vDSP_Length(h))
            }
            for gate in [0, 1] {
                if gate == 0 {
                    vDSP_vneg(reset, 1, &reset, 1, count)
                    vvexpf(&reset, reset, &length)
                    vDSP_vsadd(reset, 1, &one, &reset, 1, count)
                    vvrecf(&reset, reset, &length)
                } else {
                    vDSP_vneg(update, 1, &update, 1, count)
                    vvexpf(&update, update, &length)
                    vDSP_vsadd(update, 1, &one, &update, 1, count)
                    vvrecf(&update, update, &length)
                }
            }
            // n = tanh(x_n + r ⊙ h_n)
            vDSP_vma(reset, 1, recurrentPart, 1, candidate, 1, &candidate, 1, count)
            vvtanhf(&candidate, candidate, &length)
            // state = n + z ⊙ (state − n)
            vDSP_vsub(candidate, 1, state, 1, &scratch, 1, count)
            vDSP_vma(update, 1, scratch, 1, candidate, 1, &state, 1, count)
            vDSP_mmov(state, output + step * 2 * h, vDSP_Length(h), vDSP_Length(n), vDSP_Length(h), vDSP_Length(t * 2 * h))
        }
    }
}

/// `--dettato-check DIR` compares the spectrogram and the maps of the window that convert.py wrote to DIR with the ones that
/// the app computes, to check the front end and the Core ML model.
enum DettatoCheck {
    static func run(_ dir: String) {
        func read(_ name: String) -> [Float] {
            guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { return [] }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let window = read("check-window.f32"), expected = read("check-spectrogram.f32"), maps = read("check-maps.f32")
        guard window.count == Dettato.windowSamples, expected.count == Dettato.channels * Dettato.frames * Dettato.bins else {
            print("dettato check: missing files in \(dir)")
            exit(1)
        }
        var spectrogram = [Float](repeating: 0, count: expected.count)
        let started = Date()
        window.withUnsafeBufferPointer { w in spectrogram.withUnsafeMutableBufferPointer { DettatoFrontEnd().spectrogram(w.baseAddress!, into: $0.baseAddress!) } }
        let took = Date().timeIntervalSince(started)
        let differences = zip(spectrogram, expected).map { abs($0 - $1) }
        print(String(format: "spectrogram: largest difference %.5f, mean %.6f, %.0f ms", differences.max() ?? 0, differences.reduce(0, +) / Float(differences.count), took * 1000))
        do {
            let network = try Dettato.network()
            let input = try MLMultiArray(shape: [1, 9, 800, 288], dataType: .float32)
            spectrogram.withUnsafeBufferPointer { input.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
            _ = try network.maps(input)
            let timing = Date()
            let output = try network.maps(input)
            let predicted = Date().timeIntervalSince(timing)
            let strides = output.strides.map(\.intValue)
            var largest: Float = 0
            output.withUnsafeBufferPointer(ofType: Float.self) { values in
                for head in 0 ..< 6 {
                    for frame in 0 ..< 400 {
                        for key in 0 ..< 88 {
                            let probability = 1 / (1 + exp(-values[head * strides[1] + frame * strides[2] + key * strides[3]]))
                            largest = max(largest, abs(probability - maps[(head * 400 + frame) * 88 + key]))
                        }
                    }
                }
            }
            print(String(format: "maps: largest difference of a probability %.4f, %.0f ms a window", largest, predicted * 1000))
            exit(0)
        } catch {
            print("dettato check: \(error)")
            exit(1)
        }
    }
}

extension Stem {
    /// The General MIDI program that the notes of the stem get in MIDI and MusicXML files.
    var program: Int {
        switch self {
        case .bass: 33
        case .guitar: 27
        case .piano: 0
        case .vocals: 53
        case .winds: 65
        case .other: 48
        case .drums: 0
        }
    }
}
