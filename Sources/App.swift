import AppKit
import Carbon.HIToolbox
import Combine
import Network
import os
import ServiceManagement
import SwiftUI

struct DetectedKey: Equatable {
    /// Each key spelled the way it is usually written, indexed by pitch class from C.
    private static let majorNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    private static let minorNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]

    let pitchClass: Int
    let minor: Bool

    init?(_ result: EKResult) {
        guard (0 ..< 12).contains(result.pitchClass) else { return nil }
        pitchClass = Int(result.pitchClass)
        minor = result.minor != 0
    }

    init(pitchClass: Int, minor: Bool) {
        self.pitchClass = pitchClass
        self.minor = minor
    }

    /// Semitones that move this key onto `target`, the shorter way, from six down to five up. A pitch change keeps
    /// the mode, so a target in the other mode is reached through its relative, which has the same notes: from
    /// A major, C minor is E♭ major. A key mistaken for its relative gives the same shift.
    func shift(to target: DetectedKey) -> Int {
        let goal = target.minor == minor ? target : target.relative
        return ((goal.pitchClass - pitchClass + 6) % 12 + 12) % 12 - 6
    }

    var tonic: String { minor ? Self.minorNames[pitchClass] : Self.majorNames[pitchClass] }

    /// The pitch class whose name in this mode is `letter`, plain or with the sharp or flat that the key strip
    /// shows: in C♯ minor, E with an accidental is E♭ and D has none.
    static func pitchClass(letter: Character, accidental: Bool, minor: Bool) -> Int? {
        (minor ? minorNames : majorNames).firstIndex { $0.first == letter && ($0.count == 2) == accidental }
    }
    var name: String { "\(tonic) \(minor ? "minor" : "major")" }
    /// The name written short, as in the menu bar and the pills under the key: `Cm`, `F♯`, `E♭m`.
    var short: String { tonic + (minor ? "m" : "") }

    /// Same notes, other mode: a minor third up from minor, down from major.
    var relative: DetectedKey { DetectedKey(pitchClass: (pitchClass + (minor ? 3 : 9)) % 12, minor: !minor) }

    /// The key's code on the Camelot wheel that DJs mix by: `8A` is A minor, `8B` is C major, and neighbouring
    /// numbers are a fifth apart.
    var camelot: String {
        let major = minor ? (pitchClass + 3) % 12 : pitchClass
        return "\((major * 7 % 12 + 7) % 12 + 1)\(minor ? "A" : "B")"
    }

    func transposed(by semitones: Int) -> DetectedKey {
        DetectedKey(pitchClass: ((pitchClass + semitones) % 12 + 12) % 12, minor: minor)
    }

    /// A key written like `Cm`, `F#` or `Eb`, for the `--keep` test flag.
    init?(name: String) {
        guard let letter = name.first, letter != " ", let natural = "C D EF G A B".firstIndex(of: letter) else { return nil }
        var pitchClass = "C D EF G A B".distance(from: "C D EF G A B".startIndex, to: natural)
        var rest = name.dropFirst()
        if let accidental = rest.first, "#♯b♭".contains(accidental) {
            pitchClass += "#♯".contains(accidental) ? 1 : -1
            rest = rest.dropFirst()
        }
        guard rest.isEmpty || rest == "m" else { return nil }
        self.init(pitchClass: (pitchClass + 12) % 12, minor: rest == "m")
    }

    /// Stands in for a detected key in the `--pick` and `--shift` test flags.
    static let sample = DetectedKey(pitchClass: 4, minor: true)
}

/// Text and icon colours: warm near-black ink in light mode, warm near-white in dark mode.
struct Palette {
    let ink: Color
    let muted: Color
    let accent: Color

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(
                ink: Color(red: 1.0, green: 0.97, blue: 0.96),
                muted: Color(red: 0.91, green: 0.85, blue: 0.86),
                accent: Color(red: 0.96, green: 0.85, blue: 0.89)
            )
            : Palette(
                ink: Color(red: 0.13, green: 0.08, blue: 0.10),
                muted: Color(red: 0.29, green: 0.20, blue: 0.24),
                accent: Color(red: 0.33, green: 0.19, blue: 0.26)
            )
    }
}

/// Runs Essentia's KeyExtractor again over everything heard so far, once a second, off the IO queue.
final class KeyAnalyzer {
    static let profile = "shaath"
    static let firstEstimateAfter = 4.0

    private let queue = DispatchQueue(label: "muskey.analysis", qos: .userInitiated)
    /// The rate that the samples are read at: the tap's rate, divided by the speed of a song that Muskey Player plays
    /// faster or slower, which brings its key and its tempo back to the song's own.
    private var rate: Double
    private let tapRate: Double
    private var samples: [Float] = []
    private var analyzedCount = 0
    private var peak: Float = 0
    private var finished = false
    private let wavPath: String?

    /// `recordTo` writes everything heard to a mono Float32 WAV on finish, for checking the capture by ear or with another tool.
    init(sampleRate: Double, speed: Double = 1, recordTo wavPath: String? = nil) {
        tapRate = sampleRate
        rate = sampleRate / speed
        self.wavPath = wavPath
        samples.reserveCapacity(Int(sampleRate * 32))
    }

    func append(_ chunk: [Float], update: @escaping (EKResult, Float) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            samples += chunk
            for sample in chunk { peak = max(peak, abs(sample)) }
            guard samples.count >= Int(rate * Self.firstEstimateAfter), samples.count - analyzedCount >= Int(rate) else { return }
            let result = analyze()
            let peak = peak
            DispatchQueue.main.async { update(result, peak) }
        }
    }

    /// The song plays at another speed: what was heard at the old one is dropped, and the rest is read at the new one.
    func play(at speed: Double) {
        queue.async { [self] in
            guard !finished, rate != tapRate / speed else { return }
            rate = tapRate / speed
            samples.removeAll(keepingCapacity: true)
            analyzedCount = 0
            peak = 0
        }
    }

    /// The final key, the peak, and the tempo of everything heard, which only the final estimate looks for.
    func finish(_ completion: @escaping (EKResult, Float, (bpm: Double, confidence: Float)?) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            let result = analyze()
            let tempo = peak >= 0.0005 ? TempoDetector.bpm(samples, sourceRate: rate) : nil
            if let wavPath { writeWAV(samples, rate: UInt32(rate.rounded()), to: wavPath) }
            let peak = peak
            DispatchQueue.main.async { completion(result, peak, tempo) }
        }
    }

    private func analyze() -> EKResult {
        analyzedCount = samples.count
        return samples.withUnsafeBufferPointer { ek_key($0.baseAddress, UInt32($0.count), rate, Self.profile) }
    }
}

/// Float32 WAV; `samples` are interleaved when there is more than one channel.
func writeWAV(_ samples: [Float], rate: UInt32, channels: UInt16 = 1, to path: String) {
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16))
    put(UInt16(3)); put(channels); put(rate); put(rate * 4 * UInt32(channels)); put(4 * channels); put(UInt16(32))
    data.append(contentsOf: Array("data".utf8)); put(bytes)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try? data.write(to: URL(fileURLWithPath: path))
}

final class HUDModel: ObservableObject {
    enum Phase { case listening, done, silent, failed, denied, idle }
    @Published var phase: Phase = .listening
    @Published var key: DetectedKey?
    @Published var progress: Double = 0
    // A repeating symbol effect keeps rendering in an ordered-out window, so effects run only while the HUD is up.
    @Published var shown = false

    /// Semitones the pitch change moves the song by; the HUD shows the key that is heard.
    @Published var shift = 0
    /// The picked key is in the other mode than the detected key: from A major, Option-C plays E♭ major and the HUD
    /// shows it as C minor.
    @Published var relative = false
    /// The HUD waits for a key to be picked, and stays up until closed.
    @Published var picking = false
    @Published var pitchFailed = false
    /// A key is locked, and every song that starts playing gets moved to it. Lock Key shows red only then.
    @Published var keepKey = false
    /// The key that Lock Key moved a new song from, and the key it moved it to: G♯ minor to C minor.
    @Published var moved: KeyMove?
    /// The kept key that a new song is going to. Until the first estimate of the song's own key, the song plays in
    /// that key, and the HUD shows where it is going with a spinner.
    @Published var pending: DetectedKey?
    /// The song that the Mac plays and its cover, for the record beside the key.
    @Published var track: NowPlaying.Track?
    /// The tempo of a song, from a listen or from Noiseblend. It shows while that song plays.
    @Published var tempo: SongTempo?
    var shownTempo: SongTempo? { tempo.flatMap { $0.song == track?.song ? $0 : nil } }
    /// The speed that Muskey Player plays its song at, against the song's own tempo.
    @Published var speed = 1.0
    /// The song plays in Muskey Player, whose speed the tempo keys and the tempo pill change.
    @Published var speedAdjustable = false
    /// The fastest speed of the song that plays: 150 % in Muskey Player, and 100 % for another player's song, which can
    /// only be slowed down.
    @Published var fastestSpeed = 1.5
    /// Muskey had to stop slowing another player's song, which was asked for at this speed. The speed shows in a red
    /// pill with Retry until the slowing works again, the pill is dismissed or another player plays.
    @Published var slowFailed: Double?
    /// How far a slowed song has come back to 100 %, 0 to 1, while the output catches up with the player.
    @Published var tempoReturn: Double?
    var onOpenFile: () -> Void = {}
    /// A click on the key listens to the song again.
    var onRedetect: () -> Void = {}
    var onSeekFraction: (Double) -> Void = { _ in }
    /// The pointer is over the record and its time bar, where ← → and 0 move the song.
    @Published var overRecord = false
    var onOpenLocation: () -> Void = {}
    /// A seek would be instant: the stems aren't separated live, the lyrics don't play behind, and the player took
    /// the last seek. The seek keys and their hints exist only then.
    @Published var seekable = false
    /// The key 0 starts the song over in karaoke: the player took the last seek and the lyrics don't play behind.
    @Published var restartable = false
    /// The key, the stems or the tempo is changed, and the song can be saved with the changes.
    @Published var savable = false
    /// A save in progress, which the HUD shows in place of everything else until it ends.
    @Published var saving: SavingState?
    /// The song plays, as the record and its tonearm show it. Space changes it before the player reports the change.
    @Published var playing = false
    /// The last play or pause, for the glyph on the record or over the lyrics.
    @Published var playFlash: PlayFlash?
    @Published var artwork: NSImage?
    /// The single card instead of the wide layout. Muskey remembers the layout.
    @Published var card = UserDefaults.standard.string(forKey: "layout") == "card"
    /// The second row of keys, or the inner ring of the card, with the keys in the other mode.
    @Published var relativeKeys = false
    /// Option is held over the keys: they show the other mode.
    @Published var flipped = false
    /// The card shows the keyboard shortcuts in place of the record and its keys.
    @Published var shortcuts = false
    /// The lyrics of the song in place of the key in the wide layout, and in place of the record on the card.
    @Published var lyricsShown = false
    /// Karaoke: the lyrics large, in a glass as tall as the screen, for singing along, with the vocals muted when
    /// Settings has it (Return while the lyrics show).
    @Published var lyricsFocus = false
    /// The backspins that the output played when it stepped back in the song, for the records to turn back with them.
    @Published var rewinds = 0
    /// A new song that the stems or the lyrics delay play only seconds later: from when it started to when it is heard.
    @Published var songArriving: ClosedRange<Date>?
    /// The size of the glass when the song changed under a HUD with a key. The listen of the new song shows no key
    /// until its first estimate, and the glass keeps this size until then, so the record stays under the pointer.
    @Published var heldGlass: CGSize?
    /// The HUD takes keys: the pointer is over it, or it has the keyboard. The key hints are faint otherwise, since the
    /// keys do nothing then, but they keep their place and some weight in the layout.
    @Published var keysActive = false
    /// The hints are already lighter than the buttons, so 0.45 of that comes close to the buttons that FocusDim dims.
    var hintsOpacity: Double { keysActive ? 1 : 0.45 }
    /// The pointer is over the key at the top of karaoke, which shows the key row in its place.
    @Published var karaokeKeys = false
    /// The pointer is over the cover in the middle of karaoke's record, which shows the instruments and vocals.
    @Published var karaokeStems = false
    /// The height of the visible part of the screen that the HUD is on, which the large lyrics never outgrow.
    @Published var screenHeight: CGFloat = 900
    /// Where the glass is in the panel, in points from its top left corner, for keeping it on the screen.
    @Published var glassFrame: CGRect = .zero
    @Published var lyrics: LyricsState = .none
    /// The line of the lyrics sung now.
    @Published var lyricLine: Int?
    /// The speech model that times lyrics without times is downloading.
    @Published var lyricsDownloading = false
    /// Whisper listens to a song that LRCLIB has no lyrics for, and writes them.
    @Published var lyricsWriting = false
    /// Whisper skips the part of the song that plays, since it was transcribed in an earlier play.
    @Published var lyricsSkipped = false
    /// Seconds until the song steps back 30 seconds, so the lines that Whisper writes come before they are sung.
    @Published var lyricsWaiting: Int?
    /// Karaoke's countdown while the vocals are separated, before the song rewinds or starts over.
    @Published var karaokeCountdown: KaraokeCountdown?

    /// The model that separates the stems is on the Mac, so the HUD offers to separate the song.
    @Published var stemsAvailable = false
    /// Stems that don't play. While any is muted, the Mac plays the other stems a few seconds behind the song.
    @Published var stemsMuted: Set<Stem> = []
    /// The stems are separated and played, while any is muted and while the HUD shows them after that.
    @Published var stemsEngaged = false
    /// What the stems wait for after a stem is muted, while the song still plays whole.
    @Published var stemsProgress: StemsProgress?
    /// The stems couldn't be separated, and every stem plays again.
    @Published var stemsFailed = false
    /// How loud each stem plays, in their own object so that the meters redraw without the rest of the HUD.
    let stemMeters = StemMeters()
    /// The scroll over the tempo or a stem.
    let scroll = ScrollFeel()
    /// Where a scroll over the time bar moves the song, from 0 to 1, shown on the bar until the player reports it.
    @Published var scrub: Double?
    /// The volume of each stem that a scroll over it set, from 0 to 1.5. A stem that isn't in it plays at 1.
    @Published var stemVolumes: [Stem: Double] = [:]
    /// A stem is muted, or plays louder or softer than the others, so the stems play in place of the song.
    var stemsAdjusted: Bool { !stemsMuted.isEmpty || !stemVolumes.isEmpty }
    /// The stems show in place of the Separate instruments and vocals button: while they play, while any is muted,
    /// and while their failure shows.
    var stemsOpen: Bool { stemsEngaged || stemsFailed || stemsAdjusted }

    func shown(_ key: DetectedKey) -> DetectedKey { relative ? key.relative : key }
    /// The key that is heard, as the HUD names it.
    var heard: DetectedKey? { key.map { shown($0.transposed(by: shift)) } }
    /// Holds off the automatic dismissal of a result while the pointer is over the HUD, and turns on the keys
    /// that pick a key by its letter.
    var hovering = false {
        didSet { if hovering != oldValue { onHoverChange() } }
    }
    var onHoverChange: () -> Void = {}

    /// A key picked in the rows or on the rings: its shift, and whether it is in the other mode than the song.
    var onShift: (Int, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    var onStop: () -> Void = {}
    var onKeep: () -> Void = {}
    var onLayout: () -> Void = {}
    var onSave: () -> Void = {}
    var onSaveCancel: () -> Void = {}
    var onSaveStop: () -> Void = {}
    var onLyrics: () -> Void = {}
    var onKaraoke: () -> Void = {}
    /// Slower with -1, faster with 1, and the song's own tempo with 0.
    var onSpeed: (Int) -> Void = { _ in }
    var onLyricsRetry: () -> Void = {}
    var onLyricsEdit: () -> Void = {}
    /// A stem chip or its key: mute it or play it again, or with Option play only that stem.
    var onStem: (Stem, Bool) -> Void = { _, _ in }
    /// The V key and karaoke's Vocals pill: the vocals muted, or playing again.
    var onVocals: () -> Void = {}
    var onStemsReset: () -> Void = {}
    /// The Separate instruments and vocals button.
    var onSeparate: () -> Void = {}
    /// The ✕ on the stems: every stem plays again, and the Separate button takes their place.
    var onStemsClose: () -> Void = {}
    var onStemsRetry: () -> Void = {}
    var onSlowRetry: () -> Void = {}
    /// Files or links dropped on the HUD, which Muskey plays.
    var onOpen: ([URL]) -> Void = { _ in }
    /// A click on the record: play or pause.
    var onPlayPause: () -> Void = {}
    /// The previous (-1) or next (1) song, from the buttons beside the record.
    var onSkip: (Int) -> Void = { _ in }
    /// A link in the HUD, like the credit under the lyrics, opens in the browser.
    var onLink: (URL) -> Void = { _ in }
    /// A file or a link is dragged over the HUD.
    @Published var dropTargeted = false

    /// The waveform of the song, with its zoom, its lanes and the region loop, in their own object so that the
    /// waveform redraws without the rest of the HUD.
    let wave = WaveState()
    /// Settings > HUD > Waveform, and W over the HUD.
    @Published var waveformShown = Preferences.shared.waveform
    @Published var waveformStyle = Preferences.shared.waveformStyle
    /// The region loop (R), on the waveform, the time bar and the lyrics.
    @Published var loop: LoopRegion?
    var onLoopSet: (LoopEnd, Double) -> Void = { _, _ in }
    var onLoopTyping: (Bool) -> Void = { _ in }
}

/// The waveform of the song that plays: whole for a file, and drawn while it plays for a song from another player.
final class WaveState: ObservableObject {
    @Published var waveform: SongWaveform?
    /// 1 shows the whole song, and more shows a close-up of the moments around the playhead (⌘+ and ⌘−, a pinch, ⌘
    /// with a scroll).
    @Published var zoom = 1.0
    /// ⌥W: one lane per stem, while the stems of the whole song are known.
    @Published var lanes = false

    static let zoomLimit = 40.0

    func zoom(by factor: Double) {
        let next = min(Self.zoomLimit, max(1, zoom * factor))
        // Close to 1 means the whole song, so the last step out lands on it exactly.
        zoom = next < 1.08 ? 1 : next
    }
}

/// The level of each stem, in the order of `Stem`, 20 times a second while the stems play and the HUD shows.
final class StemMeters: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: Stem.allCases.count)
}

/// What a scroll over the HUD adjusts: the tempo of a song in Muskey Player, the volume of a stem, or the place in
/// the song, over the time bar.
enum ScrollRegion: Hashable {
    case tempo
    case stem(Stem)
    case timeBar
    /// The waveform, where a scroll moves the song as over the time bar, and ⌘ with a scroll zooms.
    case waveform

    /// A scroll here moves the song, sideways as well as up and down.
    var seeks: Bool { self == .timeBar || self == .waveform }
}

/// The scroll that adjusts the tempo or a stem, in its own object so that the lift redraws only what it moves.
final class ScrollFeel: ObservableObject {
    /// What the scroll that goes on adjusts.
    @Published var region: ScrollRegion?
    /// How far the fingers moved since the scroll began, from −1 down to 1 up, which lifts what they adjust.
    @Published var lift: CGFloat = 0
    /// Where each adjustable thing is in the HUD, in the coordinates of the HUD's window from its top left, by the
    /// view that shows it. The stems that fade out under the lyrics and the ones that fade in under the keys are both
    /// there for a moment, and each takes only its own place away.
    private(set) var frames: [UUID: (region: ScrollRegion, frame: CGRect)] = [:]

    func place(_ region: ScrollRegion, at frame: CGRect, by owner: UUID) { frames[owner] = (region, frame) }
    func remove(by owner: UUID) { frames[owner] = nil }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var tint = Tint.current
    @Environment(\.colorScheme) private var colorScheme
    /// Hides the key row or the instruments of karaoke a moment after the pointer leaves them.
    @State private var keysCollapse: Task<Void, Never>?
    @State private var stemsCollapse: Task<Void, Never>?

    /// The key strip shows with the first estimate and stays on the result. Using it pins the HUD open.
    private var showsStrip: Bool { model.key != nil && (model.picking || model.phase == .done || model.phase == .listening) }

    /// How much taller the card gets when the stems take the place of the Separate instruments and vocals button.
    private static let cardStemsGrowth: CGFloat = 79.5

    private var cardStemsOpen: Bool { model.card && model.saving == nil && !focus && showsStrip && model.stemsAvailable && model.stemsOpen && !model.shortcuts }

    /// The ✕ closes the HUD while it stays up: with the key row, a listen, its result, or nothing playing. A failed
    /// listen closes by itself.
    private var closable: Bool { model.picking || [.listening, .done, .idle].contains(model.phase) }
    private var showsSave: Bool { showsStrip && model.saving == nil && !model.shortcuts && !focus && model.savable }

    /// The large lyrics take the place of either layout.
    private var focus: Bool { model.saving == nil && !model.shortcuts && model.lyricsFocus && model.lyricsShown && showsStrip }

    /// The record shows while a song with a title plays, from the start of a listen.
    private var deckTrack: NowPlaying.Track? {
        // Nothing plays: an empty record, which plays whatever macOS played last.
        if model.phase == .idle { return NowPlaying.Track() }
        guard model.phase == .listening || model.phase == .done, let track = model.track, track.title?.isEmpty == false else { return nil }
        return track
    }

    /// The timing of karaoke's lyrics while they don't come with times, for the status in its top row. The key row
    /// covers the top row while it shows.
    private var karaokeTiming: Lyrics.Timing? {
        guard focus, !model.karaokeKeys, case let .found(lyrics) = model.lyrics, lyrics.timing == .estimated || lyrics.timing == .written else { return nil }
        return lyrics.timing
    }

    var body: some View {
        let palette = Palette.of(colorScheme)
        Group {
            if let saving = model.saving {
                // A save takes the whole HUD until it ends, in a compact layout with the record, so nothing else
                // changes while the song is saved.
                SavingCard(saving: saving, track: model.track?.title?.isEmpty == false ? model.track : nil, artwork: model.artwork,
                           spinning: model.shown && (saving.left == nil || model.playing), palette: palette,
                           cancel: model.onSaveCancel, stop: model.onSaveStop)
                    .transition(.opacity)
            } else if model.shortcuts {
                // Every key and gesture, in place of the layout that they work on, until ?, Escape or the ✕ closes
                // them. A key opens them, so they show at once.
                ShortcutsSheet(card: model.card, otherMode: model.key.map { $0.minor != model.relative ? "major" : "minor" } ?? "major",
                               hotkey: Preferences.shared.hotkey.symbols, palette: palette) { model.shortcuts = false }
            } else if focus {
                lyricsFocus(palette)
            } else if model.card {
                HUDCard(model: model, palette: palette, showsKeys: showsStrip, track: deckTrack)
            } else {
                wide(palette)
            }
        }
        // Sized to its content: the main column fills only the width that the hint bar adds.
        // A glass held at its size gives the layout its whole width, which keeps the record at the same place.
        .fixedSize(horizontal: model.heldGlass == nil, vertical: true)
        .frame(width: model.heldGlass?.width)
        .frame(minWidth: 180, minHeight: max(92, model.heldGlass?.height ?? 0), alignment: .top)
        .overlay(alignment: .topLeading) {
            // In karaoke, the close button, the timing of the lyrics, the key, the lyrics' source and the karaoke button
            // sit in one row.
            if closable || karaokeTiming != nil || showsSave {
                HStack(spacing: 10) {
                    if closable {
                        // Over the shortcuts, the ✕ closes them and leaves the HUD open, as Escape does.
                        CloseButton(size: focus ? 16 : 14, action: { if model.shortcuts { model.shortcuts = false } else { model.onClose() } })
                            .transition(.opacity)
                    }
                    // Beside the ✕ rather than in the row at the top right, where the card's record reached under it.
                    if showsSave {
                        RoundButton(symbol: "square.and.arrow.down", help: "Save the song with its changes (⌘S)", label: "Save", key: "⌘S",
                                    labelAfter: true, palette: palette, action: model.onSave)
                            .transition(.opacity)
                    }
                    if let timing = karaokeTiming {
                        LyricsTimingStatus(timing: timing, downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped,
                                           palette: palette, large: true)
                            .padding(.leading, model.picking ? 0 : 3)
                            .transition(.opacity)
                    }
                }
                .frame(height: focus ? 16 : 14)
                .padding(focus ? 15 : 12)
                .modifier(FocusDim(on: focus))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsStrip, model.saving == nil, !model.shortcuts {
                HStack(spacing: 6) {
                    // Karaoke keeps only its own button, which closes it.
                    if !focus {
                        RoundButton(symbol: "quote.bubble", help: model.lyricsShown ? "Show the keys (L)" : "Show the lyrics (L)", label: "Lyrics", key: "L",
                                    isOn: model.lyricsShown, palette: palette, action: model.onLyrics)
                            .transition(.opacity)
                    }
                    // Karaoke's lyrics name their source before its button, within reach of the pointer.
                    if focus, !model.karaokeKeys, case let .found(lyrics) = model.lyrics, let source = lyrics.source {
                        LyricsCredit(source: source, palette: palette, large: true)
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    }
                    // Karaoke has a button too, besides Return and ⌘K, so that it can be found and clicked like the lyrics.
                    // Return opens it while the lyrics show, and ⌘K from the keys.
                    RoundButton(symbol: "music.microphone", help: focus ? "Close karaoke (↩)" : model.lyricsShown ? "Open karaoke (↩)" : "Open karaoke (⌘K)",
                                label: "Karaoke", key: model.lyricsShown ? "↩" : "⌘K", isOn: focus, size: focus ? 26 : 20, palette: palette,
                                action: model.onKaraoke)
                    if !focus {
                        RoundButton(symbol: model.card ? "rectangle" : "rectangle.portrait", help: model.card ? "Switch to the wide layout (S)" : "Switch to the card layout (S)",
                                    label: model.card ? "Wide style" : "Card style", key: "S", palette: palette, action: model.onLayout)
                            .transition(.opacity)
                    }
                }
                .padding(focus ? 10 : 9)
                .modifier(FocusDim(on: focus))
                .transition(.opacity)
            }
        }
        .overlay {
            if model.dropTargeted {
                // A file or a link dragged over the HUD plays once dropped.
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.of(colorScheme).ink.opacity(0.08))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.dropTargeted)
        .animation(.smooth(duration: 0.3), value: model.saving == nil)
        .modifier(HUDBackground(tint: tint, scheme: colorScheme))
        .dropDestination(for: DroppedSong.self) { songs, _ in
            model.onOpen(songs.map(\.url))
            return !songs.isEmpty
        } isTargeted: { model.dropTargeted = $0 }
        .environment(\.recordRewinds, model.rewinds)
        .environment(\.songArriving, model.songArriving)
        .environment(\.recordActions, RecordActions(playPause: { model.onPlayPause() }, skip: { model.onSkip($0) }, scroll: model.scroll, scrub: model.scrub,
                                                    seek: { model.onSeekFraction($0) }, seekable: model.seekable))
        .environment(\.recordPlaying, model.playing)
        .environment(\.songLoop, model.loop)
        .environment(\.openURL, OpenURLAction { url in
            model.onLink(url)
            return .systemAction
        })
        .animation(.smooth(duration: 0.35), value: model.songArriving == nil)
        // A drag anywhere on the glass moves the panel (HUDPanel.sendEvent).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.glassFrame = $0 }
        .onHover { model.hovering = $0 }
        .animation(.snappy, value: model.phase)
        .animation(.snappy, value: model.picking)
        .animation(.snappy(duration: 0.25), value: model.shift)
        .animation(.snappy(duration: 0.25), value: model.relative)
        .animation(.snappy(duration: 0.2), value: model.keepKey)
        .animation(.smooth(duration: 0.4), value: model.key)
        .animation(.smooth(duration: 0.4), value: deckTrack?.song)
        .animation(.snappy(duration: 0.3), value: model.moved)
        .animation(.snappy(duration: 0.3), value: model.pending)
        .animation(.smooth(duration: 0.35), value: model.card)
        .animation(.snappy(duration: 0.3), value: model.relativeKeys)
        .animation(.snappy(duration: 0.3), value: model.lyricsShown)
        .animation(.snappy(duration: 0.3), value: model.stemsAvailable)
        .animation(.snappy(duration: 0.3), value: model.stemsOpen)
        // Karaoke is opened by a key or a click, so it shows almost at once instead of growing into place.
        .animation(.easeOut(duration: 0.12), value: model.lyricsFocus)
        .animation(.easeOut(duration: 0.15), value: model.keysActive)
        // The card is taller than the wide glass, so it grows up from where the bottom of the wide glass sits,
        // instead of reaching down toward the Dock. The stems open downward, which keeps the top of the card and its
        // corner buttons in place and the card inside the panel.
        .padding(.bottom, model.card && !focus ? HUDPanel.size.height / 2 - 150 - (cardStemsOpen ? Self.cardStemsGrowth : 0) : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.card && !focus ? .bottom : .center)
    }

    /// The key beside the record, with the hint bar along the bottom, which has Lock Key and Stop Pitch Change at
    /// its right end.
    private func wide(_ palette: Palette) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Takes any width that the hint bar adds, so the record keeps the same gap on both sides: the side
                // padding of the glass on its right, and the same from the divider on its left.
                Group {
                    if model.lyricsShown, showsStrip {
                        // The stems stay under the lyrics, which get shorter by as much, so the vocals can be muted
                        // while the lyrics show.
                        VStack(spacing: 10) {
                            LyricsPanel(state: model.lyrics, line: model.lyricLine, palette: palette, width: 470, height: lyricsHeight,
                                        downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped, waiting: model.lyricsWaiting, retry: model.onLyricsRetry,
                                        add: model.onLyricsEdit, edit: model.onLyricsEdit, showsFooter: false)
                            stems(palette)
                        }
                        .transition(.opacity)
                    } else {
                        main(palette)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                // The timing and the service of the lyrics, at the top right of this side, in the row of the close
                // button.
                .overlay(alignment: .topTrailing) {
                    if model.lyricsShown, showsStrip, case let .found(lyrics) = model.lyrics {
                        LyricsBadges(lyrics: lyrics, downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped, palette: palette)
                            .offset(y: -13)
                            .transition(.opacity)
                    }
                }
                if let track = deckTrack {
                    Rectangle()
                        .fill(palette.ink.opacity(0.1))
                        .frame(width: 1)
                        .padding(.leading, 30)
                        .transition(.opacity)
                    TurntableDeck(track: track, artwork: model.artwork, playing: model.playing, spinning: model.shown && model.playing,
                                  flash: model.playFlash, palette: palette)
                        .onHover { model.overRecord = $0 }
                        .padding(.leading, 30)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, showsStrip ? 16 : 22)

            if showsStrip, let key = model.key {
                HStack(spacing: 16) {
                    KeyHints(lyrics: model.lyricsShown, vocals: model.stemsAvailable, seek: model.seekable, restart: model.restartable, otherMode: key.minor != model.relative ? "major" : "minor", palette: palette)
                        .opacity(model.hintsOpacity)
                    Spacer(minLength: 0)
                    // The ? button sits as close to Lock Key as Stop Pitch Change does.
                    HStack(spacing: 6) {
                        PitchControls(model: model, palette: palette, small: true)
                        RoundButton(symbol: "questionmark", help: "Shortcuts (?)", isOn: model.shortcuts, size: HUDButton.questionSize, palette: palette) { model.shortcuts.toggle() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
                .background(palette.ink.opacity(0.04))
                .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.1)).frame(height: 1) }
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
                .transition(.opacity)
            }
        }
    }

    /// The title fills as the listen goes on, so there is no progress bar under it.
    private func main(_ palette: Palette) -> some View {
        VStack(spacing: 7) {
            VStack(spacing: 12) {
            TitleLine(model: model, palette: palette)
            if model.phase == .idle {
                IdleActions(model: model, palette: palette)
                    .transition(.opacity)
            }
            if model.pending ?? model.heard != nil {
                ShiftPills(model: model, palette: palette)
                    .padding(.top, -6)
            }
            if showsStrip, let key = model.key {
                KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys, flipped: model.flipped != model.relative,
                          palette: palette, select: model.onShift)
                    // The row still has the last song's keys while a new song waits for its key.
                    .opacity(model.pending == nil ? 1 : 0.4)
                    .allowsHitTesting(model.pending == nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
            if showsWaveform(.ribbon) {
                waveform(palette, width: Self.keyRowWidth - 14, height: 40)
                    .transition(.opacity)
            }
            }
            // The key sits in the middle of the space above the stems.
            .frame(maxHeight: .infinity)
            // The stems stay at the bottom of this column, beside the record, so they don't make the glass taller.
            stems(palette)
        }
        // The strip grows up from the hints bar across the whole column, behind the stems and their button.
        .background(alignment: .bottom) {
            if showsWaveform(.strip) {
                GeometryReader { column in
                    waveform(palette, width: column.size.width + 40, height: 30)
                        .frame(width: column.size.width + 40, height: 30)
                        .offset(x: -20, y: column.size.height - 30 + 16)
                }
                .transition(.opacity)
            }
        }
    }

    /// The waveform shows in `style` while a song with a length plays and the key row shows.
    private func showsWaveform(_ style: WaveformStyle) -> Bool {
        showsStrip && model.key != nil && model.waveformShown && model.waveformStyle == style && deckTrack?.duration != nil && model.phase != .idle
    }

    private func waveform(_ palette: Palette, width: CGFloat, height: CGFloat) -> some View {
        WaveformHost(wave: model.wave, track: deckTrack, style: model.waveformStyle, width: width, height: height, ticking: model.shown && model.playing,
                     bpm: model.shownTempo?.bpm, muted: model.stemsMuted, loop: model.loop, setLoop: model.onLoopSet, typing: model.onLoopTyping, palette: palette)
    }

    /// Karaoke: the lyrics large in a glass as tall as the screen allows, with the key at the top and the record
    /// rising from the bottom edge. The key turns into the key row while the pointer is over it, and the cover in the
    /// middle of the record shows the instruments and vocals. With no song playing there is no record, and the hints
    /// sit under the lyrics, dimmed until the pointer is over them.
    private func lyricsFocus(_ palette: Palette) -> some View {
        let track = deckTrack
        return VStack(spacing: 0) {
            // The key's place in the top row, which the overlay fills.
            Color.clear.frame(height: Self.focusRowHeight).padding(.top, Self.focusRowTop)
            GeometryReader { space in
                LyricsPanel(state: model.lyrics, line: model.lyricLine, palette: palette, width: Self.focusLyricsWidth, height: space.size.height, large: true,
                            downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped, waiting: model.lyricsWaiting,
                            rewind: model.karaokeCountdown, retry: model.onLyricsRetry, add: model.onLyricsEdit, edit: model.onLyricsEdit)
                    .overlay { if track == nil { PlayFlashView(flash: model.playFlash, size: 80) } }
            }
            .frame(width: Self.focusLyricsWidth)
            .padding(.top, 8)
            if let track {
                KaraokeRecord(track: track, artwork: model.artwork, spinning: model.shown && model.playing, flash: model.playFlash, side: recordSide,
                              width: Self.focusWidth, palette: palette, hoverLabel: { karaokeHover($0, \.karaokeStems, $stemsCollapse) }) {
                    karaokeFooter
                }
                .overlay(alignment: .bottom) { karaokeStems(palette) }
                .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    if let track = deckTrack {
                        Text([track.title, track.artist].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: Self.focusLyricsWidth)
                    }
                    // FocusDim makes these faint without the pointer, so they get no second dim.
                    KeyHints(lyrics: true, focus: true, vocals: model.stemsAvailable, seek: model.seekable, restart: model.restartable, karaokeKeys: model.karaokeKeys, otherMode: otherMode,
                             palette: palette)
                }
                .modifier(FocusDim(on: true))
                // Without the record, the song and the hints show the instruments and vocals.
                .onHover { karaokeHover($0, \.karaokeStems, $stemsCollapse) }
                .overlay(alignment: .bottom) { karaokeStems(palette).padding(.bottom, 40) }
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(width: Self.focusWidth, height: focusHeight)
        .overlay(alignment: .top) { karaokeKey(palette).padding(.top, Self.focusRowTop) }
        .overlay { if track != nil { karaokeTransport(palette) } }
    }

    /// Karaoke's playback buttons, in a pill of their own between the lyrics and the record, which doesn't hold them,
    /// since its cover shows the instruments and vocals.
    private func karaokeTransport(_ palette: Palette) -> some View {
        KaraokeTransport(size: 30, ink: palette.ink)
            .padding(.horizontal, 4)
            .background(Capsule().fill(palette.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(palette.ink.opacity(0.1), lineWidth: 0.5))
            .modifier(FocusDim(on: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, KaraokeRecord<EmptyView>.height(side: recordSide) + 2)
    }

    /// The mode that Option picks keys in: the one that the key row hides.
    private var otherMode: String { model.key.map { $0.minor != model.relative ? "major" : "minor" } ?? "" }

    /// The hints along the bottom edge of the record, no wider than the record: the keys of the lyrics, or the keys
    /// that change the key while the key row shows.
    private var karaokeFooter: some View {
        KeyHints(style: .footer, lyrics: true, focus: true, vocals: model.stemsAvailable, seek: model.seekable, restart: model.restartable, karaokeKeys: model.karaokeKeys, otherMode: otherMode,
                 palette: Palette.of(.dark))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 5)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                    .fill(Color(white: 0.06).opacity(0.75))
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 8) }
            }
            .environment(\.colorScheme, .dark)
            .opacity(model.hintsOpacity)
    }

    /// The key in the top row, which turns into the key row while the pointer is over it.
    /// The key at the top of karaoke, which opens the key row while the pointer is over it. With the instruments
    /// model, the Vocals pill sits under the key, and the key row takes the pill's place while it is open. Only the
    /// key opens the row, never the pill.
    private func karaokeKey(_ palette: Palette) -> some View {
        let pill = model.stemsAvailable && showsStrip
        return VStack(spacing: 6) {
            ZStack(alignment: .top) {
                if model.karaokeKeys, !pill, let key = model.key {
                    karaokeKeyRow(key, palette)
                } else {
                    TitleLine(model: model, palette: palette, symbolSize: 13, keySize: 15, relativeSize: 11, listeningSize: 15)
                        .frame(height: Self.focusRowHeight)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                        .opacity(0.75)
                        .transition(.opacity)
                }
            }
            .onHover { karaokeHover($0, \.karaokeKeys, $keysCollapse) }
            if pill {
                if model.karaokeKeys, let key = model.key {
                    karaokeKeyRow(key, palette)
                        .onHover { karaokeHover($0, \.karaokeKeys, $keysCollapse) }
                } else {
                    KaraokeVocalsPill(muted: model.stemsMuted.contains(.vocals), hudHovered: model.hovering, palette: palette, action: model.onVocals)
                        .transition(.opacity)
                }
            }
        }
    }

    private func karaokeKeyRow(_ key: DetectedKey, _ palette: Palette) -> some View {
        KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys, flipped: model.flipped != model.relative,
                  palette: palette, select: model.onShift)
            // A new song still waits for its key.
            .opacity(model.pending == nil ? 1 : 0.4)
            .allowsHitTesting(model.pending == nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(KaraokePopup())
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    /// The instruments and vocals over the record's cover while the pointer is over it, or the button that separates
    /// them. The number keys mute and solo them without the pointer there too.
    @ViewBuilder private func karaokeStems(_ palette: Palette) -> some View {
        if model.karaokeStems, showsStrip, model.stemsAvailable {
            Group {
                if model.stemsOpen {
                    StemsRow(model: model, palette: palette, compact: true)
                        .frame(width: Self.keyRowWidth)
                } else {
                    SeparateButton(palette: palette, action: model.onSeparate)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(KaraokePopup())
            .padding(.bottom, 30)
            .onHover { karaokeHover($0, \.karaokeStems, $stemsCollapse) }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        }
    }

    /// Shows a part of karaoke while the pointer is over its spot, and hides it a moment after the pointer leaves, so
    /// that the pointer can move from the spot onto what it shows.
    private func karaokeHover(_ inside: Bool, _ flag: ReferenceWritableKeyPath<HUDModel, Bool>, _ collapse: Binding<Task<Void, Never>?>) {
        collapse.wrappedValue?.cancel()
        if inside {
            guard !model[keyPath: flag] else { return }
            withAnimation(.snappy(duration: 0.2)) { model[keyPath: flag] = true }
        } else {
            collapse.wrappedValue = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.2)) { model[keyPath: flag] = false }
            }
        }
    }

    /// The record fills the glass's width, short of the corners that hold the times, and leaves the lyrics at least
    /// 300 points on a short screen.
    private var recordSide: CGFloat { min(540, max(360, (focusHeight - 340) * 2)) }

    private static let focusRowTop: CGFloat = 10
    private static let focusRowHeight: CGFloat = 26
    private static var focusWidth: CGFloat { focusLyricsWidth + 56 }

    /// The large lyrics fill the screen's height, with a margin, up to a height that still reads as one glass.
    private var focusHeight: CGFloat { min(Self.focusMaxHeight, max(560, model.screenHeight - 2 * HUDPanel.screenMargin)) }
    static let focusMaxHeight: CGFloat = 1000
    private static let focusLyricsWidth: CGFloat = 600

    /// The Separate instruments and vocals button, or the stems in its place, under the keys or the lyrics.
    @ViewBuilder private func stems(_ palette: Palette) -> some View {
        if showsStrip, model.stemsAvailable {
            if model.stemsOpen {
                StemsRow(model: model, palette: palette, compact: true)
                    .frame(width: Self.keyRowWidth)
                    .transition(.opacity)
            } else {
                SeparateButton(palette: palette, action: model.onSeparate)
                    // Quiet until the pointer is over it, so the keys read first.
                    .modifier(FocusDim(on: true))
                    .transition(.opacity)
            }
        }
    }

    /// The lyrics in the wide layout keep the glass at the same height with the stems or the button under them.
    private var lyricsHeight: CGFloat {
        guard model.stemsAvailable else { return 250 }
        // The stems are smaller while the pointer is away from the HUD, and the lyrics take the room that they leave.
        return model.stemsOpen ? 250 - (model.keysActive ? Self.stemsRowHeight : Self.compactStemsRowHeight) : 250 - Self.separateButtonHeight
    }

    private static let stemsRowHeight: CGFloat = 106
    private static let compactStemsRowHeight: CGFloat = 72
    private static let separateButtonHeight: CGFloat = 34

    /// The width of the key row, which the stems under it match.
    private static let keyRowWidth: CGFloat = 466
}

/// The glass of the key row and the instruments that karaoke shows over the lyrics and the record.
private struct KaraokePopup: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        shape.fill(scheme == .dark ? Color(white: 0.13).opacity(0.96) : Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.97))
            .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.08 : 0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

