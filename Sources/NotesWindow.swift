import AppKit
import Carbon.HIToolbox
import os
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "NotesWindow")

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
    /// A song from another app plays to its end, so that Muskey hears all of it.
    case capture
    case beats, stems, notes

    var name: String { ["Song", "Beats", "Stems", "Notes"][rawValue] }

    /// The part of the work that the step takes until this Mac has timed it: separating every stem takes longest, and
    /// hearing the rest of a song takes longer still.
    var share: Double { [1, 0.05, 0.55, 0.4][rawValue] }

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
        /// The stem hardly plays in the song, so the transcription waits for Transcribe Anyway or another stem.
        case quiet
        /// The transcription found too few notes to fill a page.
        case empty

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
    /// The capo for the tab, the same one that the chords over the lyrics use.
    @Published var capo = 0 { didSet { if capo != oldValue { rebuild() } } }
    /// The speed that Muskey plays the song at against its own tempo, 1 while the tempo isn't changed.
    @Published var speed = 1.0
    /// The HUD can change the speed of the song, so the tempo in the status bar changes it too.
    @Published var speedAdjustable = false
    @Published var fastestSpeed = 1.5
    /// The HUD names the key in the other mode than the song's, as the key row's second row does.
    @Published var relative = false { didSet { if relative != oldValue { rebuild() } } }
    /// The key picker shows the second row with the other mode, as the HUD's does with "Both modes" in Settings.
    @Published var relativeKeys = false
    /// The page that the song is on, counted from 0, and how many pages the notes take in this view and window size.
    @Published var page = 0
    @Published var pageCount = 1
    /// The time of the first bar of each page, which the page buttons and the arrows move the song to.
    var pageStarts: [Double] = []
    /// A page that the buttons asked for, which the page number keeps showing while the player catches up with the seek.
    var pageAsked: (page: Int, at: Date)?
    /// The other stems that play in the song, the most present first, offered when this one hardly plays.
    @Published var otherStems: [Stem] = []
    /// Transcribe Anyway was pressed, so the transcription runs even though the stem hardly plays.
    var forced = false
    /// The song from another app that the window's notes belong to, or nil for a song of Muskey Player.
    var song: [String?]?

    /// Moves the song to the first bar of a page, which turns the pages to it.
    func goToPage(_ target: Int) {
        guard done, pageStarts.indices.contains(target), target != page else { return }
        page = target
        pageAsked = (target, Date())
        onSeek(pageStarts[target])
    }
    @Published var view: NotesView
    @Published var loop: LoopRegion?
    @Published var playing = false
    /// The time that a paused song is at, which a seek changes.
    @Published var pausedAt = 0.0
    @Published var artwork: NSImage?
    /// The score as the window shows it, with a bar of rest for each run of bars without notes.
    @Published private(set) var score: Score
    /// Every bar of the song, for saving and copying the notes.
    private(set) var fullScore: Score

    /// The time in the song now, or nil while the song isn't the one in the window.
    var now: () -> Double? = { nil }
    var onSeek: (Double) -> Void = { _ in }
    var onLoop: (Double, Double) -> Void = { _, _ in }
    var onPlayPause: () -> Void = {}
    var onTranspose: (Int) -> Void = { _ in }
    var onCapo: (Int) -> Void = { _ in }
    /// A key picked in the status bar: the shift, and whether the key is in the other mode than the song.
    var onPickKey: (Int, Bool) -> Void = { _, _ in }
    /// The tempo's arrows and the keys [ and ]: a step slower or faster, and 0 for the song's own tempo.
    var onSpeedStep: (Int) -> Void = { _ in }
    /// A scroll over the tempo: the speed to play at.
    var onSpeed: (Double) -> Void = { _ in }
    var onRetry: () -> Void = {}
    var onStopHere: () -> Void = {}
    var onTranscribeAnyway: () -> Void = {}
    var onPickStem: (Stem) -> Void = { _ in }
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
        let empty = Score(notes: [], stem: stem, beats: [], bpm: 120, key: nil, duration: duration)
        score = empty
        fullScore = empty
    }

    // MARK: Progress

    private var stepStarted = Date()
    /// Where the step that runs was when it started: a separation that was already running starts further on.
    private var stepFrom: Double?
    /// The furthest the bar went, which it never goes back from.
    private var reached = 0.0
    /// The seconds left at the last estimate, and when it was made. The time left counts down between estimates.
    private var left: (seconds: Double, at: Date)?

    /// The seconds of song that the capture step waits to hear, which is its length.
    var captureSeconds = 0.0

    /// The seconds that a step takes, when this Mac timed it. The capture takes as long as the song has left to play.
    private func seconds(_ step: NotesStep) -> Double? {
        step == .capture ? captureSeconds : NotesTiming.rate(step).map { $0 * max(step == .notes ? transcribing : duration, 1) }
    }

    /// Every step was timed on this Mac.
    private var timed: Bool { steps.allSatisfy { seconds($0) != nil } }

    /// The weight of each step in the bar: the seconds it takes on this Mac when every step was timed, or its share.
    private var weights: [Double] {
        timed ? steps.map { seconds($0)! } : steps.map(\.share)
    }

    private func rawProgress(at date: Date) -> Double {
        switch phase {
        case .ready, .empty: return 1
        case .failed, .quiet: return reached
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
        } else if timed {
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

    /// The capture is done and the steps after it start, which keeps the capture in the steps row, ticked.
    func carryOn(_ rest: [NotesStep]) {
        steps = [.capture] + (rest.isEmpty ? [.notes] : rest)
        phase = .working(steps[1], 0)
    }

    var done: Bool { phase == .ready }
    var hasTab: Bool { stem == .bass || stem == .guitar }

    func setGrid(beats: [Double], bpm: Double) {
        self.beats = beats
        self.bpm = bpm > 0 ? bpm : 120
        rebuild()
    }

    /// Where a transcription that Stop Here ended stopped, in seconds of the song. The bars after it stay faint.
    var transcribedUntil: Double?

    /// The region loop that T transcribed in place of the whole song.
    var region: ClosedRange<Double>?

    /// The part of the song that was transcribed, when it isn't the whole song: the region loop, up to the place where
    /// Stop Here ended the transcription. The bars outside it stay faint.
    var transcribed: ClosedRange<Double>? {
        guard region != nil || transcribedUntil != nil else { return nil }
        let start = region?.lowerBound ?? 0
        return start ... max(start, min(region?.upperBound ?? .infinity, transcribedUntil ?? .infinity))
    }

    /// The seconds of the song that the notes step transcribes: the region loop with the context around it, or the
    /// whole song.
    var transcribing: Double {
        region.map { min(duration > 0 ? duration : .infinity, $0.upperBound + NotesPipeline.regionContext) - max(0, $0.lowerBound - NotesPipeline.regionContext) }
            ?? duration
    }

    /// The fewest notes that are worth showing. With fewer, the window says that there are no notes to transcribe. After
    /// Transcribe Anyway, any note shows: runs of bars without notes are one bar of rest each, so a few notes never fill
    /// pages of empty bars. A region loop can be a few notes long.
    var fewest: Int { forced || region != nil ? 1 : 4 }

    func finish(_ notes: [TranscribedNote]) {
        self.notes = notes
        phase = notes.count < fewest ? .empty : .ready
        rebuild()
    }

    /// The score of the notes moved by the pitch change, in the key that the song plays in after it.
    private func rebuild() {
        let moved = shift == 0 ? notes : notes.map { TranscribedNote(start: $0.start, end: $0.end, pitch: $0.pitch + shift, program: $0.program, drum: $0.drum) }
        // The key in the mode that the HUD names it: the signature is the same, and a minor key writes its leading tone
        // on the letter under the tonic.
        let shown = key.map { relative ? $0.transposed(by: shift).relative : $0.transposed(by: shift) }
        fullScore = Score(notes: moved, stem: stem, beats: beats, bpm: bpm, key: shown, duration: duration, capo: hasTab ? capo : 0)
        // Until the notes are done, the faint page under the progress shows every bar.
        score = notes.isEmpty ? fullScore : fullScore.collapsingRests()
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

    /// The page, the line on it, the bar on the line and the x of the moment `time`.
    func spot(at time: Double, in score: Score) -> (page: Int, row: Int, slot: Int, x: CGFloat)? {
        guard let place = score.place(at: time) else { return nil }
        let line = place.bar / barsPerLine, slot = place.bar % barsPerLine
        return (line / linesPerPage, line % linesPerPage, slot, x(atBeats: (Double(slot) + place.fraction) * Double(Score.beatsPerBar)))
    }

    /// The margin that the notes keep after the bar line at the start of a bar: tab and sheet music draw their notes
    /// inside it, and the piano roll from the bar line.
    var notePad: CGFloat { staff.view == .tab ? 10 : staff.view == .sheet ? 14 : 0 }

    /// The x of a place `beats` from the start of a line, where its notes are drawn, so that the line touches each note
    /// as it starts. In the last sixteenth of a bar, the place crosses the margins at the bar line to the first place
    /// of the next bar, so that the line never jumps.
    func x(atBeats beats: Double) -> CGFloat {
        let perBar = Double(Score.beatsPerBar), last = perBar - 0.25
        let slot = min(barsPerLine - 1, max(0, Int((beats / perBar).rounded(.down))))
        let beat = min(perBar, max(0, beats - Double(slot) * perBar))
        let start = x0 + CGFloat(slot) * barWidth, pad = notePad, content = barWidth - pad * 1.6
        if beat <= last { return start + pad + CGFloat(beat / perBar) * content }
        let lastX = start + pad + CGFloat(last / perBar) * content
        let next = slot == barsPerLine - 1 ? start + barWidth : start + barWidth + pad
        return lastX + (next - lastX) * CGFloat((beat - last) / 0.25)
    }

    /// The place in beats from the start of a line at `x`, the opposite of `x(atBeats:)`. The margin before the first
    /// note of a line belongs to its start.
    func beats(atX x: CGFloat) -> Double {
        let perBar = Double(Score.beatsPerBar), last = perBar - 0.25
        let pad = notePad, content = max(1, barWidth - pad * 1.6)
        var slot = Int(((x - x0) / barWidth).rounded(.down))
        // The margin after a bar line is the end of the bar before it, which the line crosses in its last sixteenth.
        if slot > 0, slot < barsPerLine, x < x0 + CGFloat(slot) * barWidth + pad { slot -= 1 }
        slot = min(barsPerLine - 1, max(0, slot))
        let start = x0 + CGFloat(slot) * barWidth
        let lastX = start + pad + CGFloat(last / perBar) * content
        let beat: Double
        if x <= lastX {
            beat = max(0, Double((x - start - pad) / content) * perBar)
        } else {
            let next = slot == barsPerLine - 1 ? start + barWidth : start + barWidth + pad
            beat = last + min(1, Double((x - lastX) / max(1, next - lastX))) * 0.25
        }
        return Double(slot) * perBar + min(perBar - 0.001, beat)
    }

    /// The row of the half that a point is over.
    func row(at point: CGPoint, top: Bool) -> Int {
        let range = rows(top: top)
        return min(range.upperBound - 1, max(range.lowerBound, Int(((point.y - Self.margin) / staff.height).rounded(.down))))
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
        let line = page * linesPerPage + row(at: point, top: top)
        return min(Double(bars * Score.beatsPerBar), Double(line * barsPerLine * Score.beatsPerBar) + beats(atX: point.x))
    }
}

// MARK: Drawing

/// The accent of the notes window: a deep, saturated amber on the dark page, and a red with a tinge of magenta on
/// paper. The honey of the HUD looked washed out on the dark page and muddy on paper.
enum NotesAccent {
    static func color(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .oklch(0.76, 0.18, 62) : .oklch(0.58, 0.24, 16)
    }

    /// The glow around a lit note.
    static func glow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .oklch(0.78, 0.19, 60) : .oklch(0.7, 0.2, 16)
    }

    /// The colour that a lit note turns towards at its brightest: a bright gold on the dark page and a vivid red on
    /// paper, never a paler colour.
    static func hot(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .oklch(0.86, 0.18, 76) : .oklch(0.6, 0.26, 20)
    }
}

/// Draws the lines of a page: tab, a staff or a piano roll.
struct NotesPainter {
    let score: Score
    let layout: NotesLayout
    let byBar: [[Score.Note]]
    let ink: Color
    let paper: Color
    let accent: Color
    /// The bars that start after this time aren't transcribed yet.
    let until: Double
    /// The bars that end before this time weren't transcribed, since only a region loop was.
    var from = 0.0

    private var staff: NotesStaff { layout.staff }

    func draw(_ context: inout GraphicsContext, page: Int, rows: Range<Int>) {
        for row in rows {
            let line = page * layout.linesPerPage + row
            let first = line * layout.barsPerLine
            guard first < score.bars.count else { break }
            let bars = first ..< min(score.bars.count, first + layout.barsPerLine)
            let top = layout.top(ofRow: row)
            rests(&context, bars: bars, top: top + staff.linesTop)
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

    private func faint(_ bar: Int) -> Bool { score.bars[bar].start > until || score.bars[bar].end <= from }

    /// A bar that stands for a run of bars without notes: the thick bar of a multi-bar rest across the middle of the
    /// lines, with short ends, and the number of bars over it.
    private func rests(_ context: inout GraphicsContext, bars: Range<Int>, top: CGFloat) {
        let middle = top + staff.linesHeight / 2
        for bar in bars {
            guard let count = score.rests[bar] else { continue }
            let inset = min(24, layout.barWidth * 0.18)
            let left = barX(bar, bars.lowerBound) + inset, right = barX(bar + 1, bars.lowerBound) - inset
            guard right > left + 8 else { continue }
            let alpha = faint(bar) ? 0.25 : 1.0
            context.fill(Path(CGRect(x: left, y: middle - 2.5, width: right - left, height: 5)), with: .color(ink.opacity(0.7 * alpha)))
            for x in [left, right] {
                context.fill(Path(CGRect(x: x - 0.75, y: middle - 7, width: 1.5, height: 14)), with: .color(ink.opacity(0.7 * alpha)))
            }
            context.draw(text("\(count)", size: 11, weight: .heavy, color: ink.opacity(0.75 * alpha)), at: CGPoint(x: (left + right) / 2, y: middle - 15))
        }
    }

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
            context.draw(text("\(score.number(of: bar))", size: 7.5, color: ink.opacity(0.45)), at: CGPoint(x: x + 2, y: top - 9), anchor: .leading)
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
            // An accidental once per step in a bar. A note in the key, on a step that had another sign in the bar,
            // takes the key's sign again: the flat or the sharp of the signature, or a natural.
            var sign = note.accidental
            if sign == nil, shown[note.step] != nil { sign = spelling.keySign(step: note.step) }
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
                             with: .color(accent.opacity(alpha)))
            }
        }
    }

    // MARK: Note names

    /// A note under the pointer: where it is drawn, its name in the key, and in sheet music the string and the fret
    /// that the tab gives it.
    struct NamedNote: Equatable {
        let center: CGPoint
        let name: String
        var fret: String?
    }

    /// The note drawn nearest to a point of a line, if the point is on it: on its head, its fret number or its bar in
    /// the piano roll.
    func note(near point: CGPoint, page: Int, row: Int) -> NamedNote? {
        let line = page * layout.linesPerPage + row
        let first = line * layout.barsPerLine
        guard first < score.bars.count else { return nil }
        let lineTop = layout.top(ofRow: row)
        let top = lineTop + staff.linesTop
        let spelling = Spelling(key: score.key)
        let clefs = staff.view == .sheet ? clefs(top: top) : []
        let lift = score.stem == .guitar || score.stem == .bass ? 12 : 0
        var best: (distance: CGFloat, note: NamedNote)?
        for bar in first ..< min(score.bars.count, first + layout.barsPerLine) where !faint(bar) {
            for note in byBar[bar] where !note.drum {
                let center: CGPoint
                let reach: CGSize
                switch staff.view {
                case .tab:
                    guard let string = note.string else { continue }
                    center = CGPoint(x: noteX(bar, first, beat: note.beat), y: top + NotesStaff.tabGap * CGFloat(staff.strings - 1 - string))
                    reach = CGSize(width: 7, height: 5.5)
                case .sheet:
                    let clef = clefs.count == 1 || note.pitch >= 60 ? clefs[0] : clefs[1]
                    let step = spelling.spell(note.pitch + lift).step
                    center = CGPoint(x: noteX(bar, first, beat: note.beat, pad: 14), y: clef.bottom - CGFloat(step - clef.step) * NotesStaff.staffGap / 2)
                    reach = CGSize(width: 6, height: 3.5)
                case .roll:
                    let pitch = min(staff.high, max(staff.low, note.pitch))
                    let x = barX(bar, first) + layout.barWidth * CGFloat(note.beat / Double(Score.beatsPerBar))
                    let width = max(3, layout.barWidth * CGFloat(note.length / Double(Score.beatsPerBar)) - 1.5)
                    // The bar of a note is a target along its whole length, and its name shows over the pointer.
                    guard point.x >= x - 1, point.x <= x + width + 1 else { continue }
                    center = CGPoint(x: point.x, y: top + (CGFloat(staff.high - pitch) + 0.5) * NotesStaff.rowHeight)
                    reach = CGSize(width: 1, height: NotesStaff.rowHeight / 2 + 1)
                }
                let dx = abs(center.x - point.x), dy = abs(center.y - point.y)
                guard dx <= reach.width, dy <= reach.height else { continue }
                let distance = hypot(dx, dy)
                guard distance < best?.distance ?? .infinity else { continue }
                var named = NamedNote(center: center, name: spelling.name(note.pitch))
                if staff.view == .sheet, let string = note.string, let fret = note.fret {
                    named.fret = "string \(staff.strings - string) · fret \(fret)"
                }
                best = (distance, named)
            }
        }
        return best?.note
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

    /// A note lights from ink to the accent, and then towards the hot colour when it's brightest, less so on paper. A note
    /// of the piano roll is in the accent already, so it goes towards the hot colour all the way.
    private func light(_ level: Double, colors: LightColors, base: Color) -> Light? {
        guard level > 0.01 else { return nil }
        let hot = min(1, level)
        // A note reaches the full accent at half its brightness, so that the afterglow stays in colour instead of
        // passing through a pale mix with the ink for most of its fade.
        let tint = base == accent ? accent.mix(with: colors.hot, by: hot * (colors.dark ? 0.75 : 0.5))
            : hot < 0.5 ? base.mix(with: accent, by: hot / 0.5)
            : accent.mix(with: colors.hot, by: (hot - 0.5) / 0.5 * (colors.dark ? 0.6 : 0.35))
        return Light(tint: tint, glow: colors.glow, level: level, dark: colors.dark)
    }

    /// The light around a lit note, which adds to the dark page and tints the light one.
    private func halo(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, light: Light) {
        let alpha = (light.dark ? 0.34 : 0.3) * min(1.35, light.level)
        var glow = context
        if light.dark { glow.blendMode = .plusLighter }
        // A bright core and a soft falloff, drawn as one gradient, which is cheaper to draw on every frame than a blur.
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
                        guard let light = light(level(onset), colors: colors, base: accent) else { continue }
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

    /// The x of an edge of a region at `position` beats on `line`: on the bar line at the start of a bar, and elsewhere
    /// between the notes at that position and the sixteenth before them, so that the edge never crosses a fret number or
    /// a note head. Notes of the piano roll start where their place is, so the edge sits there.
    private func edgeX(_ position: Double, line: Int) -> CGFloat {
        let first = line * layout.barsPerLine
        let inLine = position - Double(first * Score.beatsPerBar)
        let bar = Int((inLine / Double(Score.beatsPerBar) + 0.0001).rounded(.down))
        let beat = max(0, inLine - Double(bar * Score.beatsPerBar))
        let start = barX(first + bar, first)
        guard beat > 0.001 else { return start }
        // A place between the sixteenths, like the end of a drag that is still going, has its edge right there.
        guard abs(beat * 4 - (beat * 4).rounded()) < 0.01 else { return layout.x(atBeats: inLine) }
        switch staff.view {
        case .roll:
            return start + layout.barWidth * CGFloat(beat / Double(Score.beatsPerBar))
        case .tab, .sheet:
            let pad: CGFloat = staff.view == .tab ? 10 : 14
            let sixteenth = (layout.barWidth - pad * 1.6) / CGFloat(Score.beatsPerBar * 4)
            return noteX(first + bar, first, beat: beat, pad: pad) - max(sixteenth / 2, staff.view == .tab ? 7 : 8)
        }
    }

    /// The rectangles of a region from `start` to `end` in beats on the lines of a page half.
    func region(from start: Double, to end: Double, page: Int, rows: Range<Int>) -> [CGRect] {
        var rects: [CGRect] = []
        let perLine = Double(layout.barsPerLine * Score.beatsPerBar)
        for row in rows {
            let line = page * layout.linesPerPage + row
            let lineStart = Double(line) * perLine, lineEnd = lineStart + perLine
            let from = max(start, lineStart), to = min(end, lineEnd)
            guard to > from else { continue }
            let top = layout.top(ofRow: row) + staff.linesTop - 8
            let left = edgeX(from, line: line), right = edgeX(to, line: line)
            rects.append(CGRect(x: left, y: top, width: max(0, right - left), height: staff.linesHeight + 16))
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
            // The state of the song sits in the status bar at the bottom, so the top bar only holds what changes the page.
            NotesViewSwitch(view: $model.view, palette: palette)
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

/// The capo of the tab, with round buttons that move it a fret down or up, sized for the status bar.
private struct NotesCapo: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 4) {
            step("minus", by: -1).disabled(model.capo == 0)
            Text(model.capo == 0 ? "No capo" : "Capo \(model.capo)")
                .monospacedDigit()
                .foregroundStyle(model.capo == 0 ? palette.muted : palette.ink.opacity(0.8))
                .contentTransition(.numericText(value: Double(model.capo)))
                .fixedSize()
            step("plus", by: 1).disabled(model.capo >= 11)
        }
        .help("Capo (⌥↑ ⌥↓)")
        .animation(.snappy(duration: 0.2), value: model.capo)
    }

    private func step(_ symbol: String, by amount: Int) -> some View {
        Button { model.onCapo(amount) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(palette.ink)
                .frame(width: 16, height: 16)
                .background(Circle().fill(palette.ink.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
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

/// `--notes-hover key,tempo` renders the key or the tempo of the status bar as the pointer over it shows them.
private let notesHoverInRenders = TestFlags.value("--notes-hover") ?? ""

/// The ‹ and › of a control in the status bar, which show while the pointer is over it, in the room that the control
/// keeps for them on each side, so nothing moves when they appear.
private struct StatusArrow: View {
    let symbol: String
    let help: String
    let shown: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(palette.ink.opacity(0.7))
                .frame(width: 13, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
    }
}

/// The key in the status bar. The pointer over it shows the relative key in a pill above it and the arrows that move
/// the key a semitone, and a click opens the HUD's key row to pick another key. An Option-click names the key in the
/// other mode, with the same notes. Every change goes through the HUD's pitch change, so the HUD and the window show
/// the same key.
private struct NotesKeyControl: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @State private var hovering = notesHoverInRenders.contains("key")
    @State private var picking = false
    /// Option is held: the pill above names the relative key that a click switches to, and the key row shows the
    /// other mode, as over the HUD.
    @State private var option = notesHoverInRenders.contains("option")
    @State private var optionTimer: Timer?
    @Environment(\.colorScheme) private var colorScheme

    /// The key that the song plays in now, named in the mode that the HUD names it.
    private var shown: DetectedKey? {
        model.key.map { key in
            let moved = key.transposed(by: model.shift)
            return model.relative ? moved.relative : moved
        }
    }

    var body: some View {
        let active = hovering || picking
        HStack(spacing: 5) {
            if let shown { Text(shown.name) }
            if model.shift != 0 { Text(Shift.short(model.shift)).foregroundStyle(NotesAccent.color(colorScheme)) }
        }
        .padding(.horizontal, 15)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.ink.opacity(active ? 0.07 : 0)).padding(.vertical, 4).padding(.horizontal, 1))
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.key != nil else { return }
            if NSEvent.modifierFlags.contains(.option) {
                model.onPickKey(model.shift, !model.relative)
            } else {
                picking = true
            }
        }
        // Before the arrows, which have tooltips of their own: a tooltip around them would cover theirs.
        .help(model.key == nil ? "" : "Pick a key (⌥-click for the relative key)")
        .overlay(alignment: .leading) {
            StatusArrow(symbol: "chevron.left", help: "Semitone down (↓)", shown: active, palette: palette) { model.onTranspose(-1) }
                .disabled(model.shift <= Shift.range.lowerBound)
                .padding(.leading, 2)
        }
        .overlay(alignment: .trailing) {
            StatusArrow(symbol: "chevron.right", help: "Semitone up (↑)", shown: active, palette: palette) { model.onTranspose(1) }
                .disabled(model.shift >= Shift.range.upperBound)
                .padding(.trailing, 2)
        }
        .overlay(alignment: .top) {
            // The relative key, the same notes in the other mode, as the HUD shows it beside the key. With Option held,
            // a click switches to it, as the ⌥ in the pill says.
            if let relative = shown?.relative, hovering, !picking {
                HStack(spacing: 5) {
                    Text(relative.name)
                        .foregroundStyle(option ? palette.ink : palette.muted)
                    if option {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(palette.ink)
                    } else {
                        Keycap(text: "⌥", palette: palette, small: true)
                    }
                }
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .padding(.leading, 8)
                .padding(.trailing, option ? 8 : 4)
                .frame(height: 20)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.ink.opacity(option ? 0.25 : 0.1), lineWidth: 0.5))
                .fixedSize()
                .offset(y: -22)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: option)
        .onChange(of: hovering || picking) { _, watching in watchOption(watching) }
        .onDisappear { watchOption(false) }
        .popover(isPresented: $picking, arrowEdge: .top) {
            if let key = model.key {
                VStack(spacing: 8) {
                    // The chips show the mode of the key that the song is in now, and the other mode while Option is
                    // held, as over the HUD.
                    KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys,
                              flipped: option != model.relative, palette: palette, stepKeys: ("↓", "↑")) { shift, relative in
                        model.onPickKey(shift, relative)
                    }
                    // The one row has no other way to the other mode, and two rows still flip with Option.
                    if let shown {
                        HStack(spacing: 5) {
                            Keycap(text: "⌥", palette: palette, small: true)
                            Text("\(shown.minor ? "major" : "minor") keys")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(palette.muted)
                        }
                        .opacity(0.8)
                    }
                }
                .padding(12)
            }
        }
    }

    /// Option is read 30 times a second while the pointer is over the key or the key row shows, as over the HUD:
    /// Muskey gets no modifier changes while another app is in front, which it is until the first click.
    private func watchOption(_ watching: Bool) {
        optionTimer?.invalidate()
        optionTimer = nil
        guard watching, notesHoverInRenders.isEmpty else { return option = false }
        func held() -> Bool {
            let flags = NSEvent.modifierFlags
            return flags.contains(.option) && !flags.contains(.command)
        }
        option = held()
        optionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            let now = held()
            if option != now { option = now }
        }
    }
}

