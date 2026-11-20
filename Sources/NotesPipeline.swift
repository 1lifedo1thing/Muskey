import Foundation

/// Everything the notes window needs for a song, kept in one file so that the window can be opened and tested without
/// the transcription model or the stems (`--notes-file FILE`).
struct NotesFixture: Codable {
    var title: String
    var stem: String
    var key: String?
    var bpm: Double
    var duration: Double
    var beats: [Double]
    var notes: [TranscribedNote]

    var stemValue: Stem { Stem.allCases.first { $0.name.lowercased() == stem.lowercased() } ?? .bass }
    var keyValue: DetectedKey? { key.flatMap(DetectedKey.init(name:)) }

    var score: Score { Score(notes: notes, stem: stemValue, beats: beats, bpm: bpm, key: keyValue, duration: duration) }
}

extension DetectedKey {
    /// `Em`, `F#`, `Bb`: the short name that `init(name:)` reads, with plain sharps and flats.
    var code: String {
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return names[pitchClass] + (minor ? "m" : "")
    }
}

enum NotesPipeline {
    /// The left and right channels of one stem of a song whose stems are in the cache, mixed to mono.
    static func stemSamples(_ cache: StemsCache, stem: Stem) -> [Float] {
        let frames = cache.frames
        var planes = [Float](repeating: 0, count: frames * 2)
        planes.withUnsafeMutableBufferPointer { buffer in
            cache.copy([stem.rawValue * 2, stem.rawValue * 2 + 1], from: 0, count: frames, into: buffer.baseAddress!)
        }
        return (0 ..< frames).map { (planes[$0] + planes[frames + $0]) * 0.5 }
    }

    /// The stems of the whole song from the cache, separating them first when the cache doesn't have them yet.
    @MainActor static func stems(for path: String, builder: StemsCacheBuilder, log: @escaping (String) -> Void) async -> StemsCache? {
        if let cache = StemsCache.open(for: path) { return cache }
        log("separating the whole song into stems")
        let done: Bool = await withCheckedContinuation { continuation in
            let previous = builder.onDone
            builder.onDone = { donePath, ok in
                previous(donePath, ok)
                guard donePath == path else { return }
                builder.onDone = previous
                continuation.resume(returning: ok)
            }
            builder.start(path)
        }
        return done ? StemsCache.open(for: path) : nil
    }

    /// `--notes-headless FILE [--stem NAME] [--notes-out DIR]`: the stems of the file from the cache (separated first if
    /// needed), the notes of one stem from Dettato, the beats and the key, and then the score written as MusicXML,
    /// MIDI and text tab next to the fixture that `--notes-file` opens.
    @MainActor static func headless(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let stem = TestFlags.value("--stem").flatMap { name in Stem.allCases.first { $0.name.lowercased() == name.lowercased() } } ?? .bass
        let out = URL(fileURLWithPath: TestFlags.value("--notes-out") ?? FileManager.default.temporaryDirectory.appending(path: "muskey-notes").path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let builder = StemsCacheBuilder()
        builder.log = { print($0) }
        Task { @MainActor in
            let started = Date()
            let duration = await ChordDetector.duration(url)
            guard let cache = await stems(for: path, builder: builder, log: { print($0) }) else {
                print("notes: the stems couldn't be separated")
                exit(1)
            }
            print(String(format: "stems ready after %.1f s", Date().timeIntervalSince(started)))
            let samples = stemSamples(cache, stem: stem)
            let transcribing = Date()
            let notes: [TranscribedNote]
            do {
                let audio = Dettato.resample(samples, from: StemsCache.rate)
                notes = try await Task.detached(priority: .userInitiated) {
                    try Dettato.transcribe(audio, program: stem.program) { progress in
                        print(String(format: "%.0f%%", progress * 100), terminator: " ")
                        fflush(stdout)
                    }
                }.value
            } catch {
                print("\nnotes: transcription failed: \(error.localizedDescription)")
                exit(1)
            }
            print(String(format: "\n%d notes in %.1f s", notes.count, Date().timeIntervalSince(transcribing)))
            let grid = await ChordDetector.analyse(url, duration: duration)
            let analysis = await QueueItem.analyse(url, duration: duration)
            let fixture = NotesFixture(title: url.deletingPathExtension().lastPathComponent, stem: stem.name, key: analysis.key?.code,
                                       bpm: grid?.bpm ?? analysis.bpm ?? 120, duration: duration, beats: grid?.beats ?? [], notes: notes)
            let score = fixture.score
            let name = "\(fixture.title) \(stem.name)"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(fixture).write(to: out.appending(path: "\(name).json"))
            try? score.musicXML(title: fixture.title).write(to: out.appending(path: "\(name).musicxml"), atomically: true, encoding: .utf8)
            try? score.midi.write(to: out.appending(path: "\(name).mid"))
            if stem == .bass || stem == .guitar { try? score.textTab.write(to: out.appending(path: "\(name).txt"), atomically: true, encoding: .utf8) }
            print("key \(fixture.key ?? "unknown"), \(Int(fixture.bpm.rounded())) BPM, \(score.bars.count) bars, \(score.notes.count) notes placed")
            print("wrote \(out.path)/\(name).{json,musicxml,mid\(stem == .bass || stem == .guitar ? ",txt" : "")}")
            exit(0)
        }
    }
}
