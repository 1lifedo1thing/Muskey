import AVFoundation
import Foundation

/// A note that MuScriptor heard: when it starts and ends, in seconds from the start of the audio, its MIDI pitch, and
/// the General MIDI program of its instrument group. A drum hit has the General MIDI percussion note as its pitch,
/// program 128, and lasts 10 ms. The model hears no velocity.
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

/// Turns audio into notes with MuScriptor (Kyutai and Mirelo), through the muskey-transcribe helper in
/// Contents/Helpers. The helper is an executable of its own because it links its own copy of ggml, which would clash
/// with the one that whisper.cpp brings into the app.
enum Transcriber {
    static var helperURL: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/muskey-transcribe") }
    /// MuScriptor Medium, which ModelDownload.transcriber puts next to the other models.
    static var modelURL: URL { StemModel.folder.appending(path: "muscriptor-medium-f16.gguf") }
    static var installed: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// The notes in an audio file that Core Audio reads, sorted by start.
    ///
    /// - `instruments`: MuScriptor's instrument groups, such as `Stem.instruments`. The model is told that only these
    ///   play, and no other instrument can appear in the notes. Empty lets any instrument appear.
    /// - `gain`: decibels added to the audio before the model hears it. How many notes the model finds depends on the
    ///   level, and a stem keeps the level it had in the mix.
    /// - `model`: a GGUF other than the downloaded one.
    /// - `progress`: from 0 to 1, after every 5 seconds of audio, on a background thread.
    ///
    /// Cancelling the task stops the helper.
    static func transcribe(_ audio: URL, instruments: [String] = [], gain: Double = 0, model: URL? = nil,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscribedNote]
    {
        let model = model ?? modelURL
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError(message: "The transcription model isn't downloaded")
        }
        var arguments = ["--model", model.path]
        if !instruments.isEmpty { arguments += ["--instrument", instruments.joined(separator: ",")] }
        if gain != 0 { arguments += ["--gain", String(format: "%.2f", gain)] }
        arguments.append(audio.path)

        let helper = Helper(arguments: arguments)
        return try await withTaskCancellationHandler {
            try helper.start()
            async let notes = readNotes(helper.output)
            async let failure = readStatus(helper.errors, progress: progress)
            let (found, error) = await (notes, failure)
            let status = await helper.exit()
            if Task.isCancelled { throw CancellationError() }
            guard status == 0 else {
                throw TranscriptionError(message: error ?? "The transcriber stopped with status \(status)")
            }
            // The helper prints each note when it closes, which is not quite the order the notes start in.
            return found.sorted { ($0.start, $0.drum ? 1 : 0, $0.program, $0.pitch) < ($1.start, $1.drum ? 1 : 0, $1.program, $1.pitch) }
        } onCancel: {
            helper.stop()
        }
    }

    /// The notes in `samples`, mono at `sampleRate`, for a stem that is in memory rather than in a file. The samples go
    /// to the helper through a temporary WAV file, which is deleted afterwards.
    static func transcribe(samples: [Float], sampleRate: Double, instruments: [String] = [], gain: Double = 0,
                           model: URL? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscribedNote]
    {
        let url = FileManager.default.temporaryDirectory.appending(path: "muskey-transcribe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWAV(samples, sampleRate: sampleRate, to: url)
        return try await transcribe(url, instruments: instruments, gain: gain, model: model, progress: progress)
    }

    private static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw TranscriptionError(message: "The stem can't be written for the transcriber") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        file.close()
    }

    private static func readNotes(_ handle: FileHandle) async -> [TranscribedNote] {
        await readLines(handle, into: [TranscribedNote]()) { notes, line in
            if let note = try? JSONDecoder().decode(TranscribedNote.self, from: Data(line.utf8)) { notes.append(note) }
        }
    }

    /// Passes on the progress lines, and returns the reason the helper gave for failing, if it gave one.
    private static func readStatus(_ handle: FileHandle, progress: @escaping @Sendable (Double) -> Void) async -> String? {
        await readLines(handle, into: String?.none) { failure, line in
            if line.hasPrefix("progress "), let value = Double(line.dropFirst(9)) {
                progress(value)
            } else if line.hasPrefix("error: ") {
                failure = String(line.dropFirst(7))
            }
        }
    }

    /// Hands each line that the helper writes to `handle` to `add` as soon as the line is complete, until the helper
    /// closes it. `FileHandle.bytes` held lines back and delivered several at once, which made the progress jump.
    private static func readLines<Result: Sendable>(_ handle: FileHandle, into initial: Result,
                                                    _ add: @escaping @Sendable (inout Result, String) -> Void) async -> Result
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result = initial
                var pending = Data()
                // The read returns nothing once the helper has exited, which a cancel makes happen at once.
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        add(&result, String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex ... newline)
                    }
                }
                if !pending.isEmpty { add(&result, String(decoding: pending, as: UTF8.self)) }
                continuation.resume(returning: result)
            }
        }
    }

    /// The helper's process. A task can be cancelled before the process starts, so `stop()` remembers that and
    /// `start()` then doesn't run it.
    private final class Helper: @unchecked Sendable {
        let output: FileHandle
        let errors: FileHandle
        private let process = Process()
        private let lock = NSLock()
        private var stopped = false
        private let exits: AsyncStream<Int32>
        private let exited: AsyncStream<Int32>.Continuation

        init(arguments: [String]) {
            let out = Pipe(), err = Pipe()
            output = out.fileHandleForReading
            errors = err.fileHandleForReading
            process.executableURL = Transcriber.helperURL
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            (exits, exited) = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = { [exited] process in
                exited.yield(process.terminationStatus)
                exited.finish()
            }
        }

        func start() throws {
            try lock.withLock {
                guard !stopped else { throw CancellationError() }
                try process.run()
            }
        }

        func stop() {
            lock.withLock {
                stopped = true
                if process.isRunning { process.terminate() }
            }
        }

        func exit() async -> Int32 {
            var status: Int32 = -1
            for await code in exits { status = code }
            return status
        }
    }
}

extension Stem {
    /// The MuScriptor instrument groups that this stem is transcribed with. Guitar and winds list every group that
    /// the stem can hold, and the model picks one for each note. Other can hold any instrument, so it has none.
    var instruments: [String] {
        switch self {
        case .bass: ["electric_bass"]
        case .drums: ["drums"]
        case .vocals: ["voice"]
        case .piano: ["acoustic_piano"]
        case .guitar: ["clean_electric_guitar", "distorted_electric_guitar", "acoustic_guitar"]
        case .winds: [
                "trumpet", "trombone", "tuba", "french_horn", "brass_section", "soprano_and_alto_sax", "tenor_sax",
                "baritone_sax", "oboe", "english_horn", "bassoon", "clarinet", "flutes",
            ]
        case .other: []
        }
    }
}
