import Foundation

/// Times the lyrics of a song that another app plays, by fitting their text onto the vocals of the parts of the song
/// that have played. Muskey can't read such a song ahead, so the fit runs on what the live separation of the vocals
/// has given so far, and what it finds is kept for the next play of the song.
///
/// A part of a song can start and end at any line, and lines that repeat fit it in more than one place. So the fit
/// is told where each line is expected, by the times that the lyrics come with or by where the heard words and the
/// estimate have the lines, and pays for starting or ending far from there.
enum LiveFit {
    /// The second of the song that played at a moment of the audio.
    struct Mark: Sendable {
        var audio: Double
        var song: Double
    }

    /// A part of the song heard without a seek or a pause: its vocals, mono at the timing model's rate, and where the
    /// song was at moments of it, in seconds from the start of `samples`.
    struct Stretch: Sendable {
        var samples: [Float]
        var marks: [Mark]

        var seconds: Double { Double(samples.count) / AlignerModel.rate }

        /// The second of the song at `audio` seconds into the stretch. A player reports its position a little early
        /// or late from one report to the next, so the song is placed by the middle one of the reports around that
        /// moment.
        func song(at audio: Double) -> Double {
            var shifts = marks.filter { abs($0.audio - audio) <= 3 }.map { $0.song - $0.audio }
            if shifts.isEmpty, let nearest = marks.min(by: { abs($0.audio - audio) < abs($1.audio - audio) }) {
                shifts = [nearest.song - nearest.audio]
            }
            shifts.sort()
            return audio + (shifts.isEmpty ? 0 : shifts[shifts.count / 2])
        }
    }

    /// How far from its expected time a line can start a part of the song at no price, and the price of each second
    /// beyond that, in the log-probability that the letters are fitted by.
    struct Reach: Sendable {
        var slack: Double
        var price: Float
        /// With times, only the lines expected within this many seconds of the part are fitted onto it.
        var window: Double?

        /// Lyrics with times are off by seconds at most.
        static let synced = Reach(slack: 5, price: 1, window: 10)
        /// Lines without times are expected where the estimate or the heard words have them, which can be far from
        /// where they are sung, so the expected time only decides between places that fit the letters as well.
        static let plain = Reach(slack: 10, price: 0.1, window: nil)
    }

    /// Everything that a fit of the parts heard so far needs.
    struct Request: Sendable {
        var lines: [String]
        var expected: [Double]
        var heard: [Int: Double]
        var reach: Reach
        var stretches: [Stretch]
        var duration: Double?
    }

    struct Found: Sendable {
        /// The second of the song at which the first word is sung, for each line that was found.
        var starts: [Int: Double] = [:]
        /// Lines with words to sing in the parts of the song that were fitted.
        var sung = 0
        /// The parts of the song whose lines were used, in seconds of the song.
        var covered: [ClosedRange<Double>] = []
        /// Every part that was fitted, with the ones that were left out for not agreeing with the heard words. The
        /// same audio would be left out again, so no later play fits those parts for nothing.
        var fitted: [ClosedRange<Double>] = []
    }

    /// A shorter part of a song has too few lines to tell where in the lyrics it is.
    static let shortest = 15.0
    /// A line that starts this close to the start of a part may have started before it.
    static let edge = 1.0

    /// A part that starts in the first seconds of the song holds the first line of the lyrics, and one that ends
    /// in its last seconds holds the last line.
    static let songEdge = (start: 5.0, end: 10.0)

    /// A line found this far from where a heard word has it is in doubt.
    static let heardApart = 3.0

    /// A part that doesn't start with the song is used when at least this many of its lines are near their heard
    /// words.
    static let heardNear = 3

    /// The lines of lyrics without times found in a part that doesn't start with the song, without the ones that are
    /// far from where the heard words have them. Such a part can be fitted a chorus early or late, and heard words rarely match the
    /// same wrong chorus. Nil when too few lines are near their heard words, or more are far from them than near
    /// them: nothing says that the part was fitted in the right place.
    static func agreeing(_ starts: [Int: Double], heard: [Int: Double]) -> [Int: Double]? {
        let far = starts.filter { line, start in heard[line].map { abs($0 - start) > heardApart } == true }
        let near = starts.count { line, start in heard[line].map { abs($0 - start) <= heardApart } == true }
        guard near >= heardNear, far.count <= near else { return nil }
        return starts.filter { far[$0.key] == nil }
    }

