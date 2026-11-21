import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: Model

/// The formats that Save As writes the notes in.
enum NotesFormat: String, CaseIterable, Identifiable {
    case musicXML, midi, textTab

    var id: String { rawValue }

    var name: String {
        switch self {
        case .musicXML: "MusicXML"
        case .midi: "MIDI"
        case .textTab: "Text Tab"
        }
    }

    var fileExtension: String {
        switch self {
        case .musicXML: "musicxml"
        case .midi: "mid"
        case .textTab: "txt"
        }
    }

    var type: UTType {
        switch self {
        case .musicXML: UTType(filenameExtension: "musicxml") ?? .xml
        case .midi: .midi
        case .textTab: .plainText
        }
    }
}

/// One notes window: the song, the stem, how far the transcription got, and the notes placed on the song's beats.
/// A step of a transcription, in the order that they run.
enum NotesStep: Int, CaseIterable, Comparable {
    case beats, stems, notes

    var name: String { ["Beats", "Stems", "Notes"][rawValue] }

    /// The part of the work that the step takes until this Mac has timed it: separating every stem takes longest.
    var share: Double { [0.05, 0.55, 0.4][rawValue] }

    static func < (a: NotesStep, b: NotesStep) -> Bool { a.rawValue < b.rawValue }
}

/// How long each step took on this Mac, per second of song, for the bar and the time left of the next transcription.
enum NotesTiming {
    private static let key = "notesStepSeconds"

    static func rate(_ step: NotesStep) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key)?[step.name] as? Double).flatMap { $0 > 0 ? $0 : nil }
    }

    /// A step that ran from its start took `seconds` for `song` seconds of song. The rate moves halfway to it, so one
    /// slow run doesn't decide the next estimate.
    static func learn(_ step: NotesStep, seconds: Double, song: Double) {
        guard seconds > 0.5, song > 10 else { return }
        var rates = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        let measured = seconds / song
        rates[step.name] = rate(step).map { ($0 + measured) / 2 } ?? measured
        UserDefaults.standard.set(rates, forKey: key)
    }
}

final class NotesModel: ObservableObject {
    enum Phase: Equatable {
        /// A step runs, and the fraction of it that is done, from 0 to 1.
        case working(NotesStep, Double)
        case ready
        case failed

        var step: NotesStep? {
            if case let .working(step, _) = self { step } else { nil }
        }
    }

    let path: String
    let title: String
    let artist: String?
    let stem: Stem
    let duration: Double

    @Published var phase: Phase {
        didSet {
            guard phase != oldValue else { return }
            if case let .working(step, fraction) = phase, step != oldValue.step || stepFrom == nil {
                stepStarted = Date()
                stepFrom = fraction
            }
            reached = max(reached, rawProgress(at: Date()))
            estimate()
        }
    }
    /// The steps that this transcription runs, which the bar covers from start to finish.
    @Published private(set) var steps: [NotesStep] = [.notes]
    /// The notes as Dettato heard them, before the transpose.
    @Published private(set) var notes: [TranscribedNote] = []
    @Published private(set) var beats: [Double] = []
    @Published private(set) var bpm: Double = 120
    @Published var key: DetectedKey? { didSet { if key != oldValue { rebuild() } } }
    /// The pitch change of the song, which the notes follow.
    @Published var shift = 0 { didSet { if shift != oldValue { rebuild() } } }
    @Published var view: NotesView
    @Published var loop: LoopRegion?
    @Published var playing = false
    @Published var artwork: NSImage?
    @Published private(set) var score: Score

    /// The time in the song now, or nil while the song isn't the one in the window.
    var now: () -> Double? = { nil }
    var onSeek: (Double) -> Void = { _ in }
    var onLoop: (Double, Double) -> Void = { _, _ in }
    var onPlayPause: () -> Void = {}
    var onTranspose: (Int) -> Void = { _ in }
    var onRetry: () -> Void = {}
    var onClose: () -> Void = {}
    var onSave: (NotesFormat) -> Void = { _ in }
    var onCopyTab: () -> Void = {}
    var onTurnPage: () -> Void = {}

    init(path: String, title: String, artist: String?, stem: Stem, duration: Double) {
        self.path = path
        self.title = title
        self.artist = artist
        self.stem = stem
        self.duration = duration
        view = .preferred(for: stem)
        phase = .working(.notes, 0)
        score = Score(notes: [], stem: stem, beats: [], bpm: 120, key: nil, duration: duration)
    }

    // MARK: Progress

    private var stepStarted = Date()
    /// Where the step that runs was when it started: a separation that was already running starts further on.
    private var stepFrom: Double?
    /// The furthest the bar went, which it never goes back from.
    private var reached = 0.0
    /// The seconds left at the last estimate, and when it was made. The time left counts down between estimates.
    private var left: (seconds: Double, at: Date)?

    /// The weight of each step in the bar: the seconds it takes on this Mac when every step was timed, or its share.
    private var weights: [Double] {
        let rates = steps.map(NotesTiming.rate)
        if rates.allSatisfy({ $0 != nil }) { return rates.map { $0! * max(duration, 1) } }
        return steps.map(\.share)
    }

    private func rawProgress(at date: Date) -> Double {
        switch phase {
        case .ready: return 1
        case .failed: return reached
        case let .working(step, fraction):
            let weights = weights, total = weights.reduce(0, +)
            guard total > 0, let index = steps.firstIndex(of: step) else { return reached }
            var fraction = fraction
            // Finding the beats tells nothing about how far it got, so its part of the bar fills with the time it takes.
            if step == .beats, let rate = NotesTiming.rate(.beats) {
                fraction = max(fraction, min(0.9, date.timeIntervalSince(stepStarted) / max(0.5, rate * duration)))
            }
            return (weights.prefix(index).reduce(0, +) + min(1, fraction) * weights[index]) / total
        }
    }

    /// The part of the transcription that is done, from 0 to 1, which only goes forward.
    func progress(at date: Date) -> Double { max(reached, rawProgress(at: date)) }

    /// The seconds until the notes are done, once there is an estimate.
    func secondsLeft(at date: Date) -> Double? {
        guard case .working = phase, let left else { return nil }
        return max(0, left.seconds - date.timeIntervalSince(left.at))
    }

    /// The time left from how fast the step that runs moves: the rest of that step, and the steps after it at the
    /// same speed for their weight. Before the step has moved, the timings of this Mac give it when every step was
    /// timed. A new estimate moves the countdown only part of the way, so it counts down instead of jumping.
    private func estimate() {
        guard case let .working(step, fraction) = phase, let index = steps.firstIndex(of: step) else { return left = nil }
        let now = Date(), weights = weights
        let elapsed = now.timeIntervalSince(stepStarted), moved = fraction - (stepFrom ?? fraction)
        let rest = (1 - fraction) * weights[index] + weights.suffix(from: index + 1).reduce(0, +)
        var seconds: Double?
        if elapsed >= 3, moved >= 0.03 {
            seconds = elapsed / (moved * weights[index]) * rest
        } else if steps.allSatisfy({ NotesTiming.rate($0) != nil }) {
            seconds = rest
        }
        guard let seconds else { return }
        let counted = secondsLeft(at: now)
        left = (counted.map { $0 * 0.6 + seconds * 0.4 } ?? seconds, now)
    }

    /// Shows `seconds` left, for renders.
    func showLeft(_ seconds: Double) { left = (seconds, Date()) }

    /// Starts a transcription that runs `steps`.
    func begin(_ steps: [NotesStep]) {
        self.steps = steps.isEmpty ? [.notes] : steps
        notes = []
        reached = 0
        stepFrom = nil
        left = nil
        phase = .working(self.steps[0], 0)
        rebuild()
    }

    var done: Bool { phase == .ready }
    var hasTab: Bool { stem == .bass || stem == .guitar }

    func setGrid(beats: [Double], bpm: Double) {
        self.beats = beats
        self.bpm = bpm > 0 ? bpm : 120
        rebuild()
    }

    func finish(_ notes: [TranscribedNote]) {
        self.notes = notes
        phase = .ready
        rebuild()
    }

    /// The score of the notes moved by the pitch change, in the key that the song plays in after it.
    private func rebuild() {
        let moved = shift == 0 ? notes : notes.map { TranscribedNote(start: $0.start, end: $0.end, pitch: $0.pitch + shift, program: $0.program, drum: $0.drum) }
        score = Score(notes: moved, stem: stem, beats: beats, bpm: bpm, key: key?.transposed(by: shift), duration: duration)
    }

    /// The score as it was heard, for the files that Save As writes, moved by the pitch change like the page.
    var fixture: NotesFixture {
        NotesFixture(title: title, stem: stem.name, key: key?.code, bpm: bpm, duration: duration, beats: beats, notes: notes)
    }
}

// MARK: Layout

/// The heights inside one line of notes, which depend on the view and the stem.
struct NotesStaff: Equatable {
    let view: NotesView
    /// Tab: the strings, lowest first.
    let strings: Int
    /// Sheet: a grand staff for the piano, one staff for the rest.
    let grand: Bool
    /// Sheet with one staff: the bass clef.
    let bassClef: Bool
    /// Piano roll: the lowest and the highest pitch that get a row.
    let low: Int
    let high: Int