/// The tempo in the status bar, at the speed that the song plays, with the change of speed. While the HUD can change
/// the speed, the pointer over it shows the arrows that make it a step slower or faster, and a scroll over it moves the
/// speed by 1 % every 6 points, as over the HUD's tempo. Otherwise it is plain text.
private struct NotesTempoControl: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @State private var hovering = notesHoverInRenders.contains("tempo")
    /// The speed when the scroll began, and how far the fingers moved since, up being faster.
    @State private var scroll: (start: Double, travel: CGFloat)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.renderingPreview) private var renderingPreview

    /// The change of speed in whole percent, like the HUD's speed pill: −10% for a song slowed to 90 %.
    private var speedChange: String? {
        let percent = Int(((model.speed - 1) * 100).rounded())
        return percent == 0 ? nil : "\(percent < 0 ? "−" : "+")\(abs(percent))%"
    }

    var body: some View {
        let live = model.speedAdjustable
        let active = live && hovering
        HStack(spacing: 5) {
            Text("\(Int((model.bpm * model.speed).rounded())) BPM")
            if let change = speedChange {
                Text(change).foregroundStyle(StripColors.text(model.speed < 1 ? StripColors.down : StripColors.up, colorScheme))
            }
        }
        .padding(.horizontal, 15)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.ink.opacity(active ? 0.07 : 0)).padding(.vertical, 4).padding(.horizontal, 1))
        .overlay {
            // A render draws an AppKit view as a placeholder, and the catcher draws nothing anyway.
            if live, !renderingPreview { ScrollCatcher(onScroll: scrolled) }
        }
        // Before the arrows, which have tooltips of their own: a tooltip around them would cover theirs.
        .help(live ? "Slower or faster (scroll, [ ])" : "")
        .overlay(alignment: .leading) {
            if live {
                StatusArrow(symbol: "chevron.left", help: "Slower ([)", shown: active, palette: palette) { model.onSpeedStep(-1) }
                    .disabled(model.speed <= 0.5)
                    .padding(.leading, 2)
            }
        }
        .overlay(alignment: .trailing) {
            if live {
                StatusArrow(symbol: "chevron.right", help: "Faster (])", shown: active, palette: palette) { model.onSpeedStep(1) }
                    .disabled(model.speed >= model.fastestSpeed)
                    .padding(.trailing, 2)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }

    /// A trackpad moves the speed with the travel of the fingers, and a mouse wheel a step at each notch. The momentum
    /// after the fingers lift changes nothing.
    private func scrolled(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        guard event.hasPreciseScrollingDeltas else {
            if event.scrollingDeltaY != 0 { model.onSpeedStep(sign * event.scrollingDeltaY > 0 ? 1 : -1) }
            return
        }
        if event.phase == .began || scroll == nil { scroll = (model.speed, 0) }
        guard var current = scroll else { return }
        current.travel += sign * event.scrollingDeltaY
        scroll = current
        let speed = min(max(((current.start + Double(current.travel) / 600) * 100).rounded() / 100, 0.5), model.fastestSpeed)
        if speed != model.speed { model.onSpeed(speed) }
        if event.phase == .ended || event.phase == .cancelled { scroll = nil }
    }
}

