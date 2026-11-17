import AVFoundation
import Foundation

/// `--lyrics-transcribe FILE` runs a song file through what Muskey does to write lyrics by ear: the vocals alone when
/// the stems model is on the Mac (`--no-vocals` skips them), cut into phrases, and Whisper on a server
/// (`--whisper-server URL`) or the model on the Mac. Prints each phrase with its time in the song, then quits.
enum LyricsTranscribeTest {
    @MainActor static func run(file: String, server: String?, vocals: Bool) {
        guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: file)),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil, let channels = buffer.floatChannelData
        else {
            print("can't read \(file)")
            exit(1)
        }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount), rate = buffer.format.sampleRate
        let mono = (0 ..< frames).map { i in (0 ..< count).reduce(Float(0)) { $0 + channels[$1][i] } / Float(count) }

        let backend: WhisperBackend
        if let server {
            guard let parsed = WhisperServer(server) else {
                print("not a server URL: \(server)")
                exit(1)
            }
            backend = parsed
        } else {
            guard WhisperModel.installed else {
                print("no Whisper model at \(WhisperModel.url.path); pass --whisper-server URL")
                exit(1)
            }
            backend = WhisperModel.shared
        }
        let separate = vocals && StemModel.installed
        let transcriber = WhisperTranscriber(backend: backend, inputRate: separate ? StemModel.sampleRate : rate, vocals: separate)
        let started = Date()
        var printed = 0, lastPhrase = Date()
        transcriber.onPhrases = { phrases in
            lastPhrase = Date()
            for phrase in phrases.dropFirst(printed) {
                guard let first = phrase.first, let last = phrase.last else { continue }
                print(String(format: "[%6.2f–%6.2f] ", first.start, last.end) + phrase.map(\.text).joined(separator: " "))
            }
            printed = phrases.count
        }
        transcriber.onError = { print("Whisper failed: \($0)") }
        Task { @MainActor in
            try? await transcriber.start()
            let feed = separate ? VocalsFeed(inputRate: rate) { transcriber.feed($0) } : nil
            let step = Int(rate / 10)
            for start in stride(from: 0, to: frames, by: step) {
                let chunk = Array(mono[start ..< min(frames, start + step)])
                if let feed { feed.push(chunk) } else { transcriber.feed(chunk) }
            }
            // A second of silence closes the last phrase. The vocals come out a block behind, and Whisper takes its
            // time, so the test waits until no phrase came for 30 seconds, at most 15 minutes.
            let silence = [Float](repeating: 0, count: Int(rate))
            for _ in 0 ..< 8 { if let feed { feed.push(silence) } else { transcriber.feed(silence) } }
            for _ in 0 ..< 900 {
                try? await Task.sleep(for: .seconds(1))
                if Date().timeIntervalSince(lastPhrase) > 30 { break }
            }
            print(String(format: "%d phrases in %.0fs, for %.0fs of audio%@", printed, Date().timeIntervalSince(started) - 30,
                         Double(frames) / rate, separate ? ", from the vocals" : ""))
            exit(0)
        }
    }
}