    static let tabGap: CGFloat = 11
    static let staffGap: CGFloat = 7
    static let rowHeight: CGFloat = 4
    /// The gap between the two staves of a grand staff.
    static let grandGap: CGFloat = 44

    init(view: NotesView, score: Score) {
        self.view = view
        strings = score.tuning.count
        grand = score.stem == .piano
        let pitches = score.notes.filter { !$0.drum }.map(\.pitch).sorted()
        let median = pitches.isEmpty ? 60 : pitches[pitches.count / 2]
        bassClef = score.stem == .bass || (score.stem != .guitar && median < 55)
        var low = pitches.first ?? 48, high = pitches.last ?? 72
        low -= 1
        high += 1
        // At least two octaves, and at most four, around the middle of the notes.
        while high - low < 24 {
            low -= 1
            high += 1
        }
        if high - low > 48 {
            low = max(low, median - 24)
            high = low + 48
        }
        self.low = low
        self.high = high
    }

    /// From the top of a line to the top of its staff lines, past the bar numbers and the notes above the staff.
    var linesTop: CGFloat {
        switch view {
        case .tab: 18
        case .sheet: 32
        case .roll: 16
        }
    }

    /// The staff lines, or the rows of the piano roll: the part that the moving line covers.
    var linesHeight: CGFloat {
        switch view {
        case .tab: Self.tabGap * CGFloat(strings - 1)
        case .sheet: grand ? Self.staffGap * 8 + Self.grandGap : Self.staffGap * 4
        case .roll: Self.rowHeight * CGFloat(high - low + 1)
        }
    }

    /// The whole line, with the room under the staff and the gap to the next line.
    var height: CGFloat {
        switch view {
        case .tab: linesTop + linesHeight + 24 + 14
        case .sheet: linesTop + linesHeight + 26 + 10
        case .roll: linesTop + linesHeight + 16
        }
    }
}

/// Where every bar, note and moment of a score sits on the pages of the notes window. A page holds as many lines as
/// fit, split into a top half and a bottom half that turn one at a time.
struct NotesLayout: Equatable {
    static let margin: CGFloat = 16

    let size: CGSize
    let staff: NotesStaff
    let barsPerLine: Int
    let linesPerPage: Int
    let topLines: Int
    let lines: Int
    let pages: Int
    let bars: Int
    /// The left of the first bar of a line, after the clef, the key signature or the names of the strings.
    let x0: CGFloat

    init(score: Score, view: NotesView, size: CGSize) {
        self.size = size
        staff = NotesStaff(view: view, score: score)
        bars = score.bars.count
        switch view {
        case .tab: x0 = 40
        case .sheet: x0 = 40 + CGFloat(Spelling(key: score.key).signature.count) * 7
        case .roll: x0 = 32
        }
        let landscape = size.width > size.height * 1.05
        let shortest: CGFloat = view == .roll ? 60 : min(420, max(96, score.busiestBarWidth))
        let fit = Int((size.width - x0 - Self.margin) / shortest)
        barsPerLine = max(1, min(landscape ? 8 : 4, fit))
        linesPerPage = max(2, Int((size.height - Self.margin * 2) / staff.height))
        topLines = (linesPerPage + 1) / 2
        lines = max(1, (bars + barsPerLine - 1) / barsPerLine)
        pages = max(1, (lines + linesPerPage - 1) / linesPerPage)
    }

    var barWidth: CGFloat { max(10, (size.width - x0 - Self.margin) / CGFloat(barsPerLine)) }

    /// The top of a line of a page, from the top of the page.
    func top(ofRow row: Int) -> CGFloat { Self.margin + CGFloat(row) * staff.height }

    /// Where the top half of the page ends and the bottom half starts.
    var middle: CGFloat { top(ofRow: topLines) - 4 }

    func rows(top: Bool) -> Range<Int> { top ? 0 ..< topLines : topLines ..< linesPerPage }

    /// The page, the line on it and the x of the moment `time`.
    func spot(at time: Double, in score: Score) -> (page: Int, row: Int, x: CGFloat)? {
        guard let place = score.place(at: time) else { return nil }
        let line = place.bar / barsPerLine
        return (line / linesPerPage, line % linesPerPage, x0 + (CGFloat(place.bar % barsPerLine) + CGFloat(place.fraction)) * barWidth)
    }

    /// The page in each half while the song is at `time`: the top half shows the next page once the song reaches the
    /// bottom half, so the eyes never wait for a turn.
    func pagesShown(at time: Double?, in score: Score) -> (top: Int, bottom: Int) {
        guard let time, let spot = spot(at: time, in: score) else { return (0, 0) }
        if spot.row < topLines { return (spot.page, spot.page) }
        return (min(pages - 1, spot.page + 1), spot.page)
    }

    /// The place in beats under a point of the half that shows `page`.
    func position(at point: CGPoint, page: Int, top: Bool) -> Double {
        let range = rows(top: top)
        let row = min(range.upperBound - 1, max(range.lowerBound, Int(((point.y - Self.margin) / staff.height).rounded(.down))))
        let line = page * linesPerPage + row
        let offset = min(Double(barsPerLine) - 0.001, max(0, Double((point.x - x0) / barWidth)))
        let bar = Double(line * barsPerLine) + offset
        return min(Double(bars * Score.beatsPerBar), bar * Double(Score.beatsPerBar))
    }
}

// MARK: Drawing

/// Draws the lines of a page: tab, a staff or a piano roll.
struct NotesPainter {
    let score: Score
    let layout: NotesLayout
    let byBar: [[Score.Note]]
    let ink: Color
    let paper: Color
    let honey: Color
    /// The bars that start after this time aren't transcribed yet.
    let until: Double

    private var staff: NotesStaff { layout.staff }

    func draw(_ context: inout GraphicsContext, page: Int, rows: Range<Int>) {
        for row in rows {
            let line = page * layout.linesPerPage + row
            let first = line * layout.barsPerLine
            guard first < score.bars.count else { break }
            let bars = first ..< min(score.bars.count, first + layout.barsPerLine)
            let top = layout.top(ofRow: row)
            switch staff.view {
            case .tab: tab(&context, bars: bars, top: top)
            case .sheet: sheet(&context, bars: bars, top: top)
            case .roll: roll(&context, bars: bars, top: top)
            }
        }
    }

    private func barX(_ bar: Int, _ first: Int) -> CGFloat { layout.x0 + CGFloat(bar - first) * layout.barWidth }

    /// The x of a place in a bar, inside the padding of the bar.
    private func noteX(_ bar: Int, _ first: Int, beat: Double, pad: CGFloat = 10) -> CGFloat {
        barX(bar, first) + pad + CGFloat(beat / Double(Score.beatsPerBar)) * (layout.barWidth - pad * 1.6)
    }

    private func faint(_ bar: Int) -> Bool { score.bars[bar].start > until }

    private func text(_ string: String, size: CGFloat, weight: Font.Weight = .bold, color: Color) -> Text {
        Text(string).font(.system(size: size, weight: weight, design: .rounded)).foregroundColor(color)
    }

