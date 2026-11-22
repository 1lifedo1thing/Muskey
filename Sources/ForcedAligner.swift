import Foundation

/// Fits the words of lyrics onto a song whose singing a speech model has read. The model gives, for every 20 ms of
/// the vocals, how likely each letter is, and how likely it is that no new letter starts there (the blank). The
/// letters of the lyrics are laid over those frames in order, by the path that the model finds most likely, which
/// gives the time of every word.
///
/// Songs aren't sung as their lyrics are written, so a line that isn't sung at all can be left out, at a price for
/// each of its letters. No price is right for every song: a low one drops lines that the model reads badly, and a
/// high one forces lines that nobody sings onto their neighbours' words. So the lyrics are fitted twice, with a high
/// and a lower price, and a line counts as found when both fits start it at the same moment.
struct ForcedAligner {
    /// The model's reading of a song: for each frame, the log-probability of the blank and of each label that the
    /// lyrics use.
    struct Emissions: Sendable {
        static let frameSeconds = 0.02

        var frames: Int
        /// Labels in each frame, the blank first.
        var width: Int
        /// `frames` rows of `width` log-probabilities.
        var values: [Float]
    }

    struct Word: Sendable {
        var line: Int
        /// The place of the word among the words of its line, counting the ones in brackets.
        var index: Int
        var start: Double
        var end: Double
        /// How likely the model found the word's letters where the path put them, from 0 to 1.
        var confidence: Float
    }

    struct Result: Sendable {
        var words: [Word]
        /// Lines that the path left out as not sung.
        var skipped: Set<Int>

        /// The start of each line's first word, and how sure the model was of the line's words. Nil for a line that
        /// was left out, has no words, or is all in brackets.
        func lines(count: Int) -> [(start: Double, end: Double, confidence: Float)?] {
            var lines = [(start: Double, end: Double, confidence: Float)?](repeating: nil, count: count)
            var sums = [Float](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
            for word in words {
                if lines[word.line] == nil { lines[word.line] = (word.start, word.end, 0) }
                lines[word.line]?.end = word.end
                sums[word.line] += word.confidence
                counts[word.line] += 1
            }
            for line in 0 ..< count where counts[line] > 0 { lines[line]?.confidence = sums[line] / Float(counts[line]) }
            return lines
        }
    }

    private enum Kind: UInt8 {
        /// Between two lines: silence, or singing that the lyrics don't have.
        case gap
        case letter
        /// Between two letters of a line.
        case blank
    }

    private let kinds: [Kind]
    /// The column of each letter in the emissions, 0 for gaps and blanks.
    private let columns: [Int]
    /// The state of the gap before each line, and of the one after the last line.
    private let gaps: [Int]
    private let words: [(line: Int, index: Int, first: Int, last: Int)]
    /// The model's labels that the lyrics use, in the order of the emissions' columns after the blank.
    let labels: [Int]

    /// The price in log-probability of a frame of singing between two lines that the lyrics don't have.
    static let unwrittenFrame: Float = 2
    /// The two prices of each letter of a line that is left out.
    static let skippedLetter: (high: Float, low: Float) = (8, 5)
    /// The part of the model's doubt that anyone sings in a frame that the letters keep. The model leaves most of a
    /// sung frame to the blank when the voice is processed or buried, and still tells one letter from another there.
    static let doubtKept: Float = 0.6
    /// Two fits agree on a line when they start it within this many seconds of each other.
    static let agreement = 0.3

    /// The lines that the two fits start at the same moment, with the second their first word is sung at, and every
    /// word of those lines.
    func fit(_ emissions: Emissions) -> (starts: [Int: Double], words: [Word])? {
        let tempered = Self.tempered(emissions)
        guard let high = align(tempered, skippedLetter: Self.skippedLetter.high),
              let low = align(tempered, skippedLetter: Self.skippedLetter.low) else { return nil }
        let count = gaps.count - 1
        let first = high.lines(count: count), second = low.lines(count: count)
        var starts: [Int: Double] = [:]
        for line in 0 ..< count {
            guard let a = first[line], let b = second[line], abs(a.start - b.start) < Self.agreement else { continue }
            starts[line] = a.start
        }
        return (starts, high.words.filter { starts[$0.line] != nil })
    }

    /// The letters with only a part of the model's doubt that anyone sings: each letter's log-probability, less the
    /// rest of the log-probability that the frame isn't blank.
    private static func tempered(_ emissions: Emissions) -> Emissions {
        var tempered = emissions
        let width = emissions.width
        tempered.values.withUnsafeMutableBufferPointer { values in
            for frame in 0 ..< emissions.frames {
                let row = values.baseAddress! + frame * width
                let sung = log(max(1e-6, 1 - exp(row[0])))
                let lift = (1 - doubtKept) * sung
                for column in 1 ..< width { row[column] -= lift }
            }
        }
        return tempered
    }

    /// `label` gives the model's label for a character of the lyrics, or nil when the model has none for it.
    /// `space` is the model's label for the space between words, when it writes one.
    init(lines: [String], space: Int?, label: (Character) -> Int?) {
        var kinds: [Kind] = [], columns: [Int] = [], gaps: [Int] = []
        var words: [(line: Int, index: Int, first: Int, last: Int)] = []
        var labels: [Int] = [], column: [Int: Int] = [:]
        func columnOf(_ label: Int) -> Int {
            if let known = column[label] { return known }
            labels.append(label)
            column[label] = labels.count
            return labels.count
        }
        for (line, text) in lines.enumerated() {
            gaps.append(kinds.count)
            kinds.append(.gap)
            columns.append(0)
            var first = true
            for (index, word) in Self.sung(text) {
                let letters = word.compactMap(label)
                guard !letters.isEmpty else { continue }
                var start: Int?
                for (place, letter) in ((first || space == nil ? [] : [space!]) + letters).enumerated() {
                    if kinds.last == .letter {
                        kinds.append(.blank)
                        columns.append(0)
                    }
                    kinds.append(.letter)
                    columns.append(columnOf(letter))
                    let isSpace = !first && space != nil && place == 0
                    if !isSpace, start == nil { start = kinds.count - 1 }
                }
                words.append((line, index, start ?? kinds.count - 1, kinds.count - 1))
                first = false
            }
        }
        gaps.append(kinds.count)
        kinds.append(.gap)
        columns.append(0)
        self.kinds = kinds
        self.columns = columns
        self.gaps = gaps
        self.words = words
        self.labels = labels
    }

