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
final class NotesModel: ObservableObject {
    enum Phase: Equatable {
        case separating(Double)
        case transcribing(Double)
        case ready
        case failed
    }

    let path: String
    let title: String
    let artist: String?
    let stem: Stem
    let duration: Double

    @Published var phase: Phase
    /// The notes as Dettato heard them, before the transpose.
    @Published private(set) var notes: [TranscribedNote] = []
    /// The time up to which the stem is transcribed: the bars after it are drawn faint.
    @Published private(set) var transcribedUntil: Double = 0
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
        phase = .transcribing(0)
        score = Score(notes: [], stem: stem, beats: [], bpm: 120, key: nil, duration: duration)
    }

    var done: Bool { phase == .ready }
    var hasTab: Bool { stem == .bass || stem == .guitar }

    func setGrid(beats: [Double], bpm: Double) {
        self.beats = beats
        self.bpm = bpm > 0 ? bpm : 120
        rebuild()
    }

    /// Notes found so far, up to `until` seconds.
    func show(_ notes: [TranscribedNote], until: Double) {
        self.notes = notes
        transcribedUntil = until
        rebuild()
    }

    func finish(_ notes: [TranscribedNote]) {
        self.notes = notes
        transcribedUntil = duration + 10
        phase = .ready
        rebuild()
    }

    func restart() {
        notes = []
        transcribedUntil = 0
        phase = .transcribing(0)
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
        let shortest: CGFloat = view == .roll ? 60 : 96
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
        var clefs: [Clef] = []
        if staff.grand {
            clefs = [Clef(bottom: top + gap * 4, step: 30, bass: false), Clef(bottom: top + gap * 8 + NotesStaff.grandGap, step: 18, bass: true)]
        } else {
            clefs = [Clef(bottom: top + gap * 4, step: staff.bassClef ? 18 : 30, bass: staff.bassClef)]
        }
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
    private func chord(_ context: inout GraphicsContext, _ notes: [Score.Note], x: CGFloat, clef: Clef, spelling: Spelling, shown: inout [Int: String], alpha: Double) {
        let gap = NotesStaff.staffGap
        let color = ink.opacity(alpha)
        // Guitar and bass are written an octave above where they sound.
        let lift = score.stem == .guitar || score.stem == .bass ? 12 : 0
        let spelled = notes.map { note -> (step: Int, accidental: String?, length: Double) in
            let (step, accidental) = spelling.spell(note.pitch + lift)
            return (step, accidental, note.length)
        }
        let length = spelled.map(\.length).min() ?? 1
        var ys: [CGFloat] = []
        for note in spelled {
            let y = clef.bottom - CGFloat(note.step - clef.step) * gap / 2
            ys.append(y)
            // Ledger lines under and over the staff.
            if note.step < clef.step - 1 {
                for step in stride(from: clef.step - 2, through: note.step, by: -2) {
                    let ly = clef.bottom - CGFloat(step - clef.step) * gap / 2
                    line(&context, from: CGPoint(x: x - 7, y: ly), to: CGPoint(x: x + 7, y: ly), color: ink.opacity(0.45 * alpha))
                }
            } else if note.step > clef.step + 9 {
                for step in stride(from: clef.step + 10, through: note.step, by: 2) {
                    let ly = clef.bottom - CGFloat(step - clef.step) * gap / 2
                    line(&context, from: CGPoint(x: x - 7, y: ly), to: CGPoint(x: x + 7, y: ly), color: ink.opacity(0.45 * alpha))
                }
            }
            // An accidental once per step in a bar, and a natural for a step that had one.
            var sign = note.accidental
            if sign == nil, shown[note.step] != nil { sign = "♮" }
            if let sign, shown[note.step] != sign {
                shown[note.step] = sign
                context.draw(Text(sign).font(.system(size: 11)).foregroundColor(color), at: CGPoint(x: x - 10, y: y))
            }
            let head = Path(ellipseIn: CGRect(x: -4.2, y: -3.1, width: 8.4, height: 6.2))
                .applying(CGAffineTransform(rotationAngle: -0.35))
                .applying(CGAffineTransform(translationX: x, y: y))
            if length >= 2 { context.stroke(head, with: .color(color), lineWidth: 1.3) } else { context.fill(head, with: .color(color)) }
            if [0.75, 1.5, 3].contains(length) {
                context.fill(Path(ellipseIn: CGRect(x: x + 6, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(color))
            }
        }
        guard length < 4, let low = ys.max(), let high = ys.min() else { return }
        // Notes under the middle line take a stem up on their right, the others a stem down on their left.
        let middle = clef.bottom - gap * 2
        let up = (low + high) / 2 > middle
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
            .frame(maxWidth: .infinity, alignment: .leading)
            NotesViewSwitch(view: $model.view, palette: palette)
            NotesStatus(model: model, palette: palette)
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

/// The key and the tempo once the notes are done, the progress before that, and Retry after a failure.
private struct NotesStatus: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case let .separating(fraction):
                progress("Separating stems", fraction)
            case let .transcribing(fraction):
                progress("Transcribing \(model.stem.name.lowercased())", fraction)
            case .failed:
                pill("Transcription failed", color: Color(red: 1, green: 0.42, blue: 0.4))
                HUDButton(title: "Retry", symbol: "arrow.clockwise", palette: palette, small: true, action: model.onRetry)
            case .ready:
                if model.shift != 0 { pill(Shift.text(model.shift), color: StripColors.text(.honey, colorScheme)) }
                if let key = model.key?.transposed(by: model.shift) { pill(key.name, color: palette.ink) }
                pill("\(Int(model.bpm.rounded())) BPM", color: palette.ink)
            }
        }
    }

    private func progress(_ label: String, _ fraction: Double) -> some View {
        HStack(spacing: 7) {
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(StripColors.text(.honey, colorScheme), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .background(Circle().stroke(palette.ink.opacity(0.18), lineWidth: 2.5))
                .frame(width: 11, height: 11)
            Text("\(label) \(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(palette.ink.opacity(0.08)))
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

/// The page: two halves of lines that stay still, a line that moves through them with the song, and the region loop.
/// A click moves the song there, and a drag across the notes sets the region loop.
private struct NotesPageView: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown = (top: 0, bottom: 0)
    @State private var drag: (from: Double, to: Double)?
    @Environment(\.renderingPreview) private var renderingPreview

    private static let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.094, blue: 0.098) : Color(red: 0.99, green: 0.975, blue: 0.955)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = NotesLayout(score: model.score, view: model.view, size: geometry.size)
            // A render has no timer to turn the pages, so it shows the pages of the moment it renders.
            let pages = renderingPreview ? layout.pagesShown(at: model.now(), in: model.score) : shown
            let painter = NotesPainter(score: model.score, layout: layout, byBar: model.score.notesByBar, ink: palette.ink, paper: paper,
                                       honey: StripColors.text(.honey, colorScheme), until: model.transcribedUntil)
            ZStack(alignment: .topLeading) {
                half(painter, top: true, page: pages.top)
                half(painter, top: false, page: pages.bottom)
                Rectangle()
                    .fill(palette.ink.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .offset(y: layout.middle)
                regions(painter, pages: pages)
                NotesPlayhead(model: model, layout: layout, shown: pages)
            }
            .contentShape(Rectangle())
            .gesture(pointer(layout))
            .onReceive(Self.tick) { _ in turn(layout) }
            .onChange(of: layout) { turn(layout, animated: false) }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(paper))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.ink.opacity(0.06), lineWidth: 1))
    }

    private func half(_ painter: NotesPainter, top: Bool, page: Int) -> some View {
        let layout = painter.layout
        let height = top ? layout.middle : layout.size.height - layout.middle
        return NotesPageTurn(page: page, paper: paper) { page in
            Canvas { context, _ in
                if !top { context.translateBy(x: 0, y: -layout.middle) }
                painter.draw(&context, page: page, rows: layout.rows(top: top))
            }
            .frame(width: layout.size.width, height: max(0, height))
        }
        .frame(width: layout.size.width, height: max(0, height))
        .clipped()
        .offset(y: top ? 0 : layout.middle)
    }

    @ViewBuilder private func regions(_ painter: NotesPainter, pages: (top: Int, bottom: Int)) -> some View {
        let beats = model.score.beats
        let loop: (Double, Double)? = drag.map { (min($0.from, $0.to), max($0.from, $0.to)) }
            ?? model.loop.flatMap { loop in loop.end.map { (Score.position(of: loop.start, in: beats), Score.position(of: $0, in: beats)) } }
        if let (start, end) = loop {
            let honey = StripColors.text(.honey, colorScheme)
            let rects = painter.region(from: start, to: end, page: pages.top, rows: painter.layout.rows(top: true))
                + painter.region(from: start, to: end, page: pages.bottom, rows: painter.layout.rows(top: false))
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 5)
                    .fill(honey.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(honey.opacity(0.55), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
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
        let pages = layout.pagesShown(at: model.now(), in: model.score)
        guard pages != shown else { return }
        if animated { shown = pages } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { shown = pages }
        }
    }
}

/// The honey line, which moves through the lines at the speed of the song and jumps to the next line at the end of
/// each one.
private struct NotesPlayhead: View {
    @ObservedObject var model: NotesModel
    let layout: NotesLayout
    let shown: (top: Int, bottom: Int)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.playing)) { _ in
            Canvas { context, _ in
                guard let time = model.now(), let spot = layout.spot(at: time, in: model.score) else { return }
                let inTop = spot.row < layout.topLines
                guard spot.page == (inTop ? shown.top : shown.bottom) else { return }
                let top = layout.top(ofRow: spot.row) + layout.staff.linesTop - 7
                let rect = CGRect(x: spot.x - 1, y: top, width: 2, height: layout.staff.linesHeight + 14)
                let honey = StripColors.text(.honey, colorScheme)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: honey.opacity(0.7), radius: 4))
                    layer.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(honey))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Half a page that turns like a page of a book when it shows another page: the old page lifts at its right edge and
