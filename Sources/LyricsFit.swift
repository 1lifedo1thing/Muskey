import CryptoKit
import Foundation

/// Times lyrics by fitting their text onto the vocals of the whole song, for a song whose stems are in the cache.
/// Lyrics without times get the start of every line that was found, and lyrics with times that are off as a whole
/// get moved by the offset.
enum LyricsFit {
    struct Outcome: Sendable {
        /// The second at which the first word is sung, for each line that was found.
        var starts: [Int: Double]
        /// The words of those lines.
        var words: [ForcedAligner.Word]
        /// Lines with words to sing, without the ones in brackets.
        var sung: Int

        /// Enough lines were found for their times to carry the rest. With fewer, the model didn't make out the
        /// singing, or the lyrics are another song's, and the lines are timed by listening as before.
        var found: Bool { sung > 0 && starts.count >= 4 && starts.count * 2 >= sung }
    }

    /// Lyrics with times are moved only when they are off by at least this long, since a line's time and the start of
    /// its first word are a few tenths of a second apart in lyrics that people timed well.
    static let smallestOffset = 0.5
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
        let reader = try AlignerModel.reader()
        // A song is fitted once, and the model takes about a gigabyte of memory while it is loaded.
        defer { AlignerModel.unload() }
        let aligner = ForcedAligner(lines: lines, space: reader.space, label: reader.label)
        let sung = lines.count { line in ForcedAligner.sung(line).contains { $0.word.contains { reader.label($0) != nil } } }
        guard sung > 0 else { return Outcome(starts: [:], words: [], sung: 0) }
        let audio = Dettato.resample(vocals, from: rate)
        guard let emissions = try reader.emissions(audio, columns: aligner.labels, stop: stop) else { return nil }
        guard let fit = aligner.fit(emissions) else { return Outcome(starts: [:], words: [], sung: sung) }
        return Outcome(starts: fit.starts, words: fit.words, sung: sung)
    }

    /// The seconds that lyrics with times are off by as a whole: the median of how far each found line's first word
    /// is from the line's time. Nil when the lines don't agree on it, or when it is too small to tell from the
    /// habits of whoever timed the lyrics.
    static func offset(of lyrics: Lyrics, _ outcome: Outcome) -> Double? {
        guard outcome.found else { return nil }
        let gaps = outcome.starts.compactMap { line, start in lyrics.lines.indices.contains(line) ? start - lyrics.lines[line].time : nil }.sorted()
        guard gaps.count >= 4 else { return nil }
        let median = gaps[gaps.count / 2]
        let spread = gaps.map { abs($0 - median) }.sorted()[gaps.count / 2]
        guard abs(median) >= smallestOffset, spread <= min(largestSpread, abs(median) / 2) else { return nil }
        return median
    }
}