    /// Fits `lines` onto each part of the song in `stretches`. `expected` is the second at which each line is
    /// expected to start, `heard` the second at which a heard word has the lines that it matched, and `duration` the
    /// length of the song, when it is known. Returns nil when `stop` says to end early.
    static func fit(_ lines: [String], expected: [Double], heard: [Int: Double] = [:], reach: Reach, stretches: [Stretch], duration: Double? = nil,
                    reader: some LyricsReading, stop: () -> Bool = { false }) throws -> Found?
    {
        var found = Found()
        var starts: [(line: Int, start: Double)] = []
        for stretch in stretches where stretch.seconds >= shortest && !stretch.marks.isEmpty {
            let from = stretch.song(at: 0), to = stretch.song(at: stretch.seconds)
            var window = 0 ..< lines.count
            if let reach = reach.window {
                let near = lines.indices.filter { expected[$0] >= from - reach && expected[$0] <= to + reach }
                guard let first = near.first, let last = near.last else { continue }
                window = first ..< last + 1
            }
            let texts = Array(lines[window])
            guard texts.count(where: reader.sings) >= 2 else { continue }
            let aligner = ForcedAligner(lines: texts, space: reader.space, label: reader.label)
            // The place after the last line is expected a line's length after it.
            let times = window.map { expected[$0] } + [(expected[window.upperBound - 1]) + 4]
            func price(_ time: Double, _ end: Double) -> Float { reach.price * Float(max(0, abs(time - end) - reach.slack)) }
            // A line is expected in the part when its time is inside it by more than the time can be wrong. A part
            // that starts with the song holds every line from the first one on, wherever the lines are expected,
            // and a part that ends with the song every line to the last one. Lines that repeat can't slide by a
            // chorus against an end of the song.
            let inside = texts.indices.filter { times[$0] >= from + reach.slack && times[$0] <= to - reach.slack }
            let fromStart = from <= songEdge.start && window.lowerBound == 0
            let toEnd = duration.map { to >= $0 - songEdge.end } == true && window.upperBound == lines.count
            guard fromStart || toEnd || !inside.isEmpty else { continue }
            let expected = (fromStart ? 0 : inside.first ?? texts.count) ..< (toEnd ? texts.count : inside.last.map { $0 + 1 } ?? 0)
            let ends = ForcedAligner.Ends(enter: times.map { price($0, from) }, leave: times.map { price($0, to) }, expected: expected)
            guard let emissions = try reader.emissions(stretch.samples, columns: aligner.labels, stop: stop) else { return nil }
            guard let fit = aligner.fit(emissions, ends: ends) else { continue }
            found.fitted.append(from ... max(from, to))
            var lineEnd: [Int: Double] = [:]
            for word in fit.words { lineEnd[word.line] = max(lineEnd[word.line] ?? 0, word.end) }
            var part: [Int: Double] = [:]
            for (line, start) in fit.starts {
                // A line that the part cuts at its start or its end is fitted onto the words of it that were heard.
                guard start >= edge, (lineEnd[line] ?? start) <= stretch.seconds - 0.5 else { continue }
                part[window.lowerBound + line] = stretch.song(at: start)
            }
            // Lines with times are fitted near their times, which leaves a chorus no other place to go.
            if reach.window == nil, !fromStart {
                guard let agreed = agreeing(part, heard: heard) else { continue }
                part = agreed
            }
            found.covered.append(from ... max(from, to))
            found.sung += fit.span.count { reader.sings(texts[$0]) }
            starts += part.map { ($0.key, $0.value) }
        }
        found.starts = inOrder(starts)
        return found
    }

    /// The most lines whose times go up with their place in the lyrics. Two parts of the song can both claim a
    /// line, or put a later line before an earlier one, when one of them was fitted in the wrong place.
    static func inOrder(_ starts: [(line: Int, start: Double)]) -> [Int: Double] {
        let sorted = starts.sorted { ($0.line, $0.start) < ($1.line, $1.start) }
        guard !sorted.isEmpty else { return [:] }
        var length = [Int](repeating: 1, count: sorted.count), before = [Int](repeating: -1, count: sorted.count)
        for index in sorted.indices {
            for earlier in 0 ..< index where sorted[earlier].line < sorted[index].line && sorted[earlier].start < sorted[index].start
                && length[earlier] + 1 > length[index]
            {
                length[index] = length[earlier] + 1
                before[index] = earlier
            }
        }
        var index = length.indices.max { length[$0] < length[$1] } ?? 0
        var kept: [Int: Double] = [:]
        while index >= 0 {
            kept[sorted[index].line] = sorted[index].start
            index = before[index]
        }
        return kept
    }

    /// What the lines found say about lyrics with times.
    enum Verdict: Equatable, Sendable {
        /// Every line is this many seconds early or late.
        case off(Double)
        case holds
        /// Too few lines were found, or they don't agree.
        case unsure
    }