    /// The words of a line with their place in it, without the ones in brackets, which someone else often sings in
    /// the background.
    static func sung(_ line: String) -> [(index: Int, word: String)] {
        var result: [(Int, String)] = []
        var depth = 0
        for (index, word) in line.split(whereSeparator: \.isWhitespace).enumerated() {
            let inBrackets = depth > 0 || word.first == "(" || word.first == "["
            depth += word.count { $0 == "(" || $0 == "[" } - word.count { $0 == ")" || $0 == "]" }
            depth = max(depth, 0)
            if !inBrackets { result.append((index, String(word))) }
        }
        return result
    }

    /// Letters in the lyrics, for telling lyrics that are too short to fit from the rest.
    var letters: Int { kinds.count { $0 == .letter } }

    private func align(_ emissions: Emissions, skippedLetter: Float) -> Result? {
        let frames = emissions.frames, width = emissions.width, states = kinds.count
        guard frames > 1, width == labels.count + 1, !words.isEmpty else { return nil }
        let low: Float = -1e30

        // A gap takes a frame as silence, or as singing that the lyrics don't have: any label but the blank.
        var gapScore = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            let blank = emissions.values[frame * width]
            let sung = Self.doubtKept * log(max(1e-6, 1 - exp(blank))) - Self.unwrittenFrame
            gapScore[frame] = max(blank, sung)
        }
        // A letter follows the letter before it without a blank between them, unless the two are the same letter.
        var jumps = [Bool](repeating: false, count: states)
        for state in 2 ..< max(2, states) where kinds[state] == .letter && kinds[state - 1] == .blank && kinds[state - 2] == .letter {
            jumps[state] = columns[state] != columns[state - 2]
        }
        var skipCost = [Float](repeating: 0, count: gaps.count - 1)
        for line in skipCost.indices {
            let letters = (gaps[line] ..< gaps[line + 1]).count { kinds[$0] == .letter }
            skipCost[line] = skippedLetter * Float(letters)
        }

        var score = [Float](repeating: low, count: states)
        var next = score
        // The move that reached each state in each frame: 0 stayed, 1 from the state before, 2 from two before, 4 from
        // the gap before the line that was left out.
        var moves = [UInt8](repeating: 0, count: frames * states)
        score[0] = gapScore[0]
        for line in skipCost.indices { score[gaps[line + 1]] = max(score[gaps[line + 1]], score[gaps[line]] - skipCost[line]) }
        let isGap = kinds.map { $0 == .gap }

        emissions.values.withUnsafeBufferPointer { values in
            moves.withUnsafeMutableBufferPointer { moves in
                for frame in 1 ..< frames {
                    let row = values.baseAddress! + frame * width
                    let move = moves.baseAddress! + frame * states
                    let gap = gapScore[frame]
                    for state in 0 ..< states {
                        var best = score[state]
                        var from: UInt8 = 0
                        if state > 0, score[state - 1] > best {
                            best = score[state - 1]
                            from = 1
                        }
                        if jumps[state], score[state - 2] > best {
                            best = score[state - 2]
                            from = 2
                        }
                        next[state] = best + (isGap[state] ? gap : row[columns[state]])
                        move[state] = from
                    }
                    for line in skipCost.indices {
                        let skipped = next[gaps[line]] - skipCost[line]
                        if skipped > next[gaps[line + 1]] {
                            next[gaps[line + 1]] = skipped
                            move[gaps[line + 1]] = 4
                        }
                    }
                    swap(&score, &next)
                }
            }
        }

        // Back from the gap after the last line: the first and the last frame of each state on the path.
        var enter = [Int](repeating: -1, count: states), leave = enter
        var skipped: Set<Int> = []
        var state = states - 1, frame = frames - 1
        var lineOfGap: [Int: Int] = [:]
        for (line, gap) in gaps.enumerated() { lineOfGap[gap] = line }
        while frame >= 0 {
            let move = moves[frame * states + state]
            if move == 4 || (frame == 0 && state != 0) {
                // Only a gap is reached by leaving a line out, in the first frame too.
                guard let line = lineOfGap[state], line > 0 else { return nil }
                skipped.insert(line - 1)
                state = gaps[line - 1]
                continue
            }
            if leave[state] < 0 { leave[state] = frame }
            enter[state] = frame
            state -= Int(move)
            frame -= 1
        }

        var result = Result(words: [], skipped: skipped)
        let seconds = Emissions.frameSeconds
        for word in words where !skipped.contains(word.line) && enter[word.first] >= 0 {
            var sum: Float = 0, count: Float = 0
            for state in word.first ... word.last where kinds[state] == .letter && enter[state] >= 0 {
                var best = -Float.infinity
                for frame in enter[state] ... leave[state] { best = max(best, emissions.values[frame * width + columns[state]]) }
                sum += min(1, exp(best))
                count += 1
            }
            result.words.append(Word(line: word.line, index: word.index, start: Double(enter[word.first]) * seconds,
                                     end: Double(leave[word.last] + 1) * seconds, confidence: count > 0 ? sum / count : 0))
        }
        return result
    }
}
