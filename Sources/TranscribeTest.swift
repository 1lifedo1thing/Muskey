import AVFoundation

/// `--transcribe FILE` turns an audio file into notes with MuScriptor, through the helper the way the app runs it,
/// prints how many notes it found, the first ones and how long it took, and quits.
/// - `--instrument NAME[,NAME...]` limits the notes to those instrument groups, and a stem's name (`bass`, `guitar`...)
///   picks that stem's groups.
/// - `--transcribe-model PATH` uses that GGUF instead of the downloaded one.
/// - `--transcribe-gain DB` changes the level of the audio before the model hears it.
enum TranscribeTest {
    static func run(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let instruments: [String] = TestFlags.value("--instrument").map { value in
            if let stem = Stem.allCases.first(where: { $0.name.lowercased() == value.lowercased() }) { return stem.instruments }
            return value.split(separator: ",").map(String.init)
        } ?? []
        let model = TestFlags.value("--transcribe-model").map { URL(fileURLWithPath: $0) }
        let gain = TestFlags.value("--transcribe-gain").flatMap(Double.init) ?? 0
        let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        print(String(format: "audio: %.1fs, instruments: %@", duration, instruments.isEmpty ? "any" : instruments.joined(separator: ",")))

        Task.detached {
            let started = Date()
            do {
                let notes = try await Transcriber.transcribe(url, instruments: instruments, gain: gain, model: model) { progress in
                    print(String(format: "%.0f%%", progress * 100), terminator: " ")
                    fflush(stdout)
                }
                let took = Date().timeIntervalSince(started)
                print("")
                for note in notes.prefix(12) {
                    print(String(format: "[%7.2f–%7.2f] %@ %3d  program %3d", note.start, note.end,
                                 note.drum ? "drum" : name(note.pitch).padding(toLength: 4, withPad: " ", startingAt: 0), note.pitch, note.program))
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