    private func line(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, width: CGFloat = 1) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func barLines(_ context: inout GraphicsContext, bars: Range<Int>, top: CGFloat, bottom: CGFloat) {
        for bar in bars {
            let x = barX(bar, bars.lowerBound)
            line(&context, from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom), color: ink.opacity(0.42))
            context.draw(text("\(bar + 1)", size: 7.5, color: ink.opacity(0.45)), at: CGPoint(x: x + 2, y: top - 9), anchor: .leading)
        }
        let end = barX(bars.upperBound, bars.lowerBound)
        line(&context, from: CGPoint(x: end, y: top), to: CGPoint(x: end, y: bottom), color: ink.opacity(0.42))
    }

    // MARK: Tab

    private func tab(_ context: inout GraphicsContext, bars: Range<Int>, top lineTop: CGFloat) {
        let gap = NotesStaff.tabGap
        let top = lineTop + staff.linesTop
        let count = staff.strings
        let bottom = top + gap * CGFloat(count - 1)
        let end = barX(bars.upperBound, bars.lowerBound)
        let names = score.tuning.map { ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][$0 % 12] }
        // The highest string at the top, as tab is written.
        for index in 0 ..< count {
            let y = top + gap * CGFloat(index)
            line(&context, from: CGPoint(x: layout.x0 - 12, y: y), to: CGPoint(x: end, y: y), color: ink.opacity(0.3))
            context.draw(text(names[count - 1 - index], size: 7, color: ink.opacity(0.4)), at: CGPoint(x: layout.x0 - 18, y: y))
        }
        for (index, letter) in ["T", "A", "B"].enumerated() {
            context.draw(text(letter, size: 8.5, weight: .heavy, color: ink.opacity(0.55)),
                         at: CGPoint(x: 8, y: (top + bottom) / 2 + CGFloat(index - 1) * 9.5))
        }
        barLines(&context, bars: bars, top: top, bottom: bottom)
        for bar in bars {
            let notes = byBar[bar]
            let alpha = faint(bar) ? 0.25 : 1.0
            var onsets: [(x: CGFloat, length: Double, beat: Double)] = []
            for note in notes {
                guard let string = note.string, let fret = note.fret else { continue }
                let x = noteX(bar, bars.lowerBound, beat: note.beat)
                let y = top + gap * CGFloat(count - 1 - string)
                let label = "\(fret)"
                let width: CGFloat = label.count > 1 ? 13 : 9
                context.fill(Path(CGRect(x: x - width / 2, y: y - 5.5, width: width, height: 11)), with: .color(paper))
                context.draw(text(label, size: 9.5, weight: .heavy, color: ink.opacity(alpha)), at: CGPoint(x: x, y: y))
                if !onsets.contains(where: { abs($0.x - x) < 0.5 }) { onsets.append((x, note.length, note.beat)) }
            }
            rhythm(&context, onsets: onsets.sorted { $0.x < $1.x }, top: bottom + 6, alpha: alpha)
        }
    }

    /// The rhythm under the tab: a stem for each onset, beams joining the eighths and sixteenths of one beat.
    private func rhythm(_ context: inout GraphicsContext, onsets: [(x: CGFloat, length: Double, beat: Double)], top: CGFloat, alpha: Double) {
        let color = ink.opacity(0.55 * alpha)
        for onset in onsets {
            line(&context, from: CGPoint(x: onset.x, y: top), to: CGPoint(x: onset.x, y: top + (onset.length >= 2 ? 7 : 11)), color: color)
        }
        let byBeat = Dictionary(grouping: onsets.filter { $0.length <= 0.5 }) { Int($0.beat) }
        for group in byBeat.values {
            let sorted = group.sorted { $0.x < $1.x }
            guard let first = sorted.first, let last = sorted.last else { continue }
            if sorted.count > 1 {
                line(&context, from: CGPoint(x: first.x, y: top + 11), to: CGPoint(x: last.x, y: top + 11), color: color, width: 2)
                if sorted.allSatisfy({ $0.length <= 0.25 }) {
                    line(&context, from: CGPoint(x: first.x, y: top + 7.5), to: CGPoint(x: last.x, y: top + 7.5), color: color, width: 2)
                }
            } else {
                line(&context, from: CGPoint(x: first.x, y: top + 11), to: CGPoint(x: first.x + 5, y: top + 7), color: color, width: 1.5)
            }
        }
    }

    // MARK: Sheet

    /// A staff: the y of its bottom line and the step of the note on it (E4 for the treble clef, G2 for the bass).
    private struct Clef {
        let bottom: CGFloat
        let step: Int
        let bass: Bool
    }

    private func sheet(_ context: inout GraphicsContext, bars: Range<Int>, top lineTop: CGFloat) {
        let gap = NotesStaff.staffGap
        let top = lineTop + staff.linesTop
        let end = barX(bars.upperBound, bars.lowerBound)
        let clefs = clefs(top: top)
        let spelling = Spelling(key: score.key)
        for clef in clefs {
            for index in 0 ..< 5 {
                let y = clef.bottom - gap * CGFloat(index)
                line(&context, from: CGPoint(x: 8, y: y), to: CGPoint(x: end, y: y), color: ink.opacity(0.32))
            }
            clefGlyph(&context, clef)
            signature(&context, clef, spelling)
        }
        let bottom = clefs.last!.bottom
        line(&context, from: CGPoint(x: 8, y: top), to: CGPoint(x: 8, y: bottom), color: ink.opacity(0.42))
        barLines(&context, bars: bars, top: top, bottom: bottom)
        for bar in bars {
            let alpha = faint(bar) ? 0.25 : 1.0
            var shown: [Int: String] = [:]
            let groups = Dictionary(grouping: byBar[bar]) { Int(($0.beat * 4).rounded()) }
            for onset in groups.keys.sorted() {
                let x = noteX(bar, bars.lowerBound, beat: Double(onset) / 4, pad: 14)
                for (index, clef) in clefs.enumerated() {
                    let notes = groups[onset]!.filter { clefs.count == 1 || ($0.pitch >= 60) == (index == 0) }
                    guard !notes.isEmpty else { continue }
                    chord(&context, notes, x: x, clef: clef, spelling: spelling, shown: &shown, alpha: alpha)
                }
            }
        }
    }

    /// The staves of a line whose top staff line is at `top`: one, or the treble and the bass of a grand staff.
    private func clefs(top: CGFloat) -> [Clef] {
        let gap = NotesStaff.staffGap
        if staff.grand {
            return [Clef(bottom: top + gap * 4, step: 30, bass: false), Clef(bottom: top + gap * 8 + NotesStaff.grandGap, step: 18, bass: true)]
        }
        return [Clef(bottom: top + gap * 4, step: staff.bassClef ? 18 : 30, bass: staff.bassClef)]
    }

    private func clefGlyph(_ context: inout GraphicsContext, _ clef: Clef) {
        let gap = NotesStaff.staffGap
        let glyph = Text(clef.bass ? "\u{1D122}" : "\u{1D11E}").font(.custom("Apple Symbols", size: clef.bass ? gap * 4.2 : gap * 5.6)).foregroundColor(ink)
        // The treble clef curls around the G line, the second from the bottom, and the bass clef's dots sit around
        // the F line, the second from the top.
        let y = clef.bass ? clef.bottom - gap * 2.6 : clef.bottom - gap * 1.6
        context.draw(glyph, at: CGPoint(x: 21, y: y))
    }

    private func signature(_ context: inout GraphicsContext, _ clef: Clef, _ spelling: Spelling) {
        guard !spelling.signature.isEmpty else { return }
        let gap = NotesStaff.staffGap
        // The steps of the sharps and the flats on the treble clef, in the order they are added; two octaves lower on
        // the bass clef.
        let steps = spelling.flats ? [34, 37, 33, 36, 32, 35, 31] : [38, 35, 39, 36, 33, 37, 34]
        for index in spelling.signature.indices {
            let step = steps[index] - (clef.bass ? 14 : 0)
            let y = clef.bottom - CGFloat(step - clef.step) * gap / 2
            context.draw(Text(spelling.flats ? "♭" : "♯").font(.system(size: 12)).foregroundColor(ink), at: CGPoint(x: 38 + CGFloat(index) * 7, y: y))
        }
    }

    /// The notes that start together on one staff: heads, accidentals, ledger lines, one stem and the flags of the
    /// shortest note.
    /// A lit chord takes the colour of its light and glows, over the ink chord of the page; `draw` false only keeps
    /// the accidentals of the bar up to date.
    private func chord(_ context: inout GraphicsContext, _ notes: [Score.Note], x: CGFloat, clef: Clef, spelling: Spelling, shown: inout [Int: String],
                       alpha: Double, light: Light? = nil, draw: Bool = true) {
        let gap = NotesStaff.staffGap
        let color = light?.tint ?? ink.opacity(alpha)
        // Guitar and bass are written an octave above where they sound.
        let lift = score.stem == .guitar || score.stem == .bass ? 12 : 0
        let spelled = notes.map { note -> (step: Int, accidental: String?, length: Double) in
            let (step, accidental) = spelling.spell(note.pitch + lift)
            return (step, accidental, note.length)
        }
        let length = spelled.map(\.length).min() ?? 1
        let ys = spelled.map { clef.bottom - CGFloat($0.step - clef.step) * gap / 2 }
        // Notes under the middle line take a stem up on their right, the others a stem down on their left.
        let middle = clef.bottom - gap * 2
        let up = ys.isEmpty ? true : (ys.max()! + ys.min()!) / 2 > middle
        // Two notes a step apart can't share a column: the upper one of a second goes right of an up stem, the lower one
        // left of a down stem, walking away from the stem's foot so that a cluster alternates sides.
        let shift: CGFloat = 7.6
        var side = [CGFloat](repeating: 0, count: spelled.count)
        let order = spelled.indices.sorted { up ? spelled[$0].step < spelled[$1].step : spelled[$0].step > spelled[$1].step }
        for (n, index) in order.enumerated() where n > 0 {
            let before = order[n - 1]
            if abs(spelled[index].step - spelled[before].step) == 1, side[before] == 0 { side[index] = up ? shift : -shift }
        }
        let left = side.contains { $0 < 0 } ? shift : 0
        let right = side.contains { $0 > 0 } ? shift : 0
        // Accidentals from the top down, each in the first column left of the heads that has no sign within a sixth.
        var columns: [[Int]] = []
        var signs: [(index: Int, sign: String, column: Int)] = []
        for index in spelled.indices.sorted(by: { spelled[$0].step > spelled[$1].step }) {
            let note = spelled[index]
            // An accidental once per step in a bar, and a natural for a step that had one.
            var sign = note.accidental
            if sign == nil, shown[note.step] != nil { sign = "♮" }
            guard let sign, shown[note.step] != sign else { continue }
            shown[note.step] = sign
            let column = columns.firstIndex { $0.allSatisfy { abs($0 - note.step) > 5 } } ?? columns.count
            if column == columns.count { columns.append([]) }
            columns[column].append(note.step)
            signs.append((index, sign, column))
        }
        guard draw else { return }
        if let light, let low = ys.max(), let high = ys.min() {
            halo(&context, at: CGPoint(x: x, y: (low + high) / 2), radius: 10 + 7 * min(1.35, light.level) + (low - high) / 2, light: light)
        }
        for (index, note) in spelled.enumerated() {
            let y = ys[index]
            // Ledger lines under and over the staff, wide enough for a head moved to either side.
            let from = x - 7 - left, to = x + 7 + right
            if light != nil {
                // The ledger lines of a lit chord stay as the page draws them.
            } else if note.step < clef.step - 1 {
                for step in stride(from: clef.step - 2, through: note.step, by: -2) {
                    let ly = clef.bottom - CGFloat(step - clef.step) * gap / 2
                    line(&context, from: CGPoint(x: from, y: ly), to: CGPoint(x: to, y: ly), color: ink.opacity(0.45 * alpha))
                }
            } else if note.step > clef.step + 9 {
                for step in stride(from: clef.step + 10, through: note.step, by: 2) {
                    let ly = clef.bottom - CGFloat(step - clef.step) * gap / 2
                    line(&context, from: CGPoint(x: from, y: ly), to: CGPoint(x: to, y: ly), color: ink.opacity(0.45 * alpha))
                }
            }
            let hx = x + side[index]
            let head = Path(ellipseIn: CGRect(x: -4.2, y: -3.1, width: 8.4, height: 6.2))
                .applying(CGAffineTransform(rotationAngle: -0.35))
                .applying(CGAffineTransform(translationX: hx, y: y))
            if length >= 2 { context.stroke(head, with: .color(color), lineWidth: 1.3) } else { context.fill(head, with: .color(color)) }
            if [0.75, 1.5, 3].contains(length) {
                context.fill(Path(ellipseIn: CGRect(x: x + 6 + right, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(color))
            }
        }
        for (index, sign, column) in signs {
            let ax = x - 10 - left - CGFloat(column) * 7
            context.draw(Text(sign).font(.system(size: 11)).foregroundColor(color), at: CGPoint(x: ax, y: ys[index]))
        }
        guard length < 4, let low = ys.max(), let high = ys.min() else { return }
        let stemX = up ? x + 3.8 : x - 3.8
        let tip = up ? high - gap * 3.5 : low + gap * 3.5
        line(&context, from: CGPoint(x: stemX, y: up ? low : high), to: CGPoint(x: stemX, y: tip), color: color, width: 1.1)
        let flags = length <= 0.25 ? 2 : length <= 0.75 && length != 0.75 ? 1 : length == 0.75 ? 1 : 0
        for index in 0 ..< flags {
            let y = tip + CGFloat(index) * (up ? 5 : -5)
            var flag = Path()
            flag.move(to: CGPoint(x: stemX, y: y))
            flag.addQuadCurve(to: CGPoint(x: stemX + 5, y: y + (up ? 10 : -10)), control: CGPoint(x: stemX + 6, y: y + (up ? 3 : -3)))
            context.stroke(flag, with: .color(color), lineWidth: 1.2)
        }
    }

    // MARK: Piano roll

    private func roll(_ context: inout GraphicsContext, bars: Range<Int>, top lineTop: CGFloat) {
        let rowHeight = NotesStaff.rowHeight
        let top = lineTop + staff.linesTop
        let rows = staff.high - staff.low + 1
        let end = barX(bars.upperBound, bars.lowerBound)
        let black: Set<Int> = [1, 3, 6, 8, 10]
        for index in 0 ..< rows {
            let pitch = staff.high - index
            let y = top + CGFloat(index) * rowHeight
            let isBlack = black.contains(pitch % 12)
            context.fill(Path(CGRect(x: 4, y: y, width: 22, height: rowHeight)),
                         with: .color(isBlack ? Color(red: 0.1, green: 0.09, blue: 0.094) : Color(red: 0.91, green: 0.89, blue: 0.85)))
            line(&context, from: CGPoint(x: 4, y: y + rowHeight), to: CGPoint(x: 26, y: y + rowHeight), color: .black.opacity(0.35), width: 0.4)
            context.fill(Path(CGRect(x: layout.x0, y: y, width: end - layout.x0, height: rowHeight)), with: .color(ink.opacity(isBlack ? 0.025 : 0.05)))
            if pitch % 12 == 0 {
                context.draw(text("C\(pitch / 12 - 1)", size: 6, color: ink.opacity(0.5)), at: CGPoint(x: layout.x0 - 3, y: y + rowHeight / 2), anchor: .trailing)
            }
        }
        let bottom = top + CGFloat(rows) * rowHeight
        for bar in bars {
            for beat in 1 ..< Score.beatsPerBar {
                let x = barX(bar, bars.lowerBound) + layout.barWidth * CGFloat(beat) / CGFloat(Score.beatsPerBar)
                line(&context, from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom), color: ink.opacity(0.07))
            }
        }
        barLines(&context, bars: bars, top: top, bottom: bottom)
        for bar in bars {
            let alpha = faint(bar) ? 0.25 : 1.0
            for note in byBar[bar] {
                let pitch = min(staff.high, max(staff.low, note.pitch))
                let x = barX(bar, bars.lowerBound) + layout.barWidth * CGFloat(note.beat / Double(Score.beatsPerBar))
                let width = max(3, min(end - x, layout.barWidth * CGFloat(note.length / Double(Score.beatsPerBar))) - 1.5)
                let y = top + CGFloat(staff.high - pitch) * rowHeight
                context.fill(Path(roundedRect: CGRect(x: x + 0.5, y: y + 0.4, width: width, height: rowHeight - 0.8), cornerRadius: 1.5),
                             with: .color(honey.opacity(alpha)))
            }
        }
    }

    // MARK: Light

    /// A place where notes start on a line: the bar and the sixteenth as a key, the line, and the x where the playhead
    /// touches it.
    struct Onset {
        let key: Int
        let line: Int
        let x: CGFloat
    }

    /// The colours of the light: the glow around a lit note, the warm white of the brightest moment, and the scheme.
    struct LightColors {
        let glow: Color
        let hot: Color
        let dark: Bool
    }

    /// A lit note: its colour, the colour of its glow, and how lit it is, from 0 to about 1.4 in the flash.
    struct Light {
        let tint: Color
        let glow: Color
        let level: Double
        let dark: Bool
    }

    /// How far left of a note's centre the playhead touches it: about half a fret number or a note head.
    private var reach: CGFloat { staff.view == .roll ? 0 : 4 }

    /// A note lights from its own colour to honey, and then towards warm white when it's brightest, less so on paper.
    private func light(_ level: Double, colors: LightColors, base: Color) -> Light? {
        guard level > 0.01 else { return nil }
        let hot = min(1, level)
        let tint = hot < 0.75 ? base.mix(with: honey, by: hot / 0.75)
            : honey.mix(with: colors.hot, by: (hot - 0.75) / 0.25 * (colors.dark ? 0.7 : 0.35))
        return Light(tint: tint, glow: colors.glow, level: level, dark: colors.dark)
    }

    /// The light around a lit note, which adds to the dark page and tints the light one.
    private func halo(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, light: Light) {
        let alpha = (light.dark ? 0.34 : 0.3) * min(1.35, light.level)
        var glow = context
        if light.dark { glow.blendMode = .plusLighter }
        // A bright core and a soft falloff, drawn as one gradient: a blur filter on every frame cost frames.
        let gradient = Gradient(stops: [
            .init(color: light.glow.opacity(min(1, alpha * 1.8)), location: 0),
            .init(color: light.glow.opacity(alpha * 0.9), location: 0.22),
            .init(color: light.glow.opacity(alpha * 0.35), location: 0.55),
            .init(color: light.glow.opacity(0), location: 1),
        ])
        glow.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                  with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
    }

    /// Draws the notes of a page half that the playhead lights, over the page. `level` says how lit an onset is.
    func drawLight(_ context: inout GraphicsContext, page: Int, rows: Range<Int>, colors: LightColors, level: (Onset) -> Double) {
        for row in rows {
            let line = page * layout.linesPerPage + row
            let first = line * layout.barsPerLine
            guard first < score.bars.count else { break }
            let bars = first ..< min(score.bars.count, first + layout.barsPerLine)
            let top = layout.top(ofRow: row) + staff.linesTop
            switch staff.view {
            case .tab:
                // The halos first, so that no halo lies over a lit number next to it.
                var lit: [(x: CGFloat, y: CGFloat, fret: Int, light: Light)] = []
                for bar in bars {
                    for note in byBar[bar] {
                        guard let string = note.string, let fret = note.fret else { continue }
                        let x = noteX(bar, bars.lowerBound, beat: note.beat)
                        let onset = Onset(key: bar * 64 + Int((note.beat * 4).rounded()), line: line, x: x - reach)
                        guard let light = light(level(onset), colors: colors, base: ink) else { continue }
                        lit.append((x, top + NotesStaff.tabGap * CGFloat(staff.strings - 1 - string), fret, light))
                    }
                }
                for note in lit {
                    halo(&context, at: CGPoint(x: note.x, y: note.y), radius: 9 + 7 * min(1.35, note.light.level), light: note.light)
                }
                for note in lit {
                    context.draw(text("\(note.fret)", size: 9.5, weight: .heavy, color: note.light.tint), at: CGPoint(x: note.x, y: note.y))
                }
            case .sheet:
                let clefs = clefs(top: top)
                let spelling = Spelling(key: score.key)
                for bar in bars {
                    let groups = Dictionary(grouping: byBar[bar]) { Int(($0.beat * 4).rounded()) }
                    let places = groups.keys.sorted()
                    let lights = places.map { place in
                        light(level(Onset(key: bar * 64 + place, line: line, x: noteX(bar, bars.lowerBound, beat: Double(place) / 4, pad: 14) - reach)),
                              colors: colors, base: ink)
                    }
                    // A bar with nothing lit is skipped; in a lit bar every chord runs, for the accidentals of the bar.
                    guard lights.contains(where: { $0 != nil }) else { continue }
                    var shown: [Int: String] = [:]
                    for (place, light) in zip(places, lights) {
                        let x = noteX(bar, bars.lowerBound, beat: Double(place) / 4, pad: 14)
                        for (index, clef) in clefs.enumerated() {
                            let notes = groups[place]!.filter { clefs.count == 1 || ($0.pitch >= 60) == (index == 0) }
                            guard !notes.isEmpty else { continue }
                            chord(&context, notes, x: x, clef: clef, spelling: spelling, shown: &shown, alpha: 1, light: light, draw: light != nil)
                        }
                    }
                }
            case .roll:
                let rowHeight = NotesStaff.rowHeight
                let end = barX(bars.upperBound, bars.lowerBound)
                for bar in bars {
                    for note in byBar[bar] {
                        let x = barX(bar, bars.lowerBound) + layout.barWidth * CGFloat(note.beat / Double(Score.beatsPerBar))
                        let onset = Onset(key: bar * 64 + Int((note.beat * 4).rounded()), line: line, x: x)
                        guard let light = light(level(onset), colors: colors, base: honey) else { continue }
                        let pitch = min(staff.high, max(staff.low, note.pitch))
                        let width = max(3, min(end - x, layout.barWidth * CGFloat(note.length / Double(Score.beatsPerBar))) - 1.5)
                        let rect = CGRect(x: x + 0.5, y: top + CGFloat(staff.high - pitch) * rowHeight + 0.4, width: width, height: rowHeight - 0.8)
                        halo(&context, at: CGPoint(x: rect.minX + min(rect.width / 2, 8), y: rect.midY), radius: 8 + 6 * min(1.35, light.level), light: light)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(light.tint))
                    }
                }
            }
        }
    }

    // MARK: Overlays

    /// The rectangles of a region from `start` to `end` in beats on the lines of a page half.
    func region(from start: Double, to end: Double, page: Int, rows: Range<Int>) -> [CGRect] {
        var rects: [CGRect] = []
        let perLine = Double(layout.barsPerLine * Score.beatsPerBar)
        for row in rows {
            let line = page * layout.linesPerPage + row
            let lineStart = Double(line) * perLine, lineEnd = lineStart + perLine
            let from = max(start, lineStart), to = min(end, lineEnd)
            guard to > from else { continue }
            let beatWidth = layout.barWidth / CGFloat(Score.beatsPerBar)
            let top = layout.top(ofRow: row) + staff.linesTop - 8
            rects.append(CGRect(x: layout.x0 + CGFloat(from - lineStart) * beatWidth, y: top,
                                width: CGFloat(to - from) * beatWidth, height: staff.linesHeight + 16))
        }
        return rects
    }
}