/// Everything around the large lyrics fades back until the pointer is over it, and so do the busy buttons of the
/// layouts.
struct FocusDim: ViewModifier {
    let on: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .opacity(on && !hovering ? 0.3 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.25), value: on)
    }
}

/// How the HUD glass gets its warmth. `.tint()` colours the glass itself, so a pale tint vanishes and a saturated one
/// reads as a coloured button. Instead, a translucent base layer and a soft glow are painted inside regular glass.
struct Tint: Hashable {
    var baseLight = 0.38
    var baseDark = 0.45
    var glow = 0.6
    var tone = 0.3

    static let current = Tint()
}

struct HUDBackground: ViewModifier {
    let tint: Tint
    let scheme: ColorScheme
    @Environment(\.renderingPreview) private var renderingPreview

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
    // Warm skin tones in light mode, near black warmed with ember in dark mode.
    private static let flesh = rgb(0.97, 0.89, 0.84)
    private static let peach = rgb(0.95, 0.72, 0.62)
    private static let ember = rgb(0.36, 0.09, 0.15)

    private var dark: Bool { scheme == .dark }

    private func color(_ color: Color, _ opacity: Double, glow: Bool = true) -> Color {
        color.mix(with: dark ? .black : .white, by: tint.tone).opacity(min(1, opacity * (glow ? tint.glow : 1)))
    }

    private func radial(_ color: Color, _ center: UnitPoint, _ radius: CGFloat) -> RadialGradient {
        RadialGradient(colors: [color, .clear], center: center, startRadius: 0, endRadius: radius)
    }

    private var base: Color {
        dark ? Color.black.opacity(tint.baseDark) : color(Self.flesh, tint.baseLight, glow: false)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26)
        let painted = content.background { layers(shape).opacity(0.5).brightness(dark ? -0.4 : 0.4) }
        if renderingPreview {
            // ImageRenderer draws neither glass nor what sits inside it, so previews put the layers on a flat stand-in.
            painted.background(shape.fill(Color(white: dark ? 0.2 : 0.97)))
        } else {
            painted.glassEffect(.regular, in: shape)
        }
    }

    private func layers(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(base)
            shape.fill(radial(dark ? color(Self.ember, 0.55) : color(Self.peach, 0.55), .bottomLeading, 300))
        }
    }
}

/// The first click on a button in the HUD acts on it, instead of only making the panel key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

final class HUDPanel: NSPanel {
    /// Tall enough for the large lyrics at their tallest, and for the single card with the stems, which grows up
    /// from where the bottom of the wide glass sits.
    static let size = CGSize(width: 900, height: HUDView.focusMaxHeight + 100)
    /// The glass stays at least this far inside the visible part of its screen.
    static let screenMargin: CGFloat = 12

    /// Only while a key is being picked, so Esc and the arrow keys reach the HUD. The panel is non-activating,
    /// so the app in front stays in front.
    private var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard }
    private let model: HUDModel

    init(model: HUDModel) {
        self.model = model
        // Room for the key picker and the record; the transparent margin around the glass lets clicks through.
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FirstClickHostingView(rootView: HUDView(model: model))
    }

    /// `clickable` for a result with a Change Key button, `keyboard` while a key is being picked.
    /// The panel stops being key when it is ordered out after the fade.
    func setInteraction(clickable: Bool, keyboard: Bool) {
        wantsClicks = clickable
        watchPointer(clickable)
        updatePassThrough()
        takesKeyboard = keyboard
        if keyboard { makeKey() }
    }

    /// The panel takes the mouse only while the pointer is over the glass. The window server lets left clicks through
    /// the clear margin around the glass, but not right clicks, which then did nothing anywhere under the panel, and
    /// the pointer over the margin counted as over the HUD, which took its keys.
    private var wantsClicks = false
    private var pointerMonitors: [Any] = []

    func updatePassThrough() {
        // While the button is held after a press on the glass, the panel keeps the mouse, since a fast drag can take
        // the pointer past the edge of the glass before the panel catches up with it.
        let ignore = pressStart == nil && !(wantsClicks && overGlass(NSEvent.mouseLocation))
        if ignoresMouseEvents != ignore { ignoresMouseEvents = ignore }
    }

    /// A control that a drag along it moves, like the bar with the song's time, sets this while its drag runs, so
    /// that the drag doesn't move the panel instead.
    static var controlTracksDrag = false
    /// Where the pointer and the panel were when the mouse button went down on the glass.
    private var pressStart: (mouse: NSPoint, origin: NSPoint)?
    private var draggingPanel = false
    /// For the log: what the press landed on, when it went down, and whether a drag event came after it.
    private var pressHit = ""
    private var pressedAt = Date.distantPast
    private var pressDragged = false
    var log: (String) -> Void = { _ in }
    /// Runs on each move of the pointer while the panel takes clicks.
    var pointerMoved: () -> Void = {}

    /// The press is on the time bar, a little taller than the bar, which seeks with its drag.
    private func onTimeBar(_ event: NSEvent) -> Bool {
        guard let view = contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.contains { $0.region.seeks && $0.frame.insetBy(dx: -2, dy: -4).contains(point) }
    }

    /// A drag that starts anywhere on the glass moves the panel once the pointer has moved a few points, also from
    /// a button, the key or the record. SwiftUI's window drag gesture never moved this non-activating panel.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            Self.controlTracksDrag = false
            draggingPanel = false
            // Text fields, scroll bars and the time bar keep their drags.
            let hit = contentView?.hitTest(event.locationInWindow)
            let onBar = onTimeBar(event)
            pressStart = hit is NSControl || hit is NSText || onBar ? nil : (NSEvent.mouseLocation, frame.origin)
            pressHit = onBar ? "the time bar" : hit.map { String(describing: type(of: $0)).components(separatedBy: "<").first ?? "" } ?? "nothing"
            pressedAt = Date()
            pressDragged = false
        case .leftMouseDragged:
            if !pressDragged {
                pressDragged = true
                log("HUD drag: pressed on \(pressHit), " + (pressStart == nil ? "which keeps the drag" : "the panel follows the drag"))
            }
            guard let start = pressStart, !Self.controlTracksDrag else { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
            if !draggingPanel {
                guard hypot(dx, dy) >= 4 else { break }
                draggingPanel = true
                // The drag sets the new place, so a move that kept the glass on the screen is forgotten.
                pushed = .zero
                heading = nil
            }
            setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
            return
        case .leftMouseUp:
            pressStart = nil
            // A press held this long is usually a drag, so a press without a single drag event means that the
            // system never sent the drag to the panel.
            if !pressDragged, Date().timeIntervalSince(pressedAt) > 0.4 {
                log(String(format: "HUD drag: pressed on %@ for %.1f s, with no drag events", pressHit, Date().timeIntervalSince(pressedAt)))
            }
            guard draggingPanel else { break }
            draggingPanel = false
            // The button or the record under the pointer would take this release as a click. SwiftUI gets it far
            // outside the panel instead, which ends the press without one.
            let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10000, y: -10000), modifierFlags: event.modifierFlags,
                                             timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                             eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0)
            if let outside { super.sendEvent(outside) }
            updatePassThrough()
            return
        default: break
        }
        super.sendEvent(event)
    }

    private func overGlass(_ point: NSPoint) -> Bool {
        let glass = model.glassFrame
        guard !glass.isEmpty else { return true }
        // The glass frame is in the window's coordinates, from its top left.
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        return glass.insetBy(dx: -4, dy: -4).contains(local)
    }

    /// The pointer moves over other apps while the panel lets it through, and over the panel while it doesn't.
    private func watchPointer(_ on: Bool) {
        guard on != !pointerMonitors.isEmpty else { return }
        if on {
            acceptsMouseMovedEvents = true
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            pointerMonitors = [
                NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                    self?.updatePassThrough()
                    self?.pointerMoved()
                },
                NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                    self?.updatePassThrough()
                    self?.pointerMoved()
                    return event
                },
            ].compactMap { $0 }
        } else {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors = []
        }
    }

    func present() {
        // Already up: leave it where it is, even if the pointer has moved to another screen or the glass was dragged.
        guard !isVisible || alphaValue < 1 else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        pushed = .zero
        heading = nil
        if let visible = screen?.visibleFrame {
            // Where it was dragged to last, on the screen with the pointer, and kept on that screen below.
            let home = Self.home(on: visible, size: frame.size)
            let dragged = Self.dragged
            setFrameOrigin(NSPoint(x: home.x + dragged.dx, y: home.y + dragged.dy))
            if model.screenHeight != visible.height { model.screenHeight = visible.height }
        }
        keepOnScreen(animated: false)
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    /// Where the panel is headed while it moves there.
    private var heading: NSRect?
    /// How far the panel was moved to keep a growing glass on the screen, or to centre karaoke on it. It moves back
    /// once the glass fits where it was, as when karaoke closes.
    private var pushed = CGVector.zero
    /// Karaoke was dragged, and stays where it was dropped instead of being centred again.
    private var karaokeDragged = false

    /// The glass on the screen with the panel at `frame`, from where SwiftUI last laid it out in the panel.
    private func glassOnScreen(in frame: NSRect) -> CGRect? {
        let glass = model.glassFrame
        guard glass.width > 0, glass.height > 0 else { return nil }
        return CGRect(x: frame.minX + glass.minX, y: frame.maxY - glass.maxY, width: glass.width, height: glass.height)
    }

    /// The screen that holds most of the glass.
    private func screen(holding glass: CGRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(glass)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let best = NSScreen.screens.max { overlap($0) < overlap($1) }
        return best.flatMap { overlap($0) > 0 ? $0 : nil } ?? screen ?? NSScreen.main
    }

    /// Moves the panel so the whole glass is on the screen that holds most of it, when the glass grows, as the large
    /// lyrics do, and back to where it was once the glass shrinks. The large lyrics are sized for that screen, and
    /// karaoke opens in the middle of it, unless it was dragged since it opened. `start` is the place to keep on the
    /// screen in place of where the panel would be without its push.
    func keepOnScreen(animated: Bool, from start: NSRect? = nil) {
        if !model.lyricsFocus { karaokeDragged = false }
        let base = heading ?? frame
        let home = start ?? base.offsetBy(dx: -pushed.dx, dy: -pushed.dy)
        guard let glass = glassOnScreen(in: home), let screen = screen(holding: glass) else { return }
        let visible = screen.visibleFrame
        if model.screenHeight != visible.height { model.screenHeight = visible.height }
        // Only once the glass has karaoke's size: it is at least 560 points tall, and the other layouts never are.
        let centred = model.lyricsFocus && !karaokeDragged && glass.height >= 540
            ? CGVector(dx: visible.midX - glass.midX, dy: visible.midY - glass.midY) : .zero
        let inside = Self.offset(keeping: glass.offsetBy(dx: centred.dx, dy: centred.dy), inside: visible, margin: Self.screenMargin)
        let move = CGVector(dx: centred.dx + inside.dx, dy: centred.dy + inside.dy)
        pushed = move
        let target = home.offsetBy(dx: move.dx, dy: move.dy)
        guard target != base else { return }
        guard animated else {
            heading = nil
            return setFrame(target, display: true)
        }
        heading = target
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            if self?.heading == target { self?.heading = nil }
        })
    }

    /// A glass dropped partly off the screen moves fully onto it, and stays there as its new place.
    func settleAfterDrag() {
        if model.lyricsFocus { karaokeDragged = true }
        pushed = .zero
        heading = nil
        keepOnScreen(animated: true)
        pushed = .zero
        // Karaoke opens in the middle of the screen each time, so only a drag of the other layouts is kept.
        let target = heading ?? frame
        guard !model.lyricsFocus, let glass = glassOnScreen(in: target), let visible = screen(holding: glass)?.visibleFrame else { return }
        let home = Self.home(on: visible, size: frame.size)
        Self.dragged = CGVector(dx: target.minX - home.x, dy: target.minY - home.y)
    }

    /// ⌘⌥C: the HUD moves back to where it opens when it was never dragged, at the bottom centre of the screen that
    /// holds most of the glass, and forgets the place it was dragged to. Karaoke and the large lyrics are pushed from
    /// there as usual, so karaoke ends in the middle of the screen and the HUD comes back home when it closes.
    func returnHome() {
        Self.dragged = .zero
        karaokeDragged = false
        guard let glass = glassOnScreen(in: heading ?? frame), let visible = screen(holding: glass)?.visibleFrame else { return }
        let home = NSRect(origin: Self.home(on: visible, size: frame.size), size: frame.size)
        pushed = .zero
        log("HUD back to its home")
        keepOnScreen(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, from: home)
    }

    /// The glass centred in the panel, at the same height as when the panel was 240 points tall: the place of a HUD
    /// that was never dragged.
    private static func home(on visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.14 + 120 - size.height / 2)
    }

    /// How far the HUD was dragged from its home, which it opens at the next time, on any screen.
    private static var dragged: CGVector {
        get {
            let values = UserDefaults.standard.array(forKey: "hudDragged") as? [Double] ?? []
            return values.count == 2 ? CGVector(dx: values[0], dy: values[1]) : .zero
        }
        set { UserDefaults.standard.set([Double(newValue.dx), Double(newValue.dy)], forKey: "hudDragged") }
    }

    /// How far `glass` has to move to sit inside `visible`, `margin` points from its edges, in screen points with y
    /// going up. A glass taller or wider than that keeps its top or its left edge inside.
    static func offset(keeping glass: CGRect, inside visible: CGRect, margin: CGFloat) -> CGVector {
        let area = visible.insetBy(dx: margin, dy: margin)
        func shift(_ low: CGFloat, _ high: CGFloat, within min: CGFloat, _ max: CGFloat, keepHigh: Bool) -> CGFloat {
            if high - low > max - min { return keepHigh ? max - high : min - low }
            if low < min { return min - low }
            if high > max { return max - high }
            return 0
        }
        return CGVector(dx: shift(glass.minX, glass.maxX, within: area.minX, area.maxX, keepHigh: false),
                        dy: shift(glass.minY, glass.maxY, within: area.minY, area.maxY, keepHigh: true))
    }

    func fadeOut(then completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; animator().alphaValue = 0 }, completionHandler: completion)
    }
}