    /// Whether lyrics with times are off as a whole, by the lines found in the parts of the song heard so far. The
    /// rule is the one for a whole song, and a move also needs the earlier half and the later half of the found lines
    /// to agree on it, since a wrong move would stay with the song.
    static func verdict(of lyrics: Lyrics, _ found: Found) -> Verdict {
        let outcome = LyricsFit.Outcome(starts: found.starts, words: [], sung: found.sung)
        guard outcome.found else { return .unsure }
        let gaps = found.starts.keys.sorted().compactMap { line in
            lyrics.lines.indices.contains(line) ? found.starts[line]! - lyrics.lines[line].time : nil
        }
        func median(_ values: some Sequence<Double>) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        guard gaps.count >= 4 else { return .unsure }
        let middle = median(gaps)
        let spread = median(gaps.map { abs($0 - middle) })
        if let offset = LyricsFit.offset(of: lyrics, outcome) {
            guard gaps.count >= 8 else { return .unsure }
            let half = gaps.count / 2
            return abs(median(gaps[..<half]) - median(gaps[half...])) <= halvesApart ? .off(offset) : .unsure
        }
        return abs(middle) < LyricsFit.smallestOffset && spread <= LyricsFit.largestSpread ? .holds : .unsure
    }

    /// The two halves of the found lines agree on an offset when they are within this many seconds of each other.
    static let halvesApart = 0.25
}

/// The vocals of the song that plays in another app, kept while the lyrics show, with the position of the song at
/// moments of them. The vocals come from the live separation on its queue, and the positions from the main thread.
final class LiveVocals: @unchecked Sendable {
    /// Songs longer than this keep their first part only, which takes about 60 MB.
    static let longest = 15.0 * 60

    private let lock = NSLock()
    private var samples: [Float] = []
    private var marks: [LiveFit.Mark] = []
    private let resampler: Resampler?

    /// `rate` is the sample rate of the vocals added.
    init(rate: Double) {
        resampler = rate == AlignerModel.rate ? nil : Resampler(from: rate, to: AlignerModel.rate)
    }

    /// Adds vocals. Every sample of the audio that the tap heard comes here once, in order, so the place of a sample
    /// is its time in the tap's audio.
    func add(_ vocals: [Float]) {
        let converted = resampler.map { $0.convert(vocals[...], vocals[...])[0] } ?? vocals
        lock.withLock {
            guard !closed, Double(samples.count) / AlignerModel.rate < Self.longest else { return }
            samples += converted
        }
    }

    /// Keeps no more vocals, for a separation that failed and hands over the whole song instead.
    func close() { lock.withLock { closed = true } }

    private var closed = false

    /// Notes that the song was at `song` seconds after `audio` seconds of the tap's audio.
    func mark(audio: Double, song: Double) {
        lock.withLock { marks.append(LiveFit.Mark(audio: audio, song: song)) }
    }

    /// Seconds of vocals so far.
    var seconds: Double { lock.withLock { Double(samples.count) / AlignerModel.rate } }

    /// The parts of the song that the vocals hold. A new part starts where the position of the song jumps against
    /// the audio: at a seek, or after a pause, since the tap goes on hearing silence while the song stands still.
    /// `until` leaves out the audio after that second, which the tap heard after the last position of the song.
    func stretches(until: Double? = nil) -> [LiveFit.Stretch] {
        let (samples, marks) = lock.withLock { (self.samples, self.marks) }
        let end = min(Double(samples.count) / AlignerModel.rate, until ?? .infinity)
        var runs: [[LiveFit.Mark]] = []
        for mark in marks where mark.audio <= end {
            if let last = runs.last?.last, abs((mark.song - mark.audio) - (last.song - last.audio)) <= Self.jump {
                runs[runs.count - 1].append(mark)
            } else {
                runs.append([mark])
            }
        }
        return runs.compactMap { run in
            guard let first = run.first, let last = run.last, last.audio > first.audio else { return nil }
            let from = Int(first.audio * AlignerModel.rate), to = min(samples.count, Int(last.audio * AlignerModel.rate))
            guard to > from else { return nil }
            return LiveFit.Stretch(samples: Array(samples[from ..< to]), marks: run.map { LiveFit.Mark(audio: $0.audio - first.audio, song: $0.song) })
        }
    }

    /// The song's position moves against the audio by less than this from one report to the next while it plays on.
    static let jump = 0.5

    /// The parts of the song that the marks cover, whether their vocals have come yet or not.
    var heard: [ClosedRange<Double>] {
        let marks = lock.withLock { self.marks }
        var ranges: [ClosedRange<Double>] = []
        var start: LiveFit.Mark?, last: LiveFit.Mark?
        for mark in marks {
            if let from = start, let previous = last, abs((mark.song - mark.audio) - (previous.song - previous.audio)) > Self.jump {
                if previous.song > from.song { ranges.append(from.song ... previous.song) }
                start = mark
            } else if start == nil {
                start = mark
            }
            last = mark
        }
        if let start, let last, last.song > start.song { ranges.append(start.song ... last.song) }
        return ranges
    }
}