// MARK: Views

/// The notes window: the song and the views at the top, a page of notes in the middle, and the time and the keys at
/// the bottom.
struct NotesWindowView: View {
    @ObservedObject var model: NotesModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.of(colorScheme)
        VStack(spacing: 0) {
            NotesTopBar(model: model, palette: palette)
            NotesPageView(model: model, palette: palette)
                .padding(.horizontal, 12)
            NotesFooter(model: model, palette: palette)
        }
        .frame(minWidth: 520, minHeight: 420)
        .modifier(HUDBackground(tint: .current, scheme: colorScheme))
        .ignoresSafeArea()
    }
}

private struct NotesTopBar: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 12) {
            CloseButton(action: model.onClose)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text([model.stem.name, model.artist].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .frame(minWidth: 90, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
            NotesViewSwitch(view: $model.view, palette: palette)
            // A narrow window keeps the pills that it has room for, the transpose first.
            ViewThatFits(in: .horizontal) {
                NotesStatus(model: model, palette: palette, tempo: true, key: true)
                NotesStatus(model: model, palette: palette, tempo: false, key: true)
                NotesStatus(model: model, palette: palette, tempo: false, key: false)
            }
            RoundButton(symbol: "rectangle.portrait.rotate", help: "Portrait or landscape page", palette: palette, action: model.onTurnPage)
            Menu {
                Section("Save the notes as") {
                    ForEach(NotesFormat.allCases.filter { $0 != .textTab || model.hasTab }) { format in
                        Button(format.name) { model.onSave(format) }
                    }
                }
                if model.hasTab {
                    Divider()
                    Button("Copy Text Tab", action: model.onCopyTab).keyboardShortcut("c", modifiers: [.command, .shift])
                }
            } label: {
                Text("Save As…")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(palette.ink.opacity(0.1)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.done)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }
}

/// Sheet, Tab and Piano roll, in a capsule like the pills of the HUD.
private struct NotesViewSwitch: View {
    @Binding var view: NotesView
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NotesView.allCases) { option in
                Button { view = option } label: {
                    Text(option.name)
                        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(option == view ? palette.ink : palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(palette.ink.opacity(option == view ? 0.14 : 0)))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(2)
        .background(Capsule().fill(palette.ink.opacity(0.07)))
        .help("Next view (⇥)")
    }
}

/// The key and the tempo once the notes are done. The progress and a failure show on the page.
private struct NotesStatus: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    var tempo = true
    var key = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            if model.done {
                if model.shift != 0 { pill(Shift.text(model.shift), color: StripColors.text(.honey, colorScheme)) }
                if key, let shown = model.key?.transposed(by: model.shift) { pill(shown.name, color: palette.ink) }
                if tempo { pill("\(Int(model.bpm.rounded())) BPM", color: palette.ink) }
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
    }
}

/// The transcription in the middle of the blank page until the notes are done: the steps that it runs, the step that
/// runs now, one bar from start to finish and the time left. A failure shows here too, with Retry.
private struct NotesProgressCard: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme

    private var honey: Color { StripColors.text(.honey, colorScheme) }

    var body: some View {
        VStack(spacing: 14) {
            if model.phase == .failed {
                HStack(spacing: 8) {
                    let red = Color(red: 1, green: 0.42, blue: 0.4)
                    Text("Transcription failed")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(red.opacity(0.12)))
                        .fixedSize()
                    HUDButton(title: "Retry", symbol: "arrow.clockwise", palette: palette, small: true, action: model.onRetry)
                }
            } else {
                if model.steps.count > 1 { stepsRow }
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let done = model.progress(at: context.date)
                    VStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(palette.ink.opacity(0.1))
                                Capsule().fill(honey).frame(width: max(6, geo.size.width * done))
                            }
                        }
                        .frame(height: 6)
                        .animation(.linear(duration: 0.25), value: done)
                        HStack {
                            // Rounded down, so 100% shows only with the notes.
                            Text("\(Int((done * 100).rounded(.down)))%")
                            Spacer()
                            if let left = model.secondsLeft(at: context.date) { Text("\(Self.time(left)) left") }
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.muted)
                    }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(colorScheme == .dark ? Color(white: 0.15) : .white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.14), radius: 18, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(palette.ink.opacity(0.07), lineWidth: 1))
    }

    private var title: String {
        switch model.phase.step ?? .notes {
        case .beats: "Finding the beats"
        case .stems: "Separating stems"
        case .notes: "Transcribing \(model.stem.name.lowercased())"
        }
    }

    /// The steps that run, the done ones ticked and the one that runs now in honey.
    private var stepsRow: some View {
        let current = model.phase.step ?? .notes
        return HStack(spacing: 10) {
            ForEach(Array(model.steps.enumerated()), id: \.element) { index, step in
                if index > 0 { Capsule().fill(palette.ink.opacity(0.15)).frame(width: 14, height: 1.5) }
                HStack(spacing: 4) {
                    Image(systemName: step < current ? "checkmark.circle.fill" : step == current ? "circle.inset.filled" : "circle")
                        .font(.system(size: 11, weight: .bold))
                    Text(step.name)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(step == current ? honey : step < current ? palette.ink.opacity(0.75) : palette.muted.opacity(0.7))
                .fixedSize()
            }
        }
    }

    /// Minutes and seconds, in steps of five seconds above a minute, so the count doesn't flicker.
    static func time(_ seconds: Double) -> String {
        let whole = seconds > 60 ? Int((seconds / 5).rounded(.up)) * 5 : Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The page: two halves of lines that stay still, a line that moves through them with the song, and the region loop.
/// A click moves the song there, and a drag across the notes sets the region loop.
private struct NotesPageView: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown = (top: 0, bottom: 0)
    /// The pages turn with an animation only when the song reaches another page. The first pages, another view and
    /// another size of the window show at once.
    @State private var animateTurns = false
    @State private var placed = false
    @State private var drag: (from: Double, to: Double)?
    /// The halves that are turning, where the playhead waits until the new page lies flat.
    @State private var turning: Set<Bool> = []
    @Environment(\.renderingPreview) private var renderingPreview

    private static let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.094, blue: 0.098) : Color(red: 0.99, green: 0.975, blue: 0.955)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = NotesLayout(score: model.score, view: model.view, size: geometry.size)
            // A render has no timer to turn the pages, so it shows the pages of the moment it renders. Until the notes
            // are done, the first page stays, with faint lines under the progress.
            let pages = !model.done ? layout.pagesShown(at: nil, in: model.score)
                : renderingPreview ? layout.pagesShown(at: model.now(), in: model.score) : shown
            let painter = NotesPainter(score: model.score, layout: layout, byBar: model.score.notesByBar, ink: palette.ink, paper: paper,
                                       honey: StripColors.text(.honey, colorScheme), until: model.done ? .infinity : -1)
            ZStack(alignment: .topLeading) {
                Group {
                    half(painter, top: true, page: pages.top)
                    half(painter, top: false, page: pages.bottom)
                }
                .opacity(model.done ? 1 : 0.3)
                Rectangle()
                    .fill(palette.ink.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .offset(y: layout.middle)
                if model.done {
                    NotesPlayhead(model: model, painter: painter, shown: pages, turning: turning)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(pointer(layout), isEnabled: model.done)
            .overlay {
                if !model.done {
                    NotesProgressCard(model: model, palette: palette)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.done)
            .onReceive(Self.tick) { _ in turn(layout) }
            .onChange(of: layout) { turn(layout, animated: false) }
            .onAppear { turn(layout, animated: false) }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(paper))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.ink.opacity(0.06), lineWidth: 1))
    }

    private func half(_ painter: NotesPainter, top: Bool, page: Int) -> some View {
        let layout = painter.layout
        let height = top ? layout.middle : layout.size.height - layout.middle
        return NotesPageTurn(page: page, animated: animateTurns && !renderingPreview, paper: paper, onTurn: { on in
            if on { turning.insert(top) } else { turning.remove(top) }
        }) { page in
            // The region loop belongs to the page, so it turns with it.
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    if !top { context.translateBy(x: 0, y: -layout.middle) }
                    painter.draw(&context, page: page, rows: layout.rows(top: top))
                }
                region(painter, page: page, top: top)
            }
            .frame(width: layout.size.width, height: max(0, height), alignment: .topLeading)
        }
        .frame(width: layout.size.width, height: max(0, height))
        .clipped()
        .offset(y: top ? 0 : layout.middle)
    }

    /// The region loop on the lines of one half of a page, in the coordinates of that half.
    @ViewBuilder private func region(_ painter: NotesPainter, page: Int, top: Bool) -> some View {
        let beats = model.score.beats
        let loop: (Double, Double)? = drag.map { (min($0.from, $0.to), max($0.from, $0.to)) }
            ?? model.loop.flatMap { loop in loop.end.map { (Score.position(of: loop.start, in: beats), Score.position(of: $0, in: beats)) } }
        if let (start, end) = loop {
            let honey = StripColors.text(.honey, colorScheme)
            let rects = painter.region(from: start, to: end, page: page, rows: painter.layout.rows(top: top))
            let dy = top ? 0 : painter.layout.middle
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 5)
                    .fill(honey.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(honey.opacity(0.55), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY - dy)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A click moves the song to the beat under the pointer, and a drag sets the region loop between two beats.
    private func pointer(_ layout: NotesLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) > 4 else { return }
                let from = position(value.startLocation, layout).rounded()
                let to = position(value.location, layout).rounded()
                drag = (from, to)
            }
            .onEnded { value in
                defer { drag = nil }
                if let drag, abs(drag.to - drag.from) >= 1 {
                    let start = model.score.time(at: min(drag.from, drag.to)), end = model.score.time(at: max(drag.from, drag.to))
                    model.onLoop(start, end)
                } else if hypot(value.translation.width, value.translation.height) <= 4 {
                    model.onSeek(max(0, model.score.time(at: position(value.location, layout).rounded(.down))))
                }
            }
    }

    private func position(_ point: CGPoint, _ layout: NotesLayout) -> Double {
        let top = point.y < layout.middle
        return layout.position(at: point, page: top ? shown.top : shown.bottom, top: top)
    }

    private func turn(_ layout: NotesLayout, animated: Bool = true) {
        // The first notes show at once, on the pages of the moment they arrive.
        guard model.done else { return placed = false }
        let pages = layout.pagesShown(at: model.now(), in: model.score)
        defer { placed = true }
        guard pages != shown else { return }
        animateTurns = animated && placed
        shown = pages
    }
}

