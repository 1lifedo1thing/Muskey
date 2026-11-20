import AVFoundation

/// A chord of the song, from its beat until the next chord.
struct ChordMark: Equatable, Sendable {
    let time: Double
    let root: Int
    let minor: Bool

    /// The chord moved by `semitones`, its root spelled the way the key with that root and mode is written: `E♭`, `F♯m`.
    func name(moved semitones: Int) -> String {
        let root = ((self.root + semitones) % 12 + 12) % 12
        return DetectedKey(pitchClass: root, minor: minor).tonic + (minor ? "m" : "")
    }
}

/// The beats and the chords of a whole file, found once for each file that Muskey Player plays.
struct SongGrid: Sendable {
    let beats: [Double]
    let bpm: Double
    let chords: [ChordMark]

    /// The chords with the mode that the key of the song gives their root: chord detection often hears a G minor in a
    /// song in E minor, where the chord on G is major. A chord whose root and mode are both outside the key stays as it
    /// was heard, and so does a chord that the key has.
    func fitted(to key: DetectedKey?) -> [ChordMark] {
        guard let key else { return chords }
        // The triads of the key's scale, and the major chord on the fifth that songs in a minor key use.
        let steps = key.minor ? [(0, true), (3, false), (5, true), (7, true), (7, false), (8, false), (10, false)]
            : [(0, false), (2, true), (4, true), (5, false), (7, false), (9, true)]
        let allowed = Set(steps.map { "\((key.pitchClass + $0.0) % 12)\($0.1)" })
        var fitted: [ChordMark] = []
        for chord in chords {
            var minor = chord.minor
            if !allowed.contains("\(chord.root)\(minor)"), allowed.contains("\(chord.root)\(!minor)") { minor.toggle() }
            if let last = fitted.last, last.root == chord.root, last.minor == minor { continue }
            fitted.append(ChordMark(time: chord.time, root: chord.root, minor: minor))
        }
        return fitted
    }

    /// The chords that start within `range`, for the line of the lyrics sung then. A chord that started before the
    /// line and still plays at its start comes first, at the start of the line.
    func chords(in range: Range<Double>) -> [ChordMark] {
        var inside = chords.filter { range.contains($0.time) }
        if let before = chords.last(where: { $0.time < range.lowerBound }), inside.first.map({ $0.time > range.lowerBound + 0.3 }) ?? true {
            inside.insert(ChordMark(time: range.lowerBound, root: before.root, minor: before.minor), at: 0)
        }
        return inside
    }
}

enum ChordDetector {
    static func duration(_ url: URL) async -> Double {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return seconds.isFinite ? seconds : 0
    }

    /// Reads the whole file and finds its beats with Essentia's RhythmExtractor2013 and the chord between each two beats
    /// with ChordsDetectionBeats. A chord that repeats on the next beat is one chord, and a chord shorter than a beat
    /// between two of the same chord is taken for noise.
    static func analyse(_ url: URL, duration: Double) async -> SongGrid? {
        let samples = await LoopSnap.excerpt(url, from: 0, to: duration + 1)
        guard samples.count > Int(LoopSnap.rate * 10) else { return nil }
        var bpm: Float = 0
        var ticks = [Float](repeating: 0, count: Int(duration * 5) + 64)
        let count = samples.withUnsafeBufferPointer { buffer in
            ticks.withUnsafeMutableBufferPointer { ek_beats(buffer.baseAddress, UInt32(buffer.count), $0.baseAddress, Int32($0.count), &bpm) }
        }
        guard count > 4 else { return nil }
        let allBeats = Array(ticks.prefix(Int(count)))
        let step = Int(TestFlags.value("--chord-step") ?? "") ?? 2
        let beats = stride(from: 0, to: allBeats.count, by: step).map { allBeats[$0] }
        var roots = [Int32](repeating: -1, count: beats.count), minors = [Int32](repeating: 0, count: beats.count)
        var strengths = [Float](repeating: 0, count: beats.count)
        let found = samples.withUnsafeBufferPointer { buffer in
            beats.withUnsafeBufferPointer { ticks in
                ek_chords(buffer.baseAddress, UInt32(buffer.count), ticks.baseAddress, Int32(ticks.count), &roots, &minors, &strengths, Int32(beats.count))
            }
        }
        var raw: [ChordMark?] = []
        for index in 0 ..< Int(found) {
            let sure = roots[index] >= 0 && strengths[index] >= 0.2
            raw.append(sure ? ChordMark(time: Double(beats[index]), root: Int(roots[index]), minor: minors[index] != 0) : nil)
        }
        // A one-beat chord between two of the same chord.
        for index in raw.indices.dropFirst().dropLast() {
            if let before = raw[index - 1], let after = raw[index + 1], before.root == after.root, before.minor == after.minor {
                raw[index] = ChordMark(time: raw[index]?.time ?? Double(beats[index]), root: before.root, minor: before.minor)
            }
        }
        var chords: [ChordMark] = []
        for case let chord? in raw where chords.last.map({ $0.root != chord.root || $0.minor != chord.minor }) ?? true {
            chords.append(chord)
        }
        return SongGrid(beats: allBeats.map(Double.init), bpm: Double(bpm), chords: chords)
    }
}

/// The chords over the lyrics: the song's chords, moved with the pitch change and down by the capo.
struct SongChords: Equatable {
    let marks: [ChordMark]
    let shift: Int
    let capo: Int

    var move: Int { shift - capo }
}
