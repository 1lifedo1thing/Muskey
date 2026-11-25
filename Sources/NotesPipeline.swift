import Accelerate
import Foundation
import os

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "NotesPipeline")

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

/// How much of the music each stem plays in, and the seconds of music that it was measured over.
struct StemActivity: Sendable {
    var shares: [Stem: Double]
    var seconds: Double
}

enum NotesPipeline {
    /// How much of the music each stem plays in, from 0 to 1: of the half seconds where the stems together are louder
    /// than −50 dB, the share where the stem is at most 20 dB below them. The parts of a capture that weren't heard
    /// are silent, so they count neither way. With `range`, only the music in those seconds of the song counts.
    static func activity(_ cache: StemsCache, range: ClosedRange<Double>? = nil) -> StemActivity {
        let window = Int(StemsCache.rate / 2)
        let frames = frames(of: range, in: cache)
        let stems = Stem.allCases.count
        var buffer = [Float](repeating: 0, count: StemsCache.planes * window)
        var mix = [Float](repeating: 0, count: window * 2)
        var music = 0
        var playing = [Int](repeating: 0, count: stems)
        var power = [Float](repeating: 0, count: stems)
        let floor = Float(window * 2) * 0.003 * 0.003
        for start in stride(from: frames.lowerBound, to: frames.upperBound, by: window) {
            buffer.withUnsafeMutableBufferPointer { cache.copy(Array(0 ..< StemsCache.planes), from: start, count: window, into: $0.baseAddress!) }
            var mixPower: Float = 0
            buffer.withUnsafeBufferPointer { planes in
                mix.withUnsafeMutableBufferPointer { out in
                    out.update(repeating: 0)
                    for s in 0 ..< stems {
                        var left: Float = 0, right: Float = 0
                        for channel in 0 ..< 2 {
                            let plane = planes.baseAddress! + (s * 2 + channel) * window
                            let target = out.baseAddress! + channel * window
                            vDSP_vadd(target, 1, plane, 1, target, 1, vDSP_Length(window))
                        }
                        vDSP_svesq(planes.baseAddress! + s * 2 * window, 1, &left, vDSP_Length(window))
                        vDSP_svesq(planes.baseAddress! + (s * 2 + 1) * window, 1, &right, vDSP_Length(window))
                        power[s] = left + right
                    }
                    vDSP_svesq(out.baseAddress!, 1, &mixPower, vDSP_Length(window * 2))
                }
            }
            guard mixPower > floor else { continue }
            music += 1
            for s in 0 ..< stems where power[s] > mixPower * 0.01 { playing[s] += 1 }
        }
        let shares = Dictionary(uniqueKeysWithValues: Stem.allCases.map { ($0, music == 0 ? 0 : Double(playing[$0.rawValue]) / Double(music)) })
        return StemActivity(shares: shares, seconds: Double(music * window) / StemsCache.rate)
    }

    /// A stem that plays in less than this share of the music is too quiet to transcribe without asking.
    static let quiet = 0.1

    /// `--stem-activity FILE.stems`: prints how much of the music each stem in a stems cache plays in.
    static func printActivity(_ file: String) {
        guard let cache = try? StemsCache(url: URL(fileURLWithPath: file)) else { return print("no stems in \(file)") }
        let activity = activity(cache)
        print(Stem.allCases.map { String(format: "%@ %.2f", $0.name, activity.shares[$0] ?? 0) }.joined(separator: "  ")
            + String(format: "  (%.0f s of music)", activity.seconds))
    }

    /// The left and right channels of one stem of a song whose stems are in the cache, mixed to mono. With `range`,
    /// only those seconds of the song.
    static func stemSamples(_ cache: StemsCache, stem: Stem, range: ClosedRange<Double>? = nil) -> [Float] {
        let span = frames(of: range, in: cache)
        let frames = span.count
        var planes = [Float](repeating: 0, count: frames * 2)
        planes.withUnsafeMutableBufferPointer { buffer in
            cache.copy([stem.rawValue * 2, stem.rawValue * 2 + 1], from: span.lowerBound, count: frames, into: buffer.baseAddress!)
        }
        return (0 ..< frames).map { (planes[$0] + planes[frames + $0]) * 0.5 }
    }

    /// The frames of the cache in a range of seconds of the song, or all of them.
    private static func frames(of range: ClosedRange<Double>?, in cache: StemsCache) -> Range<Int> {
        guard let range else { return 0 ..< cache.frames }
        let start = min(cache.frames, max(0, Int(range.lowerBound * StemsCache.rate)))
        return start ..< min(cache.frames, max(start, Int((range.upperBound * StemsCache.rate).rounded(.up))))
    }

    /// The seconds of the song on each side of a region loop that Dettato hears with it, so that the notes at its
    /// edges are found as they are in the whole song.
    static let regionContext = 2.0

    /// The notes that start in a region loop, with their ends cut at its end. A note that starts a moment before the
    /// region is kept, since a loop set by hand can start just after the attack of its first note.
    static func notes(_ notes: [TranscribedNote], in region: ClosedRange<Double>) -> [TranscribedNote] {
        notes.filter { $0.start >= region.lowerBound - 0.05 && $0.start < region.upperBound }.map {
            TranscribedNote(start: $0.start, end: min($0.end, region.upperBound), pitch: $0.pitch, program: $0.program, drum: $0.drum)
        }
    }

    /// The stems of the whole song from the cache, separating them first when the cache doesn't have them yet.
    @MainActor static func stems(for path: String, builder: StemsCacheBuilder) async -> StemsCache? {
        if let cache = StemsCache.open(for: path) { return cache }
        log.info("separating the whole song into stems")
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
        builder.log.echo = { print($0) }
        Task { @MainActor in
            let started = Date()
            let duration = await ChordDetector.duration(url)
            guard let cache = await stems(for: path, builder: builder) else {
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
