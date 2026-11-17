import AVFoundation
import Foundation
import NaturalLanguage
import os
import Speech

/// Transcribes the song while it plays, for timing lyrics that come without times. The speech model runs on the Mac,
/// in the language of the lyrics, and macOS downloads it once when it isn't on the Mac yet. `feed` takes the audio
/// from one thread at a time, and the words come back on the main thread, in seconds of the audio fed since `start`.
final class LyricsListener: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unsupported(Locale)
        case noFormat

        var description: String {
            switch self {
            case let .unsupported(locale): "no speech model for \(locale.identifier)"
            case .noFormat: "no audio format for the speech model"
            }
        }
    }

    /// The language of the lyrics, as one of the speech models' languages, or nil when no model knows it. A model
    /// that is on the Mac already comes first, then the one for the Mac's region, then the most common one.
    static func locale(for text: String) async -> Locale? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage?.rawValue else { return nil }
        let region = Locale.current.region?.identifier
        let common = ["en": "US", "es": "ES", "fr": "FR", "de": "DE", "pt": "BR", "it": "IT", "zh": "CN", "ja": "JP", "ko": "KR"][language]
        let regions = [region, common].compactMap { $0 }
        func pick(_ locales: [Locale]) -> Locale? {
            let same = locales.filter { $0.language.languageCode?.identifier == language }
            for region in regions { if let match = same.first(where: { $0.region?.identifier == region }) { return match } }
            return same.first
        }
        if let installed = await pick(SpeechTranscriber.installedLocales) { return installed }
        if let supported = await pick(SpeechTranscriber.supportedLocales) { return supported }
        if let installed = await pick(DictationTranscriber.installedLocales) { return installed }
        return await pick(DictationTranscriber.supportedLocales)
    }

    /// Every word heard so far, on the main thread, each time the model hears more. The last few words are the
    /// model's first guess, which it may still change.
    var onWords: ([LyricsAligner.Heard]) -> Void = { _ in }
    /// Words the model is sure of, and its guess at the words after them.
    private var final: [LyricsAligner.Heard] = []
    private var guess: [LyricsAligner.Heard] = []
    /// The end of the audio that the last guess covered.
    private var guessEnd = 0.0
    /// Called on the main thread while macOS downloads the speech model.
    var onDownload: () -> Void = {}

    let locale: Locale
    let inputRate: Double
    /// Words that the lyrics have, so the model expects them over similar sounding ones.
    var vocabulary: [String] = []

    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private let state = OSAllocatedUnfairLock(initialState: Feed())

    private struct Feed: @unchecked Sendable {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var outputFormat: AVAudioFormat?
        /// Frames given to the model, in its sample rate.
        var frames: Int64 = 0
    }

    init(locale: Locale, inputRate: Double) {
        self.locale = locale
        self.inputRate = inputRate
    }

    /// Seconds of audio given to the model so far, the clock that the words' times are on.
    var seconds: Double {
        state.withLock { feed in feed.outputFormat.map { Double(feed.frames) / $0.sampleRate } ?? 0 }
    }

    func start() async throws {
        let module: any SpeechModule
        if await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
            module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                       attributeOptions: [.audioTimeRange])
        } else if await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil {
            module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [.volatileResults, .frequentFinalization],
                                          attributeOptions: [.audioTimeRange])
        } else {
            throw Failure.unsupported(locale)
        }

        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: throw Failure.unsupported(locale)
        case .installed: break
        default:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                await MainActor.run { onDownload() }
                try await request.downloadAndInstall()
            }
        }

        guard let output = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw Failure.noFormat }

        let analyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
        try await analyzer.prepareToAnalyze(in: output)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        self.analyzer = analyzer

        results = Task { [weak self] in
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await result in transcriber.results { self?.deliver(result.text, range: result.range, final: result.isFinal) }
                } else if let transcriber = module as? DictationTranscriber {
                    for try await result in transcriber.results { self?.deliver(result.text, range: result.range, final: result.isFinal) }
                }
            } catch {}
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        state.withLock { feed in
            feed.continuation = continuation
            feed.converter = converter
            feed.inputFormat = input
            feed.outputFormat = output
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Mono samples at `inputRate`. Audio that arrives before the model is ready is dropped.
    func feed(_ samples: [Float]) {
        state.withLock { feed in
            guard let continuation = feed.continuation, let converter = feed.converter, let input = feed.inputFormat, let output = feed.outputFormat,
                  let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            source.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let capacity = AVAudioFrameCount(Double(samples.count) * output.sampleRate / input.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return source
            }
            guard error == nil, converted.frameLength > 0 else { return }
            let start = CMTime(value: feed.frames, timescale: CMTimeScale(output.sampleRate))
            feed.frames += Int64(converted.frameLength)
            continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
        }
    }

    /// Stops listening and drops what the model hasn't finished.
    func stop() {
        let continuation = state.withLock { feed in
            defer { feed.continuation = nil }
            return feed.continuation
        }
        continuation?.finish()
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    /// The model's guesses come as phrases with one time for the whole phrase, which is split between its words by
    /// their length.
    static func split(_ phrase: LyricsAligner.Heard) -> [LyricsAligner.Heard] {
        let parts = phrase.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count > 1 else { return parts.isEmpty ? [] : [LyricsAligner.Heard(start: phrase.start, end: phrase.end, text: parts[0])] }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var start = phrase.start
        return parts.map { part in
            let end = start + (phrase.end - phrase.start) * Double(part.count) / total
            defer { start = end }
            return LyricsAligner.Heard(start: start, end: end, text: part)
        }
    }

    /// Waits for the words of all the audio fed so far, for tests that feed a file.
    func finish() async throws {
        let continuation = state.withLock { feed in
            defer { feed.continuation = nil }
            return feed.continuation
        }
        continuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }

    /// Final results time each word. A guess, which comes about once a second, has one time for all its words, so
    /// the words that a guess adds to the one before it are placed in the second of audio between the two.
    private func deliver(_ text: AttributedString, range: CMTimeRange, final isFinal: Bool) {
        var words: [LyricsAligner.Heard] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            words += Self.split(LyricsAligner.Heard(start: range.start.seconds, end: range.end.seconds, text: String(text[run.range].characters)))
        }
        let start = range.start.seconds, end = range.end.seconds
        DispatchQueue.main.async { [self] in
            if isFinal {
                final += words
                guess = guess.filter { $0.start >= end }
            } else {
                let previous = guess.filter { $0.start >= start }
                var same = 0
                while same < min(previous.count, words.count),
                      Self.sameWord(words[same].text, previous[same].text) { same += 1 }
                var kept = Array(previous.prefix(same))
                for index in kept.indices { kept[index].text = words[index].text }
                let new = Array(words[same...])
                let from = same == previous.count && guessEnd > start ? max(guessEnd, kept.last?.end ?? start) : (kept.last?.end ?? start)
                guess = kept + Self.split(LyricsAligner.Heard(start: min(from, end), end: end, text: new.map(\.text).joined(separator: " ")))
                guessEnd = end
            }
            onWords(final + guess)
        }
    }

    /// The same word in two guesses, or the start of it in the first: `We'` and `We're`.
    private static func sameWord(_ new: String, _ old: String) -> Bool {
        let a = LyricsAligner.normalized(new), b = LyricsAligner.normalized(old)
        return a == b || (!b.isEmpty && a.hasPrefix(b))
    }
}