/// folds away to the left over the new one, or back from the left for an earlier page.
private struct NotesPageTurn<Content: View>: View {
    let page: Int
    let paper: Color
    @ViewBuilder let content: (Int) -> Content
    @State private var under: Int?
    @State private var lifted: Int?
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content(under ?? page)
            if let lifted {
                content(lifted)
                    .background(paper)
                    .overlay(Color.black.opacity(abs(angle) / 90 * 0.25))
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.35)
                    .opacity(reduceMotion ? 1 - abs(angle) / 90 : 1)
            }
        }
        .onChange(of: page) { old, new in turn(from: under ?? old, to: new) }
    }

    private func turn(from old: Int, to new: Int) {
        let forward = new > old
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if forward {
            // The old page lies on top of the new one and folds away.
            withTransaction(transaction) {
                under = new
                lifted = old
                angle = 0
            }
            withAnimation(.easeIn(duration: reduceMotion ? 0.15 : 0.32)) { angle = -90 } completion: {
                if lifted == old { lifted = nil }
            }
        } else {
            // The earlier page comes back from the left over the later one.
            withTransaction(transaction) {
                under = old
                lifted = new
                angle = -90
            }
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.32)) { angle = 0 } completion: {
                guard lifted == new else { return }
                under = new
                lifted = nil
            }
        }
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
        window.contentView = NSHostingView(rootView: NotesWindowView(model: model))
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
            KeyHintsRow(hints: [(["1–\(picking.stems.count)"], "stem"), (["↩"], "transcribe"), (["esc"], "back")], palette: palette)
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
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? honey.opacity(0.2) : palette.ink.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? honey : palette.ink.opacity(0.05), lineWidth: on ? 1.5 : 1))
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
                    Keycap(text: "↩", palette: palette, small: true)
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
    if let shift = TestFlags.value("--notes-shift").flatMap(Int.init) { model.shift = shift }
    if let loop = TestFlags.value("--notes-loop")?.split(separator: "-").compactMap({ Double($0) }), loop.count == 2 {
        model.loop = LoopRegion(start: loop[0], end: loop[1], startPress: nil)
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
