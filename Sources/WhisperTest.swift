import AVFoundation

/// `--whisper-file PATH --whisper-model MODEL` transcribes an audio file with whisper.cpp, prints each segment and the
/// time of every word, how long the model took to load and to transcribe, and quits. `--whisper-language`,
/// `--whisper-prompt` and `--whisper-beam` (1 for greedy decoding) change the transcription, and `--whisper-verbose`
/// shows the whisper.cpp log.
enum WhisperTest {
    static func run(file: String, model: String) {
        guard !model.isEmpty else {
            print("usage: --whisper-file AUDIO --whisper-model ggml-large-v3-turbo.bin")
            exit(1)
        }
        if TestFlags.has("--whisper-verbose") { whisperLogLevel = GGML_LOG_LEVEL_INFO }
        DispatchQueue.global().async {
            do {
                let samples = try decode(URL(fileURLWithPath: file))
                let duration = Double(samples.count) / sampleRate
                print(String(format: "audio: %.1fs", duration))

                var started = Date()
                let beam = TestFlags.value("--whisper-beam").flatMap(Int.init) ?? 5
                let engine = try WhisperEngine(modelPath: model, beamSize: beam)
                print(String(format: "model loaded in %.2fs", Date().timeIntervalSince(started)))

                started = Date()
                let segments = try engine.transcribe(
                    samples, language: TestFlags.value("--whisper-language"), prompt: TestFlags.value("--whisper-prompt")
                )
                let took = Date().timeIntervalSince(started)

                for segment in segments {
                    print(String(format: "[%.2f–%.2f] ", segment.start, segment.end) + segment.text)
                    for word in segment.words {
                        print(String(format: "    [%.2f–%.2f] ", word.start, word.end) + word.text)
                    }
                }
                print(String(format: "transcribed in %.2fs with %@, %.1fx faster than real time", took,
                             beam > 1 ? "beam size \(beam)" : "greedy decoding", duration / took))
                exit(0)
            } catch {
                print("whisper failed: \(error)")
                exit(1)
            }
        }
    }

    private static let sampleRate = 16000.0

    /// Any file that AVAudioFile reads, mixed down to mono and resampled to the 16 kHz that Whisper expects.
    private static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: source)
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let capacity = AVAudioFrameCount(Double(source.frameLength) * sampleRate / input.sampleRate) + 4096
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw CocoaError(.fileReadCorruptFile) }
        var given = false
        var error: NSError?
        // The end of the stream makes the converter flush the samples that its resampler still holds.
        let status = converter.convert(to: target, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return source
        }
        if status == .error { throw error ?? CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
    }
}
