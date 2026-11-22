import Foundation

/// Times the lines of lyrics that come without times, by the words that the speech transcriber heard in the song.
/// The heard words are matched to the words of the lyrics in order, so a chorus that repeats is told apart by where it
/// falls, and each line starts at its first matched word. Lines without a match are placed between their neighbours
/// by the estimate, which spreads the lines over the song by their syllables.
struct LyricsAligner {
    /// A word of the song as the transcriber heard it, with its seconds in the song.
    struct Heard: Hashable, Sendable, Codable {
        var start: Double
        var end: Double
        var text: String
    }

    private struct Token {
        let line: Int
        let text: String
        let weight: Double
        /// Words in brackets, often sung by someone else in the background, cost nothing to miss.
        let optional: Bool
        /// A break between verses, which matches no word and lines up with a pause in the singing.
        var isBreak: Bool { text.isEmpty }
        /// Syllables before this word in its line.
        let syllablesBefore: Int
        let syllables: Int
        /// Where the estimate puts the word, in seconds.
        let prior: Double
    }

    private let tokens: [Token]
    private let firstToken: [Int?]
    private let estimate: [Double]
    /// Syllables of each line, 0 for a break between verses.
    private let syllables: [Int]

    /// Seconds per syllable of sung words, for the start of a line whose first words weren't heard.
    private static let syllableSeconds = 0.3

    /// The estimate is the times of a version of the song of another length, like a music video with an intro, so the
    /// lines keep their spacing after the last line that was heard, instead of taking the time of their syllables.
    private let keepsSpacing: Bool

    init(texts: [String], estimate: [Double], keepsSpacing: Bool = false) {
        self.estimate = estimate
        self.keepsSpacing = keepsSpacing
        var tokens: [Token] = []
        var firstToken: [Int?] = []
        for (line, text) in texts.enumerated() {
            let words = Self.words(text)
            let lineSyllables = max(1, words.reduce(0) { $0 + $1.syllables })
            let start = estimate[line]
            let next = line + 1 < estimate.count ? estimate[line + 1] : start + Double(lineSyllables) * Self.syllableSeconds
            // A line can't take longer to sing than its syllables at a slow pace, whatever slot the estimate gave it.
            let span = min(next - start, Double(lineSyllables) * 0.6)
            firstToken.append(words.isEmpty ? nil : tokens.count)
            if text.trimmingCharacters(in: .whitespaces).isEmpty, line > 0 {
                tokens.append(Token(line: line, text: "", weight: 0, optional: false, syllablesBefore: 0, syllables: 0, prior: start))
            }
            var before = 0
            for word in words {
                tokens.append(Token(line: line, text: word.text, weight: Self.weight(word.text) * (word.optional ? 0.5 : 1), optional: word.optional,
                                    syllablesBefore: before, syllables: word.syllables, prior: start + span * Double(before) / Double(lineSyllables)))
                before += word.syllables
            }
        }
        self.tokens = tokens
        self.firstToken = firstToken
        syllables = texts.map { Self.words($0).reduce(0) { $0 + $1.syllables } }
    }

    // MARK: Times

    /// The lines that the heard words matched, kept so the times can be worked out again as the song plays on
    /// without matching all the words again.
    struct Alignment {
        /// The start of each line that a heard word matched.
        fileprivate var lineStart: [Int: Double] = [:]
        /// The estimate's time and the heard time of each matched word.
        fileprivate var points: [(prior: Double, time: Double)] = []
        /// The words heard after the last matched word, which show where the singer paused since.
        fileprivate var after: [Heard] = []
        /// The end of the last matched word.
        fileprivate var lastMatchedEnd = 0.0

        var anchored: Int { lineStart.count }
        /// The lines that start at a heard word.
        var matchedLines: Set<Int> { Set(lineStart.keys) }
    }

    /// Lines show a little before they are sung, as they do in lyrics with times.
    static let lead = 0.5

