import AVFoundation

/// `--transcribe FILE` turns an audio file into notes with Dettato the way the notes window does with a stem, prints how
/// many notes it found, the first ones and how long it took, and quits. `--stem NAME` gives the notes the General MIDI
/// program of that stem.
enum TranscribeTest {
    static func run(_ path: String) {
        let stem = TestFlags.value("--stem").flatMap { name in Stem.allCases.first { $0.name.lowercased() == name.lowercased() } } ?? .bass
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData
        else {
            print("can't read \(path)")
            exit(1)
        }
        let count = Int(buffer.frameLength), width = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0 ..< width {
            for index in 0 ..< count { mono[index] += channels[channel][index] / Float(width) }
        }
        let duration = Double(count) / file.processingFormat.sampleRate
        let audio = Dettato.resample(mono, from: file.processingFormat.sampleRate)
        print(String(format: "audio: %.1fs, stem: %@", duration, stem.name))

        Task.detached {
            let started = Date()
            do {
                let notes = try Dettato.transcribe(audio, program: stem.program) { progress in
                    print(String(format: "%.0f%%", progress * 100), terminator: " ")
                    fflush(stdout)
                }
                let took = Date().timeIntervalSince(started)
                print("")
                for note in notes.prefix(12) {
                    print(String(format: "[%7.2f–%7.2f] %@ %3d", note.start, note.end,
                                 name(note.pitch).padding(toLength: 4, withPad: " ", startingAt: 0), note.pitch))
                }
                if let low = notes.map(\.pitch).min(), let high = notes.map(\.pitch).max() {
                    print("pitches \(low)–\(high) (\(name(low))–\(name(high)))")
                }
                print(String(format: "%d notes in %.2fs, %.1fx faster than real time", notes.count, took, took > 0 ? duration / took : 0))
                exit(0)
            } catch {
                print("\ntranscription failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// The note's name with its octave, where C4 is middle C (MIDI 60).
    private static func name(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((pitch % 12) + 12) % 12] + String(pitch / 12 - 1)
    }
}
