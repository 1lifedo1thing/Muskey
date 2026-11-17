import AVFoundation
import Foundation

/// Something that listens to the song and hears words, timed in seconds of the audio fed to it: Apple's speech model,
/// or Whisper on a server or on the Mac.
protocol LyricsHearing: AnyObject {
    var onWords: ([LyricsAligner.Heard]) -> Void { get set }
    var onDownload: () -> Void { get set }
    /// Seconds of audio fed so far.
    var seconds: Double { get }
    func start() async throws
    func stop()
    func feed(_ samples: [Float])
}

extension LyricsListener: LyricsHearing {}

/// Whisper, wherever it runs: the words in a clip of 16 kHz mono audio, timed from the start of the clip.
protocol WhisperBackend: Sendable {
    func words(in samples: [Float], language: String?, prompt: String?) async throws -> [LyricsAligner.Heard]
}

/// A server with the OpenAI transcription API (`POST {base}/audio/transcriptions`). Word times come from servers that
/// give them (`verbose_json` with word timestamps); otherwise the words share the time of their segment, or of the
/// whole clip, by their length.
struct WhisperServer: WhisperBackend {
    let base: URL

    struct Failure: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { "HTTP \(status): \(body.prefix(200))" }
    }

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed), url.scheme?.hasPrefix("http") == true else { return nil }
        base = url
    }

    func words(in samples: [Float], language: String?, prompt: String?) async throws -> [LyricsAligner.Heard] {
        let boundary = "muskey-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(Self.wav(samples))
        body.append(Data("\r\n".utf8))
        field("model", "whisper-1")
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "word")
        field("timestamp_granularities[]", "segment")
        field("temperature", "0")
        if let language { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        // Dictation servers clean up what they hear; sung words are kept as they are.
        field("fix", "0")
        field("cleanup", "0")
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: base.appending(path: "audio/transcriptions"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let duration = Double(samples.count) / 16000

        if let words = json["words"] as? [[String: Any]], !words.isEmpty {
            return words.compactMap { word in
                guard let text = (word["word"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
                      let start = word["start"] as? Double, let end = word["end"] as? Double else { return nil }
                return LyricsAligner.Heard(start: start, end: end, text: text)
            }
        }
        if let segments = json["segments"] as? [[String: Any]], !segments.isEmpty {
            return segments.flatMap { segment -> [LyricsAligner.Heard] in
                guard let text = segment["text"] as? String, let start = segment["start"] as? Double, let end = segment["end"] as? Double else { return [] }
                return LyricsListener.split(LyricsAligner.Heard(start: start, end: min(end, duration), text: Whisper.clean(text)))
            }
        }
        let text = Whisper.clean(json["text"] as? String ?? "")
        return LyricsListener.split(LyricsAligner.Heard(start: 0, end: duration, text: text))
    }

    /// 16-bit mono WAV at 16 kHz, the format every Whisper server reads.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8)); put(UInt32(36) + bytes); data.append(Data("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16000)); put(UInt32(32000)); put(UInt16(2)); put(UInt16(16))
        data.append(Data("data".utf8)); put(bytes)
        for sample in samples { put(Int16(max(-1, min(1, sample)) * 32767)) }
        return data
    }
}

enum Whisper {
    /// What Whisper writes on music and silence that nobody sang, and the marks it puts around sung parts.
    private static let made = ["thank you for watching", "thanks for watching", "subtitles by", "please subscribe", "amara.org"]

    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "♪", with: " ").replacingOccurrences(of: "♫", with: " ")
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        let lowered = text.lowercased()
        if made.contains(where: lowered.contains) { return "" }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What Whisper writes for a clip of music that nobody sings in, in the language that it guesses for the clip.
    private static let music: Set<String> = [
        "music", "musica", "música", "muzica", "muzică", "musik", "musique", "muziek", "muzyka", "музыка", "instrumental",
    ]

    /// The words of a clip, or none when the clip holds nothing but a word for music. A sung "music" in a longer
    /// phrase stays.
    static func sung(_ words: [LyricsAligner.Heard]) -> [LyricsAligner.Heard] {
        let text = words.map(\.text).joined(separator: " ").lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return music.contains(text) ? [] : words
    }
}