/// The honey line, which moves through the lines at the speed of the song and jumps to the next line at the end of
/// each one. The notes light like phosphor as it passes: a note barely stirs as the line comes close, flashes a little
/// past full brightness when the line touches it, and keeps an afterglow that fades over about a second of the song.
/// The light comes from the song's time alone, so it holds still while the song is paused and is right after a seek.
/// `--log-notes-frames` logs how many frames the line drew in each second and the longest wait between two frames.
nonisolated(unsafe) var notesFrameLog: ((Int, Double) -> Void)?
nonisolated(unsafe) private var notesFrames = (start: Date.distantPast, count: 0, last: Date.distantPast, gap: 0.0)

private func countNotesFrame(_ report: (Int, Double) -> Void) {
    let now = Date()
    let since = now.timeIntervalSince(notesFrames.last)
    if since < 1 { notesFrames.gap = max(notesFrames.gap, since) }
    notesFrames.count += 1
    notesFrames.last = now
    if now.timeIntervalSince(notesFrames.start) >= 1 {
        if notesFrames.count > 1 { report(notesFrames.count, notesFrames.gap) }
        notesFrames = (now, 0, now, 0)
    }
}

private struct NotesPlayhead: View {
    @ObservedObject var model: NotesModel
    let painter: NotesPainter
    let shown: (top: Int, bottom: Int)
    /// The halves that are turning (true is the top one): the line and the light show there once the page lies flat.
    var turning: Set<Bool> = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(paused: !model.playing)) { timeline in
            // The frame's date goes into the drawing, so that the canvas draws again on every frame: with nothing in it
            // that changed, the canvas only drew when another view made it.
            let frame = timeline.date
            Canvas { context, _ in
                _ = frame
                if let notesFrameLog { countNotesFrame(notesFrameLog) }
                let layout = painter.layout
                guard let time = model.now(), let spot = layout.spot(at: time, in: model.score) else { return }
                let dark = colorScheme == .dark
                let colors = NotesPainter.LightColors(
                    glow: dark ? Color(red: 1, green: 0.82, blue: 0.48) : Color(red: 0.94, green: 0.71, blue: 0.26),
                    hot: dark ? Color(red: 1, green: 0.965, blue: 0.886) : Color(red: 1, green: 0.84, blue: 0.55),
                    dark: dark
                )
                let line = spot.page * layout.linesPerPage + spot.row
                let score = model.score
                for top in [true, false] where !turning.contains(top) {
                    painter.drawLight(&context, page: top ? shown.top : shown.bottom, rows: layout.rows(top: top), colors: colors) { onset in
                        Self.phosphor(onset, time: time, line: line, x: spot.x, layout: layout, score: score)
                    }
                }
                let inTop = spot.row < layout.topLines
                guard spot.page == (inTop ? shown.top : shown.bottom), !turning.contains(inTop) else { return }
                let top = layout.top(ofRow: spot.row) + layout.staff.linesTop - 7
                let rect = CGRect(x: spot.x - 1, y: top, width: 2, height: layout.staff.linesHeight + 14)
                let honey = StripColors.text(.honey, colorScheme)
                // The glow is a band of honey that fades out on both sides, which costs nothing like a shadow filter.
                let band = rect.insetBy(dx: -6, dy: 0)
                context.fill(Path(roundedRect: band, cornerRadius: 6), with: .linearGradient(
                    Gradient(stops: [.init(color: honey.opacity(0), location: 0), .init(color: honey.opacity(dark ? 0.32 : 0.24), location: 0.5),
                                     .init(color: honey.opacity(0), location: 1)]),
                    startPoint: CGPoint(x: band.minX, y: band.midY), endPoint: CGPoint(x: band.maxX, y: band.midY)))
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(honey))
            }
        }
        .allowsHitTesting(false)
    }

    /// How lit an onset is with the playhead at `x` on `line`: a faint warm-up over the last seventh of a bar before
    /// the touch, then the flash and the afterglow, timed from the moment that the playhead touched it.
    static func phosphor(_ onset: NotesPainter.Onset, time: Double, line: Int, x: CGFloat, layout: NotesLayout, score: Score) -> Double {
        guard onset.line < line || (onset.line == line && onset.x <= x) else {
            guard onset.line == line else { return 0 }
            let span = layout.barWidth * 0.14, distance = onset.x - x
            return distance < span ? 0.16 * pow(1 - distance / span, 3) : 0
        }
        let bars = Double(onset.line * layout.barsPerLine) + Double((onset.x - layout.x0) / layout.barWidth)
        let age = time - score.time(at: bars * Double(Score.beatsPerBar))
        guard age >= 0, age < 5 else { return 0 }
        return exp(-age / 1.1) * (1 + 0.45 * exp(-age / 0.09))
    }
}

/// Half a page that turns like a page of a book when it shows another page: the old page lifts at its right edge and
/// folds away to the left over the new one, or back from the left for an earlier page.
/// `--notes-fold F` renders each half in the middle of a turn, with the fold at F (1 is the right edge, 0 the left).
nonisolated(unsafe) var notesFoldInRenders: Double?