/// Takes the scrolls over a view and lets every other event through to the views under it, so the arrows and the hover
/// still work.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (NSEvent) -> Void

    func makeNSView(context _: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context _: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: (NSEvent) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) { onScroll(event) }
    }
}

/// The bar along the bottom of the window: the keys on the left, and on the right the state of the song once the notes
/// are done, between hairlines. The key carries the pitch change beside it and the tempo carries the change of speed,
/// so neither takes a place of its own. The key and the tempo are controls (`NotesKeyControl`, `NotesTempoControl`).
private struct NotesStatusBar: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            // A narrow window keeps the hints that it has room for, and the state of the song always.
            ViewThatFits(in: .horizontal) {
                if model.view == .tab, model.hasTab {
                    hints([(["space"], "play or pause"), (["R"], "region loop"), (["⇧", "R"], "loop song"), (["⇥"], "view"), (["←", "→"], "page"), (["↑", "↓"], "transpose"), (["⌥", "↑", "↓"], "capo"), (["esc"], "close")])
                }
                hints([(["space"], "play or pause"), (["R"], "region loop"), (["⇧", "R"], "loop song"), (["⇥"], "view"), (["←", "→"], "page"), (["↑", "↓"], "transpose"), (["esc"], "close")])
                hints([(["space"], "play or pause"), (["R"], "region loop"), (["⇥"], "view"), (["←", "→"], "page"), (["↑", "↓"], "transpose"), (["esc"], "close")])
                hints([(["space"], "play or pause"), (["R"], "region loop"), (["←", "→"], "page"), (["↑", "↓"], "transpose")])
                hints([(["space"], "play or pause"), (["R"], "region loop"), (["↑", "↓"], "transpose")])
                hints([(["R"], "region loop")])
                Color.clear.frame(width: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.done {
                HStack(spacing: 0) {
                    if model.key != nil || model.shift != 0 {
                        item(padded: false) { NotesKeyControl(model: model, palette: palette) }
                    }
                    item(padded: false) { NotesTempoControl(model: model, palette: palette) }
                    if model.view == .tab, model.hasTab { item { NotesCapo(model: model, palette: palette) } }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26).fill(palette.ink.opacity(0.03)))
        .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1) }
    }

    /// `padded` false for a control that keeps the room for its arrows in its own padding.
    private func item(padded: Bool = true, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(palette.ink.opacity(0.8))
            .padding(.horizontal, padded ? 12 : 0)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { Rectangle().fill(palette.ink.opacity(0.08)).frame(width: 1) }
    }

    private func hints(_ list: [([String], String)]) -> some View {
        HStack(spacing: 12) {
            ForEach(list, id: \.1) { keys, name in
                HStack(spacing: 5) {
                    HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0, palette: palette, small: true) } }
                    Text(name)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .fixedSize()
                }
            }
        }
        .opacity(0.6)
        .fixedSize()
    }
}

