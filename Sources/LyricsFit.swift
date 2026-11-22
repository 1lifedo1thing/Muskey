import CryptoKit
import Foundation

/// Times lyrics by fitting their text onto the vocals of the whole song, for a song whose stems are in the cache.
/// Lyrics without times get the start of every line that was found, while the heard words time the other lines.
/// Lyrics with times that are off as a whole get moved by the offset.
enum LyricsFit {
    struct Outcome: Sendable {
        /// The second at which the first word is sung, for each line that was found.
        var starts: [Int: Double]
        /// The words of those lines.
        var words: [ForcedAligner.Word]
        /// Lines with words to sing, without the ones in brackets.
        var sung: Int

        /// Enough lines were found to say whether lyrics with times are off as a whole. With fewer, the model
        /// didn't make out the singing, or the lyrics are another song's.
        var found: Bool { sung > 0 && starts.count >= 4 && starts.count * 2 >= sung }
        /// Enough lines were found to time them by. Where the model makes out next to nothing, the one or two lines
        /// that both fits agree on can be anywhere in the song, and they would hold the heard lines away from where
        /// they are sung.
        var usable: Bool { starts.count >= 4 && starts.count * 5 >= sung }
    }

    /// Lyrics with times are offered a fix only when they are off by at least this long, since a line's time and the
    /// start of its first word are a few tenths of a second apart in lyrics that people timed well, and the fit can't
    /// tell an offset near half a second from that habit.
    static let smallestOffset = 0.8
    /// The found lines agree on the offset when half of them are within half of it, and never further than this.
    static let largestSpread = 0.6

    /// The lyrics as one short string, which tells whether a kept fit is of the same lyrics: their text, and their
    /// times when they come with times, since the offset is of those times.
    static func key(_ lyrics: Lyrics) -> String {
        var text = lyrics.lines.map(\.text).joined(separator: "\n")
        if lyrics.timing == .synced { text += lyrics.lines.map { String(format: "\n%.2f", $0.time) }.joined() }
        let digest = SHA256.hash(data: Data(text.utf8))
        return (lyrics.timing == .synced ? "t" : "p") + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Fits `lines` onto the vocals, mono at `rate`. Returns nil when `stop` says to end early. Takes a few seconds,
    /// so it runs off the main thread.
    static func fit(_ lines: [String], vocals: [Float], rate: Double, stop: () -> Bool = { false }) throws -> Outcome? {
        try AlignerModel.use { reader in
            let aligner = ForcedAligner(lines: lines, space: reader.space, label: reader.label)
            let sung = lines.count { reader.sings($0) }
            guard sung > 0 else { return Outcome(starts: [:], words: [], sung: 0) }
            let audio = Dettato.resample(vocals, from: rate)
            guard let emissions = try reader.emissions(audio, columns: aligner.labels, stop: stop) else { return nil }
            guard let fit = aligner.fit(emissions) else { return Outcome(starts: [:], words: [], sung: sung) }
            return Outcome(starts: fit.starts, words: fit.words, sung: sung)
        }
    }

    /// The seconds that lyrics with times are off by as a whole: the median of how far each found line's first word
    /// is from the line's time. Nil when the lines don't agree on it, or when it is too small to tell from the
    /// habits of whoever timed the lyrics.
    static func offset(of lyrics: Lyrics, _ outcome: Outcome) -> Double? {
        if case let .off(offset) = check(of: lyrics, outcome) { offset } else { nil }
    }

    /// What a fit says about the times of lyrics with times.
    enum Check: Equatable {
        /// Off as a whole by that many seconds.
        case off(Double)
        /// Right: the found lines agree on an offset too small to tell from the habits of whoever timed them.
        case right
        /// Too few lines found, or found lines that disagree on how far off they are.
        case unclear
    }

    static func check(of lyrics: Lyrics, _ outcome: Outcome) -> Check {
        guard outcome.found else { return .unclear }
        let gaps = outcome.starts.compactMap { line, start in lyrics.lines.indices.contains(line) ? start - lyrics.lines[line].time : nil }.sorted()
        guard gaps.count >= 4 else { return .unclear }
        let median = gaps[gaps.count / 2]
        let spread = gaps.map { abs($0 - median) }.sorted()[gaps.count / 2]
        if abs(median) >= smallestOffset { return spread <= min(largestSpread, abs(median) / 2) ? .off(median) : .unclear }
        return spread <= largestSpread ? .right : .unclear
    }
}
