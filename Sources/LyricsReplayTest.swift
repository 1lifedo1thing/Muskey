import AVFoundation
import Foundation

/// `--lyrics-replay FILE --whisper-server URL` plays a song file through the lyrics code several times, four times
/// faster than real time, as a song that has no lyrics, so Whisper writes them and each play saves what it covered.
/// `--plays 0-60,0-120` sets each play in seconds of the song, with `end` for the end of the file. `0-40+90-130`
/// seeks from 40 to 90 seconds in one play, and `0-40+p5+40-90` pauses for 5 seconds at 40. Prints what each play sent to Whisper, where it asked for the lyrics
/// delay, and what it saved. Uses a store of its own, in /tmp.
enum LyricsReplayTest {
    /// Hands over the samples that the test pushes, as the system tap would.
    final class FileTap: AudioTapping {
        let sampleRate: Double
        var onSamples: (([Float]) -> Void)?
        init(rate: Double) { sampleRate = rate }
        func prepare() throws {}
        func start(onSamples: @escaping ([Float]) -> Void) throws { self.onSamples = onSamples }
        func stop() { onSamples = nil }
    }

    /// Counts the clips and the seconds sent to Whisper.
    final class Counter: WhisperBackend, @unchecked Sendable {
        let inner: WhisperBackend
        let lock = NSLock()
        var clips = 0
        var seconds = 0.0
        init(_ inner: WhisperBackend) { self.inner = inner }

        func words(in samples: [Float], language: String?, prompt: String?) async throws -> [LyricsAligner.Heard] {
            lock.withLock {
                clips += 1
                seconds += Double(samples.count) / 16000
            }
            return try await inner.words(in: samples, language: language, prompt: prompt)
        }

        func take() -> (clips: Int, seconds: Double) {
            lock.withLock {
                defer { clips = 0; seconds = 0 }
                return (clips, seconds)
            }
        }
    }

    @MainActor static func run(file: String, server: String, plays spec: String) {
        guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: file)),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil, let channels = buffer.floatChannelData
        else {
            print("can't read \(file)")
            exit(1)
        }
        guard let parsed = WhisperServer(server) else {
            print("not a server URL: \(server)")
            exit(1)
        }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount), rate = buffer.format.sampleRate
        let mono = (0 ..< frames).map { i in (0 ..< count).reduce(Float(0)) { $0 + channels[$1][i] } / Float(count) }
        let duration = Double(frames) / rate
        let plays = spec.split(separator: ",").map { play in
            play.split(separator: "+").compactMap { part -> (Double, Double)? in
                // A pause is a part that ends where it starts, and lasts its length in silence.
                if part.hasPrefix("p"), let length = Double(part.dropFirst()) { return (-length, -length) }
                let ends = part.split(separator: "-").map { $0 == "end" ? duration : Double($0) }
                guard ends.count == 2, let from = ends[0], let to = ends[1], from < to else { return nil }
                return (from, min(to, duration))
            }
        }

        let url = URL(fileURLWithPath: "/tmp/muskey-lyrics-replay.json")
        try? FileManager.default.removeItem(at: url)
        let store = LyricsStore(url: url)
        let counter = Counter(parsed)
        let sync = LyricsSync(store: store)
        let id = "replay"
        var position = 0.0
        sync.log = { print("    " + $0) }
        sync.whisper = { counter }
        sync.onNeedsLead = { print(String(format: "    the lyrics delay starts at %.1fs", position)) }

        Task { @MainActor in
            for (index, play) in plays.enumerated() {
                print("play \(index + 1): " + play.map { $0.0 < 0 ? String(format: "a pause of %.0fs", -$0.0) : String(format: "%.0fs to %.0fs", $0.0, $0.1) }
                    .joined(separator: ", then ")
                    + String(format: " of %.0fs", duration))
                let covered = store.covered(for: id)
                let earlier = store.written(for: id).flatMap { Lyrics.parse(lrc: $0) }?.lines ?? []
                if LyricsCoverage.complete(covered, duration: duration) {
                    print("    the whole song was transcribed before, \(earlier.count) lines, nothing sent to Whisper")
                    continue
                }
                let tap = FileTap(rate: rate)
                sync.makeTap = { tap }
                _ = sync.transcribe(song: id, written: earlier, covered: covered, duration: duration)
                for _ in 0 ..< 200 where tap.onSamples == nil { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(300))
                let step = Int(rate / 10)
                for part in play {
                    if part.0 < 0 {
                        // Silence through the tap while the player reports no position, as in a pause.
                        for _ in 0 ..< Int(-part.0 * 10) {
                            tap.onSamples?([Float](repeating: 0, count: step))
                            sync.mark(position: nil)
                            try? await Task.sleep(for: .milliseconds(25))
                        }
                        continue
                    }
                    for start in stride(from: Int(part.0 * rate), to: Int(part.1 * rate), by: step) {
                        tap.onSamples?(Array(mono[start ..< min(frames, start + step)]))
                        position = Double(min(frames, start + step)) / rate
                        sync.mark(position: position)
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
                // The play ends as it does when the next song starts, and Whisper finishes the last phrases after it.
                sync.end()
                for _ in 0 ..< 160 where sync.finishingCount > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                let sent = counter.take()
                let lines = (store.written(for: id).flatMap { Lyrics.parse(lrc: $0) }?.lines ?? []).filter { !$0.text.isEmpty }
                let ranges = store.covered(for: id).map { String(format: "%.1f–%.1f", $0.lowerBound, $0.upperBound) }
                print(String(format: "    sent %d clips, %.1fs of audio, to Whisper", sent.clips, sent.seconds))
                print("    saved \(lines.count) lines, covered \(ranges.joined(separator: ", "))")
            }
            let lines = (store.written(for: id).flatMap { Lyrics.parse(lrc: $0) }?.lines ?? [])
            for line in lines { print(String(format: "  [%6.2f] ", line.time) + line.text) }
            exit(0)
        }
    }
}