/// The transcription in the middle of the blank page until the notes are done: the steps that it runs, the step that
/// runs now, one bar from start to finish and the time left. A failure shows here too, with Retry.
private struct NotesProgressCard: View {
    @ObservedObject var model: NotesModel
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme

    private var honey: Color { NotesAccent.color(colorScheme) }

    var body: some View {
        VStack(spacing: 14) {
            if model.phase == .quiet || model.phase == .empty {
                choice
            } else if model.phase == .failed {
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
                HStack(spacing: 8) {
                    // Once the notes are being found, Stop Here shows the ones found so far.
                    if case let .working(.notes, fraction) = model.phase, fraction > 0 {
                        HUDButton(title: "Stop Here", symbol: "stop.fill", palette: palette, small: true, action: model.onStopHere)
                            .help("Stop transcribing and show the notes found so far")
                    }
                    // Cancel closes the window, which stops the transcription and a separation that only it needed.
                    HUDButton(title: "Cancel", symbol: "xmark", palette: palette, isOn: true, small: true, action: model.onClose)
                        .help("Stop transcribing and close the window")
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

    /// A stem that hardly plays: Transcribe Anyway while the transcription waits, and the other stems that play.
    private var choice: some View {
        VStack(spacing: 14) {
            Text(choiceTitle)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.phase == .quiet { anyway }
            if !model.otherStems.isEmpty {
                FlowRow(spacing: 6, centred: true) {
                    ForEach(model.otherStems, id: \.self) { stem in
                        HUDButton(title: LocalizedStringKey(stem.name), symbol: stem.symbol, palette: palette, small: true) { model.onPickStem(stem) }
                            .help("Transcribe the \(stem.name.lowercased())")
                    }
                }
            }
        }
    }

    private var choiceTitle: String {
        model.phase == .empty ? "No notes to transcribe" : "\(model.stem.name) stem mostly silent"
    }

    /// Transcribe Anyway in the accent colour, with the key that presses it.
    private var anyway: some View {
        let dark = colorScheme == .dark
        return Button(action: model.onTranscribeAnyway) {
            HStack(spacing: 6) {
                Text("Transcribe Anyway")
                Keycap(text: "↩", palette: .of(dark ? .light : .dark), small: true)
            }
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .fixedSize()
            .foregroundStyle(dark ? Color(red: 0.18, green: 0.11, blue: 0.02) : .white)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Capsule().fill(honey))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var title: String {
        switch model.phase.step ?? .notes {
        case .capture: "Capturing the song"
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
    /// The pages that a click or a drag on them left in place, which stay while the song plays on what they show.
    @State private var pinned: (top: Int, bottom: Int)?
    @Environment(\.renderingPreview) private var renderingPreview

    private static let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    /// While the song is paused, a seek is the only thing that can change the pages, so they are checked once a second.
    private static let slowTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                                       accent: NotesAccent.color(colorScheme), until: model.done ? model.transcribed?.upperBound ?? .infinity : -1,
                                       from: model.done ? model.transcribed?.lowerBound ?? 0 : 0)
            ZStack(alignment: .topLeading) {
                Group {
                    half(painter, top: true, page: pages.top)
                    half(painter, top: false, page: pages.bottom)
                }
                .opacity(model.done ? 1 : model.phase == .empty ? 0 : 0.3)
                Rectangle()
                    .fill(palette.ink.opacity(model.phase == .empty ? 0 : 0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .offset(y: layout.middle)
                if model.done {
                    NotesPlayhead(model: model, painter: painter, shown: pages, turning: turning)
                }
                // While the top half already shows the next page, each half says which page it is.
                if model.done, pages.top != pages.bottom {
                    pageLabel(pages.top).offset(y: 4)
                    pageLabel(pages.bottom).offset(y: layout.middle + 6)
                }
                if model.done, !renderingPreview || notesHoverPointInRenders != nil {
                    NotesHoverLine(layout: layout, palette: palette, hidden: drag != nil || !turning.isEmpty) { point in
                        target(at: point, layout).map { (x: $0.x, row: $0.row, time: model.score.time(at: $0.position)) }
                    } note: { point in
                        let top = point.y < layout.middle
                        return painter.note(near: point, page: top ? pages.top : pages.bottom, row: layout.row(at: point, top: top))
                    }
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
            .onReceive(model.playing ? Self.tick : Self.slowTick) { _ in turn(layout) }
            .onChange(of: layout) {
                pinned = nil
                syncPages(layout)
                turn(layout, animated: false)
            }
            .onChange(of: model.page) { turn(layout) }
            .onChange(of: model.done) { syncPages(layout) }
            .onAppear {
                syncPages(layout)
                turn(layout, animated: false)
            }
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
                untranscribed(painter, page: page, top: top)
                region(painter, page: page, top: top)
            }
            .frame(width: layout.size.width, height: max(0, height), alignment: .topLeading)
        }
        .frame(width: layout.size.width, height: max(0, height))
        .clipped()
        .offset(y: top ? 0 : layout.middle)
    }

    /// The lines before a region loop that was transcribed, and after it or after the place where Stop Here ended the
    /// transcription, dimmed under a wash of the paper, with "Not transcribed" at the start of the first of them in each
    /// half.
    @ViewBuilder private func untranscribed(_ painter: NotesPainter, page: Int, top: Bool) -> some View {
        if model.done, let part = model.transcribed {
            let layout = painter.layout
            let beats = model.score.beats
            ZStack(alignment: .topLeading) {
                if part.lowerBound > 0 {
                    wash(painter, page: page, top: top, from: 0, to: Score.position(of: part.lowerBound, in: beats))
                }
                if part.upperBound < model.duration || model.transcribedUntil != nil {
                    wash(painter, page: page, top: top, from: Score.position(of: part.upperBound, in: beats), to: Double(layout.bars * Score.beatsPerBar))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The wash over the lines from one place to another, in beats of the score shown.
    @ViewBuilder private func wash(_ painter: NotesPainter, page: Int, top: Bool, from start: Double, to end: Double) -> some View {
        if end > start {
            let layout = painter.layout
            let rects = painter.region(from: start, to: end, page: page, rows: layout.rows(top: top))
            let dy = top ? 0 : layout.middle
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                    // Up over the bar numbers, which the wash would cut in half otherwise.
                    Rectangle()
                        .fill(paper.opacity(0.72))
                        .frame(width: rect.width, height: rect.height + 12)
                        .offset(x: rect.minX, y: rect.minY - 12 - dy)
                }
                if let first = rects.first {
                    Text("Not transcribed")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(palette.ink.opacity(0.08)))
                        .fixedSize()
                        .offset(x: first.minX + 8, y: first.midY - dy - 9)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The region loop on the lines of one half of a page, in the coordinates of that half. A loop that R started and
    /// hasn't ended yet grows from its start to the place that plays, as the song plays.
    @ViewBuilder private func region(_ painter: NotesPainter, page: Int, top: Bool) -> some View {
        if drag == nil, let loop = model.loop, loop.end == nil {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.playing)) { _ in
                let now = model.now() ?? loop.start
                regionRects(painter, page: page, top: top, from: Score.position(of: loop.start, in: model.score.beats),
                            to: Score.position(of: max(now, loop.start), in: model.score.beats), animated: false)
            }
        } else {
            let beats = model.score.beats
            // A drag shows the region from the point where it started to the pointer. Once released, the region widens
            // to the notes that it cuts, which the edges slide to.
            let loop: (Double, Double)? = drag.map { (min($0.from, $0.to), max($0.from, $0.to)) }
                ?? model.loop.flatMap { loop in loop.end.map { (Score.position(of: loop.start, in: beats), Score.position(of: $0, in: beats)) } }
            if let (start, end) = loop { regionRects(painter, page: page, top: top, from: start, to: end, animated: drag == nil) }
        }
    }

    private func regionRects(_ painter: NotesPainter, page: Int, top: Bool, from start: Double, to end: Double, animated: Bool) -> some View {
        let honey = NotesAccent.color(colorScheme)
        let rects = painter.region(from: start, to: end, page: page, rows: painter.layout.rows(top: top))
        let dy = top ? 0 : painter.layout.middle
        return ZStack(alignment: .topLeading) {
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 5)
                    .fill(honey.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(honey.opacity(0.55), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY - dy)
            }
        }
        .allowsHitTesting(false)
        .animation(animated ? .easeOut(duration: 0.18) : nil, value: [start, end])
    }

    /// A click moves the song to the place under the pointer, where the faint line over the notes shows it, and a drag
    /// sets the region loop from where it started to where it ends. Neither turns a page.
    private func pointer(_ layout: NotesLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) > 4 else { return }
                drag = (position(value.startLocation, layout), position(value.location, layout))
            }
            .onEnded { value in
                defer { drag = nil }
                if let drag, abs(drag.to - drag.from) >= 0.25 {
                    // The loop covers every note that it would cut.
                    let beats = model.score.encompassing(from: min(drag.from, drag.to), to: max(drag.from, drag.to))
                    pinned = shown
                    model.onLoop(model.score.time(at: beats.start), model.score.time(at: beats.end))
                } else if hypot(value.translation.width, value.translation.height) <= 4, let target = target(at: value.location, layout) {
                    pinned = shown
                    // A hundredth of a second later, so that the rounding of the player never lands before a note or a bar.
                    model.onSeek(max(0, model.score.time(at: target.position) + 0.01))
                }
            }
    }

    private func position(_ point: CGPoint, _ layout: NotesLayout) -> Double {
        let top = point.y < layout.middle
        return layout.position(at: point, page: top ? shown.top : shown.bottom, top: top)
    }

    /// Where a click at a point moves the song: the place under it, or the start of a note when the point is within 7
    /// points of where the note is drawn, so that a click on a note plays it from its start. Nil past the last line.
    private func target(at point: CGPoint, _ layout: NotesLayout) -> (x: CGFloat, row: Int, position: Double)? {
        let top = point.y < layout.middle
        let row = layout.row(at: point, top: top)
        let line = (top ? shown.top : shown.bottom) * layout.linesPerPage + row
        guard line < layout.lines else { return nil }
        let first = line * layout.barsPerLine, lineStart = Double(first * Score.beatsPerBar)
        var beats = layout.beats(atX: point.x)
        let byBar = model.score.notesByBar
        var nearest: CGFloat = 7
        for bar in first ..< min(byBar.count, first + layout.barsPerLine) {
            for note in byBar[bar] {
                let place = Double((bar - first) * Score.beatsPerBar) + note.beat
                let distance = abs(layout.x(atBeats: place) - point.x)
                if distance <= nearest {
                    nearest = distance
                    beats = place
                }
            }
        }
        let position = min(Double(layout.bars * Score.beatsPerBar), lineStart + beats)
        return (layout.x(atBeats: beats), row, position)
    }

    private func turn(_ layout: NotesLayout, animated: Bool = true) {
        // The first notes show at once, on the pages of the moment they arrive.
        guard model.done else { return placed = false }
        let pages = layout.pagesShown(at: model.now(), in: model.score)
        // A page that the buttons asked for waits up to a second and a half for the player to report the seek, so the
        // pages and the number don't flick back to where the song was.
        if let asked = model.pageAsked {
            if pinned != nil { pinned = nil }
            if pages.bottom != asked.page, Date().timeIntervalSince(asked.at) < 1.5 { return }
            model.pageAsked = nil
        }
        // State is only written when it changes, since this runs 10 times a second.
        defer { if !placed { placed = true } }
        if model.page != pages.bottom { model.page = pages.bottom }
        if let pin = pinned {
            if let time = model.now(), let spot = layout.spot(at: time, in: model.score), Self.keeps(pin, spot: spot, layout) { return }
            pinned = nil
        }
        guard pages != shown else { return }
        animateTurns = animated && placed
        shown = pages
    }

    /// The pages that a click or a drag left in place stay while the song plays on a line that they show. When the
    /// other half doesn't show what the song plays next (the bottom of the same page under the top half, the next page
    /// over the bottom half), it turns once the song reaches the last line of its half, so that it lies flat before the
    /// song gets there.
    private static func keeps(_ pin: (top: Int, bottom: Int), spot: (page: Int, row: Int, slot: Int, x: CGFloat), _ layout: NotesLayout) -> Bool {
        let inTop = spot.row < layout.topLines
        guard spot.page == (inTop ? pin.top : pin.bottom) else { return false }
        let nextShown = inTop ? pin.bottom == spot.page : pin.top == min(layout.pages - 1, spot.page + 1)
        return nextShown || spot.row != (inTop ? layout.topLines - 1 : layout.linesPerPage - 1)
    }

    private func pageLabel(_ page: Int) -> some View {
        Text("Page \(page + 1)")
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(paper.opacity(0.9)))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// The number of pages and where each one starts, for the page buttons in the footer.
    private func syncPages(_ layout: NotesLayout) {
        let count = layout.pages
        if model.pageCount != count { model.pageCount = count }
        let barsPerPage = layout.linesPerPage * layout.barsPerLine
        // A hundredth of a second into the page: the player rounds a seek to 1/600 of a second, and a seek that landed a
        // hair before the first bar showed the last line of the page before.
        model.pageStarts = (0 ..< count).map { model.score.time(at: Double($0 * barsPerPage * Score.beatsPerBar)) + 0.01 }
    }
}

/// The line in the accent colour, which moves through the lines at the speed of the song and jumps to the next line at the end of
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
        // Sheet and Piano roll draw the line at most 60 times a second: their pages cost the window server the most for
        // each frame, and the line at 120 looked hardly smoother there. Tab keeps every frame of the display.
        TimelineView(.animation(minimumInterval: model.view == .tab ? nil : 1.0 / 60, paused: !model.playing)) { timeline in
            // The frame's date goes into the drawing, so that the canvas draws again on every frame: with nothing in it
            // that changed, the canvas only drew when another view made it.
            let frame = timeline.date
            ZStack(alignment: .topLeading) {
                // The bar that plays gets a faint wash of the accent. It is a view of its own, whose shape only changes
                // from one bar to the next, so it isn't filled again on every frame with the canvas.
                if let bar = playingBar() {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(NotesAccent.color(colorScheme).opacity(colorScheme == .dark ? 0.06 : 0.05))
                        .frame(width: bar.width, height: bar.height)
                        .offset(x: bar.minX, y: bar.minY)
                }
                line(frame)
            }
        }
        .allowsHitTesting(false)
    }

    /// The bar under the line, on a page that lies flat.
    private func playingBar() -> CGRect? {
        let layout = painter.layout
        guard let time = model.now(), let spot = layout.spot(at: time, in: model.score) else { return nil }
        let inTop = spot.row < layout.topLines
        guard spot.page == (inTop ? shown.top : shown.bottom), !turning.contains(inTop) else { return nil }
        return CGRect(x: layout.x0 + CGFloat(spot.slot) * layout.barWidth, y: layout.top(ofRow: spot.row) + layout.staff.linesTop - 7,
                      width: layout.barWidth, height: layout.staff.linesHeight + 14)
    }

    private func line(_ frame: Date) -> some View {
        Canvas { context, _ in
            _ = frame
            if let notesFrameLog { countNotesFrame(notesFrameLog) }
            let layout = painter.layout
            guard let time = model.now(), let spot = layout.spot(at: time, in: model.score) else { return }
            let dark = colorScheme == .dark
            let colors = NotesPainter.LightColors(glow: NotesAccent.glow(colorScheme), hot: NotesAccent.hot(colorScheme), dark: dark)
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
            let honey = NotesAccent.color(colorScheme)
            // The glow is a band of the accent that fades out on both sides, cheaper on every frame than a shadow filter.
            let band = rect.insetBy(dx: -6, dy: 0)
            context.fill(Path(roundedRect: band, cornerRadius: 6), with: .linearGradient(
                Gradient(stops: [.init(color: honey.opacity(0), location: 0), .init(color: honey.opacity(dark ? 0.32 : 0.24), location: 0.5),
                                 .init(color: honey.opacity(0), location: 1)]),
                startPoint: CGPoint(x: band.minX, y: band.midY), endPoint: CGPoint(x: band.maxX, y: band.midY)))
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(honey))
        }
    }

    /// How lit an onset is with the playhead at `x` on `line`: a faint warm-up over the last seventh of a bar before
    /// the touch, then the flash and the afterglow, timed from the moment that the playhead touched it.
    static func phosphor(_ onset: NotesPainter.Onset, time: Double, line: Int, x: CGFloat, layout: NotesLayout, score: Score) -> Double {
        guard onset.line < line || (onset.line == line && onset.x <= x) else {
            guard onset.line == line else { return 0 }
            let span = layout.barWidth * 0.14, distance = onset.x - x
            return distance < span ? 0.16 * pow(1 - distance / span, 3) : 0
        }
        let beats = Double(onset.line * layout.barsPerLine * Score.beatsPerBar) + layout.beats(atX: onset.x)
        let age = time - score.time(at: beats)
        guard age >= 0, age < 5 else { return 0 }
        return exp(-age / 1.1) * (1 + 0.45 * exp(-age / 0.09))
    }
}

/// A faint line where the pointer is over the notes, with the time that a click moves the song to. Over a note, its
/// name shows in a pill above it, for reading the notes while learning them.
/// `--notes-hover-note X,Y` renders the pill of the note at that point of the window's page.
private struct NotesHoverLine: View {
    let layout: NotesLayout
    let palette: Palette
    let hidden: Bool
    let target: (CGPoint) -> (x: CGFloat, row: Int, time: Double)?
    let note: (CGPoint) -> NotesPainter.NamedNote?
    @State private var point: CGPoint? = notesHoverPointInRenders

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case let .active(location) = phase { point = location } else { point = nil }
            }
            .overlay(alignment: .topLeading) {
                if !hidden, let point, let spot = target(point) {
                    let top = layout.top(ofRow: spot.row) + layout.staff.linesTop - 7
                    let named = note(point)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(palette.ink.opacity(0.4))
                            .frame(width: 1.5, height: layout.staff.linesHeight + 14)
                            .position(x: spot.x, y: top + (layout.staff.linesHeight + 14) / 2)
                        // Over a note, its name takes the place of the time, which a note near the top would cover.
                        if named == nil {
                            Text(NotesTime.time(spot.time))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(palette.ink.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.ink.opacity(0.1)))
                                .fixedSize()
                                .position(x: spot.x, y: top - 9)
                        }
                        if let named {
                            NoteNamePill(note: named, palette: palette)
                                .position(x: named.center.x, y: named.center.y - 17)
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
            }
    }
}

/// `--notes-hover-note X,Y`: a pointer at that point of the page in renders.
nonisolated(unsafe) var notesHoverPointInRenders: CGPoint?

/// The name of the note under the pointer, and in sheet music the string and the fret that play it.
private struct NoteNamePill: View {
    let note: NotesPainter.NamedNote
    let palette: Palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The sharp or the flat in full ink: it is half of what the pill says.
            Text(note.name)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            if let fret = note.fret {
                Text(fret)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.muted)
            }
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.ink.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .fixedSize()
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
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NotesTime(model: model, palette: palette)
                // A stem without notes has no pages to move through.
                if model.phase != .quiet, model.phase != .empty { NotesPager(model: model, palette: palette) }
            }
            .padding(.horizontal, 20)
            .frame(height: 50)
            NotesStatusBar(model: model, palette: palette)
        }
    }
}