/// Stays running with no Dock icon. The hotkey starts a listen, cancels a listen in progress, or closes the result.
/// A result can start a pitch change, which keeps running after the HUD closes.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let delegate = AppDelegate()

    static func main() {
        if TestFlags.has("--selftest") { exit(PitchSelfTest.run()) }
        if let path = TestFlags.value("--stems-cache") { exit(CachedStemsTest.runFile(path, speed: TestFlags.value("--speed").flatMap(Double.init) ?? 1)) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// The key picker is `model.picking`, on top of any of these: it can open on the first estimate of a listen.
    private enum State { case idle, listening, showing }

    private let model = HUDModel()
    private lazy var panel: HUDPanel = {
        let panel = HUDPanel(model: model)
        panel.log = { [weak self] in self?.log($0) }
        panel.pointerMoved = { [weak self] in self?.checkClipboard() }
        return panel
    }()
    /// When the clipboard was last checked for ⌘V over the HUD.
    private var clipboardCheckedAt = Date.distantPast

    /// Something copied while the pointer rests on the HUD turns ⌘V on or off there, from the pointer's next move.
    private func checkClipboard() {
        guard !hoverKeys.isEmpty, Date().timeIntervalSince(clipboardCheckedAt) > 0.25 else { return }
        clipboardCheckedAt = Date()
        if NSPasteboard.general.changeCount != hoverKeysPasteboard { updateHoverKeys() }
    }
    private var hotKey: HotKey?
    private var state = State.idle
    // Bumped whenever a listen starts or ends, so late callbacks from a cancelled one are dropped.
    private var session = 0
    private var tap: SystemAudioTap?
    private var analyzer: KeyAnalyzer?
    private var ticker: Timer?
    private var startedAt = Date()
    /// The song played at some point of the listen, so a pause holds the listen instead of ending it.
    private var listenHeardPlaying = false
    /// When the song of the listen paused, which stopped the recording until it plays again, and that song.
    private var listenPausedAt: Date?
    private var listenPausedSong: [String?]?
    /// The sample rate that the listen's analyzer takes.
    private var listenTapRate: Double = 0
    private var peak: Float = 0
    /// The peak comes with each estimate, so before the first one a quiet listen can't be told from a late start.
    private var estimated = false

    private let pitch = PitchChanger(recordTo: stringOption("--shift-wav"))
    /// A song from another player slowed down, and the song as it is heard while it is.
    private lazy var slow = SlowStream(pitch: pitch)
    /// The player whose song is slowed down: another player taking over stops the slowing.
    private var slowedPlayer: String?
    /// The speed that a slowed song had before it was recorded for a save, which it gets back after it.
    private var speedBeforeRecording: Double?
    /// The player whose song Muskey had to stop slowing, while the red tempo pill shows it.
    private var slowFailedPlayer: String?
    private let statusItem = StatusItem()
    /// The key the running pitch change starts from, kept for the menu bar item after the HUD shows another listen.
    private var shiftBase: DetectedKey?
    /// The key of the song that plays, in the song's own key, for the menu bar: from a listen, from the keys
    /// remembered by song, from Always listening, or from Noiseblend. `song` is the song that Now Playing named, nil
    /// when it named none, `final` is false for an estimate that the end of the listen can still change, and `online`
    /// is true for a key that Noiseblend gave and no listen confirmed yet.
    private var songKey: (song: [String?]?, key: DetectedKey, final: Bool, online: Bool)? {
        didSet {
            if songKey?.key != oldValue?.key { log("menu bar: \(songKey.map(\.key.name) ?? "turntable")") }
            updateWatching(shown: model.shown)
            refreshStatus()
        }
    }

    /// The key that the song is heard in now, with the pitch change, as the menu bar shows it.
    private var currentKey: DetectedKey? {
        songKey.map { model.shown($0.key.transposed(by: model.shift)) }
    }

    // Always listening: a listen without the HUD for each song that plays with no key known.
    private var autoTap: SystemAudioTap?
    private var autoAnalyzer: KeyAnalyzer?
    private var autoSession = 0
    private var autoSong: [String?]?
    /// Listens that each song got without finding a key, so that a song that stays silent isn't listened to over
    /// and over.
    private var autoTries: [[String?]: Int] = [:]
    /// Clears the menu bar's key when Now Playing names no song for 2 seconds.
    private var noSong: DispatchWorkItem?

    private let nowPlaying = NowPlaying()
    /// Plays the files and links that Muskey opens, through Muskey Player.
    private let filePlayer = FilePlayer()
    /// Separates the whole song that Muskey Player plays into the cache, the first time that its stems are used.
    private let stemsCache = StemsCacheBuilder()
    private var cacheSweeper: Timer?
    private static let cacheSweepQueue = DispatchQueue(label: "Muskey cache cleanup", qos: .utility)
    /// The song whose stems were looked up in the cache last. It is looked up again for another song, or once its
    /// separation is done.
    private var stemsCacheLooked: String?
    /// Songs whose whole separation failed, which aren't separated whole again until Muskey quits.
    private var stemsCacheFailed: Set<String> = []
    private let activityPill = ActivityPill()
    private lazy var locationPanel: OpenLocationPanel = {
        let panel = OpenLocationPanel()
        panel.onOpen = { [weak self] url in self?.open([url]) }
        if Self.logKeys { panel.onLog = { [weak self] in self?.log($0) } }
        // The HUD takes the keyboard back while a key is picked, and the app that was in front otherwise.
        panel.onClose = { [weak self] in
            guard let self else { return }
            dialogOpen = false
            if model.picking, self.panel.isVisible { return self.panel.makeKey() }
            if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
               let lastOtherApp, lastOtherApp != .current { lastOtherApp.activate() }
        }
        return panel
    }()
    /// Files opened before the app finished launching, as with Open With.
    private var openedEarly: [URL]?
    private var launched = false
    /// The key that every song gets moved to when it starts playing: set while Lock Key is on, from the key that
    /// was heard when a key was picked or Lock Key was turned on.
    private var keptKey: DetectedKey? {
        didSet {
            // The button shows the lock itself, so it is never red while no key is locked, as after a relaunch.
            model.keepKey = keptKey != nil
            updateWatching(shown: model.shown)
            refreshStatus()
        }
    }
    private var shownChange: AnyCancellable?
    private var glassChange: AnyCancellable?
    private var karaokeChange: AnyCancellable?
    /// When karaoke last opened or closed.
    private var focusChangedAt = Date.distantPast
    private var glyphSheet: NSWindow?
    private var backdropChange: AnyCancellable?
    /// Blurs and dims the screen around the karaoke glass, and a click on it closes karaoke.
    private lazy var karaokeBackdrop: KaraokeBackdrops = {
        let backdrop = KaraokeBackdrops()
        backdrop.onClick = { [weak self] in
            guard let self, model.lyricsFocus else { return }
            log("click outside karaoke")
            toggleKaraoke()
        }
        return backdrop
    }()
    private var dragSettle: DispatchWorkItem?

    /// A drag can leave part of the glass off the screen. Once the mouse button is up, the panel moves it back.
    private func panelMoved(tries: Int = 0) {
        dragSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Checked every 0.15 seconds while the button is down, for up to 90 seconds.
            if NSEvent.pressedMouseButtons & 1 != 0, tries < 600 { return panelMoved(tries: tries + 1) }
            panel.settleAfterDrag()
            log("the HUD was dragged to a new place")
        }
        dragSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settle)
    }

    /// The helper runs while the HUD is up, for the record, and for the song changes while a key is kept, while the
    /// menu bar shows a song's key, and with Always listening. It stays up when the HUD closes with a key kept, since
    /// starting it again would count the song as a new one.
    private func updateWatching(shown: Bool) {
        // While the stems or the lyrics delay play, a pause has to be heard at once, so the helper keeps telling.
        // A song that Muskey Player plays faster or slower keeps its pitch correction only while it is the one that plays.
        nowPlaying.watching = keptKey != nil || shown || songKey != nil || prefs.alwaysListen || model.stemsEngaged || lyricsDelayed
            || filePlayer.speed != 1 || songRecording != nil || slow.active || (prefs.pauseStop && changesRun)
    }

    /// A pitch change, a tempo change or the stems run, which the pause timeout stops.
    private var changesRun: Bool {
        pitch.running || model.shift != 0 || keptKey != nil || model.pending != nil || model.stemsEngaged || model.stemsAdjusted
            || currentSpeed != 1 || slow.active
    }

    /// Settings > General > Pause timeout: once the song has been paused that long with the HUD hidden, the pitch change,
    /// the tempo change and the stems stop, as Stop Pitch Change and the original tempo would have them. Lock Key is
    /// released too, and nothing comes back when the song plays again.
    private var pauseStopWork: DispatchWorkItem?

    private var pauseStopWaits: Bool {
        prefs.pauseStop && !model.shown && !(nowPlaying.player?.playing ?? false) && changesRun && songRecording == nil
            && saveJob == nil && karaokeRestart == nil
    }

    private func syncPauseStop() {
        updateWatching(shown: model.shown)
        guard pauseStopWaits else {
            pauseStopWork?.cancel()
            pauseStopWork = nil
            return
        }
        guard pauseStopWork == nil else { return }
        let seconds = prefs.pauseStopSeconds
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pauseStopWork = nil
            guard pauseStopWaits else { return }
            stopAfterPause(seconds)
        }
        pauseStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func stopAfterPause(_ seconds: Int) {
        let stopped = [
            model.shift != 0 || keptKey != nil ? String(format: "the pitch change (%+d)", model.shift) : nil,
            currentSpeed != 1 ? String(format: "the tempo change (%.0f %%)", currentSpeed * 100) : nil,
            model.stemsEngaged || model.stemsAdjusted ? "the stems" : nil,
        ].compactMap { $0 }
        log("paused for \(seconds) s with the HUD hidden, stopping \(stopped.isEmpty ? "the pitch change" : stopped.joined(separator: ", "))")
        // A slowed song's player is up to 30 seconds ahead of what was heard, so it moves back to the moment heard
        // before the slowing stops, and plays on from there. A player that is already there isn't moved.
        if slow.active, let heard = nowPlaying.track, let player = nowPlaying.player, heard.song == player.song,
           let at = heard.position(at: Date()), (player.position(at: Date()).map { $0 - at > 0.5 } ?? true) {
            slow.stop("the song was paused with the HUD hidden")
            log(String(format: "the player moves back to %.1f s, where the song was heard", at))
            movePlayer(player, to: at)
        } else {
            slow.stop("the song was paused with the HUD hidden")
        }
        if filePlayer.speed != 1 { filePlayer.setSpeed(1) }
        if !model.stemVolumes.isEmpty {
            model.stemVolumes = [:]
            pitch.stemVolumes = [:]
        }
        syncSpeed()
        stopPitch()
        // The separation of the whole song into the cache stops too, and starts again the next time the stems are used.
        stemsCache.cancel()
        refreshStatus()
    }

    /// The stems play seconds behind the song, so they hold where they are while the player pauses it. A track
    /// with no title, or no track, counts as playing, so a player that doesn't report never holds the stems.
    private func syncPaused() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return pitch.paused = false }
        if let guess = playGuess {
            // A report from before the player took the command would undo the change that Space made.
            guard guess.playing == track.playing else { return }
            playGuess = nil
            playGuessCheck?.cancel()
        }
        // A slowed song holds at a pause, but some players (Safari) report a pause and a play within a fraction of a
        // second around a move that Muskey sent. A pause right after a move holds the output only once it lasts.
        if !track.playing, !pitch.paused, slow.movedRecently {
            if pauseDeferredUntil == nil {
                pauseDeferredUntil = Date().addingTimeInterval(0.6)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.syncPaused() }
            }
            if let until = pauseDeferredUntil, Date() < until { return }
        }
        pauseDeferredUntil = nil
        if pitch.paused == track.playing, Self.logKeys || pitch.stemsEngaged { log(track.playing ? "song plays" : "song paused") }
        if !track.playing {
            // A move during the pause: the stems from the cache wait for the song at its new place, from the moment it
            // plays again.
            if cachedStems, let (song, position) = pausedAt, song == track.song, let position, let now = track.position(at: Date()), abs(now - position) > 2 {
                log(String(format: "the song moved to %.1f s during the pause", now))
                pitch.cachedSeek(to: now)
                pausedAt = (song, now)
            }
            pausedAt = pausedAt ?? (track.song, track.position(at: Date()))
        } else if let (song, position) = pausedAt {
            pausedAt = nil
            // Another song, or a seek, during the pause: the held stems belong to the moment before it.
            let moved = zip([position], [track.position(at: Date())]).contains { old, new in abs((old ?? 0) - (new ?? 0)) > 2 }
            if song != track.song || moved {
                log("the song changed during the pause, the stems start over")
                pitch.restartStems()
            }
        }
        pitch.paused = !track.playing
    }

    /// The song and its position when the player paused it.
    private var pausedAt: ([String?], Double?)?
    /// A pause reported right after a move, which holds the output only from this moment on.
    private var pauseDeferredUntil: Date?

    /// Space over the HUD plays or pauses the song, as the play key does. The record, the tonearm and the stems
    /// change right away, before the player reports the change, and a glyph on the record confirms it.
    private func playPause() {
        if model.phase == .idle {
            log("nothing plays: play")
            nowPlaying.play(true)
            return start()
        }
        nowPlaying.togglePlayPause()
        log("play or pause")
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        // A second press before the report counts from the first one.
        let playing = !(playGuess?.playing ?? track.playing)
        playGuess = (playing, Date())
        pitch.paused = !playing
        showPlaying(playing, flash: true)
        // A player that ignored the command sends no change, so the guess is checked against what it reports.
        playGuessCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            playGuess = nil
            syncPaused()
            if model.shown, let track = nowPlaying.track, track.title?.isEmpty == false { showPlaying(track.playing, flash: false) }
        }
        playGuessCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: check)
    }

    /// What Space asked the player for, until the player reports it or 1.5 seconds pass.
    private var playGuess: (playing: Bool, at: Date)?
    private var playGuessCheck: DispatchWorkItem?
    /// When the HUD last appeared: a play or pause reported in its first moments happened while it was hidden.
    private var shownAt = Date.distantPast

    /// The record and its tonearm show the song as playing or paused, and with `flash` the glyph confirms the change.
    private func showPlaying(_ playing: Bool, flash: Bool) {
        guard model.playing != playing else { return }
        model.playing = playing
        guard flash, model.shown else { return }
        model.playFlash = PlayFlash(playing: playing, id: (model.playFlash?.id ?? 0) + 1)
        if Self.logKeys { log(playing ? "glyph play" : "glyph pause") }
    }

    /// Return while the lyrics show: karaoke, or back to the lyrics.
    private func toggleLyricsFocus() {
        guard model.lyricsShown else { return }
        karaokeAskedAt = CACurrentMediaTime()
        model.lyricsFocus.toggle()
        log(model.lyricsFocus ? "karaoke" : "lyrics at their usual size")
    }

    /// Karaoke opened from the keys, by its button or ⌘K, which closes back to the keys.
    private var karaokeFromKeys = false
    /// When the last key or click asked for karaoke, for the log of how long it took to show.
    private var karaokeAskedAt: CFTimeInterval?

    /// The karaoke button and ⌘K: karaoke from the keys or from the lyrics, and back to where it opened from.
    private func toggleKaraoke() {
        karaokeAskedAt = CACurrentMediaTime()
        if model.lyricsFocus {
            let back = karaokeFromKeys
            model.lyricsFocus = false
            log("karaoke closed")
            if back, model.lyricsShown { toggleLyrics() }
            return
        }
        let fromKeys = !model.lyricsShown
        if fromKeys {
            toggleLyrics()
            guard model.lyricsShown else { return }
        }
        model.lyricsFocus = true
        karaokeFromKeys = fromKeys
        log(fromKeys ? "karaoke from the keys" : "karaoke")
    }

    /// Karaoke mutes the vocals it finds playing, when Settings has it, and plays them again once it closes, by
    /// Return, L or the HUD closing. Vocals that were muted before, or that V changed during karaoke, stay as they are.
    private func karaokeChanged(_ on: Bool) {
        if !on {
            karaokeFromKeys = false
            model.karaokeKeys = false
            model.karaokeStems = false
            endKaraokeRestart()
        }
        // Karaoke takes the keys that change the key, which the lyrics at their usual size don't.
        updateHoverKeys()
        if on {
            if prefs.karaokeMutesVocals, model.stemsAvailable, !model.stemsMuted.contains(.vocals) {
                karaokeMutedVocals = true
                log("karaoke: vocals muted")
                setStems(model.stemsMuted.union([.vocals]), fade: true)
            }
            if prefs.karaokeRestarts { restartForKaraoke() }
            if let asked = karaokeAskedAt {
                karaokeAskedAt = nil
                log(String(format: "karaoke: set up %.0f ms after it was asked for", (CACurrentMediaTime() - asked) * 1000))
                DispatchQueue.main.async { [self] in
                    log(String(format: "karaoke: main thread free %.0f ms after it was asked for", (CACurrentMediaTime() - asked) * 1000))
                }
            }
        } else if karaokeMutedVocals {
            karaokeMutedVocals = false
            guard model.stemsMuted.contains(.vocals) else { return }
            log("karaoke: vocals play again")
            setStems(model.stemsMuted.subtracting([.vocals]), fade: true)
        }
    }

    private var karaokeMutedVocals = false

    /// Karaoke starting the song over: waiting for the model to be ready, waiting for the player to report the song at
    /// its start since the moment the move was asked for, or started over.
    /// The song moves to its start for karaoke, or to the place that a seek key asked for while the stems play:
    /// waiting for the model, waiting for the player's report of the move, and moved, with the place in seconds.
    private enum KaraokeRestart: Equatable { case waitingForModel, seeking(Date, Double), started(Double) }

    /// The move goes to the start of the song, as karaoke's, and not to the place of a seek.
    private var restartsFromStart: Bool {
        switch karaokeRestart {
        case let .seeking(_, target), let .started(target): target == 0
        case .waitingForModel: true
        case nil: false
        }
    }
    private var karaokeRestart: KaraokeRestart?
    /// Karaoke's start over steps back to the start of the song with a fade, whatever Settings > Instruments and vocals
    /// > Rewind effect has for the other steps back: a backspin all the way to the start felt like too much. Set until
    /// that one step back is heard.
    private var fadeToStart = false {
        didSet { pitch.fadeSteps = prefs.rewindEffect == .fade || fadeToStart }
    }
    private var karaokeRestartTimeout: DispatchWorkItem?

    /// Karaoke starts the song over (Settings > Lyrics > Karaoke > Start song from beginning). While the stems play, the output dips
    /// while the player moves the song to its start, and the song plays from there with its vocals while the stems of
    /// the start are separated, under the countdown. Then it rewinds to the start without them. Without the stems, the
    /// song only moves to its start.
    private func restartForKaraoke() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false, track.playing else {
            return log("karaoke: no song plays, nothing to start over")
        }
        // The lyrics delay plays the song 30 seconds behind on the same timeline, with a countdown of its own.
        guard !lyricsDelayed else { return log("karaoke: the song doesn't start over while Whisper writes its lyrics") }
        guard model.stemsEngaged else {
            log("karaoke: the song starts over")
            return moveSong(track, to: 0)
        }
        // Stems that already play for this song are ready, as when karaoke opens again: it opens on them at once,
        // where the song is, with nothing to separate again.
        if pitch.stemsPlaying { return log("karaoke: the stems already play, the song goes on from where it is") }
        // The stems from the cache play at once wherever the song is, so the song moves to its start as for a seek.
        if cachedStems {
            log("karaoke: the song starts over, with the stems from the cache")
            pitch.cachedSeek(to: 0)
            return moveSong(track, to: 0)
        }
        // Core ML prepares the model for an unknown time, and the stems separated meanwhile would be wasted, so the song
        // plays on and starts over once the model is ready.
        guard StemModel.prepared else {
            log("karaoke: the song starts over once the model is ready")
            karaokeRestart = .waitingForModel
            return
        }
        beginKaraokeRestart()
    }

    private func beginKaraokeRestart(to target: Double = 0) {
        guard let track = nowPlaying.track else { return }
        log(target == 0 ? "karaoke: the song starts over" : String(format: "seek: the stems start over at %.1f s", target))
        if target == 0, !fadeToStart { fadeToStart = true }
        let asked = Date()
        karaokeRestart = .seeking(asked, target)
        pitch.awaitingSeek = true
        // A player that ignores the move: the song plays on, and rewinds to where karaoke opened.
        let giveUp = { [weak self] in
            guard let self, case let .seeking(at, _) = karaokeRestart, at == asked else { return }
            log(restartsFromStart ? "karaoke: the player didn't move the song to its start" : "seek: the player didn't move the song")
            karaokeRestart = nil
            pitch.awaitingSeek = false
        }
        let filePlayer = track.bundleID == FilePlayer.bundleID
        if filePlayer {
            // Karaoke waits for the report of the move. Now Playing reports a move that it sent at once, while a seek
            // sent to Muskey Player straight would be read only a few seconds later.
            nowPlaying.seek(to: target)
        } else {
            moveSong(track, to: target) { moved in if !moved { giveUp() } }
        }
        // The Automation question can stay open for long, so the sound comes back after a while without an answer.
        let timeout = DispatchWorkItem(block: giveUp)
        karaokeRestartTimeout?.cancel()
        karaokeRestartTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (filePlayer ? 2 : 30), execute: timeout)
    }

    /// The player reports the song at its start after karaoke moved it there: the stems start over from that moment.
    private func checkKaraokeRestart() {
        guard case let .seeking(asked, target) = karaokeRestart, let track = nowPlaying.track, track.playing,
              let position = track.position(at: Date()), position >= target - 0.5, position < target + 3,
              // A report from before the move would place the start at the wrong moment.
              (track.timestamp ?? .infinity) >= asked.timeIntervalSince1970 - 0.05 else { return }
        karaokeRestartTimeout?.cancel()
        karaokeRestart = .started(target)
        log(target == 0 ? String(format: "karaoke: the song started over %.2f s ago", position)
            : String(format: "seek: the song moved to %.1f s, %.2f s ago", target, position - target))
        // The player's timestamp can be a little early, and the start is better 50 ms late than in the moment
        // before the move.
        pitch.restartStems(back: max(0, (position - target) / max(track.rate ?? 1, 0.1) - 0.05))
        if model.shown { model.rewinds += 1 }
    }

    private func endKaraokeRestart() {
        if fadeToStart { fadeToStart = false }
        karaokeRestartTimeout?.cancel()
        karaokeRestartTimeout = nil
        karaokeRestart = nil
        pitch.awaitingSeek = false
    }

    /// The seconds that the stems take to start once the model is ready: the first window, the margin after it, and
    /// about the time that a window takes to separate.
    private static var stemsWait: Double { StemModel.chunkSeconds + 0.75 + (StemModel.isInstalled(.winds) ? 1.2 : 0.6) }

    /// Karaoke counts down while the stems are separated, and says how far the song rewinds after it. Nothing shows
    /// while the player is asked to move the song to its start, which takes a moment.
    private func karaokeCountdown(_ progress: StemsProgress?) -> KaraokeCountdown? {
        guard model.lyricsFocus, let progress else { return nil }
        if case .seeking = karaokeRestart { return nil }
        // The countdown starts at the seconds that the song rewinds by, rounded the same way.
        let total = Int(Self.stemsWait.rounded())
        guard case .separating = progress, let waited = pitch.stemsWaited else {
            return KaraokeCountdown(seconds: nil, total: total, restart: restartsFromStart, rewind: nil)
        }
        let left = max(1, Int((Self.stemsWait - waited).rounded()))
        // The song rewinds as far as the stems took to start: the estimate, unless they run late.
        let rewind = Int(max(Self.stemsWait, waited + 0.5).rounded())
        return KaraokeCountdown(seconds: left, total: total, restart: restartsFromStart, rewind: rewind)
    }

    /// The V key, in every layout: the vocals muted, or playing again.
    private func toggleVocals() {
        guard model.stemsAvailable else { return }
        karaokeMutedVocals = false
        let muted = model.stemsMuted.contains(.vocals) ? model.stemsMuted.subtracting([.vocals]) : model.stemsMuted.union([.vocals])
        setStems(muted, fade: true)
    }

    /// Keeps the menu bar's key on the song that plays. A song that Now Playing names for the first time starts on
    /// its remembered key, or on the turntable until a listen finds its key.
    private func syncSongKey() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else {
            // A player that quit leaves no song, and the turntable comes back. A player that starts another song
            // reports no song for a moment, so the key waits 2 seconds for a song to show up.
            if autoSong != nil { cancelAutoListen() }
            guard songKey?.song != nil, noSong == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                noSong = nil
                if nowPlaying.track?.title?.isEmpty != false, songKey?.song != nil { songKey = nil }
            }
            noSong = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
            return
        }
        noSong?.cancel()
        noSong = nil
        if let autoSong, autoSong != track.song || !track.playing { cancelAutoListen() }
        if songKey?.song != track.song {
            songKey = knownKey(for: track.song).map { (track.song, $0.key, true, $0.online) }
        }
        autoListenIfNeeded()
    }

    /// The key known for a song without a listen: the one that a full listen found, or else the one that Noiseblend
    /// gave before.
    private func knownKey(for song: [String?]) -> (key: DetectedKey, online: Bool)? {
        if prefs.rememberKeys, let key = keyCache.key(for: song) { return (key, false) }
        if let id = KeyCache.id(song), let heard = heardKeys[id] { return (heard.key, false) }
        if prefs.onlineKeys, let key = keyLookup.key(for: song) { return (key, true) }
        return nil
    }

    /// The tempo known for a song without a listen: the one that a full listen found, or else Noiseblend's.
    private func knownTempo(for song: [String?]) -> SongTempo? {
        if prefs.rememberKeys, let bpm = keyCache.bpm(for: song) { return SongTempo(song: song, bpm: bpm) }
        if let id = KeyCache.id(song), let bpm = heardKeys[id]?.bpm { return SongTempo(song: song, bpm: bpm) }
        if prefs.onlineKeys, let bpm = keyLookup.bpm(for: song) { return SongTempo(song: song, bpm: bpm, online: true) }
        return nil
    }

    /// The pill under the key shows the tempo of the song that plays, once it is known.
    private func showTempo() {
        let song = model.track?.song
        guard model.tempo?.song != song || model.tempo == nil else { return }
        let known = song.flatMap(knownTempo)
        if model.tempo != known { model.tempo = known }
    }

    /// A listen heard `tempo` in `song`. Noiseblend's tempo picks the level at which the beats are counted, and the
    /// tempo is kept with the song's key.
    private func heardTempo(_ tempo: (bpm: Double, confidence: Float)?, in song: [String?]?) -> Double? {
        guard let tempo else { return nil }
        let online = prefs.onlineKeys ? song.flatMap(keyLookup.bpm) : nil
        let shown = TempoDetector.reconcile(heard: tempo.bpm, online: online)
        log(String(format: "tempo: heard %.1f BPM, confidence %.2f, Noiseblend %@, shown %.1f", tempo.bpm, tempo.confidence,
                   online.map { String(format: "%.1f", $0) } ?? "none", shown))
        if model.track?.song == song { model.tempo = SongTempo(song: song, bpm: shown) }
        return shown
    }

    /// Asks Noiseblend for the key of a song that a listen starts on. The answer shows in the menu bar unless a listen
    /// found the song's key first, and a listen in the HUD starts on it if no estimate came before it. The listen goes
    /// on either way, and its key counts over Noiseblend's.
    private func lookUpKey(_ track: NowPlaying.Track) {
        guard prefs.onlineKeys, Self.lyricsTest == nil else { return }
        let song = track.song
        keyLookup.find(track) { [weak self] key in
            guard let self, nowPlaying.track?.song == song else { return }
            showTempo()
            guard key != nil else { return }
            if songKey?.song != song, let known = knownKey(for: song) { songKey = (song, known.key, true, known.online) }
            startOnKnownKey()
        }
    }

    /// Always listening: a song that plays with no key heard yet gets a listen of the usual length, without the HUD.
    /// Its key shows in the menu bar and is remembered like the key of any listen. Each song gets two tries, for one
    /// that was paused or quiet through the first. A key from Noiseblend shows during the listen, which confirms it.
    private func autoListenIfNeeded() {
        guard prefs.alwaysListen, state == .idle, keptKey == nil, autoAnalyzer == nil, Self.lyricsTest == nil,
              AudioCapturePermission.status == .granted, let track = nowPlaying.track, track.playing,
              track.title?.isEmpty == false, songKey.map({ $0.song != track.song || $0.online }) ?? true,
              autoTries[track.song, default: 0] < 2
        else { return }
        autoTries[track.song, default: 0] += 1
        autoSession += 1
        let current = autoSession
        autoSong = track.song
        let tap = SystemAudioTap()
        do {
            try tap.prepare()
            let analyzer = KeyAnalyzer(sampleRate: tap.sampleRate, speed: playedSpeed)
            autoTap = tap
            autoAnalyzer = analyzer
            // Only the final estimate counts here, so the ones on the way are dropped.
            try tap.start { samples in analyzer.append(samples) { _, _ in } }
        } catch {
            cancelAutoListen()
            return log("always listening: \(error)")
        }
        log("always listening to \(track.title ?? "")")
        if songKey?.song != track.song { lookUpKey(track) }
        // The listen runs its whole length. One that heard nothing ends without a key, and the song gets its second
        // try if it still plays.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, autoSession == current else { return }
            finishAutoListen()
        }
    }

    private func finishAutoListen() {
        guard let analyzer = autoAnalyzer, let song = autoSong else { return }
        autoTap?.stop()
        autoTap = nil
        let current = autoSession
        analyzer.finish { [weak self] result, peak, bpm in
            guard let self, autoSession == current else { return }
            autoAnalyzer = nil
            autoSong = nil
            guard peak >= 0.0005, let key = DetectedKey(result) else {
                log("always listening: no key heard")
                return autoListenIfNeeded()
            }
            guard nowPlaying.track?.song == song else { return syncSongKey() }
            log(String(format: "always listening: %@  strength %.3f", key.name, result.strength))
            autoTries[song] = nil
            let tempo = heardTempo(bpm, in: song)
            if prefs.rememberKeys { log(keyCache.store(key, strength: result.strength, bpm: tempo, for: song)) }
            if let id = KeyCache.id(song) { heardKeys[id] = (key, tempo) }
            keyLookup.heard(key, for: song)
            // A pitch change that runs on into this song starts from its key.
            if pitch.running, keptKey == nil { shiftBase = key }
            songKey = (song, key, true, false)
        }
    }

    /// Stops a listen of Always listening, for a listen in the HUD, a song change or a pause. It doesn't count as one
    /// of the song's tries.
    private func cancelAutoListen() {
        autoSession += 1
        autoTap?.stop()
        autoTap = nil
        autoAnalyzer = nil
        if let autoSong, let tries = autoTries[autoSong] { autoTries[autoSong] = max(0, tries - 1) }
        autoSong = nil
    }

    /// A listen in the HUD found a key for the song that it heard, or started on the song's remembered key or on
    /// Noiseblend's. A song that changed during the listen keeps the key that it has.
    private func noteKey(_ key: DetectedKey, final: Bool, online: Bool = false) {
        let song = listenSong ?? nowPlaying.track?.song
        if let playing = nowPlaying.track, playing.title?.isEmpty == false, let song, song != playing.song { return }
        if !final, let songKey, songKey.final, songKey.song == song { return }
        songKey = (song, key, final, online)
    }

    /// The record shows the song that plays. While the HUD is hidden it keeps the song that it showed last, so the
    /// HUD that opens for a song change starts on the old record and swaps to the new one.
    private func syncTrack(gapOver: Bool = false) {
        if let fake = Self.lyricsTest?.track {
            if model.track != fake { model.track = fake }
            showPlaying(fake.playing, flash: false)
            return loadLyrics()
        }
        guard nowPlaying.watching else {
            trackGap?.cancel()
            trackGap = nil
            model.track = nil
            model.artwork = nil
            showPlaying(false, flash: false)
            return
        }
        guard model.shown else { return }
        // A player that starts another song directly (Spotify's play track, a click on a song in a list) reports no
        // song for a moment. The record holds through that gap, so the HUD swaps records instead of shrinking and
        // growing back.
        if !gapOver, nowPlaying.track?.title?.isEmpty != false, model.track?.title?.isEmpty == false {
            guard trackGap == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.trackGap = nil
                self?.syncTrack(gapOver: true)
            }
            trackGap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
            return
        }
        trackGap?.cancel()
        trackGap = nil
        // A play or pause of the same song, from the play key or the player, gets the glyph that Space shows. One
        // that Space asked for already shows, and a report against it is from before the player took it.
        let sameSong = model.track?.song == nowPlaying.track?.song
        if model.track != nowPlaying.track { model.track = nowPlaying.track }
        showTempo()
        if model.artwork !== nowPlaying.artwork { model.artwork = nowPlaying.artwork }
        if let track = nowPlaying.track, playGuess == nil || playGuess?.playing == track.playing {
            showPlaying(track.playing, flash: sameSong && Date().timeIntervalSince(shownAt) > 0.6)
        }
        loadLyrics()
    }

    private var trackGap: DispatchWorkItem?
    /// The kept key, during a listen that a song change started; nil during a listen started by the hotkey.
    private var follow: DetectedKey?
    /// The first estimate of that listen has moved the song, and the key and shift hold until the listen ends.
    private var followApplied = false
    /// The key to follow was picked by a person during a listen, not kept by Lock Key: the final estimate keeps that
    /// key, and the HUD shows no red pill for it.
    private var followByPerson = false
    /// A new song plays in its original key for at least this long before Lock Key moves it.
    private static let originalKeyFor: TimeInterval = 3
    private var songChangedAt = Date.distantPast
    private let keyCache = KeyCache()
    /// The song that Now Playing named when the listen started. Its key is remembered only if it still plays at the
    /// end of the listen.
    private var listenSong: [String?]?
    /// The listen started on the key that an earlier full listen found for the song, or on Noiseblend's. Estimates
    /// don't change it, and only the final estimate can.
    private var remembered: DetectedKey?
    /// The song that this listen asked Noiseblend about, so that it asks once.
    private var lookedUp: [String?]?
    /// The keys and tempos that listens found since Muskey started, by song, also with Remember song keys off. A song
    /// that a listen found the key of shows that key at once when the HUD opens on it again.
    private var heardKeys: [String: (key: DetectedKey, bpm: Double?)] = [:]
    /// A click on the key listens to the song again, as if no key were known for it. The key that it finds replaces
    /// the remembered one.
    private var redetecting = false
    /// The HUD was opened by a person (the hotkey, the menu, a click, an opened song), or showed already when the song
    /// changed, so it stays up after the result until it is closed, unless Auto-hide is on. A HUD that a song change
    /// opened with Lock Key on closes after the period of Auto-hide either way.
    private var stayOpen = false
    private let keyLookup = KeyLookup()
    private var keyMonitor: Any?
    private var magnifyMonitor: Any?
    /// Gets keyboard focus back when the key picker closes, if a click on the HUD made Muskey the active app.
    private var lastOtherApp = NSWorkspace.shared.frontmostApplication
    private var signalSources: [DispatchSourceSignal] = []

    private let prefs = Preferences.shared
    private var prefChanges: Set<AnyCancellable> = []
    private lazy var settingsWindow: SettingsWindowController = {
        let view = SettingsView(hud: model, keyCache: keyCache, setLayout: { [weak self] card in self?.setLayout(card: card) })
        return SettingsWindowController(view: view)
    }()

    // The estimate kept getting more accurate the longer a listen ran, and stopping early once it held steady lost
    // accuracy, so a listen has a fixed length.
    private var seconds: Double { Self.stringOption("--seconds").flatMap(Double.init) ?? Double(prefs.listenSeconds) }
    private let silenceAfter = KeyAnalyzer.firstEstimateAfter + 0.5
    /// How long a result stays up before the HUD closes, or nil when it stays up until it is closed. With Auto-hide
    /// off, only a HUD that a song change opened with Lock Key on closes by itself. `--show SECONDS` sets the period
    /// for tests.
    private var resultHideDelay: TimeInterval? {
        guard prefs.autoHide || !stayOpen else { return nil }
        return Self.stringOption("--show").flatMap(Double.init) ?? Double(prefs.autoHideSeconds)
    }

    private static func stringOption(_ name: String) -> String? { TestFlags.value(name) }

    private static func option(_ name: String, _ fallback: Double) -> Double {
        stringOption(name).flatMap(Double.init) ?? fallback
    }

    func applicationDidFinishLaunching(_: Notification) {
        if let dir = Self.stringOption("--render") { return renderPreviews(to: dir) }
        if let path = Self.stringOption("--render-menubar") {
            StatusItem.renderSheet(to: path)
            return NSApp.terminate(nil)
        }
        if let spec = Self.stringOption("--lyrics-lookup") { return lookUpLyrics(spec) }
        if let spec = Self.stringOption("--key-lookup") { return lookUpKeyForTesting(spec) }
        if let path = Self.stringOption("--tempo") { return tempoForTesting(path) }
        if let path = Self.stringOption("--loop-snap") {
            // `--loop-snap FILE --at S --to S` prints where presses at those moments of the file would land.
            Task {
                let at = Self.option("--at", 30), to = Self.option("--to", at + 8)
                let url = URL(fileURLWithPath: path)
                for (name, time) in [("start", at), ("end", to)] {
                    let from = max(0, time - 8)
                    let samples = await LoopSnap.excerpt(url, from: from, to: time + 1.5)
                    let started = Date()
                    let grid = LoopSnap.grid(samples, start: from)
                    let snapped = name == "start" ? LoopSnap.snap(time, grid: grid) : LoopSnap.snapEnd(time, start: LoopSnap.snap(at, grid: grid), grid: grid, bpm: nil)
                    print(String(format: "%@: pressed %.3f s, snapped %.3f s (%+.0f ms), %d beats, %d attacks, %.1f BPM, %.0f ms", name, time, snapped,
                                 (snapped - time) * 1000, grid.beats.count, grid.onsets.count, grid.bpm ?? 0, Date().timeIntervalSince(started) * 1000))
                }
                exit(0)
            }
            return
        }
        if let path = Self.waveformTest {
            Task {
                let start = Date()
                guard let waveform = await WaveformReader.read(URL(fileURLWithPath: path)) else {
                    print("waveform: can't read \(path)")
                    exit(1)
                }
                let bars = waveform.bars(40)
                print(String(format: "waveform: %.1f s, %d levels, %.0f%% heard, read in %.2f s", waveform.duration, waveform.levels.count, waveform.heard * 100, Date().timeIntervalSince(start)))
                print(bars.map { $0 < 0 ? " " : String(" ▁▂▃▄▅▆▇█".map { $0 }[min(8, Int($0 * 8.99))]) }.joined())
                exit(0)
            }
            return
        }
        if let path = Self.stringOption("--transcribe") { return TranscribeTest.run(path) }
        if TestFlags.has("--transcriber-download") { return ModelDownload.transcriber.downloadForTesting() }
        if let path = Self.stringOption("--splice-dump") {
            exit(SlowStream.searchDump(path, old: Self.option("--splice-old", 3), move: Self.option("--splice-move", 0)))
        }
        if let path = Self.stringOption("--whisper-file") { return WhisperTest.run(file: path, model: Self.stringOption("--whisper-model") ?? "") }
        if let path = Self.stringOption("--lyrics-transcribe") {
            return LyricsTranscribeTest.run(file: path, server: Self.stringOption("--whisper-server"), vocals: !TestFlags.has("--no-vocals"))
        }
        if let path = Self.stringOption("--lyrics-replay"), let server = Self.stringOption("--whisper-server") {
            return LyricsReplayTest.run(file: path, server: server, plays: Self.stringOption("--plays") ?? "0-60,0-120")
        }
        if TestFlags.has("--stems-download") { return ModelDownload.stems.downloadForTesting() }
        if TestFlags.has("--winds-download") { return ModelDownload.winds.downloadForTesting() }
        if TestFlags.has("--whisper-download") { return ModelDownload.whisper.downloadForTesting() }
        if let path = Self.stringOption("--stems-install") { return ModelDownload.stems.installForTesting(path) }
        if let path = Self.stringOption("--winds-install") { return ModelDownload.winds.installForTesting(path) }
        if let path = Self.stringOption("--stems-file") { return StemFileTest.run(path, to: Self.stringOption("--stems-out") ?? "/tmp/muskey-stems") }
        if let path = Self.stringOption("--render-song") {
            return SaveTest.run(path, to: Self.stringOption("--render-out") ?? "/tmp/muskey-render.m4a", semitones: Int(Self.option("--render-semitones", 0)),
                                speed: Self.option("--render-speed", 1),
                                mute: (Self.stringOption("--render-mute") ?? "").split(separator: ",").map { $0.lowercased() })
        }

        NSApp.mainMenu = mainMenu()
        Updates.shared.start()
        prefs.$cacheCleanup.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.sweepCaches() } }.store(in: &prefChanges)
        cacheSweeper = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.sweepCaches() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.sweepCaches() }
        prefs.$hotkey.combineLatest(prefs.$recordingHotkey).sink { [weak self] shortcut, recording in
            self?.registerHotKey(recording ? nil : shortcut)
        }.store(in: &prefChanges)
        prefs.$launchAtLogin.sink { [weak self] in self?.updateLoginItem($0) }.store(in: &prefChanges)
        prefs.$relativeKeys.sink { [weak self] in self?.model.relativeKeys = $0 }.store(in: &prefChanges)
        prefs.$waveform.dropFirst().sink { [weak self] shown in
            self?.model.waveformShown = shown
            DispatchQueue.main.async { self?.syncWaveform() }
        }.store(in: &prefChanges)
        prefs.$waveformStyle.dropFirst().sink { [weak self] in self?.model.waveformStyle = $0 }.store(in: &prefChanges)
        // The waveform of another player's song is drawn only while the HUD shows it.
        model.$shown.dropFirst().removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.syncWaveform() } }.store(in: &prefChanges)
        prefs.$rewindEffect.sink { [weak self] effect in
            guard let self else { return }
            pitch.fadeSteps = effect == .fade || fadeToStart
        }.store(in: &prefChanges)
        // A changed timeout counts from the change.
        prefs.$pauseStop.combineLatest(prefs.$pauseStopSeconds).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.pauseStopWork?.cancel()
                self?.pauseStopWork = nil
                self?.syncPauseStop()
            }
        }.store(in: &prefChanges)
        prefs.$menuBarIcon.combineLatest(prefs.$hotkey).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }.store(in: &prefChanges)
        // Published before the change, so the new value is read on the next turn of the run loop.
        prefs.$alwaysListen.dropFirst().removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !on { cancelAutoListen() }
                updateWatching(shown: model.shown)
                guard on, AudioCapturePermission.status == .undetermined else { return syncSongKey() }
                AudioCapturePermission.request { [weak self] granted in
                    if granted { self?.syncSongKey() }
                }
            }
        }.store(in: &prefChanges)
        // A key forgotten in Settings stops showing in the menu bar for the song that plays, and Always listening
        // listens to that song again. Noiseblend's key for the song is forgotten too, so the song starts over.
        keyLookup.log = { [weak self] in self?.log($0) }
        keyCache.onForget = { [weak self] id in
            guard let self else { return }
            if let id { keyLookup.forget(id) } else { keyLookup.clear() }
            if let song = model.tempo?.song, id == nil || id == KeyCache.id(song) { model.tempo = nil }
            guard let song = songKey?.song, id == nil || id == KeyCache.id(song) else { return }
            songKey = nil
            autoTries[song] = nil
            autoListenIfNeeded()
        }

        model.onShift = { [weak self] shift, relative in
            if Self.logKeys { self?.log("click \(shift)\(relative ? " other mode" : "")") }
            self?.change(to: shift, relative: relative)
        }
        model.onClose = { [weak self] in self?.dismiss() }
        model.onRedetect = { [weak self] in self?.redetect() }
        model.onStop = { [weak self] in self?.stopPitch() }
        model.onKeep = { [weak self] in self?.toggleKeep() }
        model.onLayout = { [weak self] in self?.toggleLayout() }
        model.onLyrics = { [weak self] in self?.toggleLyrics() }
        model.onSpeed = { [weak self] in self?.changeSpeed(by: $0) }
        model.onKaraoke = { [weak self] in
            if Self.logKeys { self?.log("click karaoke") }
            self?.toggleKaraoke()
        }
        model.onLyricsRetry = { [weak self] in self?.retryLyrics() }
        model.onLyricsEdit = { [weak self] in self?.editLyrics() }
        model.onStem = { [weak self] stem, solo in self?.toggleStem(stem, solo: solo) }
        model.onVocals = { [weak self] in self?.toggleVocals() }
        model.onStemsReset = { [weak self] in self?.playAllStems() }
        model.onStemsRetry = { [weak self] in self?.retryStems() }
        model.onSeparate = { [weak self] in self?.separate() }
        lyricsSync.log = { [weak self] in self?.log($0) }
        lyricsSync.onChange = { [weak self] in self?.lyricsTimingChanged() }
        lyricsSync.whisper = { [weak self] in self?.whisperBackend() }
        // Once Whisper writes a part of a song that it hasn't transcribed before, the song stays 30 seconds behind
        // until the lyrics are hidden or the HUD closes: a new song stops the writing while its lyrics are looked
        // up, and dropping the delay then would cut off the last 30 seconds of the song before it.
        lyricsSync.onNeedsLead = { [weak self] in self?.setLyricsDelay(true) }
        lyricsSync.onWritingFailed = { [weak self] in
            guard let self, model.lyricsWriting else { return }
            model.lyricsWriting = false
            if case let .found(lyrics) = model.lyrics, lyrics.lines.isEmpty { model.lyrics = .failed }
        }
        lyricsSync.onWritten = { [weak self] lyrics in
            guard let self, model.lyricsWriting else { return }
            // How far the written lines reach, against the position that is heard, for checking that the delay is
            // enough. Never the words.
            let position = model.track?.position(at: Date()) ?? 0
            log(String(format: "lyrics: %d lines written, the last at %.0fs, heard at %.0fs", lyrics.lines.count, lyrics.lines.last?.time ?? 0,
                       position - pitch.stemsDelay))
            model.lyrics = .found(lyrics)
            updateLyricLine()
        }
        model.onHoverChange = { [weak self] in
            self?.updateHoverKeys()
            self?.updateKeysActive()
            self?.warmUpStems()
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                self?.updateKeysActive()
            }
        }
        statusItem.onFindKey = { [weak self] in
            if self?.state == .idle { self?.start() }
        }
        statusItem.onChangeKey = { [weak self] in self?.pickKey() }
        statusItem.onKeep = { [weak self] in self?.toggleKeep() }
        statusItem.onStop = { [weak self] in self?.stopPitch() }
        statusItem.onPlayAllStems = { [weak self] in self?.playAllStems() }
        statusItem.onSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem.onOpenFile = { [weak self] in self?.openFile() }
        statusItem.onOpenLocation = { [weak self] in self?.openLocation() }
        filePlayer.log = { [weak self] in self?.log($0) }
        filePlayer.onActivity = { [weak self] in self?.openActivity = $0 }
        filePlayer.onPlaying = { [weak self] in self?.filePlays() }
        filePlayer.pauseOthers = { [weak self] done in
            guard let self else { return done() }
            nowPlaying.pauseOthers(except: FilePlayer.bundleID, then: done)
        }
        activityPill.onRetry = { [weak self] in
            guard let self else { return }
            if openActivity == nil, case .saveFailed = saveActivity { retrySave() } else { filePlayer.retry() }
        }
        activityPill.onInstall = { [weak self] in self?.filePlayer.installDownloader() }
        activityPill.onDismiss = { [weak self] in
            guard let self else { return }
            if openActivity != nil { filePlayer.dismiss() } else { saveActivity = nil }
        }
        activityPill.onReveal = { [weak self] in
            guard let url = self?.savedURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self?.saveActivity = nil
        }
        model.onSave = { [weak self] in self?.saveSong() }
        model.onSaveCancel = { [weak self] in self?.cancelSave() }
        model.onSaveStop = { [weak self] in self?.stopSave() }
        statusItem.onSave = { [weak self] in self?.saveSong() }
        model.onOpen = { [weak self] urls in self?.open(urls) }
        model.onOpenFile = { [weak self] in self?.openFile() }
        model.onSeekFraction = { [weak self] in self?.seek(toFraction: $0) }
        model.onStemsClose = { [weak self] in self?.closeStems() }
        model.onOpenLocation = { [weak self] in self?.openLocation() }
        slow.onReturn = { [weak self] progress in self?.model.tempoReturn = progress }
        slow.onEnd = { [weak self] in self?.stopPitchIfUnwanted() }
        model.onPlayPause = { [weak self] in self?.playPause() }
        model.onSkip = { [weak self] in self?.skip($0) }
        model.onLink = { [weak self] url in self?.log("opening \(url.host() ?? url.absoluteString) in the browser") }
        filePlayer.onChange = { [weak self] in
            self?.refreshStatus()
            self?.syncSpeed()
            self?.syncWaveform()
        }
        filePlayer.onMove = { [weak self] in self?.playerMoved(to: $0) }
        stemsCache.log = { [weak self] in self?.log($0) }
        StemModel.log = { [weak self] message in DispatchQueue.main.async { self?.log(message) } }
        stemsCache.live = { [separating = pitch.separatingLive] in separating.value }
        stemsCache.onDone = { [weak self] path, ok in
            guard let self else { return }
            if !ok { stemsCacheFailed.insert(path) }
            stemsCacheLooked = nil
            syncStemsCache()
            syncWaveformStems()
        }
        statusItem.onStopPlaying = { [weak self] in self?.filePlayer.close() }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === panel else { return event }
            // A save in progress leaves the stems and the songs as they are, and so do the shortcuts, which hide them.
            if model.saving != nil || model.shortcuts { return nil }
            // ⌘ with a scroll over the waveform zooms it, fingers up zooming in.
            if event.modifierFlags.contains(.command), overWaveform(event) {
                let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                zoomWaveform(exp(Double(sign * event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)))
                return nil
            }
            return adjust(event) || swipe(event) ? nil : event
        }
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === panel, overWaveform(event) else { return event }
            zoomWaveform(1 + Double(event.magnification))
            return nil
        }
        nowPlaying.log = { [weak self] in self?.log($0) }
        nowPlaying.heard = { [weak self] report in self?.slow.heard(report) ?? report }
        nowPlaying.onPlayerReport = { [weak self] in self?.slow.playerReported($0) }
        slow.player = { [weak self] in self?.nowPlaying.player }
        slow.move = { [weak self] track, seconds in self?.movePlayer(track, to: seconds) }
        slow.movesKnown = { [weak self] id in self?.seekPaths[id] != nil || Self.forcedSeekPath != nil }
        slow.refresh = { [weak self] in self?.nowPlaying.refresh() }
        slow.onReadSpeed = { [weak self] in self?.syncSpeed() }
        slow.log = { [weak self] in self?.log($0) }
        slow.onFailed = { [weak self] wanted in
            guard let self else { return }
            slowFailedPlayer = slowedPlayer
            model.slowFailed = wanted
        }
        model.onSlowRetry = { [weak self] in self?.retrySlowing() }
        model.onLoopSet = { [weak self] in self?.setLoopEnd($0, $1) }
        model.onLoopTyping = { [weak self] in self?.loopTyping($0) }
        nowPlaying.onSongChange = { [weak self] in
            // Another song during karaoke's countdown plays as it comes.
            if self?.karaokeRestart != nil { self?.endKaraokeRestart() }
            self?.songArrives()
            self?.songChanged($0)
        }
        nowPlaying.onTrack = { [weak self] in
            self?.syncWaveform()
            self?.checkLoopSong()
            self?.listenWhenPlaying()
            self?.resumeListen()
            self?.syncPauseStop()
            self?.syncSpeed()
            self?.syncSeekable()
            self?.syncSavable()
            self?.checkRecording()
            self?.syncPaused()
            self?.checkKaraokeRestart()
            self?.syncTrack()
            self?.startOnKnownKey()
            self?.syncSongKey()
        }
        // The keys over the record differ from the ones over the rest of the HUD.
        overRecordChange = model.$overRecord.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }
        // A new song's listen starts with no key, and the keys that change the key come back with its first estimate.
        keyChange = model.$key.map { $0 != nil }.removeDuplicates().sink { [weak self] keyed in
            DispatchQueue.main.async {
                if keyed { self?.model.heldGlass = nil }
                self?.updateHoverKeys()
            }
        }
        // The glass that a song change held at its size lets go once the listen ends or the HUD hides.
        heldGlassChange = model.$phase.combineLatest(model.$shown).sink { [weak self] phase, shown in
            guard phase != .listening || !shown else { return }
            DispatchQueue.main.async { self?.model.heldGlass = nil }
        }
        // A save and the shortcuts leave the HUD only the keys that end them.
        lockChange = model.$saving.map { $0 != nil }.removeDuplicates().combineLatest(model.$shortcuts.removeDuplicates()).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }
        // Published before the change, so the new value comes from the publisher.
        shownChange = model.$shown.removeDuplicates().sink { [weak self] shown in
            if shown { self?.shownAt = Date() }
            // The sink runs before `shown` changes.
            DispatchQueue.main.async { self?.syncPauseStop() }
            self?.updateWatching(shown: shown)
            self?.watchOption(shown)
            self?.updateLyricsClock(shown: shown)
            self?.updateStemMeters(shown: shown)
            self?.prepareStemModel(shown: shown)
            // With every stem playing, the song as it plays comes back once the HUD is gone.
            if !shown, self?.model.stemsAdjusted == false { self?.engageStems(false) }
            // Once the HUD has faded in, a song that changed while it was hidden swaps in on the record.
            if shown { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.syncTrack() } }
        }
        backdropChange = model.$lyricsFocus.combineLatest(model.$lyricsShown, model.$shown, prefs.$karaokeBackdrop)
            .map { $0 && $1 && $2 && $3 }.removeDuplicates().dropFirst().sink { [weak self] on in
                // Published before the change, so the panel is where the change leaves it on the next turn.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    karaokeBackdrop.show(on, below: panel)
                }
            }
        // The key row and the instruments that the pointer shows in karaoke, for testing the hover from a script.
        if Self.logKeys {
            model.$karaokeKeys.removeDuplicates().dropFirst().sink { [weak self] in self?.log($0 ? "karaoke: key row shown" : "karaoke: key row hidden") }
                .store(in: &prefChanges)
            model.$karaokeStems.removeDuplicates().dropFirst().sink { [weak self] in self?.log($0 ? "karaoke: instruments shown" : "karaoke: instruments hidden") }
                .store(in: &prefChanges)
        }
        karaokeChange = model.$lyricsFocus.removeDuplicates().dropFirst().sink { [weak self] on in
            self?.focusChangedAt = Date()
            // Published before the change. The stems and the pitch change start once karaoke's first frame is drawn,
            // since they hold the main thread for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.karaokeChanged(on) }
        }
        glassChange = model.$glassFrame.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panel.updatePassThrough() }
            // Published before the change, so the panel reads the new frame on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, panel.isVisible else { return }
                // Karaoke opens or closes in place at once, so the glass doesn't slide after it.
                panel.keepOnScreen(animated: panel.alphaValue >= 1 && Date().timeIntervalSince(focusChangedAt) > 0.6)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            karaokeBackdrop.follow(panel)
            // Only a drag: the moves that keep the glass on the screen aren't a new place for it.
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
            panelMoved()
        }
        pitch.onFailure = { [weak self] error in self?.pitchFailed("\(error)") }
        pitch.onStemsFailure = { [weak self] error in self?.stemsFailed("\(error)") }
        pitch.stemsLog = { [weak self] line in DispatchQueue.main.async { self?.log(line) } }
        ModelDownload.stems.log = { [weak self] in self?.log($0) }
        ModelDownload.winds.log = { [weak self] in self?.log($0) }
        ModelDownload.whisper.log = { [weak self] in self?.log($0) }
        stopPitchOnSignals()
        network.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkChanged(online: path.status == .satisfied) }
        }
        network.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            self?.lastOtherApp = app
        }

        if TestFlags.has("--listen") { toggle() }
        // Test flags: start a pitch change, or open the key picker, from a sample key.
        if let shift = Self.stringOption("--shift").flatMap(Int.init) {
            shiftBase = .sample
            model.key = .sample
            setShift(shift)
        }
        // `--status-key Em` starts with the menu bar showing that key, as if a listen had found it for the song.
        if let name = Self.stringOption("--status-key") {
            guard let key = DetectedKey(name: name) else { return log("--status-key needs a key like Cm, F# or Eb") }
            songKey = (nowPlaying.track?.song, key, true, false)
        }
        if let name = Self.stringOption("--keep") {
            guard let key = DetectedKey(name: name) else { return log("--keep needs a key like Cm, F# or Eb") }
            keptKey = key
            log("keeping \(key.name) for the next songs")
        }
        if TestFlags.has("--pick") || Self.lyricsTest != nil {
            shiftBase = shiftBase ?? .sample
            pickKey()
        }
        // `--stems-only guitar,piano` plays only those stems, as the chips would.
        if let names = Self.stringOption("--stems-only") {
            let playing = Set(names.split(separator: ",").compactMap { name in Stem.allCases.first { $0.name.lowercased() == name.lowercased() } })
            model.stemsAvailable = StemModel.installed
            shiftBase = shiftBase ?? .sample
            model.key = model.key ?? .sample
            // As if the HUD showed the stems a few seconds before a chip was pressed: `--stems-after 0` starts cold.
            let after = Self.stringOption("--stems-after").flatMap(Double.init) ?? 3
            if after > 0 { StemModel.warmUp() }
            // `all` presses Separate instruments and vocals, which plays every stem.
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                if names == "all" { separate() } else { setStems(Set(Stem.allCases).subtracting(playing)) }
            }
        }
        if let test = Self.lyricsTest {
            lyricsFinder.keep(test.state, for: test.track)
            syncTrack()
            toggleLyrics()
        } else if Self.lyricsPlain, model.picking {
            toggleLyrics()
        }
        if TestFlags.has("--settings") || !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            settingsWindow.show()
        }
        launched = true
        // `--open PATH_OR_LINK` plays a file or a link, as a drop on the HUD does.
        if let text = Self.stringOption("--open"), let url = FilePlayer.url(from: text) { open([url]) }
        // `--install-yt-dlp` presses Install yt-dlp on the pill.
        if TestFlags.has("--install-yt-dlp") { filePlayer.installDownloader() }
        // `--menu "Stop Playing" [--menu-after SECONDS]` picks an item of the menu bar menu, which no automation can
        // open on macOS 27.
        // `--glyph-sheet` opens a window of live records with the play and pause glyph on their covers.
        if TestFlags.has("--glyph-sheet") {
            let paths = Self.stringOption("--glyph-covers")?.split(separator: ",").map(String.init) ?? []
            let window = NSWindow(contentViewController: NSHostingController(rootView: GlyphSheet(covers: GlyphSheet.covers(paths: paths))))
            window.title = "Glyph sheet"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            glyphSheet = window
        }
        // `--open-menu-after S` opens the menu bar menu after S seconds, so a posted key reaches the open menu.
        if let after = Self.stringOption("--open-menu-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                log("menu: opened")
                statusItem.openMenu()
            }
        }
        if let title = Self.stringOption("--menu") {
            let after = Self.stringOption("--menu-after").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                log(statusItem.perform(title) ? "menu: \(title)" : "menu: no item \(title)")
            }
        }
        if let urls = openedEarly {
            openedEarly = nil
            open(urls)
        }
    }

    /// Open With in Finder, or a file dropped on Muskey's icon.
    func application(_: NSApplication, open urls: [URL]) {
        guard launched else { return openedEarly = (openedEarly ?? []) + urls }
        open(urls)
    }

    /// Plays files or links: dropped on the HUD, pasted, or picked with Open File… and Open URL….
    private func open(_ urls: [URL]) {
        log("opening \(urls.count == 1 ? (urls[0].isFileURL ? "a file" : "a link") : "\(urls.count) items")")
        filePlayer.open(urls)
    }

    /// The previous or next song, from the buttons beside the record or a swipe over the HUD. The player gets the
    /// command that the media keys send, and the record shows the glyph at once.
    private func skip(_ direction: Int) {
        log(direction > 0 ? "next song" : "previous song")
        nowPlaying.skip(direction)
        guard model.shown, let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        model.playFlash = PlayFlash(playing: model.playing, id: (model.playFlash?.id ?? 0) + 1, skip: direction)
    }

    private var scrollMonitor: Any?
    /// The fingers' travel across the HUD in the swipe that goes on, in points, and whether it skipped already.
    private var swipeTravel = CGSize.zero
    private var swiped = false

    /// A two-finger swipe across the HUD skips to another song, once per swipe. The fingers moving right play the next
    /// song, and moving left play the previous one, the other way round with Natural swiping in Settings. Mostly
    /// vertical scrolls, like the lyrics', and a mouse wheel are left alone.
    private func swipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began {
            swipeTravel = .zero
            swiped = false
        }
        // The momentum after the fingers lift belongs to the swipe that skipped.
        if event.phase.isEmpty { return swiped && !event.momentumPhase.isEmpty }
        // With natural scrolling the deltas go the way the fingers go.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeTravel.width += event.scrollingDeltaX * sign
        swipeTravel.height += abs(event.scrollingDeltaY)
        if !swiped, abs(swipeTravel.width) > 60, abs(swipeTravel.width) > 2 * swipeTravel.height {
            swiped = true
            if Self.logKeys { log(String(format: "swipe %.0f points", swipeTravel.width)) }
            let right = swipeTravel.width > 0
            skip(right != prefs.naturalSwipes ? 1 : -1)
        }
        return swiped
    }

    /// The scroll over the tempo or a stem that goes on: what it adjusts, the value when it began, and the fingers'
    /// travel since then, in points, up as positive.
    private var adjusting: (region: ScrollRegion, start: Double, travel: CGFloat)?
    /// A trackpad scroll that began over the tempo or a stem, until its first points say whether it goes up and down,
    /// which adjusts, or sideways, which is a swipe.
    private var adjustCandidate: (region: ScrollRegion, start: Double, travel: CGSize)?
    /// Ends a scroll of a mouse wheel, which has no phases, a moment after its last notch.
    private var adjustEnd: DispatchWorkItem?
    /// The last adjusting scroll ended: its momentum still belongs to it.
    private var adjustedAt = Date.distantPast

    /// A scroll that begins over the tempo of a song in Muskey Player changes its speed, by 1 % for every 6 points,
    /// and one that begins over a stem changes its volume, by 1 % for every 3 points. It adjusts the same thing
    /// until the fingers lift, even after the pointer has left it. Fingers moving up raise the value, with natural
    /// scrolling or without.
    private func adjust(_ event: NSEvent) -> Bool {
        let precise = event.hasPreciseScrollingDeltas
        // The momentum after the fingers lift isn't the hand's, so it adjusts nothing, and scrolls nothing else.
        if !event.momentumPhase.isEmpty { return adjusting != nil || Date().timeIntervalSince(adjustedAt) < 0.5 }
        if event.phase == .ended || event.phase == .cancelled {
            adjustCandidate = nil
            guard adjusting != nil else { return false }
            endAdjusting()
            return true
        }
        if event.phase == .began, precise {
            if let region = scrollRegion(at: event), let value = adjustedValue(region) {
                adjusting = nil
                adjustCandidate = (region, value, .zero)
                if Self.logKeys { log("scroll begins over \(region)") }
            } else if Self.logKeys, let view = panel.contentView {
                let local = view.convert(event.locationInWindow, from: nil)
                let places = model.scroll.frames.values.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height) }
                log(String(format: "scroll begins over nothing to adjust at %.0f,%.0f (flipped %@, height %.0f): ", local.x, local.y, view.isFlipped ? "yes" : "no", view.bounds.height)
                    + places.joined(separator: " | "))
            }
        }
        if var candidate = adjustCandidate {
            // Over the time bar, a scroll sideways moves the song too, so it is never a swipe there.
            candidate.travel.width += candidate.region.seeks ? 0 : abs(event.scrollingDeltaX)
            candidate.travel.height += scrollTravel(event, for: candidate.region)
            guard candidate.travel.width + abs(candidate.travel.height) > 6 else {
                adjustCandidate = candidate
                return false
            }
            adjustCandidate = nil
            // Sideways: the swipe has seen every event so far and goes on.
            if Self.logKeys { log(abs(candidate.travel.height) > candidate.travel.width ? "the scroll adjusts" : "the scroll is a swipe") }
            guard abs(candidate.travel.height) > candidate.travel.width else { return false }
            adjusting = (candidate.region, candidate.start, candidate.travel.height)
            model.scroll.region = candidate.region
            Self.hideToolTip()
            return applyAdjusting()
        }
        // A trackpad scroll picks what it adjusts when it begins, above, and a wheel at each notch, keeping the last
        // one while the pointer is over nothing to adjust.
        if event.phase == .began {
            adjusting = nil
        } else if !precise, event.phase.isEmpty, let region = scrollRegion(at: event), let value = adjustedValue(region), adjusting?.region != region {
            adjusting = (region, value, 0)
            model.scroll.region = region
            Self.hideToolTip()
        }
        guard var current = adjusting else { return false }
        current.travel += scrollTravel(event, for: current.region) * (precise ? 1 : 8)
        adjusting = current
        let handled = applyAdjusting()
        if !precise {
            adjustEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in self?.endAdjusting() }
            adjustEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: end)
        }
        return handled
    }

    /// How far `event` moves the fingers, in points: up for the tempo and a stem, and up or right for the time bar,
    /// with natural scrolling or without.
    private func scrollTravel(_ event: NSEvent, for region: ScrollRegion) -> CGFloat {
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let up = sign * event.scrollingDeltaY
        return region.seeks ? up - sign * event.scrollingDeltaX : up
    }

    /// Sets the tempo, the volume or the place in the song from the travel so far, and the lift that goes with it.
    private func applyAdjusting() -> Bool {
        guard let current = adjusting else { return false }
        model.scroll.lift = tanh(current.travel / 60)
        switch current.region {
        case .tempo:
            let speed = min(max(((current.start + Double(current.travel) / 600) * 100).rounded() / 100, 0.5), fastestSpeed)
            if speed != currentSpeed { playSpeed(speed) }
        case let .stem(stem):
            let volume = min(max(((current.start + Double(current.travel) / 300) * 100).rounded() / 100, 0), 1.5)
            if volume != model.stemVolumes[stem] ?? 1 { setStemVolume(stem, volume) }
        case .timeBar, .waveform:
            // 400 points of travel cross the whole song. The bar shows the place, and the song moves there once the
            // fingers lift, so a player gets one seek per scroll.
            let fraction = min(max(current.start + Double(current.travel) / 400, 0), 1)
            if model.scrub != fraction { model.scrub = fraction }
        }
        return true
    }

    /// AppKit keeps a tooltip on screen through a scroll that the monitor takes, even after the view drops its text,
    /// so the one over a stem is put away when the scroll starts to change the volume.
    private static func hideToolTip() {
        guard let manager = NSClassFromString("NSToolTipManager") as? NSObject.Type,
              manager.responds(to: NSSelectorFromString("sharedToolTipManager")),
              let shared = manager.perform(NSSelectorFromString("sharedToolTipManager"))?.takeUnretainedValue() as? NSObject
        else { return }
        for name in ["abortToolTip", "orderOutToolTip"] where shared.responds(to: NSSelectorFromString(name)) {
            shared.perform(NSSelectorFromString(name))
            return
        }
    }

    private func endAdjusting() {
        adjustEnd?.cancel()
        adjustEnd = nil
        if case let .stem(stem) = adjusting?.region {
            log(String(format: "%@ at %.0f%%", stem.name.lowercased(), (model.stemVolumes[stem] ?? 1) * 100))
        }
        if adjusting?.region.seeks == true, let fraction = model.scrub {
            seek(toFraction: fraction)
            // The bar holds the place until the player reports the move.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.model.scrub == fraction { self?.model.scrub = nil }
            }
        }
        adjusting = nil
        adjustedAt = Date()
        model.scroll.region = nil
        model.scroll.lift = 0
    }

    /// The tempo or the stem under the pointer, among the ones that can be adjusted now.
    private func scrollRegion(at event: NSEvent) -> ScrollRegion? {
        guard let view = panel.contentView else { return nil }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.first { $0.frame.contains(point) && adjustedValue($0.region) != nil }?.region
    }

    /// The value that a scroll over `region` starts from, or nil while it can't be adjusted.
    private func adjustedValue(_ region: ScrollRegion) -> Double? {
        switch region {
        case .tempo: model.speedAdjustable ? currentSpeed : nil
        case let .stem(stem): model.stemsAvailable ? model.stemVolumes[stem] ?? 1 : nil
        case .timeBar, .waveform: model.seekable ? playedFraction : nil
        }
    }

    /// How far the song has played, from 0 to 1, counting a seek that the player hasn't reported yet.
    private var playedFraction: Double? {
        guard let track = nowPlaying.track, let duration = track.duration, duration > 0 else { return nil }
        let pending = seekTarget.flatMap { $0.song == track.song && Date().timeIntervalSince($0.at) < 2 ? $0.seconds : nil }
        guard let position = pending ?? track.position(at: Date()) else { return nil }
        return min(max(position / duration, 0), 1)
    }

    /// The song that Muskey opened plays: the HUD opens on it as the hotkey opens it, unless it already shows. During a
    /// pitch change or with a key locked, that is the key picker, since the song change moves the song already.
    private func filePlays() {
        syncStemsCache()
        guard state == .idle else { return }
        (pitch.running && pitchWanted) || keptKey != nil ? pickKey() : start()
    }

    @objc private func stopPlaying() { filePlayer.close() }

    @objc private func saveFromMenu() { saveSong() }

    /// Stop Playing in the File menu works only while Muskey Player has a song, and Save Song only while the song
    /// can be saved with its changes.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopPlaying): filePlayer.hasSong
        case #selector(saveFromMenu): model.savable
        default: true
        }
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard inFront({ panel.runModal() }) == .OK else { return }
        open(panel.urls)
    }

    /// A link to a song or a video, or the path of a file, in a glass bar like the HUD's.
    @objc private func openLocation() {
        dialogOpen = true
        locationPanel.show()
    }

    /// Runs a dialog in front of the app that is active, with the keyboard on the dialog. macOS brings only a regular
    /// app to the front, so Muskey shows in the Dock while the dialog is open, as it does for Settings.
    /// The app that was in front gets the keyboard back afterwards, as when the HUD closes.
    private func inFront<T>(_ run: () -> T) -> T {
        let accessory = NSApp.activationPolicy() == .accessory
        if accessory { NSApp.setActivationPolicy(.regular) }
        NSApp.takeFocus()
        // The HUD, karaoke's blur and the activity pill sit at the status bar's level, above a modal dialog, which
        // macOS keeps at its own level: the HUD hid half of the save panel and took the clicks meant for its Format
        // picker. They go below the dialog while it is open.
        let raised = NSApp.windows.filter { $0.isVisible && $0.level == .statusBar }
        raised.forEach { $0.level = .floating }
        dialogOpen = true
        let result = run()
        dialogOpen = false
        raised.forEach { $0.level = .statusBar }
        if accessory, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.setActivationPolicy(.accessory)
            if let lastOtherApp, lastOtherApp != .current { lastOtherApp.activate() }
        }
        return result
    }

    /// ⌘V over the HUD: plays the files or the link on the clipboard. Returns false when the clipboard holds neither.
    @discardableResult private func pasteSongs() -> Bool {
        let urls = Self.pastedURLs()
        guard !urls.isEmpty else { return false }
        open(urls)
        return true
    }

    /// Files or a link on the clipboard, for ⌘V over the HUD.
    private static func pastedURLs() -> [URL] {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files }
        if let text = board.string(forType: .string), let url = FilePlayer.url(from: text) { return [url] }
        return []
    }

    private func registerHotKey(_ shortcut: Shortcut?) {
        hotKey = nil
        prefs.hotkeyFailed = false
        guard let shortcut else { return }
        do {
            hotKey = try HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.toggle() }
        } catch {
            prefs.hotkeyFailed = true
            log("\(error); is \(shortcut.symbols) taken by another app?")
        }
    }

    /// The hotkey only works while the app runs. An app that moved, like from ~/Applications to /Applications,
    /// registers again, so the login item opens this copy.
    private func updateLoginItem(_ enabled: Bool) {
        let path = Bundle.main.bundlePath
        // The login item is read and changed through a system daemon, which can be slow to answer, so it happens off
        // the main thread, one change at a time.
        Self.loginItemQueue.async { [weak self] in
            let service = SMAppService.mainApp
            guard enabled else {
                if service.status == .enabled { try? service.unregister() }
                return
            }
            guard service.status != .enabled || UserDefaults.standard.string(forKey: "loginItemPath") != path else { return }
            if service.status == .enabled { try? service.unregister() }
            do {
                try service.register()
                UserDefaults.standard.set(path, forKey: "loginItemPath")
            } catch {
                DispatchQueue.main.async { self?.log("adding the login item failed: \(error)") }
            }
        }
    }

    private static let loginItemQueue = DispatchQueue(label: "muskey.login-item", qos: .utility)

    /// Settings and the key commands of its window and of the lyrics window, which work while one of them is the
    /// active window. The text editing commands are what make Command-V paste lyrics.
    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Muskey", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open File…", action: #selector(openFile), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Open URL…", action: #selector(openLocation), keyEquivalent: "l").target = self
        file.addItem(withTitle: "Save Song…", action: #selector(saveFromMenu), keyEquivalent: "s").target = self
        file.addItem(withTitle: "Stop Playing", action: #selector(stopPlaying), keyEquivalent: "").target = self
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose), keyEquivalent: "w")
        for submenu in [app, file, edit, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }

    @objc private func showSettings() { settingsWindow.show() }

    /// Quitting while the lyrics show keeps the words heard and the lines written so far, as closing the HUD does.
    func applicationWillTerminate(_: Notification) {
        filePlayer.stop()
        cancelAutoListen()
        pitch.stop(waiting: true)
        lyricsSync.end()
        nowPlaying.watching = false
    }

    /// `killall` and Ctrl-C end the app without `applicationWillTerminate`, so they stop the pitch change here.
    /// A crash or SIGKILL can't be caught, but then Core Audio removes the tap and the aggregate device with the
    /// process, and a `.mutedWhenTapped` tap stops muting once nothing reads it.
    private func stopPitchOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.pitch.stop(waiting: true)
                self?.lyricsSync.end()
                self?.filePlayer.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Opening the app again while it runs is the way to Settings when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// While a pitch change runs or a key is kept, the hotkey opens the key picker instead of starting another listen.
    private func toggle() {
        switch state {
        case .idle: (pitch.running && pitchWanted) || keptKey != nil ? pickKey() : start()
        case .listening, .showing: dismiss()
        }
    }

    private func start() {
        session += 1
        stayOpen = true
        state = .listening
        follow = nil
        followByPerson = false
        model.moved = nil
        model.pending = nil
        switch AudioCapturePermission.status {
        case .granted: listen()
        case .denied: fail(.denied, "system audio recording is not allowed")
        case .undetermined:
            let current = session
            AudioCapturePermission.request { [self] granted in
                guard session == current, state == .listening else { return }
                granted ? listen() : fail(.denied, "system audio recording was not allowed")
            }
        }
    }

    /// An open picker keeps its key and its keys during a listen that a song change started.
    private func listen() {
        cancelAutoListen()
        model.phase = .listening
        model.progress = 0
        model.pitchFailed = false
        peak = 0
        estimated = false
        listenSong = nil
        remembered = nil
        lookedUp = nil
        let shownWithKey = model.shown && model.key != nil && !model.lyricsFocus && model.glassFrame.width > 0
        model.shown = true
        if !model.picking {
            if shownWithKey { model.heldGlass = model.glassFrame.size }
            model.key = nil
            // The glass takes the mouse during the listen too, so it can be dragged away.
            panel.setInteraction(clickable: true, keyboard: false)
        }
        panel.present()
        startedAt = Date()
        listenHeardPlaying = false

        let tap = SystemAudioTap()
        self.tap = tap
        do {
            try tap.prepare()
            let analyzer = KeyAnalyzer(sampleRate: tap.sampleRate, speed: playedSpeed, recordTo: Self.stringOption("--wav"))
            self.analyzer = analyzer
            listenTapRate = tap.sampleRate
            try feed(tap, to: analyzer)
        } catch {
            return fail(.failed, "\(error)")
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        startOnKnownKey()
    }

    /// Sends what the tap records to the listen's analyzer, whose estimates show while this listen runs.
    private func feed(_ tap: SystemAudioTap, to analyzer: KeyAnalyzer) throws {
        let current = session
        try tap.start { [weak self] samples in
            analyzer.append(samples) { result, peak in
                guard let self, self.session == current else { return }
                self.update(result, peak: peak)
            }
        }
    }

    /// The song paused during its listen, after it played: the recording and the ticker stop, and the analyzer keeps
    /// what it heard. The HUD keeps the song instead of offering to play, and the listen goes on when the song plays
    /// again. A listen that starts on a paused player still ends on Nothing playing.
    private func pauseListen() {
        guard state == .listening, listenPausedAt == nil else { return }
        ticker?.invalidate()
        ticker = nil
        tap?.stop()
        tap = nil
        listenPausedAt = Date()
        listenPausedSong = nowPlaying.track?.song
        log("the song paused, and the listen waits for it without recording")
    }

    /// The song of a paused listen plays again: a new recording goes to the same analyzer, and the listen's time goes
    /// on from where it stopped.
    private func resumeListen() {
        // Another song gets a listen of its own from the song change.
        guard let pausedAt = listenPausedAt, state == .listening, let analyzer, let track = nowPlaying.track, track.playing,
              track.song == listenPausedSong else { return }
        listenPausedAt = nil
        startedAt += Date().timeIntervalSince(pausedAt)
        let tap = SystemAudioTap()
        do {
            try tap.prepare()
            // Another output device with another rate: the analyzer can't take its sound, so the listen starts over.
            guard tap.sampleRate == listenTapRate else {
                log("the song plays again at another sample rate, listening from the start")
                return listen()
            }
            try feed(tap, to: analyzer)
        } catch {
            return fail(.failed, "\(error)")
        }
        self.tap = tap
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        log("the song plays again, and so does the listen")
    }

    /// A song whose key a full listen found before shows that key at once, with no listen, unless Lock Key has to move
    /// it, which waits for the listen. A song with only Noiseblend's key starts on that key: the HUD shows it with its
    /// row right away, the listen still runs, and only its final estimate can change the key. Runs again on each Now
    /// Playing update until the first estimate, since the helper that reads the song starts with the HUD, and once
    /// more when Noiseblend answers. A click on the key listens again without either.
    private func startOnKnownKey() {
        guard state == .listening, !estimated, remembered == nil, let track = nowPlaying.track, track.playing else { return }
        // A paused player that Now Playing still names may not be what the Mac plays.
        listenSong = listenSong ?? track.song
        guard track.song == listenSong, !redetecting else { return }
        guard let known = knownKey(for: track.song) else {
            if lookedUp != track.song {
                lookedUp = track.song
                lookUpKey(track)
            }
            return
        }
        let key = known.key
        // A key remembered without its tempo, as before Muskey kept tempos, gets one more listen, which finds it.
        if !known.online, follow == nil, knownTempo(for: track.song) != nil { return finishOnKnownKey(key) }
        remembered = key
        log("starting on \(known.online ? "Noiseblend's" : "the remembered") \(key.name)")
        model.key = key
        noteKey(key, final: true, online: known.online)
        if let follow {
            shiftBase = key
            let current = session
            let wait = max(0, Self.originalKeyFor - Date().timeIntervalSince(songChangedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
                guard session == current, state == .listening, !followApplied, let key = model.key, follow == self.follow else { return }
                retarget(key, to: follow, final: false)
            }
        } else if model.picking {
            shiftBase = key
            if keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        if !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        updateHoverKeys()
    }

    /// The key of a song that a listen found before, shown as a listen's result, with no listen.
    private func finishOnKnownKey(_ key: DetectedKey) {
        stopCapture()
        analyzer = nil
        state = .showing
        remembered = key
        model.key = key
        model.phase = .done
        noteKey(key, final: true)
        if model.picking || model.shift != 0 {
            shiftBase = key
            if model.picking, keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        log("\(key.name), known from an earlier listen")
        showTempo()
        if !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        updateHoverKeys()
        if !model.picking, let delay = resultHideDelay { dismiss(after: delay) }
    }

    /// A click on the key: the song is listened to again as if no key were known for it, and the key that the listen
    /// finds replaces the remembered one.
    private func redetect() {
        guard model.saving == nil, model.phase == .done || model.phase == .listening else { return }
        log("re-detecting the key")
        stopCapture()
        analyzer = nil
        redetecting = true
        start()
    }

    private func update(_ result: EKResult, peak: Float) {
        guard state == .listening else { return }
        self.peak = peak
        estimated = true
        // A new song that the first estimate moved keeps that key and shift until the listen ends: on a real song,
        // the estimates can swing between two keys for a while, and each swing would change the pitch.
        if follow != nil, followApplied { return }
        if remembered != nil { return }
        // An open picker keeps its last key if an estimate comes back empty.
        model.key = DetectedKey(result) ?? (model.picking ? model.key : nil)
        guard let key = model.key else { return }
        noteKey(key, final: false)
        if let follow {
            shiftBase = key
            if Date().timeIntervalSince(songChangedAt) >= Self.originalKeyFor { retarget(key, to: follow, final: false) }
        } else if model.picking {
            // The rows relabel in place: each key's column is its shift, so the selected one doesn't move.
            shiftBase = key
            if keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        // The first estimate brings the key strip, which needs clicks.
        if !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        updateHoverKeys()
    }

    private func tick() {
        if let track = nowPlaying.track, track.title?.isEmpty == false {
            if track.playing { listenHeardPlaying = true } else if listenHeardPlaying { return pauseListen() }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        model.progress = min(1, elapsed / seconds)
        // Nothing has made a sound in 3 seconds of a listen that the hotkey started, and no player says that it plays:
        // the HUD offers to play. A song that starts quietly gets its whole listen.
        if follow == nil, !model.picking, elapsed >= Self.idleAfter, peak < 0.0005, nowPlaying.track?.playing != true {
            return nothingPlays(after: elapsed)
        }
        // A song that starts quietly gets the whole listen when it has to be moved to the kept key.
        if ((follow == nil || followByPerson) && elapsed >= silenceAfter && estimated && peak < 0.0005) || elapsed >= seconds { finish() }
    }

    private func stopCapture() {
        ticker?.invalidate()
        ticker = nil
        tap?.stop()
        tap = nil
        listenPausedAt = nil
    }

    private func finish() {
        guard state == .listening, let analyzer else { return }
        stopCapture()
        self.analyzer = nil
        state = .showing
        let current = session
        let elapsed = Date().timeIntervalSince(startedAt)

        analyzer.finish { [self] result, peak, bpm in
            guard session == current else { return }
            let target = follow
            let byPerson = followByPerson
            follow = nil
            followByPerson = false
            guard peak >= 0.0005, let key = DetectedKey(result) else {
                if target != nil { return followFailed(String(format: "no key found in the new song after %.1fs", elapsed)) }
                return fail(.silent, String(format: "silence after %.1fs", elapsed))
            }
            model.key = key
            model.phase = .done
            noteKey(key, final: true)
            // A listen during a pitch change hears the original song, so this is the key the change starts from.
            if let target {
                shiftBase = key
                retarget(key, to: target, final: true, byPerson: byPerson)
            } else if model.picking || model.shift != 0 {
                shiftBase = key
                if model.picking, keptKey != nil { keptKey = model.heard }
                refreshStatus()
            }
            log(String(format: "%@ (relative %@)  strength %.3f  %.1fs", key.name, key.relative.name, result.strength, elapsed))
            if let remembered, remembered != key { log("the full listen found \(key.name), not the \(remembered.name) that it started on") }
            let tempo = heardTempo(bpm, in: listenSong ?? nowPlaying.track?.song)
            if let song = listenSong, let track = nowPlaying.track, track.playing, track.song == song {
                if prefs.rememberKeys { log(keyCache.store(key, strength: result.strength, bpm: tempo, for: song, replace: redetecting)) }
                if let id = KeyCache.id(song) { heardKeys[id] = (key, tempo) }
                keyLookup.heard(key, for: song)
            }
            redetecting = false
            updateHoverKeys()
            guard !model.picking else { return }
            panel.setInteraction(clickable: true, keyboard: false)
            if let delay = resultHideDelay { dismiss(after: delay) }
        }
    }

    private func fail(_ phase: HUDModel.Phase, _ reason: String) {
        stopCapture()
        analyzer = nil
        redetecting = false
        state = .showing
        // The picker opened on an estimate, so it keeps that key rather than turning into an error.
        if model.picking {
            model.phase = .done
            return log(reason)
        }
        model.key = nil
        model.phase = phase
        model.shown = true
        panel.setInteraction(clickable: false, keyboard: false)
        panel.present()
        updateHoverKeys()
        log(reason)
        dismiss(after: 2)
    }

    private static let idleAfter = 3.0

    /// Nothing plays: the HUD stays up with an empty record that plays whatever macOS played last, and the buttons
    /// that open a file or a link. A song that starts meanwhile is listened to at once.
    private func nothingPlays(after elapsed: Double) {
        stopCapture()
        analyzer = nil
        state = .showing
        model.key = nil
        model.phase = .idle
        model.shown = true
        panel.setInteraction(clickable: true, keyboard: true)
        panel.present()
        updateHoverKeys()
        log(String(format: "nothing plays after %.1f s", elapsed))
    }

    /// A song plays while the HUD offers to play one: the listen starts over on it.
    private func listenWhenPlaying() {
        guard model.phase == .idle, model.shown, nowPlaying.track?.playing == true else { return }
        log("a song plays, listening")
        start()
    }

    private func dismiss(after delay: TimeInterval) {
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard session == current, !model.picking else { return }
            // The pointer is on the result, likely on its way to Change Key.
            if model.hovering { return dismiss(after: 1.5) }
            dismiss()
        }
    }

    /// Turns the HUD into the key picker: from a listen's first estimate (the listen keeps going), from a result,
    /// or from the hotkey and the menu bar item while a pitch change runs.
    private func pickKey() {
        guard !model.picking else { return }
        let fromHUD = (state == .listening || (state == .showing && model.phase == .done)) ? model.key : nil
        if fromHUD == nil {
            guard let base = shiftBase else { return }
            stopCapture()
            analyzer = nil
            session += 1
            state = .showing
            model.key = base
            model.phase = .done
        }
        shiftBase = model.key
        model.picking = true
        model.shown = true
        warmUpStems()
        panel.present()
        panel.setInteraction(clickable: true, keyboard: true)

        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags
            // ⌘⌥C moves the HUD back home, in every state, also while a song is saved or the shortcuts show.
            if let self, event.window === self.panel, flags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
               Int(event.keyCode) == kVK_ANSI_C {
                self.panel.returnHome()
                return nil
            }
            // While a song is saved, the HUD takes none of its keys but Escape, which closes it. ⌘Q and the other
            // menu keys still work.
            if let self, self.model.saving != nil, event.window === self.panel {
                if Int(event.keyCode) == kVK_Escape { return self.handleKey(kVK_Escape, shift: false, option: false) ? nil : event }
                return flags.contains(.command) && !Self.hudCommandKeys.contains(Int(event.keyCode)) ? event : nil
            }
            // The shortcuts hide what the HUD's keys with Command change, so those keys wait until they close.
            if let self, self.model.shortcuts, event.window === self.panel, flags.contains(.command) {
                return Self.hudCommandKeys.contains(Int(event.keyCode)) ? nil : event
            }
            // ⌘V plays the file or the link on the clipboard, while the HUD takes the keyboard.
            if let self, event.window === self.panel, flags.contains(.command), Int(event.keyCode) == kVK_ANSI_V {
                return self.pasteSongs() ? nil : event
            }
            // ⌘⌫ takes the song back to how it was: its key, its tempo and every stem.
            if let self, self.model.picking || self.model.phase == .idle, event.window === self.panel, flags.contains(.command),
               Int(event.keyCode) == kVK_Delete {
                self.resetAll()
                return nil
            }
            // ⌘O and ⌘L open a file or a link.
            if let self, event.window === self.panel, flags.contains(.command),
               [kVK_ANSI_O, kVK_ANSI_L].contains(Int(event.keyCode)) {
                Int(event.keyCode) == kVK_ANSI_O ? self.openFile() : self.openLocation()
                return nil
            }
            // ⌘+ and ⌘− zoom the waveform.
            if let self, event.window === self.panel, flags.contains(.command), !flags.contains(.option),
               [kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus].contains(Int(event.keyCode)) {
                self.zoomWaveform([kVK_ANSI_Equal, kVK_ANSI_KeypadPlus].contains(Int(event.keyCode)) ? 1.5 : 1 / 1.5)
                return nil
            }
            // ⌘K opens karaoke, or closes it.
            if let self, self.model.picking, event.window === self.panel, flags.contains(.command), !flags.contains(.option),
               Int(event.keyCode) == kVK_ANSI_K {
                self.toggleKaraoke()
                return nil
            }
            // ⌘S saves the song with its changes.
            if let self, self.model.picking, event.window === self.panel, flags.contains(.command), !flags.contains(.option),
               Int(event.keyCode) == kVK_ANSI_S, self.model.savable {
                self.saveSong()
                return nil
            }
            // Typing in the lyrics editor, or a time of the region loop, stays in the field.
            if self?.loopTyping == true { return event }
            guard let self, self.model.picking, !flags.contains(.command), !flags.contains(.control),
                  event.window == nil || event.window === self.panel else { return event }
            return self.handleKey(Int(event.keyCode), shift: flags.contains(.shift), option: flags.contains(.option)) ? nil : event
        }
        updateHoverKeys()
    }

    /// The keys with Command that the HUD uses, which a save in progress turns off.
    private static let hudCommandKeys: Set<Int> = [kVK_ANSI_V, kVK_Delete, kVK_ANSI_O, kVK_ANSI_L, kVK_ANSI_K, kVK_ANSI_S]

    /// Letter keys: A picks the A in the song's mode, Option the A in the other mode, and Shift the key with a sharp or
    /// flat on A.
    private static let letters: [Int: Character] = [
        kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_A: "A", kVK_ANSI_B: "B",
    ]

    /// Keys of the key picker, from the picker's own key events or from the hotkeys that hovering over the HUD
    /// registers. Returns false for a key it doesn't use.
    @discardableResult private func handleKey(_ code: Int, shift: Bool, option: Bool) -> Bool {
        if Self.logKeys { log("key \(code)\(shift ? " shift" : "")\(option ? " option" : "")") }
        // A save in progress leaves the HUD only Escape, which closes it while the save goes on.
        if model.saving != nil {
            if code == kVK_Escape { dismiss() }
            return true
        }
        // ? shows every key and gesture in place of the HUD, and closes them again, on whichever key types ? in the
        // keyboard layout. While they show, Escape closes them too, and the other keys do nothing, since what they
        // change is hidden under them.
        if let question = LayoutKey.questionMark, code == question.code, shift == question.shift, option == question.option {
            model.shortcuts.toggle()
            return true
        }
        if model.shortcuts {
            if code == kVK_Escape { model.shortcuts = false }
            return true
        }
        if !shift, handleSongKey(code, option: option) { return true }
        // With the key row hidden, the keys that change the pitch would change it out of sight.
        if handleStemKey(code, option: option) { return true }
        if model.speedAdjustable, let step = Self.speedKeys[code] {
            changeSpeed(by: step)
            return true
        }
        if code == kVK_Space {
            playPause()
            return true
        }
        // W shows or hides the waveform in every layout, and ⌥W splits it into the lanes of the stems.
        if code == kVK_ANSI_W, !shift {
            option ? toggleWaveformLanes() : toggleWaveform()
            return true
        }
        // R starts the region loop, ends it and clears it, in every layout. ⌥R doesn't snap the end.
        if code == kVK_ANSI_R, !shift {
            pressLoop(snapping: !option)
            return true
        }
        if model.lyricsShown {
            switch code {
            case kVK_Escape: dismiss()
            case kVK_Return, kVK_ANSI_KeypadEnter: toggleLyricsFocus()
            case kVK_ANSI_L: toggleLyrics()
            // Karaoke has no layout button, and the layout under it would change out of sight.
            case kVK_ANSI_S where !model.lyricsFocus: toggleLayout()
            case kVK_ANSI_K: toggleKeep()
            // Karaoke changes the key with the keys of the key row, which shows while the pointer is over the key
            // at the top. Delete in the original key has nothing to undo, and leaves karaoke as it is.
            case kVK_Delete where model.lyricsFocus && model.shift == 0 && !model.relative && model.pending == nil: break
            default:
                guard model.lyricsFocus else { return false }
                return handlePitchKey(code, shift: shift, option: option)
            }
            return true
        }
        switch code {
        case kVK_ANSI_L: toggleLyrics()
        case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter: dismiss()
        // In the original key, with no move waiting for a new song's key, there is nothing to undo: close the HUD.
        case kVK_Delete where model.shift == 0 && !model.relative && model.pending == nil: dismiss()
        case kVK_Delete: change(to: 0, relative: false)
        case kVK_ANSI_K: toggleKeep()
        case kVK_ANSI_S: toggleLayout()
        default: return handlePitchKey(code, shift: shift, option: option)
        }
        return true
    }

    /// Keys 0 to 9, for the seeks over the record and in karaoke.
    private static let digitKeys = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// N and P play the next and the previous song in every layout. With the lyrics, ← and → seek 5 seconds back or
    /// ahead, except while karaoke shows its key row, which takes them for the key. In karaoke, 0 starts the song over
    /// and 1 to 9 move it to a tenth of its length, except while the stems show, which take the numbers. The seeks
    /// exist only while they are instant (`model.seekable`): a seek while the stems are separated live would start
    /// their countdown again.
    private func handleSongKey(_ code: Int, option: Bool) -> Bool {
        // Over the record and its time bar, ← → move the song 5 seconds, 0 starts it over and 1 to 9 move it to a
        // tenth of its length, in every layout. The numbers mute no stem there, even while a seek can't be instant.
        if model.overRecord, !option {
            switch code {
            case kVK_LeftArrow where model.seekable: seek(by: -5); return true
            case kVK_RightArrow where model.seekable: seek(by: 5); return true
            case kVK_ANSI_0 where model.restartable: startOver(); return true
            default:
                if let digit = Self.digitKeys.firstIndex(of: code), digit > 0 {
                    if model.seekable { seek(toFraction: Double(digit) / 10) } else { log("seek: the stems are separated as the song plays") }
                    return true
                }
            }
        }
        switch code {
        case kVK_ANSI_N where !option: skip(1)
        case kVK_ANSI_P where !option: skip(-1)
        case kVK_LeftArrow where model.seekable && model.lyricsShown && !model.karaokeKeys: seek(by: -5)
        case kVK_RightArrow where model.seekable && model.lyricsShown && !model.karaokeKeys: seek(by: 5)
        // In karaoke, 0 starts the song over in every player, as karaoke's own start does, unless the stems show.
        case kVK_ANSI_0 where model.restartable && model.lyricsFocus && !option && !(model.stemsAvailable && model.karaokeStems): startOver()
        // Karaoke's arrows change the key only while its key row shows, so they never change it out of sight.
        case kVK_LeftArrow where model.lyricsFocus && !model.karaokeKeys, kVK_RightArrow where model.lyricsFocus && !model.karaokeKeys: break
        default:
            guard model.seekable, model.lyricsFocus, !option, !(model.stemsAvailable && model.karaokeStems), let digit = Self.digitKeys.firstIndex(of: code)
            else { return false }
            seek(toFraction: Double(digit) / 10)
        }
        return true
    }

    /// The position that the last seek asked for, until the player reports it, so that quick presses add up.
    private var seekTarget: (song: [String?], seconds: Double, at: Date)?
    /// Checks that the player moved the song, a few seconds after a seek.
    private var seekCheck: DispatchWorkItem?
    /// The path that moved the song in each player, which its next seeks take at once.
    private var seekPaths: [String: SeekPath] = [:]
    /// `--seek-path elapsed|command|script` sends every seek through that path alone, for testing each one.
    private static let forcedSeekPath = TestFlags.value("--seek-path").flatMap(SeekPath.init(rawValue:))
    /// `--seek-ignore elapsed,command` sends nothing through those paths, as a player that ignores them would have it,
    /// for testing the fallbacks.
    private static let ignoredSeekPaths = Set((TestFlags.value("--seek-ignore") ?? "").split(separator: ",").compactMap { SeekPath(rawValue: String($0)) })
    /// Players that left the song where it was after a seek. The seek keys leave them alone until Muskey quits.
    private var unseekable: Set<String> = []

    /// The key 0 in karaoke: the song starts over, at once while the stems are off, and with karaoke's own start
    /// while they play: the sound dips, the song plays from its start under the countdown, and it rewinds to the start
    /// without the muted stems.
    private func startOver() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        if let id = track.bundleID, unseekable.contains(id) { return log("start over: \(id) ignored the last seek") }
        if case .seeking = karaokeRestart { return log("start over: the last move isn't done yet") }
        guard !lyricsDelayed else { return log("start over: the song plays behind itself while Whisper writes its lyrics") }
        guard model.stemsEngaged, !cachedStems else { return seek(to: 0, flash: "0%") }
        if model.shown { model.playFlash = PlayFlash(playing: model.playing, id: (model.playFlash?.id ?? 0) + 1, seek: "0%") }
        guard StemModel.prepared else {
            log("karaoke: the song starts over once the model is ready")
            karaokeRestart = .waitingForModel
            return
        }
        beginKaraokeRestart()
    }

    // MARK: Saving

    /// Where a song is saved from: the file that Muskey Player plays, or another player, which plays the song from
    /// its start to its end while Muskey records it.
    private enum SaveSource: Equatable {
        case file(path: String)
        case player(bundleID: String, song: [String?], seconds: Double)
    }

    private struct SaveJob: Equatable {
        let name: String
        let source: SaveSource
        let changes: SongChanges
        let url: URL
        let format: SaveFormat
    }

    /// The song being saved, and the last save that failed, for Retry.
    private var saveJob: SaveJob?
    private var failedSave: SaveJob?
    /// The file of the last save, for Show in Finder.
    private var savedURL: URL?
    /// The pill at the top right: a song that opens takes it, and the save shows again once that is done.
    private var openActivity: OpenActivity? {
        didSet { activityPill.show(openActivity ?? saveActivity) }
    }
    private var saveActivity: OpenActivity? {
        didSet {
            activityPill.show(openActivity ?? saveActivity)
            let saving: SavingState? = switch saveActivity {
            case let .saving(name, progress): SavingState(name: name, progress: progress, left: nil)
            case let .recording(name, left, progress): SavingState(name: name, progress: progress, left: left)
            default: nil
            }
            if model.saving != saving { model.saving = saving }
        }
    }
    /// Set by Cancel, and read by the thread that renders the save, which stops at its next step.
    private var saveCancelled = OSAllocatedUnfairLock(initialState: false)

    /// The changes that a save keeps, nil when the song plays as it is.
    private func saveChanges() -> SongChanges? {
        var changes = SongChanges(semitones: model.shift, speed: currentSpeed)
        if model.stemsEngaged, model.stemsAdjusted {
            changes.stemGains = Stem.allCases.map { model.stemsMuted.contains($0) ? 0 : Float(model.stemVolumes[$0] ?? 1) }
        }
        return changes.isEmpty ? nil : changes
    }

    private func saveSource() -> SaveSource? {
        guard let track = nowPlaying.track else { return nil }
        if track.bundleID == FilePlayer.bundleID { return filePlayer.current.map { .file(path: $0.path) } }
        // Another player has to move the song to its start, and the song has to fit in memory.
        guard model.restartable, let id = track.bundleID, let seconds = track.duration, seconds > 1, seconds <= SongRecorder.maxSeconds
        else { return nil }
        return .player(bundleID: id, song: track.song, seconds: seconds)
    }

    private func syncSavable() {
        let savable = saveChanges() != nil && saveSource() != nil
        guard savable != model.savable else { return }
        model.savable = savable
        updateHoverKeys()
    }

    /// Save Song in the menus, the button on the HUD and ⌘S: asks where to save the song, then renders it with the
    /// changes it plays with now.
    private func saveSong() {
        guard saveJob == nil else { return log("save: a song is being saved already") }
        // The changes are taken at the press, so a change made while the panel is open doesn't go in the file.
        guard let changes = saveChanges(), let source = saveSource() else { return log("save: nothing changed, or the song can't be saved") }
        let title = switch source {
        case let .file(path): filePlayer.current?.title ?? nowPlaying.track?.title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .player: nowPlaying.track?.title ?? "Song"
        }
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var caveat: String?
        if case let .player(id, _, _) = source {
            caveat = SongRecorder.hearsPlayerOnly(bundleID: id, pid: nowPlaying.track?.pid) ? SaveCaveat.recorded : SaveCaveat.recordedWithOthers
        }
        guard let (url, format) = askWhereToSave(fileName(name, changes), caveat: caveat) else { return log("save: cancelled") }
        startSave(SaveJob(name: name, source: source, changes: changes, url: url, format: format))
    }

    /// The title, and what changed in parentheses: `Bine (C minor, 90%, no vocals)`.
    private func fileName(_ name: String, _ changes: SongChanges) -> String {
        var parts: [String] = []
        if changes.semitones != 0, let base = shiftBase { parts.append(model.shown(base.transposed(by: changes.semitones)).name) }
        if abs(changes.speed - 1) > 0.001 { parts.append("\(Int((changes.speed * 100).rounded()))%") }
        if let gains = changes.stemGains {
            let muted = Stem.shown.filter { gains[$0.rawValue] == 0 }, playing = Stem.shown.filter { gains[$0.rawValue] > 0 }
            if muted.isEmpty {
                parts.append("stem volumes")
            } else if playing.count == 1 {
                parts.append("\(playing[0].name.lowercased()) only")
            } else if muted.count <= 2 {
                parts.append("no " + muted.map { $0.name.lowercased() }.joined(separator: " and "))
            } else {
                parts.append("\(playing.count) stems")
            }
        }
        return parts.isEmpty ? name : "\(name) (\(parts.joined(separator: ", ")))"
    }

    private func askWhereToSave(_ name: String, caveat: String?) -> (URL, SaveFormat)? {
        let panel = NSSavePanel()
        panel.title = "Save Song"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        var format = prefs.saveFormat
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(name).\(format.rawValue)"
        let pick = { (picked: SaveFormat) in
            format = picked
            panel.allowedContentTypes = [picked.type]
            panel.nameFieldStringValue = ((panel.nameFieldStringValue as NSString).deletingPathExtension as NSString).appendingPathExtension(picked.rawValue) ?? name
        }
        let accessory = NSHostingView(rootView: SaveAccessory(format: format, caveat: caveat, picked: pick))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        // `--save-pick wav` picks a format a second after the panel opens, as the Format picker does: macOS draws the
        // panel in a service process, which takes neither posted clicks nor accessibility.
        if let test = Self.stringOption("--save-pick").flatMap(SaveFormat.init(rawValue:)) {
            let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                pick(test)
                self?.log("save: picked \(test.name) for the test, the name reads \(panel.nameFieldStringValue)")
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        guard inFront({ panel.runModal() }) == .OK, let url = panel.url else { return nil }
        prefs.saveFormat = format
        return (url, format)
    }

    private func retrySave() {
        guard let job = failedSave, saveJob == nil else { return }
        startSave(job)
    }

    /// Renders the song on a thread of its own, into a temporary file that replaces the chosen one once it is whole.
    /// A song from another player is recorded first, as it plays from its start to its end.
    private func startSave(_ job: SaveJob, recorded: StereoAudio? = nil) {
        saveJob = job
        failedSave = nil
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        saveCancelled = cancelled
        if case .player = job.source, recorded == nil { return startRecording(job) }
        saveActivity = .saving(name: job.name, progress: 0)
        let changes = job.changes
        log(String(format: "save: %@ as %@, %+d semitones, %.0f%% tempo%@", job.name, job.format.name, changes.semitones, changes.speed * 100,
                   changes.stemGains == nil ? "" : ", stems \(changes.stemGains!.map { String(format: "%.2f", $0) }.joined(separator: " "))"))
        // With the stems separated for the output too, the separation of the whole song leaves them half of the time.
        let live = model.stemsEngaged
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var shown = -1
            let report = { (part: Double) -> Bool in
                let percent = Int(part * 100)
                if percent != shown {
                    shown = percent
                    DispatchQueue.main.async {
                        guard let self, self.saveJob == job else { return }
                        self.saveActivity = .saving(name: job.name, progress: part)
                    }
                }
                return !cancelled.withLock { $0 }
            }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "Muskey save \(UUID().uuidString).\(job.format.rawValue)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let audio: StereoAudio
                var path: String?
                if let recorded {
                    audio = recorded
                } else if case let .file(file) = job.source {
                    audio = try SongRender.read(URL(fileURLWithPath: file))
                    path = file
                } else {
                    throw SaveError(message: "The song has no file")
                }
                let rendered = try SongRender.render(audio, changes: changes, path: path, live: { live }) { report($0 * 0.95) }
                try SongRender.write(rendered, as: job.format, to: temporary) { report(0.95 + $0 * 0.05) }
                // Cancel in the last moment of the write leaves no file either.
                if cancelled.withLock({ $0 }) { throw CancellationError() }
                if FileManager.default.fileExists(atPath: job.url.path) { try FileManager.default.removeItem(at: job.url) }
                try FileManager.default.moveItem(at: temporary, to: job.url)
                DispatchQueue.main.async { self?.saveFinished(job, error: nil, seconds: Date().timeIntervalSince(started), length: rendered.seconds) }
            } catch {
                DispatchQueue.main.async { self?.saveFinished(job, error: error, seconds: Date().timeIntervalSince(started), length: 0) }
            }
        }
    }

    /// A song from another player, recorded for Save Song: the player pauses, moves the song to its start and plays
    /// it, and the recording ends at the song's length. A pause, a seek or another song ends it with a failure, which
    /// Retry starts over.
    private final class SongRecording {
        /// Learning the move that the player takes, while the song plays, then the pause, the move sent while paused
        /// (which a paused player reports no position for), and the song playing from its start.
        enum Phase { case learning, pausing, moving, playing }
        let job: SaveJob
        let recorder: SongRecorder
        var phase = Phase.pausing
        var since = Date()
        var timer: Timer?

        init(job: SaveJob, recorder: SongRecorder) {
            self.job = job
            self.recorder = recorder
        }
    }

    private var songRecording: SongRecording?

    private func startRecording(_ job: SaveJob) {
        // The player moves under a slowed song, which would stop the recording, so the song plays as it is while it is
        // recorded, and the save slows it down. The slowing comes back after the save.
        if slow.active {
            speedBeforeRecording = slow.speed
            slow.stop("the song is recorded for a save")
        }
        guard case let .player(id, _, seconds) = job.source, let track = nowPlaying.track, track.bundleID == id else {
            return saveFinished(job, error: SaveError(message: "The song isn't playing anymore"), seconds: 0, length: 0)
        }
        let recorder = SongRecorder(bundleID: id, pid: track.pid)
        let recording = SongRecording(job: job, recorder: recorder)
        songRecording = recording
        updateWatching(shown: model.shown)
        saveActivity = .recording(name: job.name, left: Self.clock(seconds))
        log("save: recording \(job.name) from \(recorder.playerOnly ? id + " alone" : "every app but Muskey")")
        recording.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkRecording() }
        guard Self.forcedSeekPath == nil, seekPaths[id] == nil else {
            if track.playing { nowPlaying.play(false) }
            return checkRecording()
        }
        // A paused player gives no position to check a move against, so the move that this player takes is learned
        // while the song plays, from its start.
        recording.phase = .learning
        if !track.playing { nowPlaying.play(true) }
        movePlayer(track, to: 0) { [weak self] moved in
            guard let self, songRecording === recording else { return }
            guard moved else { return endRecording(error: SaveError(message: "The player didn't move the song to its start")) }
            recording.phase = .pausing
            recording.since = Date()
            nowPlaying.play(false)
        }
    }

    /// Sends a move through the path that moved the song in this player before, without checking it.
    private func sendMove(_ track: NowPlaying.Track, to target: Double) {
        guard let id = track.bundleID, id != FilePlayer.bundleID else {
            return track.bundleID == FilePlayer.bundleID ? filePlayer.seek(target) : nowPlaying.seek(to: target)
        }
        switch Self.forcedSeekPath ?? seekPaths[id] ?? .elapsed {
        case .elapsed: nowPlaying.seek(to: target)
        case .command: if let pid = track.pid { nowPlaying.seek(to: target, pid: pid) } else { nowPlaying.seek(to: target) }
        case .script: PlayerScript.seek(id, to: target) { _ in }
        }
    }

    /// Steps the recording on, from the reports of the player and a timer.
    private func checkRecording() {
        guard let recording = songRecording, case let .player(_, song, seconds) = recording.job.source else { return }
        let track = nowPlaying.track
        let waited = Date().timeIntervalSince(recording.since)
        switch recording.phase {
        case .learning:
            break
        case .pausing:
            // The player stopped, or didn't answer within 3 seconds: the recording starts, then the song moves.
            guard track?.playing == false || waited > 3, let track else { return }
            do {
                try recording.recorder.start()
            } catch {
                return endRecording(error: SaveError(message: "The song can't be recorded: \(error)"))
            }
            recording.phase = .moving
            recording.since = Date()
            sendMove(track, to: 0)
        case .moving:
            // The player had a moment to take the move. A song that stayed where it was ends the recording below, once
            // it plays.
            guard waited > 0.6 else { return }
            recording.phase = .playing
            recording.since = Date()
            nowPlaying.play(true)
        case .playing:
            let rate = recording.recorder.rate, frames = recording.recorder.frames, target = Int(seconds * rate)
            if frames >= target { return endRecording(error: nil) }
            // Another song: a recording that is all but done keeps what it has.
            if let track, track.song != song {
                return frames >= target - Int(2 * rate) ? endRecording(error: nil)
                    : endRecording(error: SaveError(message: "Another song started"))
            }
            if waited > 10, !recording.recorder.heard { return endRecording(error: SaveError(message: "Nothing was heard from the player")) }
            // A pause stops the recording, and the save keeps the part recorded until then.
            if waited > 2, track?.playing == false {
                log("save: the song was paused, saving the part recorded so far")
                return endRecording(error: nil, partial: true)
            }
            // A seek moves the player away from the recording, which counts the song from its first sound.
            if recording.recorder.heard, let position = track?.position(at: Date()), abs(position - Double(frames) / rate) > 4 {
                return endRecording(error: SaveError(message: String(format: "The song moved to %.0f s", position)))
            }
            saveActivity = .recording(name: recording.job.name, left: Self.clock(Double(target - frames) / rate), progress: Double(frames) / Double(max(1, target)))
        }
    }

    /// Ends the recording of a song from another player. `partial` saves the part recorded so far, without the silence
    /// after it, and `cancelled` saves nothing.
    private func endRecording(error: Error?, partial: Bool = false, cancelled: Bool = false) {
        guard let recording = songRecording, case let .player(_, _, seconds) = recording.job.source else { return }
        recording.timer?.invalidate()
        songRecording = nil
        updateWatching(shown: model.shown)
        if let speed = speedBeforeRecording {
            speedBeforeRecording = nil
            DispatchQueue.main.async { [weak self] in
                self?.syncSpeed()
                self?.playSpeed(speed)
            }
        }
        var audio = recording.recorder.stop(frames: Int(seconds * recording.recorder.rate))
        if cancelled { return }
        if let error { return saveFinished(recording.job, error: error, seconds: 0, length: 0) }
        if partial {
            audio = audio.trimmingSilentEnd()
            guard audio.seconds >= 1 else { return saveFinished(recording.job, error: SaveError(message: "Nothing was recorded yet"), seconds: 0, length: 0) }
        }
        log(String(format: "save: recorded %.1f s of %@ at %.0f Hz", audio.seconds, recording.job.name, audio.rate))
        startSave(recording.job, recorded: audio)
    }

    /// Cancel on the HUD while a song is saved: a recording stops, a render stops at its next step, and no file is
    /// written.
    private func cancelSave() {
        guard let job = saveJob else { return }
        log("save: \(job.name) cancelled")
        saveCancelled.withLock { $0 = true }
        if songRecording != nil { endRecording(error: nil, cancelled: true) }
        saveJob = nil
        saveActivity = nil
    }

    /// Stop and Save on the HUD while a song from another player is recorded: the save keeps the part recorded so far.
    /// Before the song plays from its start, nothing is recorded, and it cancels.
    private func stopSave() {
        guard let recording = songRecording else { return }
        guard recording.phase == .playing else { return cancelSave() }
        log("save: stopped, saving the part recorded so far")
        endRecording(error: nil, partial: true)
    }

    /// `2:15` for the time left.
    private static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d left", whole / 60, whole % 60)
    }

    private func saveFinished(_ job: SaveJob, error: Error?, seconds: Double, length: Double) {
        guard saveJob == job else { return }
        saveJob = nil
        if let error {
            log("save: \(job.name) failed: \(error.localizedDescription)")
            failedSave = job
            saveActivity = .saveFailed(name: job.name)
            return
        }
        log(String(format: "save: wrote %@ (%.1f s of song) in %.1f s", job.url.lastPathComponent, length, seconds))
        savedURL = job.url
        saveActivity = .saved(name: job.name)
        // The pill of a finished save goes away by itself after a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if case .saved = self?.saveActivity { self?.saveActivity = nil }
        }
    }

    /// Seeks are instant only while nothing plays behind the song: with the stems separated live, a seek would wait
    /// for them again under a countdown, and the lyrics delay would start over. A song in Muskey Player with its stems
    /// in the cache seeks at once with the stems on, since the stems of the new place are there already.
    private func syncSeekable() {
        let track = nowPlaying.track
        let restartable = track?.title?.isEmpty == false && !(track?.bundleID.map(unseekable.contains) ?? false) && !lyricsDelayed
        let seekable = restartable && (!model.stemsEngaged || cachedStems)
        guard seekable != model.seekable || restartable != model.restartable else { return }
        model.restartable = restartable
        model.seekable = seekable
        if Self.logKeys { log("seek keys \(seekable ? "on" : "off")") }
        updateHoverKeys()
    }

    /// Deletes the cached stems and the songs downloaded from links that weren't played for the period in Settings >
    /// General > Cache. The song in Muskey Player and its stems stay, however long it has been playing.
    private func sweepCaches() {
        let age = prefs.cacheCleanup.rawValue
        guard age > 0 else { return }
        let playing = filePlayer.current?.path
        Self.cacheSweepQueue.async { [weak self] in
            var kept: Set<String> = []
            if let playing {
                kept.insert(playing)
                if let stems = StemsCache.url(for: playing) { kept.formUnion([stems.path, stems.appendingPathExtension("partial").path]) }
            }
            let stems = StemsCache.sweep(olderThan: age, keeping: kept)
            let songs = LinkCache().sweep(olderThan: age, keeping: kept)
            guard stems + songs > 0 else { return }
            DispatchQueue.main.async { self?.log("cache cleanup: deleted \(stems) stems files and \(songs) downloaded songs") }
        }
    }

    private func seek(by seconds: Double) {
        guard let track = nowPlaying.track else { return }
        let pending = seekTarget.flatMap { $0.song == track.song && Date().timeIntervalSince($0.at) < 2 ? $0.seconds : nil }
        guard let base = pending ?? track.position(at: Date()) else { return log("seek: the player gives no position for the song") }
        seek(to: base + seconds, flash: seconds < 0 ? "gobackward.5" : "goforward.5")
    }

    private func seek(toFraction fraction: Double) {
        guard let duration = nowPlaying.track?.duration, duration > 0 else { return log("seek: the player gives no length for the song") }
        seek(to: duration * fraction, flash: "\(Int((fraction * 100).rounded()))%")
    }

    /// Moves the song that plays to `seconds` and flashes the record with `flash`, a percent or an SF Symbol.
    private func seek(to seconds: Double, flash: String) {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        guard model.seekable else { return log("seek: not now, the stems or the lyrics delay would start over") }
        let target = max(0, min(seconds, (track.duration ?? .infinity) - 1))
        seekTarget = (track.song, target, Date())
        log(String(format: "seek to %.1f s", target))
        if model.shown { model.playFlash = PlayFlash(playing: model.playing, id: (model.playFlash?.id ?? 0) + 1, seek: flash) }
        // The output goes quiet until the stems of the new place play, a moment after the player moves the song.
        if model.stemsEngaged, cachedStems { pitch.cachedSeek(to: target) }
        moveSong(track, to: target)
    }

    /// Moves the song that is heard: through the slowed stream while it is slowed down, which jumps to the move.
    private func moveSong(_ track: NowPlaying.Track, to target: Double, done: ((Bool) -> Void)? = nil) {
        guard slow.active, track.bundleID != FilePlayer.bundleID else { return movePlayer(track, to: target, done: done) }
        slow.moved(track, to: target)
        done?(true)
    }

    /// Moves the song in the player of `track` to `target` seconds. Players differ in the seek they take, so the first
    /// seek in a player sets the elapsed time that Now Playing shows, and when the song didn't move 2.5 seconds later,
    /// it sends the seek command to the player's process, then sets the time through the player's AppleScript, which
    /// asks for the Automation permission the first time. The path that moved the song is kept for the player's next
    /// seeks, and a player that took none goes in `unseekable`. `done` gets whether the song moved.
    private func movePlayer(_ track: NowPlaying.Track, to target: Double, path: SeekPath? = nil, done: ((Bool) -> Void)? = nil) {
        guard let id = track.bundleID, id != FilePlayer.bundleID else {
            if track.bundleID == FilePlayer.bundleID { filePlayer.seek(target) } else { nowPlaying.seek(to: target) }
            done?(true)
            return
        }
        let path = path ?? Self.forcedSeekPath ?? seekPaths[id] ?? .elapsed
        let asked = Date()
        let before = track.position(at: asked)
        seekCheck?.cancel()
        seekCheck = nil
        // Checks where the song is a while after the move was sent, and tries the next path when it stayed.
        func check(_ sent: Date, tries: Int = 0) {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard let now = nowPlaying.player, now.song == track.song else {
                    log(nowPlaying.player == nil ? "seek: nothing plays, the move is over"
                        : "seek: another song plays (\(nowPlaying.player?.label ?? "")), the move is over")
                    return done?(false) ?? ()
                }
                guard let position = now.position(at: Date()) else {
                    // Music leaves the time out of its report right after a move, until the next report.
                    if tries < 3 { return check(sent, tries: tries + 1) }
                    log("seek: the player gives no position (elapsed \(now.elapsed.map { String($0) } ?? "none"), rate \(now.rate.map { String($0) } ?? "none")), the move is over")
                    return done?(false) ?? ()
                }
                let rate = now.playing ? now.rate ?? 1 : 0
                if abs(position - (target + Date().timeIntervalSince(sent) * rate)) <= 2 {
                    log("seek: \(id) moved the song through the \(path.name)")
                    seekPaths[id] = path
                    return done?(true) ?? ()
                }
                // A player that ignored the seek is still near where the song would have been without it.
                guard let before, abs(position - (before + Date().timeIntervalSince(asked) * rate)) < 1.5 else {
                    log(String(format: "seek: the song is at %.1f s, neither where it was nor where it was sent", position))
                    return done?(false) ?? ()
                }
                if Self.forcedSeekPath == nil, let next = path.next(for: id) {
                    log("seek: \(id) left the song where it was after the \(path.name), trying the \(next.name)")
                    return movePlayer(now, to: target, path: next, done: done)
                }
                unseekable.insert(id)
                log("seek: \(id) left the song where it was")
                syncSeekable()
                done?(false)
            }
            seekCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 2.5 : 1.5), execute: work)
        }
        if Self.ignoredSeekPaths.contains(path), path != .script {
            log("seek: nothing sent through the \(path.name), for the test")
            return check(asked)
        }
        switch path {
        case .elapsed:
            nowPlaying.seek(to: target)
            check(asked)
        case .command:
            guard let pid = track.pid else {
                log("seek: Now Playing gives no process for \(id)")
                return path.next(for: id).map { movePlayer(track, to: target, path: $0, done: done) } ?? (done?(false) ?? ())
            }
            nowPlaying.seek(to: target, pid: pid)
            check(asked)
        case .script:
            log("seek: asking \(id) through AppleScript")
            PlayerScript.seek(id, to: target) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .sent:
                    check(Date())
                case .refused:
                    log("seek: Automation for \(id) isn't allowed")
                    unseekable.insert(id)
                    syncSeekable()
                    done?(false)
                case let .failed(reason):
                    log("seek: \(reason)")
                    unseekable.insert(id)
                    syncSeekable()
                    done?(false)
                }
            }
        }
    }

    /// The keys that change the key: Delete, the arrows and the letters, with Shift for a sharp or a flat and Option
    /// for the other mode. The key row and karaoke take them.
    private func handlePitchKey(_ code: Int, shift: Bool, option: Bool) -> Bool {
        // The card's ring only shows outside karaoke, which has the key row.
        let ring = model.card && !model.lyricsFocus
        switch code {
        case kVK_Delete: change(to: 0, relative: false)
        // The row steps a semitone, and the single card steps around its ring of keys, clockwise for →.
        case kVK_LeftArrow: change(to: ring ? FifthsRing.step(from: model.shift, by: -1) : model.shift - 1)
        case kVK_RightArrow: change(to: ring ? FifthsRing.step(from: model.shift, by: 1) : model.shift + 1)
        // An octave either way, as long as it stays within an octave of the original.
        case kVK_DownArrow where model.shift - 12 >= Shift.range.lowerBound: change(to: model.shift - 12)
        case kVK_UpArrow where model.shift + 12 <= Shift.range.upperBound: change(to: model.shift + 12)
        case kVK_DownArrow, kVK_UpArrow: break
        default:
            guard let letter = Self.letters[code], let key = model.key else { return false }
            // A letter picks a key in the mode that the row shows, which is the other mode after a key was picked
            // in it, and Option picks one in the mode that it hides.
            let other = option != model.relative
            let minor = other ? !key.minor : key.minor
            // A letter with no sharp or flat key in that mode does nothing with Shift, but still counts as used.
            guard let pitchClass = DetectedKey.pitchClass(letter: letter, accidental: shift, minor: minor) else { return true }
            change(to: key.shift(to: DetectedKey(pitchClass: pitchClass, minor: minor)), relative: other)
        }
        return true
    }

    /// A key pressed over a result or a listen opens the picker first, so the HUD stays up with the change.
    /// `relative` names the keys in the other mode, and nil keeps the mode that they are named in.
    private func change(to semitones: Int, relative: Bool? = nil) {
        guard model.pending == nil else { return }
        if !model.picking { pickKey() }
        setShift(semitones, relative: relative)
    }

    /// Lock Key in the HUD, the K key and the menu: the key that is heard now is the one every next song gets.
    private func toggleKeep() {
        if !model.picking, state != .idle { pickKey() }
        if keptKey == nil {
            let base = state == .idle ? shiftBase : model.key ?? shiftBase
            guard let base else { return log("no key to lock yet") }
            keptKey = model.shown(base.transposed(by: model.shift))
            log("keeping \(keptKey!.name) for the next songs")
        } else {
            keptKey = nil
            follow = nil
            model.pending = nil
            log("not keeping a key for the next songs")
            if !pitchWanted, !model.picking, pitch.running { pitch.stopSmoothly { [self] in logShift() } }
        }
    }

    /// The corner button and the S key: the single card or the wide layout, remembered for the next launch.
    private func toggleLayout() { setLayout(card: !model.card) }

    /// Keys 1 to 7 for the stems in the order that the HUD shows them (7 with the winds model).
    private static let stemKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7]

    /// Keys 1 to 7 mute a stem or play it again, with Option they play only that stem, and 0 plays every stem.
    /// V fades the vocals out or back in, in every layout.
    private func handleStemKey(_ code: Int, option: Bool) -> Bool {
        guard model.stemsAvailable else { return false }
        if code == kVK_ANSI_0 {
            playAllStems()
        } else if code == kVK_ANSI_V, !option {
            toggleVocals()
        } else if let index = Self.stemKeys.firstIndex(of: code), index < Stem.shown.count {
            toggleStem(Stem.shown[index], solo: option)
        } else {
            return false
        }
        return true
    }

    /// Option on a stem that already plays alone brings every stem back.
    private func toggleStem(_ stem: Stem, solo: Bool) {
        var muted = model.stemsMuted
        if solo {
            let others = Set(Stem.allCases).subtracting([stem])
            muted = muted == others ? [] : others
        } else if muted.contains(stem) {
            muted.remove(stem)
        } else {
            muted.insert(stem)
        }
        setStems(muted)
    }

    /// Play all, 0 and the menu: every stem plays again, at the volume of the others.
    private func playAllStems() {
        if !model.stemVolumes.isEmpty {
            model.stemVolumes = [:]
            pitch.stemVolumes = [:]
            log("every stem at its own volume")
        }
        if model.stemsMuted.isEmpty {
            engageStems(model.shown && model.stemsEngaged)
            refreshStatus()
        } else {
            setStems([])
        }
    }

    /// A scroll over a stem sets its volume. Like a mute, it plays the stems in place of the song, and picks the key
    /// so that the HUD stays up with the change.
    private func setStemVolume(_ stem: Stem, _ volume: Double) {
        guard model.stemsAvailable else { return }
        if !model.picking, model.shown { pickKey() }
        model.stemsFailed = false
        model.stemVolumes[stem] = volume == 1 ? nil : volume
        pitch.stemVolumes = model.stemVolumes
        engageStems(model.stemsAdjusted || (model.shown && model.stemsEngaged))
        refreshStatus()
        if pitchWanted, !pitch.running { startPitch() }
    }

    /// The stems that last played apart, for Retry after a failure.
    private var lastMutedStems: Set<Stem> = []

    /// Plays every stem but the muted ones. The pitch change runs while any stem is muted, so the HUD opens the picker
    /// and keeps up with the change, the way it does for a key. With every stem playing again, the stems keep playing
    /// while the HUD shows them, so muting another one is instant; the song as it plays comes back when the HUD closes.
    /// `fade` for the vocals of karaoke and of V, which fade out and back in; keys and clicks mute a stem at once.
    private func setStems(_ muted: Set<Stem>, fade: Bool = false) {
        guard model.stemsAvailable || muted.isEmpty, muted != model.stemsMuted else { return }
        if !muted.isEmpty, !model.picking, model.shown { pickKey() }
        model.stemsFailed = false
        model.stemsMuted = muted
        if !muted.isEmpty { lastMutedStems = muted }
        pitch.stemsFade = fade ? 0.45 : 0.02
        pitch.mutedStems = muted
        engageStems(model.stemsAdjusted || (model.shown && model.stemsEngaged))
        log(muted.isEmpty ? "playing every stem" : "playing only \(Stem.shown.filter { !muted.contains($0) }.map(\.name).joined(separator: ", "))")
        refreshStatus()
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// Starts or ends the separation, and the pitch change with it when nothing else needs it.
    private func engageStems(_ engaged: Bool) {
        guard engaged != model.stemsEngaged || engaged != pitch.stemsEngaged else { return }
        model.stemsEngaged = engaged
        pitch.stemsEngaged = engaged
        syncStemsCache()
        if !engaged {
            model.stemsProgress = nil
            model.karaokeCountdown = nil
            endKaraokeRestart()
        }
        updateWatching(shown: model.shown)
        updateStemMeters(shown: model.shown)
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// The stems from the cache, for the song that Muskey Player plays, once the whole song was separated: they play at
    /// the moment that plays, so a seek or karaoke's start over is instant. The whole song is separated in the
    /// background the first time that its stems are used, while the stems are separated as it plays.
    private var cachedStems: Bool { playsInFilePlayer && pitch.instantSeeks }

    /// Muskey Player moved its song, for Muskey's seek or Control Center's scrubber, or Previous that starts it over.
    /// Now Playing reports some of these seconds later, so the stems from the cache learn of the move from the player,
    /// and wait for the new place when nobody asked them.
    private func playerMoved(to seconds: Double) {
        guard playsInFilePlayer, let feed = pitch.stemsFeed else { return }
        feed.moved(to: seconds)
        // A move during the pause is known from here, before Now Playing reports it.
        if let song = pausedAt?.0 { pausedAt = (song, seconds) }
        if model.stemsEngaged, cachedStems, !feed.asked(seconds) {
            log(String(format: "Muskey Player moved the song to %.1f s", seconds))
            pitch.cachedSeek(to: seconds)
        }
    }

    private func syncStemsCache() {
        let path = playsInFilePlayer ? filePlayer.current?.path : nil
        if path != stemsCacheLooked {
            stemsCacheLooked = path
            let cache = path.flatMap { StemsCache.open(for: $0) }
            if pitch.stemsFeed?.path != path || (pitch.stemsFeed == nil) != (cache == nil) {
                pitch.stemsFeed = path.flatMap { path in cache.map { StemsFeed(cache: $0, path: path, speed: filePlayer.speed) } }
                if pitch.stemsFeed != nil { log("stems: the whole song is in the cache") }
            }
        }
        if let feed = pitch.stemsFeed, let player = nowPlaying.player {
            feed.speed = filePlayer.speed
            feed.report(elapsed: player.elapsed, timestamp: player.timestamp, rate: player.rate)
        }
        // Another song stops the separation of the last one.
        if let building = stemsCache.path, building != path { stemsCache.cancel() }
        if let path, pitch.stemsFeed == nil, model.stemsEngaged, !stemsCacheFailed.contains(path) { stemsCache.start(path) }
        syncSeekable()
    }

    // MARK: Region loop

    /// Moves the song back to the start of the loop for players other than Muskey Player, which loops by itself.
    private var loopTimer: Timer?
    /// The song that the loop belongs to: another song clears it.
    private var loopSong: [String?]?
    private var loopSnap: Task<Void, Never>?
    /// A time of the loop is typed in, so the keys over the HUD go to the field.
    private var loopTyping = false
    /// The tempo that the beat grid found around the start of the loop, for rounding its length when the song's
    /// tempo isn't known.
    private var loopGridBPM: Double?

    /// R starts the region loop where the song is, ends it, then clears it. With the lyrics showing, the loop takes
    /// whole lines: from the start of the line sung now to the end of the line sung at the second press. ⌥R sets an
    /// end exactly where it is pressed.
    private func pressLoop(snapping: Bool) {
        guard let track = nowPlaying.track, track.title?.isEmpty == false, let duration = track.duration, duration > 0,
              let now = track.position(at: Date()) else { return log("region loop: the player gives no position for the song") }
        guard model.seekable else { return log("region loop: the song can't move at once now") }
        let lines = loopLines
        if let loop = model.loop, loop.end != nil {
            return clearLoop()
        } else if let loop = model.loop {
            var end = max(now, loop.start + 0.25)
            if let lines, let line = model.lyricLine, lines.indices.contains(line) {
                end = line + 1 < lines.count ? lines[line + 1].time : duration
                end = max(end, loop.start + 0.25)
            }
            model.loop?.end = end
            model.loop?.endPress = now
            log(String(format: "region loop ends at %.2f s", end))
            if snapping, lines == nil { snap(.end, at: end) } else { applyLoop() }
        } else {
            var start = now
            if let lines, let line = model.lyricLine, lines.indices.contains(line) { start = lines[line].time }
            model.loop = LoopRegion(start: start, end: nil, startPress: now)
            loopSong = track.song
            log(String(format: "region loop starts at %.2f s", start))
            if snapping, lines == nil { snap(.start, at: start) }
        }
        forgetLoopPresses()
    }

    /// The timed lines of the lyrics, while they show in place of the key row or as karaoke.
    private var loopLines: [Lyrics.Line]? {
        guard model.lyricsShown, case let .found(lyrics) = model.lyrics, lyrics.timing != .estimated, !lyrics.lines.isEmpty else { return nil }
        return lyrics.lines
    }

    /// Moves an end of the loop to the attack or the beat next to where it was pressed, once the audio around the press
    /// is known: a file is read around it, and a song from another player needs the 0.15 seconds after the press first.
    private func snap(_ end: LoopEnd, at time: Double) {
        let path = playsInFilePlayer ? filePlayer.current?.path : nil
        let recorder = waveformRecorder
        let bpm = model.shownTempo?.bpm ?? (end == .end ? loopGridBPM : nil)
        let song = loopSong
        loopSnap?.cancel()
        loopSnap = Task { [weak self] in
            var excerpt: (samples: [Float], start: Double)?
            if let path {
                let from = max(0, time - 8)
                excerpt = (await LoopSnap.excerpt(URL(fileURLWithPath: path), from: from, to: time + 1.5), from)
            } else {
                try? await Task.sleep(for: .milliseconds(300))
                excerpt = recorder?.excerpt(from: time - 10, to: time + 0.3)
            }
            guard let excerpt, !excerpt.samples.isEmpty, !Task.isCancelled else {
                self?.log("region loop: no audio around the press, the end stays where it was pressed")
                self?.applyLoop()
                return
            }
            let grid = await Task.detached(priority: .userInitiated) { LoopSnap.grid(excerpt.samples, start: excerpt.start) }.value
            guard let self, !Task.isCancelled, loopSong == song, var loop = model.loop else { return }
            if end == .start { loopGridBPM = grid.bpm }
            let snapped = end == .start ? LoopSnap.snap(time, grid: grid) : LoopSnap.snapEnd(time, start: loop.start, grid: grid, bpm: bpm)
            switch end {
            case .start: loop.start = loop.end.map { min(snapped, $0 - 0.25) } ?? snapped
            case .end: loop.end = max(snapped, loop.start + 0.25)
            }
            log(String(format: "region loop: %@ snapped from %.2f s to %.2f s (%d beats, %d attacks, %.0f BPM)", end == .start ? "start" : "end",
                       time, end == .start ? loop.start : loop.end ?? 0, grid.beats.count, grid.onsets.count, grid.bpm ?? 0))
            // The end slides to its snapped place with a small overshoot, which shows the snap without slowing anything.
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.32, bounce: 0.35)) { self.model.loop = loop }
            applyLoop()
        }
    }

    /// The dashed lines at the presses fade a moment after each press.
    private func forgetLoopPresses() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, model.loop != nil else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                self.model.loop?.startPress = nil
                self.model.loop?.endPress = nil
            }
        }
    }

    /// An end moved by its arrows, a drag or a typed time.
    private func setLoopEnd(_ end: LoopEnd, _ seconds: Double) {
        guard var loop = model.loop else { return }
        switch end {
        case .start: loop.start = max(0, seconds)
        case .end: loop.end = seconds
        }
        model.loop = loop
        log(String(format: "region loop %@ set to %.2f s", end == .start ? "start" : "end", seconds))
        applyLoop()
    }

    /// Repeats the part from the start to the end of the loop: Muskey Player at the exact end, other players with a
    /// seek once the song reaches the end, which lands within a few hundredths of a second.
    private func applyLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        guard let loop = model.loop, let end = loop.end else {
            if filePlayer.hasSong { filePlayer.loop(nil) }
            return
        }
        if playsInFilePlayer {
            filePlayer.loop((loop.start, end))
            // A song that already played past the end goes back at once.
            if let now = nowPlaying.track?.position(at: Date()), now > end || now < loop.start - 0.5 { seek(to: loop.start, flash: "repeat") }
            return
        }
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.checkLoopEnd() }
    }

    private func checkLoopEnd() {
        guard let loop = model.loop, let end = loop.end, let track = nowPlaying.track, track.playing, model.seekable,
              let now = track.position(at: Date()) else { return }
        // A seek that the player hasn't reported yet.
        if let target = seekTarget, Date().timeIntervalSince(target.at) < 1 { return }
        guard now >= end - 0.03, now < end + 3 else { return }
        seekTarget = (track.song, loop.start, Date())
        moveSong(track, to: loop.start)
    }

    private func clearLoop() {
        guard model.loop != nil else { return }
        loopSnap?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { model.loop = nil }
        loopSong = nil
        applyLoop()
        log("region loop cleared")
    }

    /// Another song clears the loop of the last one.
    private func checkLoopSong() {
        guard model.loop != nil, let song = nowPlaying.track?.song, nowPlaying.track?.title?.isEmpty == false, song != loopSong else { return }
        clearLoop()
    }

    /// The keys over the HUD stay off while a loop time is typed, so digits and letters reach the field.
    private func loopTyping(_ typing: Bool) {
        loopTyping = typing
        if typing {
            panel.setInteraction(clickable: true, keyboard: true)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
        updateHoverKeys()
    }

    // MARK: Waveform

    /// Draws the waveform of a song from another player from what Muskey hears, while the HUD shows.
    private var waveformRecorder: WaveformRecorder?
    /// The cache key of the waveform that the HUD has, so the same song isn't read twice.
    private var waveformKey: String?
    private var waveformRead: Task<Void, Never>?
    /// Copies what the recorder drew into the HUD four times a second.
    private var waveformTimer: Timer?
    /// `--waveform-file FILE` prints the waveform that Muskey reads from a file, for testing.
    static let waveformTest = TestFlags.value("--waveform-file")

    /// The waveform of the song that plays: a file's is read whole, and another player's comes from the cache and
    /// from what Muskey hears while the HUD shows, until the whole song was heard.
    private func syncWaveform() {
        guard model.waveformShown, let track = nowPlaying.track, track.title?.isEmpty == false, let duration = track.duration, duration > 0 else {
            stopWaveformRecorder()
            if !model.waveformShown || nowPlaying.track?.title?.isEmpty != false {
                waveformKey = nil
                if model.wave.waveform != nil { model.wave.waveform = nil }
            }
            return
        }
        if playsInFilePlayer, let path = filePlayer.current?.path {
            stopWaveformRecorder()
            guard let key = WaveformStore.key(file: path), key != waveformKey else { return }
            waveformKey = key
            model.wave.waveform = nil
            model.wave.lanes = false
            waveformRead?.cancel()
            waveformRead = Task { [weak self] in
                var waveform = WaveformStore.load(key)
                if waveform == nil {
                    waveform = await WaveformReader.read(URL(fileURLWithPath: path))
                    if let waveform { WaveformStore.save(waveform, as: key) }
                }
                guard !Task.isCancelled, let self, waveformKey == key else { return }
                model.wave.waveform = waveform
                log(waveform == nil ? "waveform: the file can't be read" : "waveform: read the whole file")
                syncWaveformStems()
            }
            return
        }
        let key = WaveformStore.key(song: track.song, duration: duration)
        if key != waveformKey {
            stopWaveformRecorder()
            waveformRead?.cancel()
            waveformKey = key
            let waveform = WaveformStore.load(key) ?? SongWaveform(duration: duration)
            model.wave.waveform = waveform
            model.wave.lanes = false
            waveformRecorder = WaveformRecorder(song: track.song, key: key, waveform: waveform)
        }
        guard let recorder = waveformRecorder else { return }
        if let player = nowPlaying.player { recorder.report(player) }
        // A hidden HUD shows no waveform. A song heard whole is still heard while the HUD shows, for the ends of the
        // region loop, which snap to the audio around them.
        let wanted = model.shown
        if wanted, !recorder.running {
            do {
                try recorder.start(SystemAudioTap())
                log("waveform: drawing the song while it plays")
            } catch {
                log("waveform: the tap failed: \(error)")
            }
            waveformTimer?.invalidate()
            waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.publishRecordedWaveform() }
        } else if !wanted, recorder.running {
            stopWaveformRecorder(keep: true)
        }
    }

    private func publishRecordedWaveform() {
        guard let recorder = waveformRecorder, recorder.key == waveformKey else { return }
        let (waveform, changed) = recorder.take()
        if changed { model.wave.waveform = waveform }
    }

    /// Stops drawing from what Muskey hears and keeps what was drawn on disk. `keep` leaves the recorder for the same
    /// song, which goes on drawing once the HUD shows again.
    private func stopWaveformRecorder(keep: Bool = false) {
        waveformTimer?.invalidate()
        waveformTimer = nil
        guard let recorder = waveformRecorder else { return }
        recorder.stop()
        let (waveform, _) = recorder.take()
        if waveform.heard > 0 { WaveformStore.save(waveform, as: recorder.key) }
        if !keep { waveformRecorder = nil }
    }

    /// The lanes of the stems, from the stems of the whole song once they are in the cache.
    private func syncWaveformStems() {
        guard playsInFilePlayer, let path = filePlayer.current?.path, let key = waveformKey, let waveform = model.wave.waveform, waveform.stems == nil,
              let cache = StemsCache.open(for: path) else { return }
        let base = waveform
        Task { [weak self] in
            let stems = await Task.detached(priority: .utility) { WaveformReader.stems(cache) }.value
            guard let self, waveformKey == key else { return }
            var waveform = model.wave.waveform ?? base
            waveform.stems = stems
            model.wave.waveform = waveform
            WaveformStore.save(waveform, as: key)
            log("waveform: lanes for the stems")
        }
    }

    /// W shows or hides the waveform, and remembers it.
    private func toggleWaveform() {
        prefs.waveform.toggle()
        log("waveform \(prefs.waveform ? "on" : "off")")
    }

    /// ⌥W: one lane per stem, or the whole song again. Without the stems of the whole song there are no lanes.
    private func toggleWaveformLanes() {
        guard model.wave.waveform?.stems != nil else {
            log("waveform: no lanes until the stems of the whole song are separated")
            return
        }
        model.wave.lanes.toggle()
    }

    /// Zooms the waveform by `factor`, from the whole song to a close-up of a few seconds.
    private func zoomWaveform(_ factor: Double) {
        guard model.waveformShown, model.waveformStyle == .ribbon, model.wave.waveform != nil else { return }
        let before = model.wave.zoom
        withAnimation(.snappy(duration: 0.2)) { model.wave.zoom(by: factor) }
        if Self.logKeys, before != model.wave.zoom { log(String(format: "waveform zoom %.1f", model.wave.zoom)) }
    }

    /// The pointer of `event` is over the waveform.
    private func overWaveform(_ event: NSEvent) -> Bool {
        guard let view = panel.contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.contains { $0.region == .waveform && $0.frame.contains(point) }
    }

    /// The Separate instruments and vocals button: separates the song with every stem playing, and shows the stems in
    /// place of the button. Like the keys, it pins the HUD open.
    private func separate() {
        guard model.stemsAvailable, !model.stemsEngaged else { return }
        if !model.picking, model.shown { pickKey() }
        model.stemsFailed = false
        lastMutedStems = model.stemsMuted
        engageStems(true)
        log("separating, with every stem playing")
        refreshStatus()
    }

    private func retryStems() {
        model.stemsFailed = false
        if lastMutedStems.isEmpty { separate() } else { setStems(lastMutedStems) }
    }

    /// The model couldn't load or run. Every stem plays again, and the pill on the stems row offers Retry.
    private func stemsFailed(_ reason: String) {
        log("stems failed: \(reason)")
        model.stemsMuted = []
        model.stemVolumes = [:]
        pitch.stemVolumes = [:]
        model.stemsFailed = true
        engageStems(false)
        refreshStatus()
    }

    private var stemModelRelease: DispatchWorkItem?

    /// The model warms up once the pointer is on the HUD or the picker opens, so a chip pressed a moment later doesn't
    /// wait 3 seconds for Core ML. A HUD that only shows a key loads nothing.
    private func warmUpStems() {
        guard model.stemsAvailable, model.hovering || model.picking else { return }
        StemModel.warmUp()
    }

    /// Fifteen minutes after the HUD closed with every stem playing, the model is freed. Each load makes Core ML
    /// compile the model for the GPU again and write hundreds of megabytes to disk, so a HUD that opens every few
    /// minutes keeps it.
    private func prepareStemModel(shown: Bool) {
        stemModelRelease?.cancel()
        stemModelRelease = nil
        if shown {
            model.stemsAvailable = StemModel.installed
        } else if !model.stemsAdjusted {
            let release = DispatchWorkItem { [weak self] in
                guard let self, !model.shown, !model.stemsAdjusted else { return }
                StemModel.unload()
            }
            stemModelRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 900, execute: release)
        }
    }

    private var stemMeterClock: Timer?

    private var arrivalClear: DispatchWorkItem?

    /// The stems and the lyrics delay play the song seconds behind it, so a new song is heard that much later than the
    /// player starts it. Its record waits in a loading state until then, while the last song plays out.
    private func songArrives() {
        arrivalClear?.cancel()
        let behind = pitch.stemsOn || lyricsDelayed ? pitch.stemsDelay : 0
        guard behind > 0.5 else {
            if model.songArriving != nil { model.songArriving = nil }
            return
        }
        let now = Date()
        model.songArriving = now ... now.addingTimeInterval(behind)
        log(String(format: "the new song is heard in %.1f s, its record waits until then", behind))
        let clear = DispatchWorkItem { [weak self] in self?.model.songArriving = nil }
        arrivalClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + behind, execute: clear)
    }

    /// The backspins that the output played so far, from the shifter that plays now.
    private var spinsSeen: UInt32 = 0

    /// The records turn back with each new backspin of the output, while the HUD shows them.
    private func checkSpins() {
        let spins = pitch.spins
        guard spins != spinsSeen else { return }
        // A new shifter counts from 0 again.
        if spins > spinsSeen {
            log("the output stepped back in the song" + (fadeToStart ? ", with a fade to the start" : ""))
            if model.shown { model.rewinds += 1 }
            if fadeToStart { fadeToStart = false }
        }
        spinsSeen = spins
    }

    /// Reads the level of each stem 20 times a second, and what the stems wait for, while the HUD shows them.
    private func updateStemMeters(shown: Bool) {
        let wanted = shown && model.stemsEngaged
        if !wanted {
            stemMeterClock?.invalidate()
            stemMeterClock = nil
            if model.stemsProgress != nil { model.stemsProgress = nil }
            if model.karaokeCountdown != nil { model.karaokeCountdown = nil }
            if model.stemMeters.levels.contains(where: { $0 != 0 }) { model.stemMeters.levels = Array(repeating: 0, count: Stem.allCases.count) }
            return
        }
        guard stemMeterClock == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Stems from the cache take over in a moment, with nothing to wait for.
            let progress = cachedStems ? nil : pitch.stemsWaited.map { waited -> StemsProgress in
                StemModel.prepared ? .separating(min(0.97, waited / Self.stemsWait)) : .loading
            }
            // A cache that stopped lining up with the song takes the seek keys away again.
            syncSeekable()
            if model.stemsProgress != progress { model.stemsProgress = progress }
            if karaokeRestart == .waitingForModel, StemModel.prepared { beginKaraokeRestart() }
            let countdown = karaokeCountdown(progress)
            if model.karaokeCountdown != countdown { model.karaokeCountdown = countdown }
            model.stemMeters.levels = Stem.allCases.map { self.pitch.stemLevel($0) }
            checkSpins()
        }
        RunLoop.main.add(timer, forMode: .common)
        stemMeterClock = timer
    }

    private func setLayout(card: Bool) {
        model.shortcuts = false
        model.card = card
        UserDefaults.standard.set(card ? "card" : "wide", forKey: "layout")
        log("layout \(card ? "card" : "wide")")
    }

    /// Another song started while a key is kept: a listen finds its key and moves it to the kept one. Another song
    /// that starts while the key picker is open gets a listen too, so the HUD shows its key and not the last song's.
    /// Without a kept key, the pitch change runs on at the same shift, and the keys relabel once the new key is known.
    private func songChanged(_ track: NowPlaying.Track) {
        let target = keptKey
        // A HUD that shows gets the new song's key, so it never shows the last song's key over the new song.
        guard target != nil || (model.shown && model.saving == nil && model.phase != .idle) else { return }
        // The song that the HUD already listens to or shows, as when a player reports the song that it just started.
        if target == nil, state != .idle, listenSong == track.song { return }
        redetecting = false
        if !model.shown { stayOpen = false }
        log(target.map { "song changed, moving it to \($0.name)" } ?? "song changed, listening for its key")
        switch AudioCapturePermission.status {
        case .granted: break
        case .denied: return log("system audio recording is not allowed")
        case .undetermined:
            // Each song change while the dialog is up asks again, so only the song that still plays gets a listen.
            return AudioCapturePermission.request { [self] granted in
                guard granted else { return log("system audio recording was not allowed") }
                if keptKey != nil || model.shown, nowPlaying.track?.song == track.song, state != .listening { songChanged(track) }
            }
        }
        stopCapture()
        analyzer = nil
        session += 1
        state = .listening
        follow = target
        followByPerson = false
        followApplied = false
        model.moved = nil
        model.pending = target
        songChangedAt = Date()
        // The shift of the last song means nothing for this one, so it plays in its own key until the first estimate.
        // The pitch change keeps running at 0, so moving it doesn't start the tap over.
        if target != nil, model.shift != 0 {
            setShift(0, relative: false, byPerson: false)
            log("original key until the new song's key is found")
        }
        listen()
    }

    /// Moves the new song to the kept key on the first estimate, and once more on the final estimate of the listen if
    /// that one needs another shift. A final estimate that only swaps the key for its relative keeps the shift and
    /// renames the keys.
    private func retarget(_ key: DetectedKey, to target: DetectedKey, final: Bool, byPerson: Bool = false) {
        let shift = key.shift(to: target)
        let relative = target.minor != key.minor
        if shift == model.shift, followApplied {
            model.relative = relative
            return refreshStatus()
        }
        followApplied = true
        setShift(shift, relative: relative, byPerson: false)
        if byPerson { return log("kept \(model.heard?.name ?? target.name) after the key turned out to be \(key.name), \(Shift.text(shift))") }
        model.pending = nil
        model.moved = KeyMove(from: key, to: model.heard ?? target)
        log("moved \(key.name) to \(model.heard?.name ?? target.name), \(Shift.text(shift))")
    }

    /// A song change listen that heard nothing keeps the shift that the song plays at.
    private func followFailed(_ reason: String) {
        log(reason)
        model.pending = nil
        state = .showing
        if model.picking {
            model.phase = .done
        } else {
            dismiss()
        }
    }

    private var hoverKeys: [HotKey] = []
    private var optionWatch: Timer?

    private let lyricsFinder = LyricsFinder()
    /// The made-up song of `--lyrics-test` keeps its lyrics apart from the real ones, so one test doesn't reuse the
    /// lyrics that Whisper wrote for another song in an earlier test.
    private let lyricsStore = lyricsTest == nil ? LyricsStore() : LyricsStore(url: URL(fileURLWithPath: "/tmp/muskey-lyrics-test.json"))
    private lazy var lyricsSync = LyricsSync(store: lyricsStore)
    private var lyricsEditor: LyricsEditorWindowController?
    /// The song that the lyrics in the HUD belong to.
    private var lyricsSong: String?
    private var lyricsClock: Timer?

    /// The L key and the lyrics button: the lyrics in place of the key, or the key again. A HUD that opens starts
    /// on the key.
    private func toggleLyrics() {
        if !model.picking { pickKey() }
        guard model.picking else { return }
        model.shortcuts = false
        model.lyricsShown.toggle()
        if !model.lyricsShown { model.lyricsFocus = false }
        log(model.lyricsShown ? "lyrics shown" : "lyrics hidden")
        if model.lyricsShown {
            loadLyrics()
        } else {
            lyricsSong = nil
            lyricsSync.end()
        }
        updateLyricsClock(shown: model.shown)
        updateHoverKeys()
    }

    /// Lyrics added by hand for the song on the record, or the lyrics services', asked for once per song while the
    /// lyrics show.
    private func loadLyrics(again: Bool = false) {
        guard model.lyricsShown, model.shown else { return }
        guard let track = model.track, let song = LyricsFinder.id(track) else {
            lyricsSong = nil
            lyricsSync.end()
            if model.lyrics != .none { model.lyrics = .none }
            return
        }
        guard again || song != lyricsSong else { return }
        lyricsSong = song
        lyricsSync.end()
        model.lyricLine = nil
        if let text = lyricsStore.text(for: song) {
            let lyrics = Lyrics.parse(lrc: text) ?? Lyrics.estimate(plain: text, duration: track.duration ?? 200)
            return showLyrics(lyrics.map { .found($0) } ?? .notFound, song: song, track: track)
        }
        if let known = lyricsFinder.known(track) { return showLyrics(known, song: song, track: track) }
        model.lyrics = .loading
        lyricsFinder.find(track) { [weak self] state in
            guard let self, lyricsSong == song else { return }
            showLyrics(state, song: song, track: track)
            log("lyrics: \(Self.describe(state))")
        }
    }

    private let network = NWPathMonitor()
    private var online = true

    /// Lyrics that failed because the Mac was offline are looked up again once it is back online, without Retry.
    private func networkChanged(online: Bool) {
        defer { self.online = online }
        guard online, !self.online, model.lyricsShown, model.lyrics == .failed else { return }
        log("lyrics: back online, looking them up again")
        retryLyrics()
    }

    /// `--lyrics-plain` drops the times of synced lyrics, to test the timing by listening on any song, and logs how
    /// far the heard times are from the dropped ones. With `--pick`, the lyrics show from the start.
    private static let lyricsPlain = TestFlags.has("--lyrics-plain")
    private var droppedTimes: [Double]?

    private func showLyrics(_ state: LyricsState, song: String, track: NowPlaying.Track) {
        var state = state
        droppedTimes = nil
        if Self.lyricsPlain, case let .found(lyrics) = state, lyrics.timing == .synced,
           let plain = Lyrics.estimate(plain: lyrics.lines.map(\.text).joined(separator: "\n"), duration: track.duration ?? 200)
        {
            // The estimate drops breaks in a row, so each of its lines takes the time of the next line with its text.
            var next = 0
            droppedTimes = plain.lines.map { line in
                guard let index = lyrics.lines[next...].firstIndex(where: { $0.text == line.text }) else { return -1 }
                next = index + 1
                return lyrics.lines[index].time
            }
            droppedLogged = 0
            state = .found(plain)
        }
        if case let .found(lyrics) = state, lyrics.timing == .estimated { lyricsSync.begin(song: song, lyrics: lyrics) }
        // A song that LRCLIB doesn't have: the lyrics that Whisper wrote in an earlier play, or Whisper writes them now.
        var writing = false
        if state == .notFound {
            let earlier = lyricsStore.written(for: song).flatMap { Lyrics.parse(lrc: $0) }?.lines ?? []
            let covered = lyricsStore.covered(for: song)
            if LyricsCoverage.complete(covered, duration: track.duration) {
                log("lyrics: \(earlier.count) lines written earlier, the whole song was transcribed")
            } else if lyricsSync.transcribe(song: song, written: earlier, covered: covered, duration: track.duration) {
                writing = true
                log(earlier.isEmpty && covered.isEmpty ? "lyrics: writing them by ear"
                    : "lyrics: \(earlier.count) lines written earlier over \(Int(covered.reduce(0) { $0 + $1.upperBound - $1.lowerBound })) seconds, writing the rest by ear")
            }
            if writing || !earlier.isEmpty { state = .found(Lyrics(lines: earlier, timing: .written)) }
        }
        if model.lyricsWriting != writing { model.lyricsWriting = writing }
        model.lyrics = state
        lyricsTimingChanged()
        updateLyricLine()
    }

    /// Whisper as Settings has it: a server, the model on the Mac, or nothing for Apple's speech model.
    private func whisperBackend() -> WhisperBackend? {
        switch prefs.lyricsTranscription {
        case .apple: nil
        case .server: WhisperServer(prefs.whisperServer)
        case .model: WhisperModel.installed ? WhisperModel.shared : nil
        }
    }

    /// The lyrics show their timing as heard once a line starts at a heard word. Lyrics that Whisper wrote keep their
    /// timing, since each line starts where Whisper heard it.
    private func lyricsTimingChanged() {
        if model.lyricsDownloading != lyricsSync.downloading { model.lyricsDownloading = lyricsSync.downloading }
        guard case var .found(lyrics) = model.lyrics, lyrics.timing != .synced, lyrics.timing != .written else { return }
        let timing: Lyrics.Timing = lyricsSync.anchored > 0 ? .heard : .estimated
        guard lyrics.timing != timing else { return }
        lyrics.timing = timing
        model.lyrics = .found(lyrics)
        if timing == .heard { log("lyrics: timed by listening") }
    }

    private func retryLyrics() {
        if let track = model.track { lyricsFinder.forget(track) }
        loadLyrics(again: true)
    }

    /// Add Lyrics, and Edit Lyrics in the panel's menu: a window to paste or edit the lyrics of the song on the
    /// record, which take the place of LRCLIB's for that song. Saving an empty text goes back to LRCLIB's.
    private func editLyrics() {
        guard let track = model.track, let song = LyricsFinder.id(track) else { return }
        var text = lyricsStore.text(for: song) ?? ""
        if text.isEmpty, case let .found(lyrics) = model.lyrics { text = lyrics.text }
        lyricsEditor?.close()
        let editor = LyricsEditorWindowController(song: track.label, text: text) { [weak self] saved in
            guard let self else { return }
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            lyricsStore.setText(trimmed.isEmpty ? nil : saved, for: song)
            log(trimmed.isEmpty ? "lyrics: removed the added lyrics" : "lyrics: added by hand")
            if lyricsSong == song { loadLyrics(again: true) }
        }
        editor.onClose = { [weak self] in
            self?.lyricsEditor = nil
            self?.updateHoverKeys()
        }
        lyricsEditor = editor
        editor.show()
        updateHoverKeys()
    }

    /// For the log, which never has the song or its words.
    private static func describe(_ state: LyricsState) -> String {
        switch state {
        case let .found(lyrics): "\(lyrics.lines.count) lines, \(lyrics.timing == .synced ? "synced" : lyrics.otherVersion ? "times of another version" : "estimated timing")\(lyrics.source.map { ", from \($0.name)" } ?? "")"
        case .instrumental: "instrumental"
        case .notFound: "not found"
        case .failed: "request failed"
        case .loading: "loading"
        case .none: "no song"
        }
    }

    /// Moves the line sung now along with the song, five times a second while the lyrics show.
    private func updateLyricsClock(shown: Bool) {
        let wanted = shown && model.lyricsShown
        guard wanted != (lyricsClock != nil) else { return }
        lyricsClock?.invalidate()
        lyricsClock = wanted ? Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateLyricLine() } : nil
        if !wanted {
            lyricsSync.end()
            setLyricsDelay(false)
        }
    }

    private var droppedLogged = 0
    /// The second of the song that was heard at the last update of the line, which tells a seek back from a new time.
    private var lyricsHeardLast = 0.0

    private func updateLyricLine() {
        guard case let .found(lyrics) = model.lyrics, let position = model.track?.position(at: Date()) else {
            if model.lyricLine != nil { model.lyricLine = nil }
            return
        }
        lyricsSync.mark(position: model.track?.playing == true ? position : nil)
        if model.lyricsSkipped != lyricsSync.inTranscribedPart { model.lyricsSkipped = lyricsSync.inTranscribedPart }
        let times = lyricsSync.times(at: position) ?? lyrics.lines.map(\.time)
        // The stems and the lyrics delay play the song seconds behind, and the line sung is the one that is heard.
        let heard = position - pitch.stemsDelay
        let waiting = lyricsDelayed ? pitch.delayWaiting.map { Int($0.rounded(.up)) } : nil
        if model.lyricsWaiting != waiting { model.lyricsWaiting = waiting }
        checkSpins()
        // A line lights up a moment before it is sung, the way people read ahead.
        var line = times.lastIndex { $0 <= heard + 0.25 }
        // The lines after the last heard word are placed ahead, and the words that the transcriber hears a few
        // seconds later can move the start of the line that lit up a little later. The highlight then stepped back a
        // line and forward again moments later, so a line that lit up stays lit through a correction of up to 3
        // seconds. A seek back, or a larger correction, still goes back.
        if let shown = model.lyricLine, let new = line, new == shown - 1, shown < times.count,
           heard >= lyricsHeardLast - 0.5, times[shown] - (heard + 0.25) < 3 {
            line = shown
        }
        lyricsHeardLast = heard
        if model.lyricLine != line { model.lyricLine = line }
        logTimingError(times, position: position)
    }

    /// With `--lyrics-plain`, the gap between the heard times and the dropped ones for the lines sung so far, each
    /// time more lines are timed.
    private func logTimingError(_ times: [Double], position: Double) {
        guard let droppedTimes, droppedTimes.count == times.count, lyricsSync.anchored > droppedLogged else { return }
        droppedLogged = lyricsSync.anchored
        let sung = zip(times, droppedTimes).filter { $0.1 >= 0 && $0.1 < position - 3 }
        let errors = sung.map { abs($0.0 - $0.1) }.sorted()
        let signed = sung.map { $0.0 - $0.1 }.sorted()
        guard !errors.isEmpty, let last = sung.last else { return }
        log(String(format: "lyrics: at %.0fs, %d lines timed, error of the lines sung: median %.2fs (signed %+.2fs), %d of %d within 1s, last line %.1fs for %.1fs",
                   position, lyricsSync.anchored, errors[errors.count / 2], signed[signed.count / 2], errors.filter { $0 <= 1 }.count, errors.count,
                   last.0, last.1))
    }

    /// `--lyrics-lookup "TITLE|ARTIST|ALBUM|SECONDS"` asks the lyrics services for a song's lyrics the way the panel does,
    /// prints what came back and quits, for checking the matching from a terminal.
    private func lookUpLyrics(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let track = NowPlaying.Track(title: parts.first, artist: parts.count > 1 ? parts[1] : nil, album: parts.count > 2 ? parts[2] : nil,
                                     duration: parts.count > 3 ? Double(parts[3]) : nil, elapsed: 0, timestamp: nil, rate: 0, bundleID: nil)
        let cleaned = LyricsFinder.clean(track.title ?? "", artist: track.artist ?? "")
        print("cleaned: \(cleaned.title) | \(cleaned.artist)")
        lyricsFinder.find(track) { state in
            print(Self.describe(state))
            if case let .found(lyrics) = state {
                for line in lyrics.lines.prefix(3) { print(String(format: "%6.2f  %@", line.time, line.text)) }
            }
            exit(0)
        }
    }

    /// `--key-lookup "Title|Artist|Album|Seconds"` asks Noiseblend for the key of that song, with an empty cache, and
    /// prints the answer.
    private func lookUpKeyForTesting(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map { $0.isEmpty ? nil : String($0) }
        let track = NowPlaying.Track(title: parts.first ?? nil, artist: parts.count > 1 ? parts[1] : nil, album: parts.count > 2 ? parts[2] : nil,
                                     duration: parts.count > 3 ? parts[3].flatMap(Double.init) : nil, elapsed: 0, timestamp: nil, rate: 0, bundleID: nil)
        let cleaned = KeyLookup.clean(track.title ?? "", artist: track.artist ?? "")
        print("sent: \(cleaned.title) | \(cleaned.artist)")
        let lookup = KeyLookup(url: FileManager.default.temporaryDirectory.appending(path: "muskey-key-lookup-\(UUID().uuidString).json"))
        lookup.log = { print($0) }
        lookup.find(track) { key in
            print(key.map { "key: \($0.name) (\($0.camelot))" } ?? "no key")
            exit(0)
        }
    }

    /// `--tempo FILE` finds the tempo of the part of FILE that a listen would hear: `--seconds` (20 by default) from
    /// `--tempo-at` (45 by default). Prints the tempo and quits.
    private func tempoForTesting(_ path: String) {
        let seconds = Self.stringOption("--seconds").flatMap(Double.init) ?? 20
        let start = Self.stringOption("--tempo-at").flatMap(Double.init) ?? 45
        exit(TempoDetector.printTempo(of: path, from: start, seconds: seconds))
    }

    /// `--lyrics-test FILE` plays a made-up song with the lyrics in FILE (LRC, or plain text for estimated timing),
    /// from `--lyrics-at` seconds or from `--lyrics-since`, and opens the lyrics, for testing them where nothing plays. `--lyrics-test failed`
    /// starts on a request that failed, and its Retry asks LRCLIB for the made-up song.
    private static let lyricsTest: (track: NowPlaying.Track, state: LyricsState)? = {
        guard let path = TestFlags.value("--lyrics-test") else { return nil }
        let text = path == "failed" ? "" : (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // `--lyrics-since TIME` starts the made-up song at that Unix time, to line it up with a file that afplay plays.
        let since = TestFlags.value("--lyrics-since").flatMap(Double.init).map { Date().timeIntervalSince1970 - $0 }
        let start = since ?? TestFlags.value("--lyrics-at").flatMap(Double.init) ?? 0
        let lyrics = Lyrics.parse(lrc: text) ?? Lyrics.estimate(plain: text, duration: 200)
        let duration = max(200, (lyrics?.lines.last?.time ?? 0) + 20)
        let track = NowPlaying.Track(title: "Test Song", artist: "Muskey", album: "Tests", duration: duration, elapsed: start,
                                     timestamp: Date().timeIntervalSince1970, rate: 1, bundleID: nil)
        return (track, path == "failed" ? .failed : lyrics.map { .found($0) } ?? .notFound)
    }()

    /// Holding Option with the pointer over the HUD flips the keys to the other mode. Without Accessibility
    /// the app gets no modifier changes from other apps, so it reads the modifiers 30 times a second while the HUD
    /// is up.
    private func watchOption(_ shown: Bool) {
        optionWatch?.invalidate()
        optionWatch = nil
        guard shown else { return model.flipped = false }
        optionWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let flags = NSEvent.modifierFlags
            // Only with the pointer over the HUD: Option held while typing in another app flipped the keys out of sight.
            let flipped = flags.contains(.option) && !flags.contains(.command) && model.key != nil && model.hovering
            if model.flipped != flipped { model.flipped = flipped }
        }
    }

    /// While the pointer is over a HUD that shows a key, its keys work without the HUD having keyboard focus,
    /// as hotkeys that go away when the pointer leaves.
    /// `--log-keys` logs the hover over the HUD and every key that reaches it, for testing the keys from a script.
    private static let logKeys = TestFlags.has("--log-keys")

    /// The key hints, the stems' number keys and the tempo keycaps show only with the pointer over the HUD. The keys
    /// also work while the HUD holds the keyboard, but the HUD stays compact then, as it does whenever the pointer is
    /// away from it.
    private func updateKeysActive() {
        let active = model.hovering
        if model.keysActive != active { model.keysActive = active }
    }

    private var hoverKeysForLyrics = false
    private var hoverKeysForStems = false
    private var hoverKeysForKaraoke = false
    private var hoverKeysForSpeed = false
    private var hoverKeysForSeek = false
    private var hoverKeysForRestart = false
    private var hoverKeysForSave = false
    private var hoverKeysForRecord = false
    private var hoverKeysForKey = false
    /// The clipboard when the keys were registered: ⌘V over the HUD is a key only while it holds files or a link.
    private var hoverKeysPasteboard = 0
    /// A save leaves the HUD only Escape, and the shortcuts only Escape and ?, which close them.
    private var hoverKeysLock = HoverKeysLock.none
    /// The key that types ? in the keyboard layout that was selected when the keys were registered.
    private var hoverKeysQuestion: LayoutKey?
    private enum HoverKeysLock { case none, saving, shortcuts }
    private var overRecordChange: AnyCancellable?
    private var lockChange: AnyCancellable?
    private var keyChange: AnyCancellable?
    private var heldGlassChange: AnyCancellable?

    /// Open File… or Open URL… is open. Its text would otherwise reach the keys over the HUD, which are global
    /// hotkeys, whenever the pointer rests on the HUD.
    private var dialogOpen = false {
        didSet { if dialogOpen != oldValue { updateHoverKeys() } }
    }

    private func updateHoverKeys() {
        let lock: HoverKeysLock = model.saving != nil ? .saving : model.shortcuts ? .shortcuts : .none
        // A listen that has no estimate yet leaves the HUD without a key. The keys that play, skip and move the song
        // work from the start, and the ones that change the key, the instruments or the tempo wait for the key.
        let keyed = model.key != nil
        let pasteboard = NSPasteboard.general.changeCount
        let wanted = model.hovering && model.shown && (model.picking || [.done, .listening, .idle].contains(model.phase))
            && lyricsEditor == nil && !dialogOpen && !loopTyping
        // The lyrics take fewer keys than the key row, so the keys change when the panel does.
        guard wanted == hoverKeys.isEmpty
            || (wanted && (hoverKeysForKey != keyed || hoverKeysPasteboard != pasteboard
                || hoverKeysForLyrics != model.lyricsShown || hoverKeysForStems != model.stemsAvailable || hoverKeysForKaraoke != model.lyricsFocus
                || hoverKeysForSpeed != model.speedAdjustable || hoverKeysForSeek != model.seekable
                || hoverKeysForRestart != model.restartable || hoverKeysForSave != model.savable
                || hoverKeysForRecord != model.overRecord || hoverKeysLock != lock || hoverKeysQuestion != LayoutKey.questionMark))
        else { return }
        if Self.logKeys, wanted == hoverKeys.isEmpty { log("keys over the HUD \(wanted ? "on" : "off")") }
        hoverKeys = []
        guard wanted else { return }
        hoverKeysForKey = keyed
        hoverKeysPasteboard = pasteboard
        hoverKeysForLyrics = model.lyricsShown
        hoverKeysForStems = model.stemsAvailable
        hoverKeysForKaraoke = model.lyricsFocus
        hoverKeysForSpeed = model.speedAdjustable
        hoverKeysForSeek = model.seekable
        hoverKeysForRestart = model.restartable
        hoverKeysForSave = model.savable
        hoverKeysForRecord = model.overRecord
        hoverKeysLock = lock
        hoverKeysQuestion = LayoutKey.questionMark
        let question = hoverKeysQuestion.map { [($0.code, $0.modifiers)] } ?? []
        if lock != .none {
            let keys = lock == .saving ? [(kVK_Escape, 0)] : [(kVK_Escape, 0)] + question
            hoverKeys = keys.compactMap { code, modifiers in
                try? HotKey(keyCode: code, modifiers: modifiers) { [weak self] in
                    self?.handleKey(code, shift: modifiers & shiftKey != 0, option: modifiers & optionKey != 0)
                }
            }
            return
        }
        let modifiers = [0, shiftKey, optionKey, optionKey | shiftKey]
        // ? shows the shortcuts.
        var keys: [(Int, Int)] = [kVK_Escape, kVK_Space, kVK_ANSI_N, kVK_ANSI_P].map { ($0, 0) } + question
        if keyed { keys += [kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_S].map { ($0, 0) } + [(kVK_ANSI_W, 0), (kVK_ANSI_W, optionKey)] }
        if model.seekable || model.loop != nil { keys += [(kVK_ANSI_R, 0), (kVK_ANSI_R, optionKey)] }
        if keyed, model.stemsAvailable {
            // V mutes the vocals or plays them again, in every layout.
            keys += Self.stemKeys.flatMap { code in [(code, 0), (code, optionKey)] } + [(kVK_ANSI_0, 0), (kVK_ANSI_V, 0)]
        }
        // A song in Muskey Player plays slower, faster or at its own tempo.
        if keyed, model.speedAdjustable { keys += Self.speedKeys.keys.map { ($0, 0) } }
        // Return shows the lyrics large, or back at their usual size, and the arrows seek while a seek is instant.
        if keyed, model.lyricsShown { keys += [kVK_Return, kVK_ANSI_KeypadEnter].map { ($0, 0) } }
        if model.lyricsShown, model.seekable { keys += [kVK_LeftArrow, kVK_RightArrow].map { ($0, 0) } }
        // Karaoke seeks with the number keys, and 0 starts the song over in every player.
        if model.lyricsFocus, model.seekable { keys += Self.digitKeys.map { ($0, 0) } }
        if model.lyricsFocus, model.restartable { keys.append((kVK_ANSI_0, 0)) }
        // The key row, and karaoke, change the key by its letter.
        if keyed, !model.lyricsShown || model.lyricsFocus {
            keys += Self.letters.keys.flatMap { code in modifiers.map { (code, $0) } }
            keys += [kVK_Delete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { ($0, 0) }
        }
        // Over the record, the arrows and the numbers move the song, and 0 starts it over.
        if model.overRecord, model.seekable { keys += [kVK_LeftArrow, kVK_RightArrow].map { ($0, 0) } }
        if model.overRecord { keys += Self.digitKeys.dropFirst().map { ($0, 0) } }
        if model.overRecord, model.restartable { keys.append((kVK_ANSI_0, 0)) }
        // A key that two lists add is registered once.
        keys = keys.reduce(into: []) { unique, key in if !unique.contains(where: { $0 == key }) { unique.append(key) } }
        hoverKeys = keys.compactMap { code, modifiers in
            try? HotKey(keyCode: code, modifiers: modifiers) { [weak self] in
                self?.handleKey(code, shift: modifiers & shiftKey != 0, option: modifiers & optionKey != 0)
            }
        }
        if keyed, let karaoke = try? HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey, action: { [weak self] in self?.toggleKaraoke() }) {
            hoverKeys.append(karaoke)
        }
        // ⌘+ and ⌘− zoom the waveform in and out, with or without Shift for the +.
        if keyed {
            for (code, modifiers, factor) in [(kVK_ANSI_Equal, cmdKey, 1.5), (kVK_ANSI_Equal, cmdKey | shiftKey, 1.5), (kVK_ANSI_Minus, cmdKey, 1 / 1.5)] {
                if let zoom = try? HotKey(keyCode: code, modifiers: modifiers, action: { [weak self] in self?.zoomWaveform(factor) }) { hoverKeys.append(zoom) }
            }
        }
        if model.savable, let save = try? HotKey(keyCode: kVK_ANSI_S, modifiers: cmdKey, action: { [weak self] in self?.saveSong() }) {
            hoverKeys.append(save)
        }
        if keyed, let reset = try? HotKey(keyCode: kVK_Delete, modifiers: cmdKey, action: { [weak self] in self?.resetAll() }) {
            hoverKeys.append(reset)
        }
        // ⌘V over the HUD plays the files or the link on the clipboard. A clipboard with other text leaves ⌘V to the
        // app in front.
        if !Self.pastedURLs().isEmpty, let paste = try? HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey, action: { [weak self] in self?.pasteSongs() }) {
            hoverKeys.append(paste)
        }
        if let open = try? HotKey(keyCode: kVK_ANSI_O, modifiers: cmdKey, action: { [weak self] in self?.openFile() }) { hoverKeys.append(open) }
        if let link = try? HotKey(keyCode: kVK_ANSI_L, modifiers: cmdKey, action: { [weak self] in self?.openLocation() }) { hoverKeys.append(link) }
        if let home = try? HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey, action: { [weak self] in self?.panel.returnHome() }) {
            hoverKeys.append(home)
        }
    }

    /// Starts, changes or stops the pitch change. While the picker is open, going back to the original key keeps
    /// the tap running, so picking another key right after doesn't rebuild it.
    /// `byPerson` is false for a shift that moves a new song to the kept key; a key that a person picks becomes
    /// the kept key, and ends the moving of a new song.
    private func setShift(_ semitones: Int, relative: Bool? = nil, byPerson: Bool = true) {
        let semitones = min(max(semitones, Shift.range.lowerBound), Shift.range.upperBound)
        model.pitchFailed = false
        model.shift = semitones
        if let relative { model.relative = relative }
        if Self.logKeys { log("heard \(model.heard?.name ?? "no key"), \(Shift.text(semitones))") }
        pitch.semitones = semitones
        if byPerson {
            model.moved = nil
            model.pending = nil
            // A key picked while the listen still runs is the key the song stays in: if the final estimate finds
            // another key, the shift changes and the key doesn't.
            if state == .listening, let heard = model.heard {
                follow = heard
                followApplied = true
                followByPerson = true
                log("picked \(heard.name) during the listen, from an estimate of \(model.key?.name ?? "no key")")
            } else {
                follow = nil
            }
            if model.keepKey, let heard = model.heard { keptKey = heard }
        }
        refreshStatus()
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// The pitch change runs for a shift, for the stems, for the lyrics delay, which play through the same output, and
    /// for a song that Muskey Player plays faster or slower, which it keeps in its key.
    /// Stops the pitch change once nothing needs it and no key row shows, as after a slowed song caught up.
    private func stopPitchIfUnwanted() {
        if !pitchWanted, !model.picking, follow == nil, pitch.running { pitch.stopSmoothly { [self] in logShift() } }
    }

    /// The slowing of another player's song needs the pitch change until the output has caught up with the player.
    private var pitchWanted: Bool { model.shift != 0 || model.stemsEngaged || lyricsDelayed || pitch.correction != 0 || slow.active }

    /// The speed of the song as the tap hears it: Muskey Player's speed while its song is the one that plays. A song
    /// from another player plays at its own speed, and only the output slows it down.
    private var playedSpeed: Double { playsInFilePlayer ? filePlayer.speed : 1 }
    /// The speed of the song that plays: Muskey Player's, or the one that another player's song is slowed down to.
    private var currentSpeed: Double { playsInFilePlayer ? filePlayer.speed : slow.speed }
    private var playsInFilePlayer: Bool { filePlayer.hasSong && nowPlaying.player?.bundleID == FilePlayer.bundleID }
    /// The pitch change hears only Muskey Player while it plays the song, so other sounds play as they are.
    private var heardProcess: pid_t? { playsInFilePlayer ? filePlayer.pid : nil }
    /// A song from another player can be slowed down while the player moves its songs, which keeps the output in step
    /// with it, and while it isn't recorded for a save.
    private var slowable: Bool {
        guard let player = nowPlaying.player, player.title?.isEmpty == false, (player.duration ?? 0) > 0, let id = player.bundleID,
              id != FilePlayer.bundleID, !unseekable.contains(id), songRecording == nil
        else { return false }
        return true
    }
    /// The fastest speed: a song from another player can only be slowed down, since the player plays it as fast as it
    /// comes.
    private var fastestSpeed: Double { playsInFilePlayer ? 1.5 : 1 }
    /// The speed that the listens running now hear the song at.
    private var heardSpeed = 1.0

    /// Retry on the red tempo pill: the player gets its moves tried again from the first way, and the song is slowed
    /// to the speed that was asked for.
    private func retrySlowing() {
        guard let wanted = model.slowFailed else { return }
        model.slowFailed = nil
        if let id = slowFailedPlayer {
            unseekable.remove(id)
            seekPaths[id] = nil
        }
        log(String(format: "slow: retry at %.0f%%", wanted * 100))
        syncSeekable()
        syncSpeed()
        playSpeed(wanted)
    }

    /// The keys of the tempo, for a song in Muskey Player.
    private static let speedKeys = [kVK_ANSI_LeftBracket: -1, kVK_ANSI_RightBracket: 1, kVK_ANSI_Equal: 0]

    /// The tempo keys and pills: 5 % slower or faster, from 50 % to 150 %, or the song's own tempo with 0.
    private func changeSpeed(by step: Int) {
        playSpeed(step == 0 ? 1 : min(max(((currentSpeed * 20).rounded() + Double(step)) / 20, 0.5), fastestSpeed))
    }

    /// `--speed S` plays the first song that Muskey Player opens at that speed, for testing the correction.
    private var testSpeed = TestFlags.value("--speed").flatMap(Double.init)

    private func playSpeed(_ target: Double) {
        guard model.speedAdjustable, target != currentSpeed else { return }
        model.slowFailed = nil
        if playsInFilePlayer {
            filePlayer.setSpeed(target)
        } else if let player = nowPlaying.player {
            slowedPlayer = player.bundleID
            slow.setSpeed(target, track: player)
        }
        log(String(format: "tempo %.0f%%", target * 100))
        syncSpeed()
    }

    /// Muskey Player's speed, and the correction that keeps its song in its key. The pitch change hears every app, so
    /// the correction applies only while Muskey Player is the player that macOS shows as playing.
    private func syncSpeed() {
        defer { syncStemsCache() }
        if pitch.heardProcess != heardProcess { pitch.heardProcess = heardProcess }
        // Another player taking over, or a save that records the song, ends the slowing: the output jumps to the player.
        if slow.active, nowPlaying.player?.bundleID != slowedPlayer || songRecording != nil {
            slow.stop(songRecording != nil ? "the song is recorded for a save" : "another player plays")
        }
        // The red tempo pill belongs to the player that couldn't be slowed.
        if model.slowFailed != nil, let id = nowPlaying.player?.bundleID, id != slowFailedPlayer { model.slowFailed = nil }
        let adjustable = playsInFilePlayer || slowable || slow.active
        if model.speedAdjustable != adjustable {
            model.speedAdjustable = adjustable
            log("tempo keys \(adjustable ? "on" : "off") (playing: \(nowPlaying.track?.bundleID ?? "nothing"))")
            updateHoverKeys()
            if adjustable, let speed = testSpeed {
                testSpeed = nil
                DispatchQueue.main.async { [self] in playSpeed(speed) }
            }
        }
        if model.speed != currentSpeed {
            model.speed = currentSpeed
            syncSavable()
        }
        if model.fastestSpeed != fastestSpeed { model.fastestSpeed = fastestSpeed }
        let speed = playedSpeed
        if speed != heardSpeed {
            heardSpeed = speed
            // A listen hears the song at one speed, so one that runs starts over at the new speed, with its whole
            // length ahead of it. A key from the few seconds left would be stored with the song.
            if let analyzer {
                analyzer.play(at: speed)
                startedAt = Date()
                log("the listen starts over at the new speed")
            }
            if autoAnalyzer != nil {
                cancelAutoListen()
                autoListenIfNeeded()
            }
        }
        lyricsSync.hearsSong = speed == 1 && !slow.active
        // The output reads a slowed song from another player as a record played slower, which the correction undoes.
        let read = playsInFilePlayer ? speed : slow.active ? slow.readSpeed : 1
        let correction = read == 1 ? 0 : -12 * log2(read)
        guard correction != pitch.correction else { return }
        pitch.correction = correction
        updateWatching(shown: model.shown)
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// The song plays this far behind itself while Whisper writes its lyrics.
    private static let lyricsLead = 30.0
    private var lyricsDelayed = false

    /// While Whisper writes the lyrics, the song plays 30 seconds behind, so each line is written before it is heard.
    /// Until then the song plays as it is, and the lyrics count down to the step back. The delay ends with the lyrics.
    private func setLyricsDelay(_ on: Bool) {
        guard on != lyricsDelayed else { return }
        lyricsDelayed = on
        syncSeekable()
        // The delay holds the stems until it steps back, so karaoke's silent countdown would outlast it: the song plays
        // from its start as it is, under Whisper's countdown.
        if on, karaokeRestart != nil {
            log("karaoke: Whisper writes the lyrics of the start, the song plays during its countdown")
            endKaraokeRestart()
        }
        pitch.lyricsDelay = on ? Self.lyricsLead : 0
        log(on ? "lyrics: the song plays 30 seconds behind while Whisper writes them" : "lyrics: the song plays without the delay")
        if !on, model.lyricsWaiting != nil { model.lyricsWaiting = nil }
        updateWatching(shown: model.shown)
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// Without the permission the tap would hear silence while still muting the Mac, so it is checked first.
    private func startPitch() {
        switch AudioCapturePermission.status {
        case .granted:
            do {
                let started = CACurrentMediaTime()
                pitch.heardProcess = heardProcess
                try pitch.start()
                log(String(format: "pitch change started (%.0f ms to build%@)", (CACurrentMediaTime() - started) * 1000,
                           pitch.hearsOneProcess ? ", hearing only Muskey Player" : ""))
            } catch {
                pitchFailed("\(error)")
            }
        case .denied:
            pitchFailed("system audio recording is not allowed")
        case .undetermined:
            AudioCapturePermission.request { [self] granted in
                guard pitchWanted, !pitch.running else { return }
                granted ? startPitch() : pitchFailed("system audio recording was not allowed")
            }
        }
    }

    private func pitchFailed(_ reason: String) {
        log("pitch change failed: \(reason)")
        slow.stop("the pitch change failed")
        pitch.stop()
        model.shift = 0
        model.relative = false
        pitch.semitones = 0
        model.stemsMuted = []
        pitch.mutedStems = []
        model.stemsEngaged = false
        pitch.stemsEngaged = false
        model.pitchFailed = true
        follow = nil
        keptKey = nil
        if filePlayer.speed != 1 { filePlayer.setSpeed(1) }
        pitch.correction = 0
        model.speed = 1
    }

    /// Stop Pitch Change in the HUD and in the menu: back to the original key, no key kept for the next songs,
    /// and the HUD closes.
    /// The ✕ on the stems: every stem plays again and the stems close into the Separate button. The stems of the whole
    /// song stay in the cache, so separating the song again is instant.
    private func closeStems() {
        log("stems closed")
        model.stemsFailed = false
        model.stemVolumes = [:]
        pitch.stemVolumes = [:]
        model.stemsMuted = []
        pitch.mutedStems = []
        engageStems(false)
        refreshStatus()
    }

    /// ⌘⌫: the song as it was, at once: its key, its tempo and every stem, with Lock Key released. The HUD stays up.
    private func resetAll() {
        log("⌘⌫: the key, the tempo and the stems back to the original")
        if currentSpeed != 1 { playSpeed(1) }
        if !model.stemVolumes.isEmpty {
            model.stemVolumes = [:]
            pitch.stemVolumes = [:]
        }
        follow = nil
        model.pending = nil
        keptKey = nil
        model.stemsMuted = []
        pitch.mutedStems = []
        model.stemsEngaged = false
        pitch.stemsEngaged = false
        updateStemMeters(shown: model.shown)
        setShift(0, relative: false, byPerson: true)
        refreshStatus()
    }

    private func stopPitch() {
        follow = nil
        model.pending = nil
        keptKey = nil
        model.stemsMuted = []
        pitch.mutedStems = []
        model.stemsEngaged = false
        pitch.stemsEngaged = false
        updateStemMeters(shown: model.shown)
        setShift(0, relative: false, byPerson: false)
        if model.picking { dismiss() }
    }

    private func refreshStatus() {
        syncSavable()
        syncPauseStop()
        statusItem.update(shift: model.shift, from: shiftBase, heard: shiftBase.map { model.shown($0.transposed(by: model.shift)) }, kept: keptKey,
                          current: currentKey,
                          stems: model.stemsAdjusted ? Stem.shown.filter { !model.stemsMuted.contains($0) } : nil,
                          alwaysShown: prefs.menuBarIcon == .always, playing: filePlayer.hasSong, savable: model.savable, hotkey: prefs.hotkey)
    }

    private func logShift() {
        guard let base = shiftBase else { return }
        let shift = model.shift
        let gaps = pitch.running || pitch.gaps == 0 ? "" : ", \(pitch.gaps) gaps in the output"
        // With stems muted, the pitch change keeps running in the original key.
        if shift == 0, pitch.running, model.stemsEngaged { return log("original key, stems playing apart") }
        if shift == 0, pitch.running, lyricsDelayed { return log("original key, 30 seconds behind for the lyrics") }
        if shift == 0, pitch.running, pitch.correction != 0 {
            return log(String(format: "original key, corrected by %+.2f semitones for the tempo", pitch.correction))
        }
        log(shift == 0 ? "pitch change stopped\(gaps)" : "pitch change \(Shift.text(shift)): \(base.name) to \(model.shown(base.transposed(by: shift)).name)")
    }

    /// Cancels a listen in progress, or closes the result or the key picker. A pitch change keeps running.
    private func dismiss() {
        stopCapture()
        analyzer = nil
        follow = nil
        stayOpen = false
        redetecting = false
        model.pending = nil
        if model.picking {
            if NSApp.isActive, let lastOtherApp, lastOtherApp != .current { lastOtherApp.activate() }
            if pitchWanted {
                logShift()
            } else if pitch.running {
                pitch.stopSmoothly { [self] in logShift() }
            }
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.picking = false
        model.hovering = false
        model.moved = nil
        model.shortcuts = false
        model.lyricsShown = false
        model.lyricsFocus = false
        lyricsSong = nil
        lyricsSync.end()
        updateLyricsClock(shown: model.shown)
        panel.setInteraction(clickable: false, keyboard: false)
        session += 1
        state = .idle
        let current = session
        panel.fadeOut { [self] in
            if session == current { panel.orderOut(nil); model.shown = false; model.overRecord = false }
        }
        autoListenIfNeeded()
    }

    /// The log file is written on a queue of its own, in the order of the lines, so a busy disk never holds up the
    /// main thread. The lines still queued when the app exits are written first.
    nonisolated private static let logQueue: DispatchQueue = {
        atexit { AppDelegate.flushLog() }
        return DispatchQueue(label: "muskey.log", qos: .utility)
    }()

    nonisolated private static func flushLog() { logQueue.sync {} }

    private func log(_ line: String) {
        // With `--log-keys`, each line also gets the host time in seconds, to line up a recording with the keys.
        let host = Self.logKeys ? String(format: "  @%.3f", CACurrentMediaTime()) : ""
        let stamped = "\(ISO8601DateFormatter().string(from: Date()))  \(line)\(host)\n"
        print(stamped, terminator: "")
        Self.logQueue.async { Self.append(stamped) }
    }

    nonisolated private static func append(_ stamped: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Muskey.log")
        guard let data = stamped.data(using: .utf8) else { return }
        // The log starts over past 5 MB, with the previous one kept as Muskey.old.log.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
            let old = url.deletingLastPathComponent().appending(path: "Muskey.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension EnvironmentValues {
    @Entry var renderingPreview = false
    /// The region loop of the song, for the time bar and the lyrics.
    @Entry var songLoop: LoopRegion?
}

/// `--render <dir>` writes a PNG of each HUD state over a light and a dark backdrop, to check the design without the screen.
@MainActor func renderPreviews(to dir: String) {
    let csm = EKResult(pitchClass: 1, minor: 1, strength: 0.8)
    let a = EKResult(pitchClass: 9, minor: 0, strength: 0.8)
    // Name, phase, key, progress, shift, picking, relative, Lock Key.
    let states: [(String, HUDModel.Phase, EKResult?, Double, Int, Bool, Bool, Bool)] = [
        ("listening-start", .listening, nil, 0.1, 0, false, false, false),
        ("listening-Csm", .listening, csm, 0.5, 0, false, false, false),
        ("listening-Csm+2", .listening, csm, 0.5, 2, false, false, false),
        ("done-Csm", .done, csm, 1, 0, false, false, false),
        ("done-Bb", .done, EKResult(pitchClass: 10, minor: 0, strength: 0.8), 1, 0, false, false, false),
        ("done-G", .done, EKResult(pitchClass: 7, minor: 0, strength: 0.8), 1, 0, false, false, false),
        ("done-Csm+2", .done, csm, 1, 2, false, false, false),
        ("listening-picking-Csm+2", .listening, csm, 0.4, 2, true, false, false),
        ("picking-Csm", .done, csm, 1, 0, true, false, false),
        ("picking-Csm-3", .done, csm, 1, -3, true, false, false),
        ("picking-Csm+7", .done, csm, 1, 7, true, false, true),
        ("picking-G+1", .done, EKResult(pitchClass: 7, minor: 0, strength: 0.8), 1, 1, true, false, false),
        // Control-C from A major: C minor in the second row, the relative of E♭ major, kept for the next songs.
        ("picking-A-to-Cm", .done, a, 1, -6, true, true, true),
        // A new song with C minor kept, before its first estimate: it plays in its own key, and the row still has the
        // last song's keys.
        ("listening-waiting-Cm", .listening, a, 0.1, 0, true, false, true),
        ("silent", .silent, nil, 0, 0, false, false, false),
        ("idle", .idle, nil, 0, 0, false, false, false),
    ]
    // Each state with no song, then with a song and its cover, then with a song that has no cover.
    let track = NowPlaying.Track(title: "Paper Lanterns", artist: "Mira Vale", album: "Low Tide Radio", duration: 238, elapsed: 102, timestamp: Date().timeIntervalSince1970, rate: 0, bundleID: nil)
    let cover = sampleCover()
    // Made-up lines for the lyrics panel.
    let sampleLyrics: [(Double, String)] = [
        (12, "Paper lanterns over the harbour"), (16.5, "Drifting slow across the tide"), (21, "Every light a little promise"),
        (25.5, "Burning low on the other side"), (30, ""), (34, "Hold the line until the morning"),
        (38.5, "Count the boats along the shore"), (43, "If the wind should change direction"), (47.5, "We'll be singing it once more"),
    ]
    var long = track
    long.title = "Paper Lanterns (Extended Version, Recorded Live at the Harbour Hall)"
    let songs: [(String, NowPlaying.Track?, NSImage?)] = [("", nil, nil), ("-song", track, cover), ("-nocover", track, nil), ("-long", long, cover)]
    // The single card for the states that change it most, with a song, and the shortcuts once from each layout.
    let cardStates = ["listening-start", "listening-Csm", "done-Csm+2", "picking-Csm-3", "picking-A-to-Cm", "listening-waiting-Cm", "silent"]
    for (name, phase, result, progress, shift, picking, relative, keep) in states {
        for (suffix, song, artwork) in songs {
        for layout in ["", "-card", "-card-shortcuts", "-shortcuts"] {
            if layout.isEmpty {
                // Only a few states with a song, and the cover-less record once.
                if song != nil, !["listening-start", "done-Csm+2", "picking-Csm-3", "picking-A-to-Cm", "listening-waiting-Cm"].contains(name) { continue }
                if song != nil, artwork == nil || suffix == "-long", name != "picking-Csm-3" { continue }
            } else {
                guard cardStates.contains(name), suffix == "-song" || (suffix.isEmpty && ["listening-start", "silent"].contains(name)) else { continue }
                if layout.hasSuffix("-shortcuts"), name != "picking-Csm-3" { continue }
            }
        // Two states once more without the relative keys, once more with Option held, and once with the lyrics.
        for variant in ["", "-clean", "-option", "-lyrics", "-lyrics-estimated", "-lyrics-heard", "-lyrics-downloading", "-lyrics-loading",
                        "-lyrics-missing", "-lyrics-instrumental", "-lyrics-failed", "-lyrics-nosong", "-stems", "-stems-solo", "-stems-waiting",
                        "-stems-failed", "-stems-button", "-stems-option", "-skip", "-skip-paused", "-tempo", "-tempo-return", "-saving", "-recording", "-lyrics-focus-skip", "-labels", "-lyrics-stems", "-lyrics-stems-button", "-lyrics-focus", "-lyrics-focus-stems", "-lyrics-focus-separate", "-lyrics-focus-keys", "-paused", "-lyrics-focus-paused", "-lyrics-waiting", "-lyrics-focus-waiting", "-lyrics-focus-rewind", "-lyrics-focus-restart", "-lyrics-focus-loading", "-lyrics-focus-ending", "-arriving", "-lyrics-focus-arriving", "-stems-idle", "-lyrics-idle", "-lyrics-focus-idle", "-key-hover", "-waveform-off", "-waveform-strip", "-waveform-zoom", "-waveform-lanes", "-waveform-streamed", "-waveform-stems", "-loop", "-loop-armed", "-loop-zoom", "-lyrics-loop", "-lyrics-focus-loop"] {
            // The stems once without a record too, where the key column sets the height of the wide glass.
            let noRecord = suffix.isEmpty && layout.isEmpty && ["-stems", "-stems-button"].contains(variant)
            // Karaoke's record once more with a long title, and with no cover.
            let karaokeSong = variant == "-lyrics-focus" && ["-long", "-nocover"].contains(suffix)
            // The glyphs on the record once more over a plain label, the lightest cover there is.
            let lightCover = variant.hasPrefix("-skip") && suffix == "-nocover"
            if !variant.isEmpty, !["picking-Csm-3", "picking-A-to-Cm"].contains(name) || (suffix != "-song" && !noRecord && !karaokeSong && !lightCover) || layout.hasSuffix("-shortcuts") { continue }
            if variant.hasPrefix("-lyrics") || variant.hasPrefix("-stems"), name != "picking-Csm-3" { continue }
        for (scheme, backdrop) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.12))] {
            let model = HUDModel()
            // The renders show both rows, and the "-clean" ones the single row that new installs start with.
            model.relativeKeys = variant != "-clean"
            // The renders show the hints as the pointer over the HUD does, and the "-idle" ones as they are without it.
            model.keysActive = !variant.hasSuffix("-idle")
            // A new song that is heard in 4 of its 6 seconds of waiting.
            if variant.hasSuffix("-arriving") { model.songArriving = Date().addingTimeInterval(-2) ... Date().addingTimeInterval(4) }
            model.flipped = variant == "-option" || variant == "-stems-option"
            // A song in another key can be saved, so its renders show the Save button.
            model.savable = shift != 0 && suffix == "-song"
            if variant.hasPrefix("-lyrics") {
                model.lyricsShown = true
                let text = sampleLyrics.map { "[00:\(String(format: "%05.2f", $0.0))] \($0.1)" }.joined(separator: "\n")
                var lyrics = variant == "-lyrics" || variant.hasSuffix("-loop") ? Lyrics.parse(lrc: text) : Lyrics.estimate(plain: sampleLyrics.map(\.1).joined(separator: "\n"), duration: 238)
                lyrics?.source = variant.hasPrefix("-lyrics-focus") ? .lrcRed(isrc: "USQX91300108") : .lrclib
                model.lyrics = switch variant {
                case "-lyrics-loading": .loading
                case "-lyrics-missing": .notFound
                case "-lyrics-instrumental": .instrumental
                case "-lyrics-failed": .failed
                case "-lyrics-nosong": .none
                case "-lyrics-heard": lyrics.map { .found(Lyrics(lines: $0.lines, timing: .heard)) } ?? .notFound
                // Whisper waits for its first phrase, 23 seconds before the song steps back.
                case "-lyrics-waiting", "-lyrics-focus-waiting": .found(Lyrics(lines: [], timing: .written))
                default: lyrics.map { .found($0) } ?? .notFound
                }
                model.lyricsDownloading = variant == "-lyrics-downloading"
                model.lyricsWriting = variant.hasSuffix("-waiting")
                model.lyricsWaiting = variant.hasSuffix("-waiting") ? 23 : nil
                model.lyricsFocus = variant.hasPrefix("-lyrics-focus")
                // The key row and the instruments as the pointer over the key or the cover shows them.
                model.karaokeKeys = variant == "-lyrics-focus-keys"
                model.karaokeStems = variant == "-lyrics-focus-stems" || variant == "-lyrics-focus-separate"
                model.lyricLine = 3
                // Karaoke's countdown while the vocals are separated: before the song rewinds to where karaoke opened,
                // before it starts over, and while the model loads.
                model.karaokeCountdown = switch variant {
                case "-lyrics-focus-rewind": KaraokeCountdown(seconds: 4, total: 6, restart: false, rewind: 6)
                case "-lyrics-focus-restart": KaraokeCountdown(seconds: 4, total: 6, restart: true, rewind: 6)
                case "-lyrics-focus-loading": KaraokeCountdown(seconds: nil, total: 6, restart: false, rewind: nil)
                // The last second, with the ring at its reddest.
                case "-lyrics-focus-ending": KaraokeCountdown(seconds: 1, total: 6, restart: true, rewind: 6)
                default: nil
                }
            }
            if variant.contains("-stems") || variant == "-lyrics-focus-separate" {
                model.stemsAvailable = true
                // Vocals and drums muted, or only the guitar playing, with the levels of a loud passage. The button
                // shows before the song is separated.
                switch variant {
                case "-stems-solo": model.stemsMuted = Set(Stem.allCases).subtracting([.guitar])
                case "-stems-failed": model.stemsFailed = true
                case "-stems-button", "-lyrics-stems-button", "-lyrics-focus-separate": break
                default: model.stemsMuted = [.vocals, .drums]
                }
                model.stemsEngaged = variant != "-stems-failed" && !variant.hasSuffix("-stems-button") && variant != "-lyrics-focus-separate"
                model.stemsProgress = variant == "-stems-waiting" ? .separating(0.6) : nil
                // Made-up levels of a loud passage.
                if variant != "-stems-waiting" { model.stemMeters.levels = [0.13, 0.2, 0.025, 0.16, 0.05, 0.07, 0.09] }
            }
            model.card = layout.hasPrefix("-card")
            model.shortcuts = layout.hasSuffix("-shortcuts")
            model.phase = phase
            model.key = result.flatMap(DetectedKey.init)
            model.progress = progress
            model.shift = shift
            model.picking = picking
            model.relative = relative
            model.keepKey = keep
            model.track = song
            model.artwork = artwork
            // The made-up waveform, whole, zoomed in, in the lanes of the stems, or half heard as a song from another
            // player is while it plays.
            if song != nil {
                var waveform = HUDSample.waveform
                if variant == "-waveform-lanes" {
                    waveform.stems = Dictionary(uniqueKeysWithValues: Stem.allCases.map { stem in
                        (stem.rawValue, Data(waveform.levels.enumerated().map { i, level in
                            UInt8(max(1, Double(level) * (0.35 + 0.65 * abs(sin(Double(i) / Double(180 + stem.rawValue * 47)))))) }))
                    })
                }
                if variant == "-waveform-streamed" { for i in Int(Double(waveform.levels.count) * 0.46) ..< waveform.levels.count { waveform.levels[i] = 0 } }
                model.wave.waveform = waveform
            }
            model.waveformShown = variant != "-waveform-off"
            model.waveformStyle = variant == "-waveform-strip" ? .strip : .ribbon
            model.wave.zoom = variant == "-waveform-zoom" ? 10 : 1
            model.wave.lanes = variant == "-waveform-lanes"
            // A region loop with the dashed lines of the presses, one still waiting for its end, and one over lyric lines.
            if variant.hasSuffix("loop") || variant.hasPrefix("-loop") {
                model.loop = variant.contains("lyrics") ? LoopRegion(start: 16.5, end: 30)
                    : LoopRegion(start: 86.2, end: variant == "-loop-armed" ? nil : 110.4, startPress: 86.6, endPress: variant == "-loop-armed" ? nil : 110.1)
                if variant == "-loop-zoom" { model.wave.zoom = 6 }
            }
            if variant == "-waveform-stems" {
                model.stemsAvailable = true
                model.stemsEngaged = true
                model.stemsMuted = [.vocals]
                model.stemMeters.levels = [0.13, 0.2, 0.025, 0.16, 0.05, 0.07, 0.09]
            }
            // A finished listen found the tempo of the song, and a listen still running hasn't yet.
            if phase == .done { model.tempo = SongTempo(song: song?.song, bpm: 124) }
            // A song in Muskey Player at 85 % of its speed.
            model.speedAdjustable = variant.hasPrefix("-tempo")
            model.speed = variant == "-tempo" ? 0.85 : 1
            // A slowed song on its way back to 100 %, with the ring on the tempo pill part filled.
            model.tempoReturn = variant == "-tempo-return" ? 0.6 : nil
            // A save of the song in progress, rendered or recorded, which covers the HUD.
            model.saving = variant == "-saving" ? SavingState(name: "Paper Lanterns (C minor, 90%)", progress: 0.42, left: nil)
                : variant == "-recording" ? SavingState(name: "Paper Lanterns (no vocals)", progress: nil, left: "2:15 left") : nil
            // The arm on the record, or lifted off it with the pause glyph that Space shows.
            model.playing = !variant.hasSuffix("-paused")
            if variant.hasSuffix("-paused") { model.playFlash = PlayFlash(playing: false, id: 1) }
            if variant.hasSuffix("-skip") { model.playFlash = PlayFlash(playing: true, id: 1, skip: 1) }
            // The pill that Lock Key shows after it moved a new song.
            if name == "picking-A-to-Cm" { model.moved = KeyMove(from: DetectedKey(pitchClass: 9, minor: false), to: DetectedKey(pitchClass: 0, minor: true)) }
            if name == "listening-waiting-Cm" { model.pending = DetectedKey(pitchClass: 0, minor: true) }
            let view = HUDView(model: model)
                .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
                .environment(\.cornerLabelsShown, variant == "-labels")
                .environment(\.recordHovered, variant.contains("-skip"))
                .environment(\.keyPillExpanded, variant == "-key-hover")
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)\(suffix)\(layout)\(variant)-\(scheme).png"))
            }
        }
        }
        }
        }
    }
    // The pill at the top right of the screen for a song that Muskey opens.
    let pills: [(String, OpenActivity)] = [
        ("pill-downloading", .downloading(name: "Never Gonna Give You Up", progress: 0.45)), ("pill-starting", .downloading(name: "youtube.com", progress: nil)),
        ("pill-installing", .installing(progress: 0.3)), ("pill-failed", .failed(name: "Never Gonna Give You Up")),
        ("pill-needs-downloader", .needsDownloader(name: "youtube.com")), ("pill-install-failed", .installFailed), ("pill-unplayable", .unplayable(name: "Concert.mkv")),
    ]
    // Open URL, empty, with a link that was downloaded before and the songs under it, and after Return on text
    // that can't be opened.
    let recent = [
        OpenLocationModel.Recent(title: "Never Gonna Give You Up", artist: "Rick Astley", site: "youtube.com"),
        OpenLocationModel.Recent(title: "Midnight City", artist: "M83", site: "soundcloud.com"),
        OpenLocationModel.Recent(title: "Around the World", artist: "Daft Punk", site: "youtube.com"),
    ]
    let locations: [(String, String, [OpenLocationModel.Recent], Bool)] = [
        ("open-location-empty", "", [], false),
        ("open-location-recent", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", recent, false),
        ("open-location-error", "not a link", recent, true),
    ]
    for (name, text, songs, submit) in locations {
        for (scheme, backdrop) in [("light", Color(white: 0.85)), ("dark", Color(white: 0.12))] {
            let model = OpenLocationModel()
            model.reset(text: text, recent: songs)
            if submit { model.submit() }
            let view = OpenLocationView(model: model)
                .frame(width: OpenLocationView.width + 40, height: songs.isEmpty ? 140 : 330)
                .padding(.top, 20)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(scheme).png"))
            }
        }
    }
    for (name, activity) in pills {
        for (scheme, backdrop) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.12))] {
            let model = ActivityPillModel()
            model.activity = activity
            let view = ActivityPillView(model: model)
                .frame(width: 460, height: 64)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(scheme).png"))
            }
        }
    }
    exit(0)
}