    func align(_ heard: [Heard]) -> Alignment {
        var alignment = Alignment()
        let anchors = anchors(heard)
        if let last = anchors.last {
            alignment.after = Array(heard[(last.word + 1)...])
            alignment.lastMatchedEnd = heard[last.word].end
        }
        for anchor in anchors {
            let token = tokens[anchor.token]
            alignment.points.append((token.prior, anchor.time))
            // The first matched word of each line marks its start, less the syllables sung before that word.
            if alignment.lineStart[token.line] == nil {
                alignment.lineStart[token.line] = anchor.time - Double(token.syllablesBefore) * Self.syllableSeconds - Self.lead
            }
        }
        return alignment
    }

    /// The lines whose first word was found by fitting the text onto the vocals, with the second it starts at. The
    /// other lines are placed between them like the lines that no heard word matched.
    func alignment(fitted starts: [Int: Double]) -> Alignment {
        var alignment = Alignment()
        for line in starts.keys.sorted() {
            guard let first = firstToken[line], let start = starts[line] else { continue }
            // Times that go back would bend the estimate between two lines the wrong way.
            if let last = alignment.points.last, start <= last.time { continue }
            alignment.lineStart[line] = start - Self.lead
            alignment.points.append((tokens[first].prior, start))
            alignment.lastMatchedEnd = start
        }
        return alignment
    }

    /// The start of each line. `listening` is the part of the song that the transcriber has heard so far without a
    /// break, while it listens: after a few seconds without a word, the singer has paused, and the next line waits
    /// for its first word instead of starting on time.
    func times(_ alignment: Alignment, listening: ClosedRange<Double>? = nil) -> [Double] {
        let points = alignment.points
        guard !points.isEmpty else {
            // Before the first match, the lines wait for the singer, unless nothing has matched for so long that the
            // transcriber likely can't make out the words.
            guard let listening, (3 ... 30).contains(listening.upperBound - listening.lowerBound) else { return estimate }
            return estimate.map { max($0, listening.upperBound + 1) }
        }

        // Before the first matched word and between matched words, the estimate is stretched to fit them.
        func warp(_ prior: Double) -> Double {
            if prior <= points[0].prior { return points[0].time - (points[0].prior - prior) }
            var low = 0, high = points.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if points[middle].prior <= prior { low = middle } else { high = middle }
            }
            let a = points[low], b = points[high]
            guard b.prior > a.prior else { return a.time }
            return a.time + (b.time - a.time) * (prior - a.prior) / (b.prior - a.prior)
        }

        let lastMatched = alignment.lineStart.keys.max() ?? 0
        let pace = pace(alignment)

        // Pauses of the singer among the words heard after the last matched word. A pause that still goes on, while
        // the transcriber listens, has no end yet.
        var pauses: [(start: Double, end: Double)] = []
        var previousEnd = alignment.lastMatchedEnd
        for word in alignment.after {
            if word.start - previousEnd >= 2 { pauses.append((previousEnd, word.start)) }
            previousEnd = max(previousEnd, word.end)
        }
        if let listening, listening.upperBound - max(previousEnd, listening.lowerBound) >= 2 { pauses.append((previousEnd, .infinity)) }
        var pause = 0