private struct NotesPageTurn<Content: View>: View {
    let page: Int
    /// False shows another page at once.
    let animated: Bool
    let paper: Color
    /// Called with true when a turn starts, and with false once the new page lies flat.
    var onTurn: (Bool) -> Void = { _ in }
    @ViewBuilder let content: (Int) -> Content
    /// The page that lies flat, and the page that turns over it, while a turn runs.
    @State private var beneath: Int?
    @State private var turning: Int?
    /// The page that the turn that runs ends on, and the number of that turn: only the latest turn may finish.
    @State private var target: Int?
    @State private var turnID = 0
    /// Where the fold is, from 1 at the right edge (the turning page lies flat) to 0 at the left edge (it is gone).
    @State private var fold: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            if let fold = notesFoldInRenders {
                // `--notes-fold`: the turn to the next page, stopped where the fold is.
                PageFold(fold: fold, width: geometry.size.width, paper: paper, dark: scheme == .dark, crossfade: false,
                         front: content(page), beneath: content(page + 1))
            } else if let turning, let beneath {
                PageFold(fold: fold, width: geometry.size.width, paper: paper, dark: scheme == .dark, crossfade: reduceMotion,
                         front: content(turning), beneath: content(beneath))
            } else {
                content(beneath ?? page)
            }
        }
        .onChange(of: page) { old, new in turn(from: target ?? beneath ?? old, to: new) }
        .onDisappear { onTurn(false) }
    }

    private func turn(from old: Int, to new: Int) {
        turnID += 1
        let id = turnID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        guard animated, old != new else {
            withTransaction(transaction) {
                beneath = new
                turning = nil
                fold = 1
            }
            target = nil
            onTurn(false)
            return
        }
        onTurn(true)
        target = new
        let curve = Animation.timingCurve(0.42, 0.05, 0.3, 1, duration: reduceMotion ? 0.2 : 0.5)
        let done = {
            guard turnID == id else { return }
            withTransaction(transaction) {
                beneath = new
                turning = nil
                fold = 1
            }
            target = nil
            onTurn(false)
        }
        if new > old {
            // The page read so far lifts at its right edge and turns over to the left, uncovering the next one. A
            // turn back to `old` that still runs reverses from where its fold is.
            if turning != old || beneath != new {
                withTransaction(transaction) {
                    beneath = new
                    turning = old
                    fold = 1
                }
            }
            withAnimation(curve, { fold = 0 }, completion: done)
        } else {
            // The earlier page turns back from the left and lies down over the later one, or a turn to `old` that
            // still runs goes back.
            if turning != new || beneath != old {
                withTransaction(transaction) {
                    beneath = old
                    turning = new
                    fold = 0
                }
            }
            withAnimation(curve, { fold = 1 }, completion: done)
        }
    }
}

/// A page turning over another, folded along a vertical line: left of the fold the page still lies flat, the part
/// right of it has flipped over to the left and shows its back, and the page beneath shows where it lifted.
private struct PageFold<Front: View, Beneath: View>: View, Animatable {
    var fold: Double
    let width: CGFloat
    let paper: Color
    let dark: Bool
    /// Reduce Motion: the pages cross-fade instead.
    let crossfade: Bool
    let front: Front
    let beneath: Beneath

    var animatableData: Double {
        get { fold }
        set { fold = newValue }
    }

    /// The back of the page, a shade lighter than its front in the dark, and warmer in the light.
    private var back: Color { dark ? Color(white: 0.2) : Color(red: 0.95, green: 0.94, blue: 0.92) }

    var body: some View {
        if crossfade {
            ZStack {
                beneath
                front.background(paper).opacity(fold)
            }
        } else {
            folded
        }
    }

    private var folded: some View {
        let w = width
        let f = CGFloat(fold) * w
        // The flipped part is as wide as what lifted, mirrored over the fold, and cut at the left edge.
        let flapStart = max(0, 2 * f - w)
        let flapWidth = max(0, f - flapStart)
        // Deepest halfway through the turn, when the page stands highest.
        let lift = sin(Double.pi * (1 - fold))
        return ZStack(alignment: .topLeading) {
            beneath
            // The shadow that the lifted page casts on the page beneath, along the fold.
            LinearGradient(colors: [.black.opacity((dark ? 0.45 : 0.22) * lift), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 22 + 34 * lift)
                .offset(x: f)
                .allowsHitTesting(false)
            // The part of the turning page that still lies flat.
            front
                .background(paper)
                .mask(alignment: .leading) { Rectangle().frame(width: flapStart) }
            // A soft shadow where the free edge of the flap hovers over the flat part.
            if flapStart > 0 {
                LinearGradient(colors: [.clear, .black.opacity((dark ? 0.3 : 0.14) * lift)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 16)
                    .offset(x: flapStart - 16)
                    .allowsHitTesting(false)
            }
            // The back of the page: paper with the notes faintly showing through, mirrored, and shaded darker towards
            // the fold, where it curves.
            ZStack(alignment: .topLeading) {
                back
                front
                    .scaleEffect(x: -1, y: 1, anchor: .center)
                    .offset(x: 2 * f - w)
                    .opacity(dark ? 0.09 : 0.07)
                // The paper bends at the fold: a bright band where it faces the light, dark at the crease itself, and a
                // little shade at the free edge.
                LinearGradient(stops: [
                    .init(color: .black.opacity(dark ? 0.18 : 0.07), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.62),
                    .init(color: .white.opacity(dark ? 0.14 : 0.7), location: 0.84),
                    .init(color: .clear, location: 0.93),
                    .init(color: .black.opacity(dark ? 0.4 : 0.2), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: flapWidth)
                    .offset(x: flapStart)
            }
            .frame(width: w, alignment: .leading)
            .mask(alignment: .leading) { Rectangle().frame(width: flapWidth).offset(x: flapStart) }
            .shadow(color: .black.opacity((dark ? 0.5 : 0.22) * lift), radius: 8 * lift, x: -3 * lift)
            // Highest halfway through, the free edge of the page comes towards the viewer.
            .rotation3DEffect(.degrees(24 * lift), axis: (x: 0, y: 1, z: 0), anchor: UnitPoint(x: Double(f / max(w, 1)), y: 0.5),
                              perspective: 0.55)
            // The last sliver of the page lying down at the left edge fades instead of lingering.
            .opacity(min(1, fold * 14))
            .allowsHitTesting(false)
        }
        .frame(width: w, alignment: .leading)
    }
}

private struct NotesFooter: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 14) {
            NotesTime(model: model, palette: palette)
            Spacer(minLength: 0)
            // A narrow window keeps the hints that it has room for.
            ViewThatFits(in: .horizontal) {
                hints([(["space"], "play or pause"), (["R"], "region loop"), (["⇥"], "view"), (["←", "→"], "transpose"), (["esc"], "close")])
                hints([(["space"], "play or pause"), (["R"], "region loop"), (["←", "→"], "transpose")])
                hints([(["R"], "region loop")])
                Color.clear.frame(width: 0)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private func hints(_ list: [([String], String)]) -> some View {
        HStack(spacing: 10) {
            ForEach(list, id: \.1) { keys, name in hint(keys, name) }
        }
        .opacity(0.62)
        .fixedSize()
    }

    private func hint(_ keys: [String], _ name: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0, palette: palette, small: true) } }
            Text(name)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted)
                .fixedSize()
        }
    }
}

/// The time of the song and a bar that a click moves the song along.
private struct NotesTime: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = model.now() ?? 0
            let fraction = model.duration > 0 ? min(1, max(0, now / model.duration)) : 0
            HStack(spacing: 8) {
                Button(action: model.onPlayPause) {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(palette.ink.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(model.playing ? "Pause (space)" : "Play (space)")
                Text(Self.time(now)).foregroundStyle(palette.ink).fixedSize()
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.ink.opacity(0.15))
                        Capsule().fill(palette.ink).frame(width: geometry.size.width * fraction)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { point in model.onSeek(model.duration * Double(point.x / max(1, geometry.size.width))) }
                }
                .frame(width: 150, height: 16)
                Text(Self.time(model.duration)).foregroundStyle(palette.muted).fixedSize()
            }
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .monospacedDigit()
        }
    }

    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Window

