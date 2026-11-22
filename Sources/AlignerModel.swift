import Accelerate
import CoreML
import Foundation

/// Something that reads sung words for the fit of lyrics: the speech model, or a reading made up for a test.
protocol LyricsReading {
    /// The label that the reader writes between words.
    var space: Int? { get }
    /// The reader's label for a character of the lyrics, or nil for one that it doesn't write.
    func label(_ character: Character) -> Int?
    /// What the reader makes of `samples`, mono at 16 kHz: for each 20 ms, the log-probability of the blank and of
    /// each of `columns`. Nil when `stop` says to end early.
    func emissions(_ samples: [Float], columns: [Int], stop: () -> Bool) throws -> ForcedAligner.Emissions?
}

extension LyricsReading {
    /// The line has a word to sing that the reader can write, outside brackets.
    func sings(_ line: String) -> Bool {
        ForcedAligner.sung(line).contains { $0.word.contains { label($0) != nil } }
    }
}

/// The speech model that reads sung words for timing lyrics: Meta's omniASR CTC model of 300 million weights
/// (Apache-2.0), which writes the characters of over 1600 languages, as a Core ML package next to the list of its
/// characters. `make aligner-model` converts it and checks it against the original on each kind of processor. It
/// runs on the GPU, where its letters stay the closest to the original's.
enum AlignerModel {
    static let rate = 16000.0
    /// The model reads 30 seconds at a time.
    static let window = 480_000
    /// Windows start 20 seconds apart, and the first and the last 5 seconds of a window are left to its neighbours,
    /// which hear what comes before and after those seconds.
    static let hop = 320_000
    static let edge = 80000
    static let frameSamples = 320

    /// `--aligner-model DIR` keeps the model elsewhere, for testing.
    static var folder: URL {
        if let dir = TestFlags.value("--aligner-model") { return URL(fileURLWithPath: dir) }
        return StemModel.folder.appending(path: "Aligner")
    }

    static var installed: Bool {
        ["Aligner.mlmodelc", "labels.json"].allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    private nonisolated(unsafe) static var loaded: Reader?
    private static let loading = NSLock()

    static func reader() throws -> Reader {
        try loading.withLock {
            if let loaded { return loaded }
            let reader = try Reader(folder: folder)
            loaded = reader
            return reader
        }
    }

    static func unload() { loading.withLock { loaded = nil } }

    private static let fitting = NSLock()

    /// Loads the model for one fit and unloads it after, since it takes about a gigabyte of memory while it is
    /// loaded. One fit runs at a time: a second one that started while the first still held the model would load a
    /// second copy of it.
    static func use<T>(_ fit: (Reader) throws -> T) throws -> T {
        try fitting.withLock {
            defer { unload() }
            return try fit(reader())
        }
    }

    final class Reader: LyricsReading {
        private let model: MLModel
        private let labels: [Character: Int]
        private let input: MLMultiArray
        /// The label that the model writes between words.
        let space: Int?

        init(folder: URL) throws {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            model = try MLModel(contentsOf: folder.appending(path: "Aligner.mlmodelc"), configuration: configuration)
            let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appending(path: "labels.json")))
            var labels: [Character: Int] = [:]
            // The first four labels are marks of the tokenizer, and the first of them is the blank.
            for (index, name) in names.enumerated() where index >= 4 && name.count == 1 { labels[name.first!] = index }
            self.labels = labels
            space = labels[" "]
            input = try MLMultiArray(shape: [1, NSNumber(value: AlignerModel.window)], dataType: .float32)
        }

        /// The model's label for a character of the lyrics: the character in lowercase, in the other form that
        /// Romanian keyboards write ș and ț in, or without its accent. Nil for punctuation and for anything else that
        /// the model doesn't write.
        func label(_ character: Character) -> Int? {
            guard character.isLetter || character.isNumber else { return nil }
            for candidate in String(character).lowercased() {
                if let label = labels[candidate] { return label }
                let other: [Character: Character] = ["ş": "ș", "ţ": "ț", "ș": "ş", "ț": "ţ"]
                if let twin = other[candidate], let label = labels[twin] { return label }
                let bare = String(candidate).folding(options: .diacriticInsensitive, locale: nil)
                if let first = bare.first, let label = labels[first] { return label }
            }
            return nil
        }

        func emissions(_ samples: [Float], columns: [Int], stop: () -> Bool) throws -> ForcedAligner.Emissions? {
            try emissions(samples, columns: columns, progress: { _ in }, stop: stop)
        }

        /// What the model reads in `samples`, mono at 16 kHz: for each 20 ms, the log-probability of the blank and of
        /// each of `columns`, the labels that the lyrics use. `progress` gets the part done, from 0 to 1, and the
        /// reading ends early with nil when `stop` says so.
        func emissions(_ samples: [Float], columns: [Int], progress: (Double) -> Void = { _ in }, stop: () -> Bool = { false }) throws -> ForcedAligner.Emissions? {
            let frames = samples.count / AlignerModel.frameSamples, width = columns.count + 1
            // Before the model reads a frame, the frame is silence: the blank is certain and no letter is.
            var values = [Float](repeating: -30, count: frames * width)
            for frame in 0 ..< frames { values[frame * width] = 0 }
            let window = AlignerModel.window, edge = AlignerModel.edge / AlignerModel.frameSamples
            var start = 0
            while start < samples.count {
                if stop() { return nil }
                let last = start + window >= samples.count
                var chunk = [Float](repeating: 0, count: window)
                let count = min(window, samples.count - start)
                chunk.replaceSubrange(0 ..< count, with: samples[start ..< start + count])
                // The model was trained on audio with zero mean and unit variance. A window without singing is left
                // as silence, since scaling it up would turn what the separation left of the instruments into a voice.
                var mean: Float = 0, deviation: Float = 0
                var normalised = [Float](repeating: 0, count: window)
                vDSP_normalize(chunk, 1, &normalised, 1, &mean, &deviation, vDSP_Length(window))
                if deviation > 1e-4 {
                    input.withUnsafeMutableBufferPointer(ofType: Float.self) { target, _ in
                        normalised.withUnsafeBufferPointer { target.baseAddress!.update(from: $0.baseAddress!, count: window) }
                    }
                    let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
                    guard let letters = result.featureValue(for: "letters")?.multiArrayValue, letters.shape.count == 3 else {
                        throw TranscriptionError(message: "The lyrics timing model returned nothing")
                    }
                    let from = start == 0 ? 0 : edge
                    let to = last ? letters.shape[1].intValue : AlignerModel.window / AlignerModel.frameSamples - edge
                    let base = start / AlignerModel.frameSamples
                    let rowStride = letters.strides[1].intValue, labelStride = letters.strides[2].intValue
                    letters.withUnsafeBufferPointer(ofType: Float.self) { read in
                        for frame in from ..< min(to, letters.shape[1].intValue) where base + frame < frames {
                            let row = read.baseAddress! + frame * rowStride
                            let out = (base + frame) * width
                            values[out] = row[0]
                            for (index, label) in columns.enumerated() { values[out + 1 + index] = row[label * labelStride] }
                        }
                    }
                }
                if last { break }
                start += AlignerModel.hop
                progress(min(1, Double(start) / Double(samples.count)))
            }
            progress(1)
            return ForcedAligner.Emissions(frames: frames, width: width, values: values)
        }
    }
}