/// The page that the song is on, of all the pages, with the previous and the next page beside it.
private struct NotesPager: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", to: model.page - 1, help: "Previous page (←)")
            Text("Page \(model.page + 1) of \(model.pageCount)")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .contentTransition(.numericText(value: Double(model.page)))
                .animation(.snappy(duration: 0.2), value: model.page)
                .fixedSize()
            arrow("chevron.right", to: model.page + 1, help: "Next page (→)")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(palette.ink.opacity(0.08)))
        .opacity(model.done ? 1 : 0.4)
        .disabled(!model.done)
    }

    private func arrow(_ symbol: String, to page: Int, help: String) -> some View {
        Button { model.goToPage(page) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(palette.ink)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(page < 0 || page >= model.pageCount)
        .help(help)
    }
}

/// The time of the song and a bar that a click moves the song along.
private struct NotesTime: View {
    @ObservedObject var model: NotesModel
    let palette: Palette

    var body: some View {
        // A quarter of a second while the song plays, and once a second while it's paused, to show a seek.
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
                // The bar takes the width that the pager leaves, so a click lands on a finer time.
                .frame(minWidth: 60, maxWidth: .infinity)
                .frame(height: 16)
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
    /// ⇧R, which loops the whole song as over the HUD.
    var onSongLoopKey: () -> Void = {}

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
        log.info("notes: \(portrait ? "landscape" : "portrait", privacy: .public) page")
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
        case kVK_Return where model.phase == .quiet, kVK_ANSI_KeypadEnter where model.phase == .quiet: model.onTranscribeAnyway()
        case kVK_Space: model.onPlayPause()
        case kVK_ANSI_R: flags.contains(.shift) ? onSongLoopKey() : onLoopKey(!flags.contains(.option))
        case kVK_Tab:
            let all = NotesView.allCases
            let index = all.firstIndex(of: model.view) ?? 0
            model.view = all[(index + (flags.contains(.shift) ? all.count - 1 : 1)) % all.count]
        // Left and right turn the pages, up and down transpose, and with Option, up and down move the capo of the tab.
        case kVK_LeftArrow, kVK_PageUp: model.goToPage(model.page - 1)
        case kVK_RightArrow, kVK_PageDown: model.goToPage(model.page + 1)
        case kVK_UpArrow where flags.contains(.option): if model.hasTab { model.onCapo(1) }
        case kVK_DownArrow where flags.contains(.option): if model.hasTab { model.onCapo(-1) }
        case kVK_UpArrow: model.onTranspose(1)
        case kVK_DownArrow: model.onTranspose(-1)
        // The HUD's tempo keys: [ and ] a step slower or faster, = the song's own tempo.
        case kVK_ANSI_LeftBracket where model.speedAdjustable: model.onSpeedStep(-1)
        case kVK_ANSI_RightBracket where model.speedAdjustable: model.onSpeedStep(1)
        case kVK_ANSI_Equal where model.speedAdjustable: model.onSpeedStep(0)
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
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch format {
                case .musicXML: try score.musicXML(title: title).write(to: url, atomically: true, encoding: .utf8)
                case .midi: try score.midi.write(to: url)
                case .textTab: try score.textTab.write(to: url, atomically: true, encoding: .utf8)
                }
                log.info("notes: saved \(format.name, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("notes: saving \(format.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
    /// The song can be transcribed: a file in Muskey Player, or a song from another app short enough for its capture.
    var available: Bool
    var duration: Double?
    /// For a song from another app, the seconds of it that Muskey heard, which is what gets transcribed.
    var heard: Double?
    /// The bytes of the models that are still missing.
    var missing: Int?
    var downloading: Double?
    var failed = false
    /// The region loop, which is transcribed in place of the whole song until Tab or a click picks the whole song.
    var region: ClosedRange<Double>?
    var wholeSong = false

    var transcribesRegion: Bool { region != nil && !wholeSong }
}

struct NotesStemPicker: View {
    let picking: NotesPicking
    let palette: Palette
    let select: (Stem) -> Void
    let start: () -> Void
    /// A song from another app plays to its end first, and is transcribed once it ends.
    var startFull: () -> Void = {}
    /// Picks the whole song (true) or the region loop (false).
    var pickPart: (Bool) -> Void = { _ in }
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
            if picking.available, let region = picking.region {
                HStack(spacing: 6) {
                    part("Region loop", seconds: region.upperBound - region.lowerBound, on: picking.transcribesRegion) { pickPart(false) }
                    part("Whole song", seconds: picking.duration, on: !picking.transcribesRegion) { pickPart(true) }
                }
            }
            HStack {
                if picking.available, picking.missing != nil || picking.downloading != nil || picking.failed {
                    // The download button needs the whole row.
                    button.frame(maxWidth: .infinity)
                } else if picking.available, picking.transcribesRegion {
                    // The row above names the region and its length.
                    button.frame(maxWidth: .infinity)
                } else if picking.available, partlyHeard {
                    // Part of a song from another app: the time heard is in the button, and Full Song is beside it. With
                    // nothing heard yet, only Full Song can work.
                    if heardEnough {
                        button
                    } else {
                        Text("Nothing heard yet").foregroundStyle(palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    fullButton
                } else if picking.available, picking.region != nil {
                    // The row above names the whole song and its length.
                    button.frame(maxWidth: .infinity)
                } else if picking.available {
                    Text(picking.duration.map { "Whole song · \(NotesTime.time($0))" } ?? "Whole song")
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    button
                } else {
                    Text(picking.heard == nil ? "Only for songs in Muskey Player" : "Only for songs up to 20 minutes")
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            KeyHintsRow(hints: picking.available
                ? [(["1–\(picking.stems.count)"], "stem")] + (picking.region == nil ? [] : [(["⇥"], picking.transcribesRegion ? "whole song" : "region loop")])
                    // With the region loop's Tab, ⌥↩ stays only on the Full Song button, which keeps the row within the picker.
                    + (heardEnough ? [(["↩"], "transcribe")] : []) + (partlyHeard && picking.region == nil ? [(["⌥", "↩"], "full song")] : []) + [(["esc"], "close")]
                : [(["esc"], "close")],
                palette: palette)
        }
        .frame(width: 330)
    }

    /// A song from another app that Muskey heard only part of, so it can be heard to its end first. A region loop was
    /// heard whole, or the picker wouldn't offer it.
    private var partlyHeard: Bool {
        guard picking.available, !picking.transcribesRegion, picking.missing == nil, picking.downloading == nil, !picking.failed, let heard = picking.heard else { return false }
        return heard < (picking.duration ?? 0) * 0.97
    }

    /// Enough of the song was heard to transcribe it now: a file, a few seconds of a song from another app, or a region
    /// loop.
    private var heardEnough: Bool { picking.transcribesRegion || (picking.heard ?? .infinity) >= 5 }

    /// One of the two parts of the song that can be transcribed while a region loop is set, with its length.
    private func part(_ name: String, seconds: Double?, on: Bool, action: @escaping () -> Void) -> some View {
        let honey = StripColors.text(.honey, colorScheme)
        return Button(action: action) {
            HStack(spacing: 0) {
                Text(name).foregroundStyle(palette.ink)
                if let seconds { Text(" · \(NotesTime.time(seconds))").foregroundStyle(palette.muted).monospacedDigit() }
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(on ? honey.opacity(0.2) : palette.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(on ? honey : palette.ink.opacity(0.12), lineWidth: on ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// Plays the rest of a song from another app, and transcribes it once it ends.
    private var fullButton: some View {
        let honey = StripColors.text(.honey, colorScheme)
        return Button(action: startFull) {
            HStack(spacing: 6) {
                // Beside Transcribe Vocals · 1:12, the other choice is the full song, which plays to its end first.
                Text("Full Song")
                Keycap(text: "⌥", palette: palette, small: true)
                Keycap(text: "↩", palette: palette, small: true)
            }
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .fixedSize()
            .foregroundStyle(honey)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(honey.opacity(0.8), lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
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
                    // Part of a song from another app names the time that gets transcribed.
                    Text("Transcribe \(picking.selected.name)" + (partlyHeard ? " · \(NotesTime.time(picking.heard ?? 0))" : ""))
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
    if let out = TestFlags.value("--notes-html") { return writeNotesSheet(fixture: path, to: out) }
    guard let model = NotesModel.fixture(path) else {
        print("notes render: can't read \(path)")
        return
    }
    let at = TestFlags.value("--notes-at").flatMap(Double.init) ?? 40
    model.now = { at }
    notesFoldInRenders = TestFlags.value("--notes-fold").flatMap(Double.init)
    if let point = TestFlags.value("--notes-hover-note")?.split(separator: ",").compactMap({ Double($0) }), point.count == 2 {
        notesHoverPointInRenders = CGPoint(x: point[0], y: point[1])
    }
    // `--notes-relative` names the key in the other mode, as the HUD does after a key was picked in it.
    if TestFlags.has("--notes-relative") { model.relative = true }
    if let shift = TestFlags.value("--notes-shift").flatMap(Int.init) { model.shift = shift }
    if let capo = TestFlags.value("--notes-capo").flatMap(Int.init) { model.capo = capo }
    if let speed = TestFlags.value("--notes-speed").flatMap(Double.init) {
        model.speed = speed
        model.speedAdjustable = true
    }
    // `--notes-loop A-` sets a loop that R started at A and hasn't ended, which grows to `--notes-at`.
    if let loop = TestFlags.value("--notes-loop")?.split(separator: "-").compactMap({ Double($0) }), (1 ... 2).contains(loop.count) {
        model.loop = LoopRegion(start: loop[0], end: loop.count == 2 ? loop[1] : nil, startPress: nil)
    }
    // `--notes-loop-beats A-B` sets the loop that a drag from beat A to beat B sets, widened to the notes it would cut.
    if let beats = TestFlags.value("--notes-loop-beats")?.split(separator: "-").compactMap({ Double($0) }), beats.count == 2 {
        let widened = model.score.encompassing(from: beats[0], to: beats[1])
        model.loop = LoopRegion(start: model.score.time(at: widened.start), end: model.score.time(at: widened.end), startPress: nil)
        print(String(format: "loop beats %.2f-%.2f widened to %.2f-%.2f", beats[0], beats[1], widened.start, widened.end))
    }
    // `--notes-progress STEP:F` shows the transcription at F of a step (beats, stems or notes), with `--notes-left S`
    // seconds left, and `--notes-failed` shows a failed one.
    if let spec = TestFlags.value("--notes-progress") {
        let parts = spec.split(separator: ":")
        let step = NotesStep.allCases.first { $0.name.lowercased() == parts.first?.lowercased() } ?? .notes
        model.begin(NotesStep.allCases.filter { $0 != .capture || step == .capture })
        model.phase = .working(step, parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
        if let left = TestFlags.value("--notes-left").flatMap(Double.init) { model.showLeft(left) }
    }
    if TestFlags.has("--notes-failed") {
        model.begin([.beats, .stems, .notes])
        model.phase = .failed
    }
    // `--notes-region A-B` shows the notes of a region loop from A to B seconds, transcribed in place of the whole song.
    if let spec = TestFlags.value("--notes-region"), case let ends = spec.split(separator: "-").compactMap({ Double($0) }), ends.count == 2 {
        model.region = ends[0] ... ends[1]
        model.finish(NotesPipeline.notes(model.notes, in: ends[0] ... ends[1]))
    }
    // `--notes-until S` shows the notes of a transcription that Stop Here ended at S seconds.
    if let until = TestFlags.value("--notes-until").flatMap(Double.init) {
        model.transcribedUntil = until
        model.finish(model.notes.filter { $0.start < until })
    }
    // `--notes-quiet` shows the card of a stem that hardly plays, and `--notes-empty` the card of a transcription that
    // found no notes.
    if TestFlags.has("--notes-quiet") || TestFlags.has("--notes-empty") {
        model.otherStems = [Stem.guitar, .vocals, .piano, .winds, .other, .bass].filter { $0 != model.stem }
        if TestFlags.has("--notes-empty") {
            model.finish([])
        } else {
            model.begin([.beats, .stems, .notes])
            model.phase = .quiet
        }
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

/// `--notes-render FIXTURE --notes-html OUT`: the page that a browser opens, written in place of the PNGs, with
/// `--notes-shift N`, `--notes-capo N`, `--notes-relative`, `--notes-view tab|sheet|roll` and `--notes-artist NAME`.
/// It rides on `--notes-render` because the app reads its launch flags in App.swift.
@MainActor func writeNotesSheet(fixture path: String, to out: String) {
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONDecoder().decode(NotesFixture.self, from: data) else {
        print("notes html: can't read \(path)")
        return
    }
    let html = NotesSheet.html(fixture, artist: TestFlags.value("--notes-artist"), view: TestFlags.value("--notes-view").flatMap(NotesView.init(rawValue:)),
                               shift: TestFlags.value("--notes-shift").flatMap(Int.init) ?? 0, relative: TestFlags.has("--notes-relative"),
                               capo: TestFlags.value("--notes-capo").flatMap(Int.init) ?? 0)
    guard !html.isEmpty else {
        print("notes html: the app has no Web folder in its resources")
        return
    }
    do {
        try html.write(toFile: out, atomically: true, encoding: .utf8)
        print("wrote \(out)")
    } catch {
        print("notes html: \(error.localizedDescription)")
    }
}