        var times: [Double] = []
        for line in estimate.indices {
            var time: Double
            if let start = alignment.lineStart[line] {
                time = start
            } else if keepsSpacing, line > lastMatched, let last = points.last {
                // The other version plays the rest of the song the way it did after the last heard word.
                time = (firstToken[line].map { tokens[$0].prior } ?? estimate[line]) + last.time - last.prior - Self.lead
            } else if line < lastMatched || times.isEmpty {
                time = warp(firstToken[line].map { tokens[$0].prior } ?? estimate[line]) - Self.lead
            } else {
                // After the last matched line, each line takes as long as its syllables at the singer's pace, and
                // a pause of the singer moves the next line to where the singing resumed.
                time = times[line - 1] + Double(syllables[line - 1]) * pace
                if syllables[line] > 0 {
                    while pause < pauses.count, pauses[pause].end <= time { pause += 1 }
                    if syllables[line - 1] == 0, listening != nil {
                        // A verse starts with the first word heard after the verse before it ended, or waits for it.
                        if let word = alignment.after.first(where: { $0.start >= time - 0.5 }) {
                            time = max(time, word.start - Self.lead)
                        } else {
                            time = .infinity
                        }
                        while pause < pauses.count, pauses[pause].end <= time { pause += 1 }
                    } else if pause < pauses.count, time >= pauses[pause].start - 0.3 {
                        time = max(time, pauses[pause].end - Self.lead)
                        pause += 1
                    }
                }
            }
            // Lines start in order, and a break between verses sits after the line before it.
            if let previous = times.last { time = max(time, previous + 0.05) }
            times.append(time)
        }
        // A matched line pulls the unmatched lines before it back, never past their own start.
        for line in stride(from: times.count - 2, through: 0, by: -1) where alignment.lineStart[line] == nil && times[line + 1].isFinite {
            times[line] = min(times[line], times[line + 1] - 0.05)
        }
        // Lines that wait for the singer stay just ahead of the song.
        let waiting = (listening?.upperBound ?? 0) + 0.3
        return times.map { $0.isFinite ? $0 : waiting }
    }

    /// Seconds per syllable between the starts of the last few pairs of matched lines that follow each other.
    private func pace(_ alignment: Alignment) -> Double {
        let lines = alignment.lineStart.keys.sorted()
        var paces: [Double] = []
        for (a, b) in zip(lines, lines.dropFirst()) where b == a + 1 && syllables[a] > 0 {
            paces.append((alignment.lineStart[b]! - alignment.lineStart[a]!) / Double(syllables[a]))
        }
        let recent = paces.suffix(6).sorted()
        guard !recent.isEmpty else { return Self.syllableSeconds }
        return min(0.7, max(0.15, recent[recent.count / 2]))
    }

    // MARK: Matching

    private struct Anchor {
        let token: Int
        let word: Int
        let time: Double
    }

    /// The heard words that match words of the lyrics, in order. The heard words are aligned to the lyrics as a
    /// whole, like two sequences of DNA: every heard word is used or skipped, and the lyrics before the first heard
    /// word and after the last one are skipped for free, since the transcriber hears only the part of the song that
    /// played while it listened.
    private func anchors(_ heard: [Heard]) -> [Anchor] {
        let n = tokens.count, m = heard.count
        guard n > 0, m > 0 else { return [] }
        let words = heard.map { Self.normalized($0.text) }

        // Scores in a flat (n + 1) × (m + 1) table, with the move that reached each cell.
        let width = m + 1
        var score = [Float](repeating: 0, count: (n + 1) * width)
        var move = [UInt8](repeating: 0, count: (n + 1) * width)
        let skipHeard: Float = 0.15
        for j in 1 ... m {
            score[j] = score[j - 1] - skipHeard
            move[j] = 2
        }
        for i in 1 ... n {
            let token = tokens[i - 1]
            let skipToken: Float = token.optional ? 0 : Float(0.1 * token.weight)
            for j in 0 ... m {
                let cell = i * width + j
                // Skipping lyrics is free before the first heard word, after the last one, and across a long pause
                // between heard words, where the transcriber stopped listening or the song has no vocals. A break
                // between verses is free across a short pause, and costs about a matched word without one, so that
                // a phrase that the next verse repeats stays in the verse being sung.
                let gap = j == 0 || j == m ? Double.infinity : heard[j].start - heard[j - 1].end
                let cost: Float = gap > 6 ? 0 : token.isBreak ? (gap >= 1.5 ? 0 : 0.8) : skipToken
                var best = score[cell - width] - cost
                var from: UInt8 = 1
                if j > 0 {
                    let skip = score[cell - 1] - skipHeard
                    if skip > best { best = skip; from = 2 }
                    let similarity = token.isBreak ? 0 : Self.similarity(token.text, words[j - 1])
                    if similarity > 0 {
                        // Far from where the estimate puts the word costs a little, which settles which chorus a
                        // repeated line belongs to when the order alone can't.
                        let distance = max(0, abs(heard[j - 1].start - token.prior) - 15)
                        let match = score[cell - width - 1] + Float(similarity * token.weight - 0.01 * distance)
                        if match > best { best = match; from = 3 }
                    }
                }
                score[cell] = best
                move[cell] = from
            }
        }

        // The best end anywhere in the last column, since the lyrics after the last heard word are skipped for free.
        var i = (0 ... n).max { score[$0 * width + m] < score[$1 * width + m] } ?? n
        var j = m
        var matches: [(token: Int, word: Int)] = []
        while i > 0, j > 0 {
            switch move[i * width + j] {
            case 3: matches.append((i - 1, j - 1)); i -= 1; j -= 1
            case 2: j -= 1
            default: i -= 1
            }
        }
        matches.reverse()

        // A lone match of a short word is often a coincidence, so a match counts when another one is close by in
        // both the lyrics and the heard words, or when it is a long word heard exactly.
        return matches.indices.compactMap { index in
            let (token, word) = matches[index]
            let neighbour = [index - 1, index + 1].contains { other in
                matches.indices.contains(other) && abs(matches[other].token - token) <= 3 && abs(matches[other].word - word) <= 3
            }
            let strong = tokens[token].text.count >= 5 && tokens[token].text == words[word]
            guard neighbour || strong else { return nil }
            return Anchor(token: token, word: word, time: Self.start(of: heard[word], syllables: tokens[token].syllables))
        }
    }

    /// The transcriber stretches a word across the pause before it, so a word that lasts much longer than its
    /// syllables starts that much later.
    private static func start(of word: Heard, syllables: Int) -> Double {
        let longest = 0.35 + Double(syllables) * 0.45
        return max(word.start, word.end - longest)
    }

    // MARK: Words

    private static let common: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "i", "im", "you", "me", "my", "we",
        "it", "its", "is", "be", "so", "oh", "that", "this", "your", "our", "no", "yeah", "do", "dont",
    ]

    private static func weight(_ word: String) -> Double {
        if common.contains(word) || word.count <= 2 { return 0.35 }
        return word.count == 3 ? 0.7 : 1
    }

    /// 1 for the same word, less for a close one (`storm` and `stone`), 0 for anything else.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard a.count >= 3, b.count >= 3, abs(a.count - b.count) <= 2 else { return 0 }
        let ratio = 1 - Double(distance(Array(a.utf8), Array(b.utf8))) / Double(max(a.utf8.count, b.utf8.count))
        return ratio >= 0.6 ? ratio * 0.8 : 0
    }

    private static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var row = Array(0 ... b.count)
        for i in 1 ... a.count {
            var previous = row[0]
            row[0] = i
            for j in 1 ... b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// Lowercase letters and digits, without accents or apostrophes: `We're` and `were` are the same word here.
    static func normalized(_ word: String) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    private static func words(_ line: String) -> [(text: String, optional: Bool, syllables: Int)] {
        var result: [(String, Bool, Int)] = []
        var depth = 0
        var current = ""
        func flush() {
            let word = normalized(current)
            if !word.isEmpty { result.append((word, depth > 0, syllables(word))) }
            current = ""
        }
        for character in line {
            switch character {
            case "(", "[": flush(); depth += 1
            case ")", "]": flush(); depth = max(0, depth - 1)
            case "'", "’": continue
            default:
                if character.isLetter || character.isNumber { current.append(character) } else { flush() }
            }
        }
        flush()
        return result
    }

    /// Groups of vowels in each word, which is close enough to the syllables for spreading lines over time.
    static func syllables(_ text: String) -> Int {
        let vowels = Set("aeiouyàáâäãåèéêëìíîïòóôöõùúûüýÿăâîșțąęėįųū")
        return text.lowercased().split(whereSeparator: { !$0.isLetter }).reduce(0) { count, word in
            var groups = 0
            var inGroup = false
            for character in word {
                let vowel = vowels.contains(character)
                if vowel, !inGroup { groups += 1 }
                inGroup = vowel
            }
            return count + max(1, groups)
        }
    }

    /// Times for lyrics that come without them: the lines are spread over the part of the song that most likely
    /// has vocals, each one taking time in proportion to its syllables, with a pause at each break between verses.
    static func estimate(_ texts: [String], duration: Double) -> [Double] {
        let weights = texts.map { $0.isEmpty ? 4 : Double(max(2, syllables($0))) }
        let total = max(1, weights.reduce(0, +))
        let start = min(15, duration * 0.07)
        let end = duration - min(20, duration * 0.08)
        var elapsed = 0.0
        return weights.map { weight in
            defer { elapsed += weight }
            return start + elapsed / total * (end - start)
        }
    }
}