/// The notes window, which takes the keyboard like Settings does: Muskey shows in the Dock while it is open.
final class NotesWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var model: NotesModel?
    private var monitor: Any?
    var onClosed: () -> Void = {}
    /// R and ⌥R, which start, end and clear the region loop as over the HUD.
    var onLoopKey: (Bool) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    var isShown: Bool { window?.isVisible == true }

    func show(_ model: NotesModel) {
        self.model = model
        let window = window ?? make()
        // The first click on the page seeks or starts a loop, instead of only bringing the window to the front.
        window.contentView = FirstClickHostingView(rootView: NotesWindowView(model: model))
        window.title = "\(model.title) · \(model.stem.name)"
        RunLoop.main.perform(inModes: [.default]) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.handle(event) else { return event }
                return nil
            }
        }
    }

    func close() { window?.close() }

    private func make() -> NSWindow {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let height = visible.height * 0.92
        let size = CGSize(width: min(visible.width * 0.9, height * 0.72), height: height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 520, height: 420)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("NotesWindow")
        self.window = window
        return window
    }

    /// Turns the page between portrait and landscape by giving the window the other shape on its screen.
    func turnPage() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let portrait = window.frame.width <= window.frame.height
        var size: CGSize
        if portrait {
            size = CGSize(width: visible.width * 0.86, height: min(visible.height * 0.86, visible.width * 0.86 * 0.6))
        } else {
            let height = visible.height * 0.92
            size = CGSize(width: min(visible.width * 0.9, height * 0.72), height: height)
        }
        size = CGSize(width: max(size.width, window.minSize.width), height: max(size.height, window.minSize.height))
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        log("notes: \(portrait ? "landscape" : "portrait") page")
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        if flags.contains(.command) {
            switch (code, flags.contains(.shift)) {
            case (kVK_ANSI_W, false): close()
            case (kVK_ANSI_S, false) where model.done: model.onSave(.musicXML)
            case (kVK_ANSI_C, true) where model.done && model.hasTab: model.onCopyTab()
            case (kVK_ANSI_1, false): model.view = .tab
            case (kVK_ANSI_2, false): model.view = .sheet
            case (kVK_ANSI_3, false): model.view = .roll
            default: return false
            }
            return true
        }
        switch code {
        case kVK_Escape: close()
        case kVK_Space: model.onPlayPause()
        case kVK_ANSI_R: onLoopKey(!flags.contains(.option))
        case kVK_Tab:
            let all = NotesView.allCases
            let index = all.firstIndex(of: model.view) ?? 0
            model.view = all[(index + (flags.contains(.shift) ? all.count - 1 : 1)) % all.count]
        case kVK_LeftArrow: model.onTranspose(-1)
        case kVK_RightArrow: model.onTranspose(1)
        default: return false
        }
        return true
    }

    func windowWillClose(_: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model = nil
        window?.contentView = nil
        // Muskey leaves the Dock once no other window of its own, like Settings, stays open.
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
        }
        onClosed()
    }

    /// Asks where to save the notes, in the format picked, and writes them.
    func save(_ format: NotesFormat, score: Score, title: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(title) \(score.stem.name).\(format.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch format {
                case .musicXML: try score.musicXML(title: title).write(to: url, atomically: true, encoding: .utf8)
                case .midi: try score.midi.write(to: url)
                case .textTab: try score.textTab.write(to: url, atomically: true, encoding: .utf8)
                }
                self?.log("notes: saved \(format.name) to \(url.lastPathComponent)")
            } catch {
                self?.log("notes: saving \(format.name) failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: Cache

/// The notes of each song and stem, kept so that opening them again is instant.
enum NotesStore {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Notes")
    }

    private static func url(path: String, stem: Stem) -> URL? {
        guard let id = StemsCache.url(for: path)?.deletingPathExtension().lastPathComponent else { return nil }
        return folder.appending(path: "\(id)-\(stem.name.lowercased()).json")
    }

    static func load(path: String, stem: Stem) -> NotesFixture? {
        guard let url = url(path: path, stem: stem), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NotesFixture.self, from: data)
    }

    static func save(_ fixture: NotesFixture, path: String, stem: Stem) {
        guard let url = url(path: path, stem: stem) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(fixture).write(to: url, options: .atomic)
    }
}

// MARK: Stem picker

/// T over the HUD: the stems that can be transcribed, in place of the key column.
struct NotesPicking: Equatable {
    var stems: [Stem]
    var selected: Stem
    /// The song plays in Muskey Player, which has the file that the stems are separated from.
    var available: Bool
    var duration: Double?
    /// The bytes of the models that are still missing.
    var missing: Int?
    var downloading: Double?
    var failed = false
}

struct NotesStemPicker: View {
    let picking: NotesPicking
    let palette: Palette
    let select: (Stem) -> Void
    let start: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 10) {
            Text("Transcribe notes")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.ink)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(picking.stems.enumerated()), id: \.element) { index, stem in
                    tile(stem, number: index + 1)
                }
            }
            .opacity(picking.available ? 1 : 0.4)
            .allowsHitTesting(picking.available)
            HStack {
                if picking.available, picking.missing != nil || picking.downloading != nil || picking.failed {
                    // The download button needs the whole row.
                    button.frame(maxWidth: .infinity)
                } else if picking.available {
                    Text(picking.duration.map { "Whole song · \(NotesTime.time($0))" } ?? "Whole song")
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    button
                } else {
                    Text("Only for songs in Muskey Player")
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            KeyHintsRow(hints: picking.available ? [(["1–\(picking.stems.count)"], "stem"), (["↩"], "transcribe"), (["esc"], "close")] : [(["esc"], "close")],
                        palette: palette)
        }
        .frame(width: 330)
    }

    private func tile(_ stem: Stem, number: Int) -> some View {
        let on = stem == picking.selected
        let honey = StripColors.text(.honey, colorScheme)
        return Button { select(stem) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(stem.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
                Text(NotesView.preferred(for: stem).name).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(alignment: .topTrailing) {
                Text("\(number)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(palette.ink.opacity(0.1)))
                    .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? honey.opacity(0.2) : palette.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? honey : palette.ink.opacity(0.12), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    @ViewBuilder private var button: some View {
        let honey = StripColors.solid(.honey, colorScheme).fill
        let red = Color(red: 1, green: 0.42, blue: 0.4)
        Button(action: start) {
            HStack(spacing: 6) {
                if let fraction = picking.downloading {
                    Text("Downloading \(Int((fraction * 100).rounded()))%").monospacedDigit()
                } else if picking.failed {
                    Text("Retry")
                } else if let missing = picking.missing {
                    Text("Download and Transcribe · \(Int((Double(missing) / 1e6).rounded())) MB")
                } else {
                    Text("Transcribe \(picking.selected.name)")
                    // The dark keycap of the light scheme, which reads on honey in both schemes.
                    Keycap(text: "↩", palette: .of(.light), small: true)
                }
            }
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .fixedSize()
            .foregroundStyle(Color(red: 0.18, green: 0.11, blue: 0.02))
            .padding(.leading, 12)
            .padding(.trailing, picking.missing == nil && picking.downloading == nil && !picking.failed ? 6 : 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(picking.failed ? red : honey))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(picking.downloading != nil)
    }
}

/// A row of keys and what they do, like the hints along the bottom of the HUD.
struct KeyHintsRow: View {
    let hints: [([String], String)]
    let palette: Palette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(hints, id: \.1) { keys, name in
                HStack(spacing: 5) {
                    HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0, palette: palette, small: true) } }
                    Text(name).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(palette.muted).fixedSize()
                }
            }
        }
        .opacity(0.62)
    }
}

// MARK: Testing

extension NotesModel {
    /// A window's model with the notes of a fixture that `--notes-headless` wrote, as if they were just transcribed.
    static func fixture(_ path: String) -> NotesModel? {
        guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONDecoder().decode(NotesFixture.self, from: data) else { return nil }
        let model = NotesModel(path: path, title: fixture.title, artist: nil, stem: fixture.stemValue, duration: fixture.duration)
        model.key = fixture.keyValue
        model.setGrid(beats: fixture.beats, bpm: fixture.bpm)
        model.finish(fixture.notes)
        return model
    }
}

/// `--notes-render FIXTURE DIR`: the notes window with the notes of a fixture, in each view on a tall and a wide page,
/// at `--notes-at S` seconds (40 by default), written as PNGs.
@MainActor func renderNotesWindow(fixture path: String, to dir: String) {
    guard let model = NotesModel.fixture(path) else {
        print("notes render: can't read \(path)")
        return
    }
    let at = TestFlags.value("--notes-at").flatMap(Double.init) ?? 40
    model.now = { at }
    notesFoldInRenders = TestFlags.value("--notes-fold").flatMap(Double.init)
    if let shift = TestFlags.value("--notes-shift").flatMap(Int.init) { model.shift = shift }
    if let loop = TestFlags.value("--notes-loop")?.split(separator: "-").compactMap({ Double($0) }), loop.count == 2 {
        model.loop = LoopRegion(start: loop[0], end: loop[1], startPress: nil)
    }
    // `--notes-progress STEP:F` shows the transcription at F of a step (beats, stems or notes), with `--notes-left S`
    // seconds left, and `--notes-failed` shows a failed one.
    if let spec = TestFlags.value("--notes-progress") {
        let parts = spec.split(separator: ":")
        let step = NotesStep.allCases.first { $0.name.lowercased() == parts.first?.lowercased() } ?? .notes
        model.begin(NotesStep.allCases)
        model.phase = .working(step, parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
        if let left = TestFlags.value("--notes-left").flatMap(Double.init) { model.showLeft(left) }
    }
    if TestFlags.has("--notes-failed") {
        model.begin(NotesStep.allCases)
        model.phase = .failed
    }
    for view in NotesView.allCases {
        for (shape, size) in [("tall", CGSize(width: 680, height: 960)), ("wide", CGSize(width: 1180, height: 680))] {
            model.view = view
            let content = NotesWindowView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.renderingPreview, true)
                .environment(\.colorScheme, TestFlags.has("--light") ? .light : .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let name = "notes-\(view.rawValue)-\(shape).png"
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: name))
                print("wrote \(dir)/\(name)")
            }
        }
    }
}
