import Foundation

/// Whisper on the Mac, from the model downloaded in Settings. One engine, loaded on the first phrase and freed five
/// minutes after the last one, since it holds 1.6 GB.
final class WhisperModel: WhisperBackend, @unchecked Sendable {
    static let shared = WhisperModel()

    static var url: URL { StemModel.folder.appending(path: "ggml-large-v3-turbo.bin") }
    static var installed: Bool { FileManager.default.fileExists(atPath: url.path) }
    static func unload() { shared.queue.async { shared.engine = nil } }

    private let queue = DispatchQueue(label: "muskey.whisper", qos: .utility)
    private var engine: WhisperEngine?
    private var release: DispatchWorkItem?

    func words(in samples: [Float], language: String?, prompt: String?) async throws -> [LyricsAligner.Heard] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                release?.cancel()
                do {
                    if engine == nil { engine = try WhisperEngine(modelPath: Self.url.path) }
                    let segments = try engine!.transcribe(samples, language: language, prompt: prompt)
                    let words = segments.flatMap { segment -> [LyricsAligner.Heard] in
                        let words = segment.words.compactMap { word -> LyricsAligner.Heard? in
                            let text = Whisper.clean(word.text)
                            return text.isEmpty ? nil : LyricsAligner.Heard(start: word.start, end: word.end, text: text)
                        }
                        if !words.isEmpty { return words }
                        return LyricsListener.split(LyricsAligner.Heard(start: segment.start, end: segment.end, text: Whisper.clean(segment.text)))
                    }
                    continuation.resume(returning: words)
                } catch {
                    continuation.resume(throwing: error)
                }
                let release = DispatchWorkItem { [weak self] in self?.engine = nil }
                self.release = release
                queue.asyncAfter(deadline: .now() + 300, execute: release)
            }
        }
    }
}