/// Hears the song through Whisper, a phrase at a time. With the vocals alone, a phrase ends at a pause in the singing;
/// with the whole song, every few seconds. The phrases go to Whisper one after another, and the words come back
/// timed in seconds of the audio fed.
final class WhisperTranscriber: LyricsHearing, @unchecked Sendable {
    var onWords: ([LyricsAligner.Heard]) -> Void = { _ in }
    var onDownload: () -> Void = {}
    /// The phrases of the last call, each with its words, in seconds of the audio fed: for lyrics written from them.
    var onPhrases: ([[LyricsAligner.Heard]]) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }

    let inputRate: Double
    /// The audio fed is the vocals alone, so a pause in it is a pause in the singing.
    let vocals: Bool
    var language: String?

    private let backend: WhisperBackend
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var fed = 0
    /// The 16 kHz audio not yet in a phrase, and where it starts in the audio fed.
    private var pending: [Float] = []
    private var pendingStart = 0
    private var speechStart: Int?
    private var lastSpeech = 0
    /// The next 20 ms frame of the 16 kHz audio to check for singing.
    private var scanned = 0
    private var clips: [(start: Int, samples: [Float])] = []
    /// Where the phrase that Whisper is hearing starts.
    private var inFlight: Int?
    /// Where the first phrase that Whisper failed on starts. Nothing after it counts as heard in this play.
    private var failedAt: Int?
    /// Where a seek left the song, in the audio fed: the phrase heard there ends at that point.
    private var breaks: [Int] = []
    /// Where the phrases that a seek cut short start. They don't count as heard, so the next play hears them whole.
    private var cutShort: [Int] = []
    private var phrases: [[LyricsAligner.Heard]] = []
    private var worker: Task<Void, Never>?
    private var running = false

    init(backend: WhisperBackend, inputRate: Double, vocals: Bool) {
        self.backend = backend
        self.inputRate = inputRate
        self.vocals = vocals
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    var seconds: Double { lock.withLock { Double(fed) / inputRate } }

    /// The song jumped to another place after `seconds` of the audio fed.
    func seek(at seconds: Double) {
        lock.withLock { breaks.append(Int(seconds * 16000)) }
    }

    /// Seconds of the audio fed where the phrases that a seek cut short start.
    var cutShortStarts: [Double] { lock.withLock { cutShort.map { Double($0) / 16000 } } }

    /// Seconds of the audio fed that Whisper is done with, sung or not: everything before the first phrase that is
    /// still queued, being heard, failed or not cut yet.
    var handled: Double {
        lock.withLock {
            let next = [inFlight, clips.first?.start, failedAt, speechStart, pendingStart].compactMap { $0 }.min() ?? pendingStart
            return Double(next) / 16000
        }
    }

    func start() async throws {
        lock.withLock { running = true }
        worker = Task.detached(priority: .utility) { [weak self] in await self?.work() }
    }

    func stop() {
        lock.withLock {
            running = false
            clips = []
        }
        worker?.cancel()
        worker = nil
    }

    func feed(_ samples: [Float]) {
        lock.withLock {
            fed += samples.count
            guard running, let converter, let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            source.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let capacity = AVAudioFrameCount(Double(samples.count) * 16000 / inputRate) + 32
            guard let target = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
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
            let converted = Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
            pending += converted
            cut()
        }
    }

    /// Phrases of the vocals: speech louder than about −44 dB, ended by half a second below it, and at most ten
    /// seconds long. The whole song is cut into clips of eight seconds.
    private func cut() {
        let frame = 320
        if !vocals {
            let length = 8 * 16000
            // A seek ends the clip, which is sent as it is and doesn't count as heard.
            while let point = breaks.first, point <= pendingStart + pending.count {
                breaks.removeFirst()
                guard point > pendingStart else { continue }
                let clip = Array(pending.prefix(point - pendingStart))
                if clip.count >= 16000 { clips.append((pendingStart, clip)) }
                cutShort.append(pendingStart)
                pending.removeFirst(point - pendingStart)
                pendingStart = point
            }
            while pending.count >= length {
                // Silence isn't sent, such as the parts of the song that were transcribed in an earlier play. The
                // level is the average over the clip, since the resampler rings for a moment before a sound starts.
                let clip = Array(pending.prefix(length))
                let rms = sqrt(clip.reduce(0) { $0 + $1 * $1 } / Float(length))
                if rms > 0.001 { clips.append((pendingStart, clip)) }
                pending.removeFirst(length)
                pendingStart += length
            }
            return
        }
        while scanned + frame <= pendingStart + pending.count {
            // A seek ends the phrase being sung, which is sent as it is and doesn't count as heard.
            if let point = breaks.first, scanned >= point {
                breaks.removeFirst()
                if let start = speechStart {
                    let from = max(pendingStart, start - 1600), to = min(scanned, pendingStart + pending.count)
                    if to - from >= 12000 { clips.append((from, Array(pending[(from - pendingStart) ..< (to - pendingStart)]))) }
                    cutShort.append(from)
                    speechStart = nil
                    pending.removeFirst(to - pendingStart)
                    pendingStart = to
                }
            }
            let local = scanned - pendingStart
            let slice = pending[local ..< local + frame]
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(frame))
            if rms > 0.006 {
                if speechStart == nil { speechStart = scanned }
                lastSpeech = scanned + frame
            }
            if let start = speechStart, scanned - lastSpeech >= 8000 || scanned + frame - start >= 10 * 16000 {
                // A tenth of a second around the singing, so Whisper hears whole words.
                let from = max(pendingStart, start - 1600), to = min(pendingStart + pending.count, lastSpeech + 1600)
                if to - from >= 12000 { clips.append((from, Array(pending[(from - pendingStart) ..< (to - pendingStart)]))) }
                speechStart = nil
                pending.removeFirst(to - pendingStart)
                pendingStart = to
                scanned = max(scanned + frame, to)
                continue
            }
            scanned += frame
        }
        // Without singing, only the last second is kept for the start of the next phrase.
        if speechStart == nil, pending.count > 16000 {
            let drop = pending.count - 16000
            pending.removeFirst(drop)
            pendingStart += drop
            scanned = max(scanned, pendingStart)
        }
    }

    private func work() async {
        var failures = 0
        while !Task.isCancelled {
            let clip: (start: Int, samples: [Float])? = lock.withLock {
                inFlight = clips.first?.start
                return clips.isEmpty ? nil : clips.removeFirst()
            }
            guard let clip else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let prompt = lock.withLock { phrases.last.map { $0.map(\.text).joined(separator: " ") } }
            do {
                let offset = Double(clip.start) / 16000
                let words = try await Whisper.sung(backend.words(in: clip.samples, language: language, prompt: prompt))
                    .map { LyricsAligner.Heard(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
                failures = 0
                guard !Task.isCancelled else { return }
                let (all, phrases) = lock.withLock { () -> ([LyricsAligner.Heard], [[LyricsAligner.Heard]]) in
                    if !words.isEmpty { self.phrases.append(words) }
                    inFlight = nil
                    return (self.phrases.flatMap { $0 }, self.phrases)
                }
                await MainActor.run {
                    onWords(all)
                    onPhrases(phrases)
                }
            } catch {
                failures += 1
                lock.withLock {
                    failedAt = min(failedAt ?? clip.start, clip.start)
                    inFlight = nil
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { onError(error) }
                // A server that keeps failing isn't asked again for every phrase.
                if failures >= 3 { try? await Task.sleep(for: .seconds(10)) }
            }
        }
    }
}

/// Separates the vocals from the song as it is heard, a few seconds behind it, for a transcriber. Every sample in
/// comes out once, in order, so the vocals keep the timing of the audio fed. Falls back to the whole song when the
/// model can't run.
final class VocalsFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "muskey.vocals", qos: .utility)
    private let inputRate: Double
    private let deliver: ([Float]) -> Void
    private var stream: StemStream?
    private var toModel: Resampler?
    private var failed = false
    private var stopped = false
    private var batch: [Float] = []

    /// `deliver` gets mono audio at 44.1 kHz, on a background queue.
    init(inputRate: Double, deliver: @escaping ([Float]) -> Void) {
        self.inputRate = inputRate
        self.deliver = deliver
    }

    func push(_ samples: [Float]) {
        queue.async { [self] in
            guard !stopped else { return }
            // A quarter of a second at a time keeps the queue short.
            batch += samples
            guard Double(batch.count) >= inputRate / 4 else { return }
            let chunk = batch
            batch = []
            run(chunk)
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            stream = nil
        }
    }

    private func run(_ samples: [Float]) {
        if toModel == nil, inputRate != StemModel.sampleRate { toModel = Resampler(from: inputRate, to: StemModel.sampleRate) }
        let converted = toModel.map { $0.convert(samples[...], samples[...]) } ?? [samples, samples]
        guard !failed else { return deliver(converted[0]) }
        do {
            if stream == nil { stream = try StemStream(model: StemModel.shared()) }
            for block in try stream!.push(converted[0][...], converted[1][...]) {
                let left = block[Stem.vocals.rawValue][0], right = block[Stem.vocals.rawValue][1]
                deliver(zip(left, right).map { ($0 + $1) / 2 })
            }
        } catch {
            failed = true
            deliver(converted[0])
        }
    }
}
