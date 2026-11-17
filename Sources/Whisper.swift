import Foundation
import Synchronization

struct WhisperWord: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
    let words: [WhisperWord]
}

enum WhisperError: Error, CustomStringConvertible {
    case modelNotLoaded(String)
    case transcriptionFailed(Int32)
    case modelFreed

    var description: String {
        switch self {
        case let .modelNotLoaded(path): "could not load the Whisper model at \(path)"
        case let .transcriptionFailed(code): "Whisper failed with code \(code)"
        case .modelFreed: "the Whisper model was freed because the app is quitting"
        }
    }
}

/// The lowest level of whisper.cpp and ggml log lines that reach stderr. Loading a model prints dozens of lines at the
/// info level, which only help when checking that Metal is used.
nonisolated(unsafe) var whisperLogLevel = GGML_LOG_LEVEL_WARN

/// Speech to text with whisper.cpp, on the GPU through Metal, from a ggml model file such as `ggml-large-v3-turbo.bin`.
/// One engine holds the model in memory. It is meant for a background thread, and the lock makes concurrent calls wait
/// for each other, because a whisper context can run only one transcription at a time.
final class WhisperEngine: @unchecked Sendable {
    init(modelPath: String, beamSize: Int = 5) throws {
        whisper_log_set({ level, text, _ in
            guard let text, level != GGML_LOG_LEVEL_CONT, level.rawValue >= whisperLogLevel.rawValue else { return }
            fputs(text, stderr)
        }, nil)

        var params = whisper_context_default_params()
        params.use_gpu = true
        // Flash attention makes the encoder faster on Metal. whisper.cpp turns off the DTW word timing when it is on,
        // so the word times come from the timestamp tokens instead.
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.modelNotLoaded(modelPath)
        }
        self.context = context
        self.beamSize = beamSize
        Self.track(self)
    }

    deinit {
        Self.untrack(self)
        unload()
    }

    /// Transcribes 16 kHz mono samples. A nil language lets Whisper detect it. The prompt is text that the audio is
    /// likely to contain, such as known lyrics or names, and makes Whisper prefer those spellings.
    func transcribe(_ samples: [Float], language: String?, prompt: String?) throws -> [WhisperSegment] {
        guard !samples.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let context else { throw WhisperError.modelFreed }

        // Beam search with 5 beams is what the reference Whisper uses for its best accuracy. It takes about a third
        // longer than greedy decoding, because the encoder does most of the work and large-v3-turbo has only 4 decoder
        // layers.
        var params = whisper_full_default_params(beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.beam_search.beam_size = Int32(max(beamSize, 1))
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.token_timestamps = true
        params.no_context = true
        params.abort_callback = { engine in
            Unmanaged<WhisperEngine>.fromOpaque(engine!).takeUnretainedValue().quitting.load(ordering: .relaxed)
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(self).toOpaque()

        let language = language.flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        let code = language.withCString { languagePointer in
            withOptionalCString(prompt.flatMap { $0.isEmpty ? nil : $0 }) { promptPointer in
                params.language = languagePointer
                params.initial_prompt = promptPointer
                return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard code == 0 else { throw WhisperError.transcriptionFailed(code) }

        return (0 ..< whisper_full_n_segments(context)).map { segment(at: $0, in: context) }
    }

    private var context: OpaquePointer?
    private let beamSize: Int
    private let lock = NSLock()
    private let quitting = Atomic(false)

    private func unload() {
        lock.lock()
        defer { lock.unlock() }
        if let context { whisper_free(context) }
        context = nil
    }

    // ggml frees its Metal device in a C++ static destructor when the process exits, and it aborts the app if a model
    // still holds GPU memory at that point. Every loaded model is freed first, by an exit handler that runs before that
    // destructor because it is registered after the first model loads. A transcription that is still running stops
    // at its next step.
    private static let engines = Mutex([ObjectIdentifier: Weak]())
    private static let freeOnExit: Void = { atexit { WhisperEngine.freeAll() } }()

    private struct Weak: Sendable {
        weak var engine: WhisperEngine?
    }

    private static func track(_ engine: WhisperEngine) {
        _ = freeOnExit
        engines.withLock { $0[ObjectIdentifier(engine)] = Weak(engine: engine) }
    }

    private static func untrack(_ engine: WhisperEngine) {
        _ = engines.withLock { $0.removeValue(forKey: ObjectIdentifier(engine)) }
    }

    private static func freeAll() {
        let live = engines.withLock { $0.values.compactMap(\.engine) }
        for engine in live {
            engine.quitting.store(true, ordering: .relaxed)
            engine.unload()
        }
    }

    private func segment(at index: Int32, in context: OpaquePointer) -> WhisperSegment {
        let start = whisper_full_get_segment_t0(context, index)
        let end = max(whisper_full_get_segment_t1(context, index), start)
        let text = String(cString: whisper_full_get_segment_text(context, index))
        return WhisperSegment(start: seconds(start), end: seconds(end),
                              text: text.trimmingCharacters(in: .whitespaces), words: words(in: index, of: context, from: start, to: end))
    }

    /// Joins the tokens of a segment into words. A token that starts with a space starts a new word, unless it holds
    /// only punctuation, which stays on the word before it. The bytes are joined before they are decoded, because a
    /// character that takes more than one byte in UTF-8 can be split over two tokens.
    private func words(in segment: Int32, of context: OpaquePointer, from segmentStart: Int64, to segmentEnd: Int64) -> [WhisperWord] {
        let firstSpecial = whisper_token_eot(context)
        var words: [WhisperWord] = []
        var bytes: [UInt8] = []
        var start: Int64 = 0
        var end: Int64 = 0

        func finishWord() {
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                words.append(WhisperWord(start: seconds(start), end: seconds(max(end, start)), text: text))
            }
            bytes.removeAll()
        }

        for i in 0 ..< whisper_full_n_tokens(context, segment) {
            let token = whisper_full_get_token_data(context, segment, i)
            // Tokens from the end of text onwards are markers such as [_BEG_] and the timestamps [_TT_…], not words.
            guard token.id < firstSpecial, let cText = whisper_full_get_token_text(context, segment, i) else { continue }
            let piece = Array(UnsafeRawBufferPointer(start: cText, count: strlen(cText)))
            guard !piece.isEmpty else { continue }

            let startsWord = piece[0] == 0x20 && piece.dropFirst().contains(where: isWordByte)
            if startsWord, !bytes.isEmpty { finishWord() }
            let tokenStart = min(max(token.t0, segmentStart), segmentEnd)
            let tokenEnd = min(max(token.t1, tokenStart), segmentEnd)
            if bytes.isEmpty { start = tokenStart }
            bytes += piece
            end = tokenEnd
        }
        finishWord()
        return words
    }
}

/// Letters and digits in ASCII, and every byte of a character outside ASCII.
private func isWordByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x80...: true
    default: false
    }
}

/// whisper.cpp counts time in units of 10 ms.
private func seconds(_ time: Int64) -> Double { Double(time) / 100 }

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
