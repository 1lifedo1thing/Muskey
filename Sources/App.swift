import AppKit
import Carbon.HIToolbox
import Combine
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
    private let rate: Double
    private var samples: [Float] = []
    private var analyzedCount = 0
    private var peak: Float = 0
    private var finished = false
    private let wavPath: String?

    /// `recordTo` writes everything heard to a mono Float32 WAV on finish, for checking the capture by ear or with another tool.
    init(sampleRate: Double, recordTo wavPath: String? = nil) {
        rate = sampleRate
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

    func finish(_ completion: @escaping (EKResult, Float) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            let result = analyze()
            if let wavPath { writeWAV(samples, rate: UInt32(rate.rounded()), to: wavPath) }
            let peak = peak
            DispatchQueue.main.async { completion(result, peak) }
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
    enum Phase { case listening, done, silent, failed, denied }
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
    /// The key that Lock Key moved a new song from, and the key it moved it to: `G♯ minor → C minor`.
    @Published var moved: String?
    /// The kept key that a new song is going to. Until the first estimate of the song's own key, the song plays in
    /// that key, and the HUD shows where it is going with a spinner.
    @Published var pending: DetectedKey?
    /// The song that the Mac plays and its cover, for the record beside the key.
    @Published var track: NowPlaying.Track?
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
    /// The HUD takes keys: the pointer is over it, or it has the keyboard. The key hints are faint otherwise, since the
    /// keys do nothing then, but they keep their place and some weight in the layout.
    @Published var keysActive = false
    /// The hints are already lighter than the buttons, so 0.45 of that comes close to the buttons that FocusDim dims.
    var hintsOpacity: Double { keysActive ? 1 : 0.45 }
    /// Karaoke shows the record with the song on it (Settings > Lyrics > Show record in karaoke).
    @Published var karaokeRecord = true
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
    /// The stems show in place of the Separate instruments and vocals button: while they play, while any is muted,
    /// and while their failure shows.
    var stemsOpen: Bool { stemsEngaged || stemsFailed || !stemsMuted.isEmpty }

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
    var onLyrics: () -> Void = {}
    var onKaraoke: () -> Void = {}
    var onLyricsRetry: () -> Void = {}
    var onLyricsEdit: () -> Void = {}
    /// A stem chip or its key: mute it or play it again, or with Option play only that stem.
    var onStem: (Stem, Bool) -> Void = { _, _ in }
    var onStemsReset: () -> Void = {}
    /// The Separate instruments and vocals button.
    var onSeparate: () -> Void = {}
    var onStemsRetry: () -> Void = {}
}

/// The level of each stem, in the order of `Stem`, 20 times a second while the stems play and the HUD shows.
final class StemMeters: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: Stem.allCases.count)
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

    private var cardStemsOpen: Bool { model.card && !focus && showsStrip && model.stemsAvailable && model.stemsOpen && !model.shortcuts }

    /// The large lyrics take the place of either layout.
    private var focus: Bool { model.lyricsFocus && model.lyricsShown && showsStrip }

    /// The record shows while a song with a title plays, from the start of a listen.
    private var deckTrack: NowPlaying.Track? {
        guard model.phase == .listening || model.phase == .done, let track = model.track, track.title?.isEmpty == false else { return nil }
        return track
    }

    var body: some View {
        let palette = Palette.of(colorScheme)
        Group {
            if focus {
                lyricsFocus(palette)
            } else if model.card {
                HUDCard(model: model, palette: palette, showsKeys: showsStrip, track: deckTrack)
            } else {
                wide(palette)
            }
        }
        // Sized to its content: the main column fills only the width that the hint bar adds.
        .fixedSize()
        .frame(minWidth: 180, minHeight: 92)
        .overlay(alignment: .topLeading) {
            if model.picking {
                // In karaoke, the close button, the key and the karaoke button sit in one row.
                CloseButton(size: focus ? 16 : 14, action: model.onClose)
                    .padding(focus ? 15 : 12)
                    .modifier(FocusDim(on: focus))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsStrip {
                HStack(spacing: 6) {
                    // Karaoke keeps only its own button, which closes it.
                    if !focus {
                        RoundButton(symbol: "quote.bubble", help: model.lyricsShown ? "Show the keys (L)" : "Show the lyrics (L)", label: "Lyrics", key: "L",
                                    isOn: model.lyricsShown, palette: palette, action: model.onLyrics)
                            .transition(.opacity)
                    }
                    // Karaoke has a button too, besides Return, so that it can be found and clicked like the lyrics.
                    if model.lyricsShown {
                        RoundButton(symbol: "music.microphone", help: focus ? "Close karaoke (↩)" : "Open karaoke (↩)", label: "Karaoke",
                                    key: "↩", isOn: focus, size: focus ? 26 : 20, palette: palette, action: model.onKaraoke)
                            .transition(.opacity)
                    }
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
        .modifier(HUDBackground(tint: tint, scheme: colorScheme))
        .environment(\.recordRewinds, model.rewinds)
        .environment(\.songArriving, model.songArriving)
        .animation(.smooth(duration: 0.35), value: model.songArriving == nil)
        // The glass moves the panel when dragged anywhere that isn't a control.
        .gesture(WindowDragGesture())
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
        .animation(.smooth(duration: 0.35), value: model.lyricsFocus)
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
                                        add: model.onLyricsEdit, edit: model.onLyricsEdit)
                            stems(palette)
                        }
                        .transition(.opacity)
                    } else {
                        main(palette)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                if let track = deckTrack {
                    Rectangle()
                        .fill(palette.ink.opacity(0.1))
                        .frame(width: 1)
                        .padding(.leading, 30)
                        .transition(.opacity)
                    TurntableDeck(track: track, artwork: model.artwork, playing: model.playing, spinning: model.shown && model.playing,
                                  flash: model.playFlash, palette: palette)
                        .padding(.leading, 30)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, showsStrip ? 16 : 22)

            if showsStrip, let key = model.key {
                HStack(spacing: 16) {
                    KeyHints(lyrics: model.lyricsShown, vocals: model.stemsAvailable, otherMode: key.minor ? "major" : "minor", palette: palette)
                        .opacity(model.hintsOpacity)
                    Spacer(minLength: 0)
                    PitchControls(model: model, palette: palette, small: true)
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
            if model.pending ?? model.heard != nil {
                ShiftPills(model: model, palette: palette)
                    .padding(.top, -6)
            }
            if showsStrip, let key = model.key {
                KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys, flipped: model.flipped,
                          palette: palette, select: model.onShift)
                    // The row still has the last song's keys while a new song waits for its key.
                    .opacity(model.pending == nil ? 1 : 0.4)
                    .allowsHitTesting(model.pending == nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
            }
            // The key sits in the middle of the space above the stems.
            .frame(maxHeight: .infinity)
            // The stems stay at the bottom of this column, beside the record, so they don't make the glass taller.
            stems(palette)
        }
    }

    /// Karaoke: the lyrics large in a glass as tall as the screen allows, with the key at the top and the record
    /// rising from the bottom edge. The key turns into the key row while the pointer is over it, and the cover in the
    /// middle of the record shows the instruments and vocals. Without the record, the song and the hints sit under
    /// the lyrics, dimmed until the pointer is over them.
    private func lyricsFocus(_ palette: Palette) -> some View {
        let track = model.karaokeRecord ? deckTrack : nil
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
                    KeyHints(lyrics: true, focus: true, vocals: model.stemsAvailable, karaokeKeys: model.karaokeKeys, otherMode: otherMode, palette: palette)
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
    }

    private var otherMode: String { model.key.map { $0.minor ? "major" : "minor" } ?? "" }

    /// The hints along the bottom edge of the record, no wider than the record: the keys of the lyrics, or the keys
    /// that change the key while the key row shows.
    private var karaokeFooter: some View {
        KeyHints(style: .footer, lyrics: true, focus: true, vocals: model.stemsAvailable, karaokeKeys: model.karaokeKeys, otherMode: otherMode,
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
    private func karaokeKey(_ palette: Palette) -> some View {
        ZStack(alignment: .top) {
            if model.karaokeKeys, let key = model.key {
                KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys, flipped: model.flipped,
                          palette: palette, select: model.onShift)
                    // A new song still waits for its key.
                    .opacity(model.pending == nil ? 1 : 0.4)
                    .allowsHitTesting(model.pending == nil)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(KaraokePopup())
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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
        return model.stemsOpen ? 250 - Self.stemsRowHeight : 250 - Self.separateButtonHeight
    }

    private static let stemsRowHeight: CGFloat = 106
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
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
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
        ignoresMouseEvents = !clickable
        takesKeyboard = keyboard
        if keyboard { makeKey() }
    }

    func present() {
        // Already up: leave it where it is, even if the pointer has moved to another screen or the glass was dragged.
        guard !isVisible || alphaValue < 1 else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        pushed = .zero
        heading = nil
        if let visible = screen?.visibleFrame {
            // The glass is centred in the panel, at the same height as when the panel was 240 points tall.
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + visible.height * 0.14 + 120 - frame.height / 2))
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
    /// karaoke opens in the middle of it, unless it was dragged since it opened.
    func keepOnScreen(animated: Bool) {
        if !model.lyricsFocus { karaokeDragged = false }
        let base = heading ?? frame
        let home = base.offsetBy(dx: -pushed.dx, dy: -pushed.dy)
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
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// The key picker is `model.picking`, on top of any of these: it can open on the first estimate of a listen.
    private enum State { case idle, listening, showing }

    private let model = HUDModel()
    private lazy var panel = HUDPanel(model: model)
    private var hotKey: HotKey?
    private var state = State.idle
    // Bumped whenever a listen starts or ends, so late callbacks from a cancelled one are dropped.
    private var session = 0
    private var tap: SystemAudioTap?
    private var analyzer: KeyAnalyzer?
    private var ticker: Timer?
    private var startedAt = Date()
    private var peak: Float = 0
    /// The peak comes with each estimate, so before the first one a quiet listen can't be told from a late start.
    private var estimated = false

    private let pitch = PitchChanger(recordTo: stringOption("--shift-wav"))
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
    private var backdropChange: AnyCancellable?
    /// Blurs and dims the screen around the karaoke glass, and a click on it closes karaoke.
    private lazy var karaokeBackdrop: KaraokeBackdrop = {
        let backdrop = KaraokeBackdrop()
        backdrop.onClick = { [weak self] in
            guard let self, model.lyricsFocus else { return }
            log("click outside karaoke")
            toggleLyricsFocus()
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
        }
        dragSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settle)
    }

    /// The helper runs while the HUD is up, for the record, and for the song changes while a key is kept, while the
    /// menu bar shows a song's key, and with Always listening. It stays up when the HUD closes with a key kept, since
    /// starting it again would count the song as a new one.
    private func updateWatching(shown: Bool) {
        // While the stems or the lyrics delay play, a pause has to be heard at once, so the helper keeps telling.
        nowPlaying.watching = keptKey != nil || shown || songKey != nil || prefs.alwaysListen || model.stemsEngaged || lyricsDelayed
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
        if pitch.paused == track.playing, Self.logKeys || pitch.stemsEngaged { log(track.playing ? "song plays" : "song paused") }
        if !track.playing {
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

    /// Space over the HUD plays or pauses the song, as the play key does. The record, the tonearm and the stems
    /// change right away, before the player reports the change, and a glyph on the record confirms it.
    private func playPause() {
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
        model.lyricsFocus.toggle()
        log(model.lyricsFocus ? "karaoke" : "lyrics at their usual size")
    }

    /// Karaoke mutes the vocals it finds playing, when Settings has it, and plays them again once it closes, by
    /// Return, L or the HUD closing. Vocals that were muted before, or that V changed during karaoke, stay as they are.
    private func karaokeChanged(_ on: Bool) {
        if !on {
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
    private enum KaraokeRestart: Equatable { case waitingForModel, seeking(Date), started }
    private var karaokeRestart: KaraokeRestart?
    private var karaokeRestartTimeout: DispatchWorkItem?

    /// Karaoke starts the song over (Settings > Lyrics > Restart song in karaoke). While the stems play, the output
    /// stays silent from here: the player moves the song to its start, the stems of the start are separated, and the
    /// countdown shows meanwhile. Without the stems, the song only moves to its start.
    private func restartForKaraoke() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false, track.playing else {
            return log("karaoke: no song plays, nothing to start over")
        }
        // The lyrics delay plays the song 30 seconds behind on the same timeline, with a countdown of its own.
        guard !lyricsDelayed else { return log("karaoke: the song doesn't start over while Whisper writes its lyrics") }
        guard model.stemsEngaged else {
            log("karaoke: the song starts over")
            return nowPlaying.seek(to: 0)
        }
        // Core ML prepares the model for an unknown time, which the Mac would spend silent, so the song plays on and
        // starts over once the model is ready.
        guard StemModel.prepared else {
            log("karaoke: the song starts over once the model is ready")
            karaokeRestart = .waitingForModel
            return
        }
        beginKaraokeRestart()
    }

    private func beginKaraokeRestart() {
        log("karaoke: the song starts over, silent until its vocals are separated")
        karaokeRestart = .seeking(Date())
        pitch.quietLead = true
        nowPlaying.seek(to: 0)
        // A player that ignores the move: the song plays again, and rewinds to where karaoke opened.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, case .seeking = karaokeRestart else { return }
            log("karaoke: the player didn't move the song to its start")
            karaokeRestart = nil
            pitch.quietLead = false
        }
        karaokeRestartTimeout?.cancel()
        karaokeRestartTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    /// The player reports the song at its start after karaoke moved it there: the stems start over from that moment.
    private func checkKaraokeRestart() {
        guard case let .seeking(asked) = karaokeRestart, let track = nowPlaying.track, track.playing,
              let position = track.position(at: Date()), position < 3,
              // A report from before the move would place the start at the wrong moment.
              (track.timestamp ?? .infinity) >= asked.timeIntervalSince1970 - 0.05 else { return }
        karaokeRestartTimeout?.cancel()
        karaokeRestart = .started
        log(String(format: "karaoke: the song started over %.2f s ago", position))
        // The player's timestamp can be a little early, and the start is better 50 ms late than in the moment
        // before the move.
        pitch.restartStems(back: max(0, position - 0.05))
        if model.shown { model.rewinds += 1 }
    }

    private func endKaraokeRestart() {
        karaokeRestartTimeout?.cancel()
        karaokeRestartTimeout = nil
        karaokeRestart = nil
        pitch.quietLead = false
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
            return KaraokeCountdown(seconds: nil, total: total, restart: karaokeRestart != nil, rewind: nil)
        }
        let left = max(1, Int((Self.stemsWait - waited).rounded()))
        // The song rewinds as far as the stems took to start: the estimate, unless they run late.
        let rewind = Int(max(Self.stemsWait, waited + 0.5).rounded())
        return KaraokeCountdown(seconds: left, total: total, restart: karaokeRestart != nil, rewind: rewind)
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
        if prefs.onlineKeys, let key = keyLookup.key(for: song) { return (key, true) }
        return nil
    }

    /// Asks Noiseblend for the key of a song that a listen starts on. The answer shows in the menu bar unless a listen
    /// found the song's key first, and a listen in the HUD starts on it if no estimate came before it. The listen goes
    /// on either way, and its key counts over Noiseblend's.
    private func lookUpKey(_ track: NowPlaying.Track) {
        guard prefs.onlineKeys, Self.lyricsTest == nil else { return }
        let song = track.song
        keyLookup.find(track) { [weak self] key in
            guard let self, key != nil, nowPlaying.track?.song == song else { return }
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
            let analyzer = KeyAnalyzer(sampleRate: tap.sampleRate)
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
        analyzer.finish { [weak self] result, peak in
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
            if prefs.rememberKeys { log(keyCache.store(key, strength: result.strength, for: song)) }
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
    private let keyLookup = KeyLookup()
    private var keyMonitor: Any?
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
    private let showResultFor = option("--show", 6)

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

        NSApp.mainMenu = mainMenu()
        Updates.shared.start()
        prefs.$hotkey.combineLatest(prefs.$recordingHotkey).sink { [weak self] shortcut, recording in
            self?.registerHotKey(recording ? nil : shortcut)
        }.store(in: &prefChanges)
        prefs.$launchAtLogin.sink { [weak self] in self?.updateLoginItem($0) }.store(in: &prefChanges)
        prefs.$relativeKeys.sink { [weak self] in self?.model.relativeKeys = $0 }.store(in: &prefChanges)
        prefs.$karaokeRecord.sink { [weak self] in self?.model.karaokeRecord = $0 }.store(in: &prefChanges)
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
        model.onStop = { [weak self] in self?.stopPitch() }
        model.onKeep = { [weak self] in self?.toggleKeep() }
        model.onLayout = { [weak self] in self?.toggleLayout() }
        model.onLyrics = { [weak self] in self?.toggleLyrics() }
        model.onKaraoke = { [weak self] in
            if Self.logKeys { self?.log("click karaoke") }
            self?.toggleLyricsFocus()
        }
        model.onLyricsRetry = { [weak self] in self?.retryLyrics() }
        model.onLyricsEdit = { [weak self] in self?.editLyrics() }
        model.onStem = { [weak self] stem, solo in self?.toggleStem(stem, solo: solo) }
        model.onStemsReset = { [weak self] in self?.setStems([]) }
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
        statusItem.onPlayAllStems = { [weak self] in self?.setStems([]) }
        statusItem.onSettings = { [weak self] in self?.settingsWindow.show() }
        nowPlaying.log = { [weak self] in self?.log($0) }
        nowPlaying.onSongChange = { [weak self] in
            // Another song during karaoke's countdown plays as it comes.
            if self?.karaokeRestart != nil { self?.endKaraokeRestart() }
            self?.songArrives()
            self?.songChanged($0)
        }
        nowPlaying.onTrack = { [weak self] in
            self?.syncPaused()
            self?.checkKaraokeRestart()
            self?.syncTrack()
            self?.startOnKnownKey()
            self?.syncSongKey()
        }
        // Published before the change, so the new value comes from the publisher.
        shownChange = model.$shown.removeDuplicates().sink { [weak self] shown in
            if shown { self?.shownAt = Date() }
            self?.updateWatching(shown: shown)
            self?.watchOption(shown)
            self?.updateLyricsClock(shown: shown)
            self?.updateStemMeters(shown: shown)
            self?.prepareStemModel(shown: shown)
            // With every stem playing, the song as it plays comes back once the HUD is gone.
            if !shown, self?.model.stemsMuted.isEmpty == true { self?.engageStems(false) }
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
            // Published before the change, so the stems change on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in self?.karaokeChanged(on) }
        }
        glassChange = model.$glassFrame.removeDuplicates().sink { [weak self] _ in
            // Published before the change, so the panel reads the new frame on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, panel.isVisible else { return }
                panel.keepOnScreen(animated: panel.alphaValue >= 1)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            // Only a drag: the moves that keep the glass on the screen aren't a new place for it.
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
            self?.panelMoved()
        }
        pitch.onFailure = { [weak self] error in self?.pitchFailed("\(error)") }
        pitch.onStemsFailure = { [weak self] error in self?.stemsFailed("\(error)") }
        pitch.stemsLog = { [weak self] line in DispatchQueue.main.async { self?.log(line) } }
        ModelDownload.stems.log = { [weak self] in self?.log($0) }
        ModelDownload.winds.log = { [weak self] in self?.log($0) }
        ModelDownload.whisper.log = { [weak self] in self?.log($0) }
        stopPitchOnSignals()
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
        let service = SMAppService.mainApp
        let path = Bundle.main.bundlePath
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
            log("adding the login item failed: \(error)")
        }
    }

    /// Settings and the key commands of its window and of the lyrics window, which work while one of them is the
    /// active window. The text editing commands are what make Command-V paste lyrics.
    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Muskey", action: #selector(NSApplication.terminate), keyEquivalent: "q")
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
        for submenu in [app, edit, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }

    @objc private func showSettings() { settingsWindow.show() }

    /// Quitting while the lyrics show keeps the words heard and the lines written so far, as closing the HUD does.
    func applicationWillTerminate(_: Notification) {
        cancelAutoListen()
        pitch.stop()
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
                self?.pitch.stop()
                self?.lyricsSync.end()
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
        model.shown = true
        if !model.picking {
            model.key = nil
            panel.setInteraction(clickable: false, keyboard: false)
        }
        panel.present()
        startedAt = Date()

        let current = session
        let tap = SystemAudioTap()
        self.tap = tap
        do {
            try tap.prepare()
            let analyzer = KeyAnalyzer(sampleRate: tap.sampleRate, recordTo: Self.stringOption("--wav"))
            self.analyzer = analyzer
            try tap.start { [weak self] samples in
                analyzer.append(samples) { result, peak in
                    guard let self, self.session == current else { return }
                    self.update(result, peak: peak)
                }
            }
        } catch {
            return fail(.failed, "\(error)")
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        startOnKnownKey()
    }

    /// A song whose key a full listen found before, or Noiseblend gave, starts on that key: the HUD shows it with its
    /// row right away, and Lock Key moves the song once it has played in its own key for a moment. The listen still
    /// runs, and only its final estimate can change the key. Runs again on each Now Playing update until the first
    /// estimate, since the helper that reads the song starts with the HUD, and once more when Noiseblend answers.
    private func startOnKnownKey() {
        guard state == .listening, !estimated, remembered == nil, let track = nowPlaying.track, track.playing else { return }
        // A paused player that Now Playing still names may not be what the Mac plays.
        listenSong = listenSong ?? track.song
        guard track.song == listenSong else { return }
        guard let known = knownKey(for: track.song) else {
            if lookedUp != track.song {
                lookedUp = track.song
                lookUpKey(track)
            }
            return
        }
        let key = known.key
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
        let elapsed = Date().timeIntervalSince(startedAt)
        model.progress = min(1, elapsed / seconds)
        // A song that starts quietly gets the whole listen when it has to be moved to the kept key.
        if ((follow == nil || followByPerson) && elapsed >= silenceAfter && estimated && peak < 0.0005) || elapsed >= seconds { finish() }
    }

    private func stopCapture() {
        ticker?.invalidate()
        ticker = nil
        tap?.stop()
        tap = nil
    }

    private func finish() {
        guard state == .listening, let analyzer else { return }
        stopCapture()
        self.analyzer = nil
        state = .showing
        let current = session
        let elapsed = Date().timeIntervalSince(startedAt)

        analyzer.finish { [self] result, peak in
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
            if let song = listenSong, let track = nowPlaying.track, track.playing, track.song == song {
                if prefs.rememberKeys { log(keyCache.store(key, strength: result.strength, for: song)) }
                keyLookup.heard(key, for: song)
            }
            updateHoverKeys()
            guard !model.picking else { return }
            panel.setInteraction(clickable: true, keyboard: false)
            dismiss(after: showResultFor)
        }
    }

    private func fail(_ phase: HUDModel.Phase, _ reason: String) {
        stopCapture()
        analyzer = nil
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
            // Typing in the lyrics editor stays in the editor.
            guard let self, self.model.picking, !flags.contains(.command), !flags.contains(.control),
                  event.window == nil || event.window === self.panel else { return event }
            return self.handleKey(Int(event.keyCode), shift: flags.contains(.shift), option: flags.contains(.option)) ? nil : event
        }
        updateHoverKeys()
    }

    /// Letter keys: A picks the A in the song's mode, Option the A in the other mode, and Shift the key with a sharp or
    /// flat on A.
    private static let letters: [Int: Character] = [
        kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_A: "A", kVK_ANSI_B: "B",
    ]

    /// Keys of the key picker, from the picker's own key events or from the hotkeys that hovering over the HUD
    /// registers. Returns false for a key it doesn't use.
    @discardableResult private func handleKey(_ code: Int, shift: Bool, option: Bool) -> Bool {
        if Self.logKeys { log("key \(code)\(shift ? " shift" : "")\(option ? " option" : "")") }
        // With the key row hidden, the keys that change the pitch would change it out of sight.
        if handleStemKey(code, option: option) { return true }
        if code == kVK_Space {
            playPause()
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
            let minor = option ? !key.minor : key.minor
            // A letter with no sharp or flat key in that mode does nothing with Shift, but still counts as used.
            guard let pitchClass = DetectedKey.pitchClass(letter: letter, accidental: shift, minor: minor) else { return true }
            change(to: key.shift(to: DetectedKey(pitchClass: pitchClass, minor: minor)), relative: option)
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
            setStems([])
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
        engageStems(!muted.isEmpty || (model.shown && model.stemsEngaged))
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

    /// Three minutes after the HUD closed with every stem playing, the model is freed.
    private func prepareStemModel(shown: Bool) {
        stemModelRelease?.cancel()
        stemModelRelease = nil
        if shown {
            model.stemsAvailable = StemModel.installed
        } else if model.stemsMuted.isEmpty {
            let release = DispatchWorkItem { [weak self] in
                guard let self, !model.shown, model.stemsMuted.isEmpty else { return }
                StemModel.unload()
            }
            stemModelRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: release)
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
            log("backspin: the output stepped back in the song")
            if model.shown { model.rewinds += 1 }
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
            let progress = pitch.stemsWaited.map { waited -> StemsProgress in
                StemModel.prepared ? .separating(min(0.97, waited / Self.stemsWait)) : .loading
            }
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
        guard target != nil || (model.shown && model.picking) else { return }
        log(target.map { "song changed, moving it to \($0.name)" } ?? "song changed, listening for its key")
        switch AudioCapturePermission.status {
        case .granted: break
        case .denied: return log("system audio recording is not allowed")
        case .undetermined:
            // Each song change while the dialog is up asks again, so only the song that still plays gets a listen.
            return AudioCapturePermission.request { [self] granted in
                guard granted else { return log("system audio recording was not allowed") }
                if keptKey != nil || (model.shown && model.picking), nowPlaying.track?.song == track.song, state != .listening { songChanged(track) }
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
        model.moved = "\(key.name) → \(model.heard?.name ?? target.name)"
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

    /// Lyrics added by hand for the song on the record, or LRCLIB's, asked for once per song while the lyrics show.
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
        case let .found(lyrics): "\(lyrics.lines.count) lines, \(lyrics.timing == .synced ? "synced" : "estimated timing")"
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
        let line = times.lastIndex { $0 <= heard + 0.25 }
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

    /// `--lyrics-lookup "TITLE|ARTIST|ALBUM|SECONDS"` asks LRCLIB for a song's lyrics the way the panel does,
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

    /// Holding Option over the keys, or while the picker is open, flips them to the other mode. Without Accessibility
    /// the app gets no modifier changes from other apps, so it reads the modifiers 30 times a second while the HUD
    /// is up.
    private func watchOption(_ shown: Bool) {
        optionWatch?.invalidate()
        optionWatch = nil
        guard shown else { return model.flipped = false }
        optionWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let flags = NSEvent.modifierFlags
            let flipped = flags.contains(.option) && !flags.contains(.command) && model.key != nil && (model.hovering || model.picking)
            if model.flipped != flipped { model.flipped = flipped }
        }
    }

    /// While the pointer is over a HUD that shows a key, its keys work without the HUD having keyboard focus,
    /// as hotkeys that go away when the pointer leaves.
    /// `--log-keys` logs the hover over the HUD and every key that reaches it, for testing the keys from a script.
    private static let logKeys = TestFlags.has("--log-keys")

    /// The key hints show while the keys work: with the pointer over the HUD, or with the HUD holding the keyboard.
    private func updateKeysActive() {
        let active = model.hovering || panel.isKeyWindow
        if model.keysActive != active { model.keysActive = active }
    }

    private var hoverKeysForLyrics = false
    private var hoverKeysForStems = false
    private var hoverKeysForKaraoke = false

    private func updateHoverKeys() {
        let wanted = model.hovering && model.shown && model.key != nil && (model.picking || model.phase == .done || model.phase == .listening)
            && lyricsEditor == nil
        // The lyrics take fewer keys than the key row, so the keys change when the panel does.
        guard wanted == hoverKeys.isEmpty
            || (wanted && (hoverKeysForLyrics != model.lyricsShown || hoverKeysForStems != model.stemsAvailable || hoverKeysForKaraoke != model.lyricsFocus))
        else { return }
        if Self.logKeys, wanted == hoverKeys.isEmpty { log("keys over the HUD \(wanted ? "on" : "off")") }
        hoverKeys = []
        guard wanted else { return }
        hoverKeysForLyrics = model.lyricsShown
        hoverKeysForStems = model.stemsAvailable
        hoverKeysForKaraoke = model.lyricsFocus
        let modifiers = [0, shiftKey, optionKey, optionKey | shiftKey]
        var keys: [(Int, Int)] = [kVK_Escape, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_S, kVK_Space].map { ($0, 0) }
        if model.stemsAvailable {
            // V mutes the vocals or plays them again, in every layout.
            keys += Self.stemKeys.flatMap { code in [(code, 0), (code, optionKey)] } + [(kVK_ANSI_0, 0), (kVK_ANSI_V, 0)]
        }
        // Return shows the lyrics large, or back at their usual size.
        if model.lyricsShown { keys += [kVK_Return, kVK_ANSI_KeypadEnter].map { ($0, 0) } }
        // The key row, and karaoke, change the key by its letter.
        if !model.lyricsShown || model.lyricsFocus {
            keys += Self.letters.keys.flatMap { code in modifiers.map { (code, $0) } }
            keys += [kVK_Delete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { ($0, 0) }
        }
        hoverKeys = keys.compactMap { code, modifiers in
            try? HotKey(keyCode: code, modifiers: modifiers) { [weak self] in
                self?.handleKey(code, shift: modifiers & shiftKey != 0, option: modifiers & optionKey != 0)
            }
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

    /// The pitch change runs for a shift, for the stems, and for the lyrics delay, which play through the same output.
    private var pitchWanted: Bool { model.shift != 0 || model.stemsEngaged || lyricsDelayed }

    /// The song plays this far behind itself while Whisper writes its lyrics.
    private static let lyricsLead = 30.0
    private var lyricsDelayed = false

    /// While Whisper writes the lyrics, the song plays 30 seconds behind, so each line is written before it is heard.
    /// Until then the song plays as it is, and the lyrics count down to the step back. The delay ends with the lyrics.
    private func setLyricsDelay(_ on: Bool) {
        guard on != lyricsDelayed else { return }
        lyricsDelayed = on
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
                try pitch.start()
                log("pitch change started")
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
    }

    /// Stop Pitch Change in the HUD and in the menu: back to the original key, no key kept for the next songs,
    /// and the HUD closes.
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
        statusItem.update(shift: model.shift, from: shiftBase, heard: shiftBase.map { model.shown($0.transposed(by: model.shift)) }, kept: keptKey,
                          current: currentKey,
                          stems: model.stemsMuted.isEmpty ? nil : Stem.shown.filter { !model.stemsMuted.contains($0) },
                          alwaysShown: prefs.menuBarIcon == .always, hotkey: prefs.hotkey)
    }

    private func logShift() {
        guard let base = shiftBase else { return }
        let shift = model.shift
        let gaps = pitch.running || pitch.gaps == 0 ? "" : ", \(pitch.gaps) gaps in the output"
        // With stems muted, the pitch change keeps running in the original key.
        if shift == 0, pitch.running, model.stemsEngaged { return log("original key, stems playing apart") }
        if shift == 0, pitch.running, lyricsDelayed { return log("original key, 30 seconds behind for the lyrics") }
        log(shift == 0 ? "pitch change stopped\(gaps)" : "pitch change \(Shift.text(shift)): \(base.name) to \(model.shown(base.transposed(by: shift)).name)")
    }

    /// Cancels a listen in progress, or closes the result or the key picker. A pitch change keeps running.
    private func dismiss() {
        stopCapture()
        analyzer = nil
        follow = nil
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
            if session == current { panel.orderOut(nil); model.shown = false }
        }
        autoListenIfNeeded()
    }

    private func log(_ line: String) {
        // With `--log-keys`, each line also gets the host time in seconds, to line up a recording with the keys.
        let host = Self.logKeys ? String(format: "  @%.3f", CACurrentMediaTime()) : ""
        let stamped = "\(ISO8601DateFormatter().string(from: Date()))  \(line)\(host)\n"
        print(stamped, terminator: "")
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
    // The single card for the states that change it most, with a song, and once with the shortcuts in place of the keys.
    let cardStates = ["listening-start", "listening-Csm", "done-Csm+2", "picking-Csm-3", "picking-A-to-Cm", "listening-waiting-Cm", "silent"]
    for (name, phase, result, progress, shift, picking, relative, keep) in states {
        for (suffix, song, artwork) in songs {
        for layout in ["", "-card", "-card-shortcuts"] {
            if layout.isEmpty {
                // Only a few states with a song, and the cover-less record once.
                if song != nil, !["listening-start", "done-Csm+2", "picking-Csm-3", "picking-A-to-Cm", "listening-waiting-Cm"].contains(name) { continue }
                if song != nil, artwork == nil || suffix == "-long", name != "picking-Csm-3" { continue }
            } else {
                guard cardStates.contains(name), suffix == "-song" || (suffix.isEmpty && ["listening-start", "silent"].contains(name)) else { continue }
                if layout == "-card-shortcuts", name != "picking-Csm-3" { continue }
            }
        // Two states once more without the relative keys, once more with Option held, and once with the lyrics.
        for variant in ["", "-clean", "-option", "-lyrics", "-lyrics-estimated", "-lyrics-heard", "-lyrics-downloading", "-lyrics-loading",
                        "-lyrics-missing", "-lyrics-instrumental", "-lyrics-failed", "-lyrics-nosong", "-stems", "-stems-solo", "-stems-waiting",
                        "-stems-failed", "-stems-button", "-stems-option", "-labels", "-lyrics-stems", "-lyrics-stems-button", "-lyrics-focus", "-lyrics-focus-stems", "-lyrics-focus-separate", "-lyrics-focus-keys", "-lyrics-focus-plain", "-paused", "-lyrics-focus-paused", "-lyrics-waiting", "-lyrics-focus-waiting", "-lyrics-focus-rewind", "-lyrics-focus-restart", "-lyrics-focus-loading", "-arriving", "-lyrics-focus-arriving", "-stems-idle", "-lyrics-idle", "-lyrics-focus-idle"] {
            // The stems once without a record too, where the key column sets the height of the wide glass.
            let noRecord = suffix.isEmpty && layout.isEmpty && ["-stems", "-stems-button"].contains(variant)
            // Karaoke's record once more with a long title, and with no cover.
            let karaokeSong = variant == "-lyrics-focus" && ["-long", "-nocover"].contains(suffix)
            if !variant.isEmpty, !["picking-Csm-3", "picking-A-to-Cm"].contains(name) || (suffix != "-song" && !noRecord && !karaokeSong) || layout == "-card-shortcuts" { continue }
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
            if variant.hasPrefix("-lyrics") {
                model.lyricsShown = true
                let text = sampleLyrics.map { "[00:\(String(format: "%05.2f", $0.0))] \($0.1)" }.joined(separator: "\n")
                let lyrics = variant == "-lyrics" ? Lyrics.parse(lrc: text) : Lyrics.estimate(plain: sampleLyrics.map(\.1).joined(separator: "\n"), duration: 238)
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
                // The key row and the instruments as the pointer over the key or the cover shows them, and karaoke
                // with Show record in karaoke off.
                model.karaokeKeys = variant == "-lyrics-focus-keys"
                model.karaokeStems = variant == "-lyrics-focus-stems" || variant == "-lyrics-focus-separate"
                model.karaokeRecord = variant != "-lyrics-focus-plain"
                model.lyricLine = 3
                // Karaoke's countdown while the vocals are separated: before the song rewinds to where karaoke opened,
                // before it starts over, and while the model loads.
                model.karaokeCountdown = switch variant {
                case "-lyrics-focus-rewind": KaraokeCountdown(seconds: 4, total: 6, restart: false, rewind: 6)
                case "-lyrics-focus-restart": KaraokeCountdown(seconds: 4, total: 6, restart: true, rewind: 6)
                case "-lyrics-focus-loading": KaraokeCountdown(seconds: nil, total: 6, restart: false, rewind: nil)
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
            model.card = !layout.isEmpty
            model.shortcuts = layout == "-card-shortcuts"
            model.phase = phase
            model.key = result.flatMap(DetectedKey.init)
            model.progress = progress
            model.shift = shift
            model.picking = picking
            model.relative = relative
            model.keepKey = keep
            model.track = song
            model.artwork = artwork
            // The arm on the record, or lifted off it with the pause glyph that Space shows.
            model.playing = !variant.hasSuffix("-paused")
            if variant.hasSuffix("-paused") { model.playFlash = PlayFlash(playing: false, id: 1) }
            // The pill that Lock Key shows after it moved a new song.
            if name == "picking-A-to-Cm" { model.moved = "A major → C minor" }
            if name == "listening-waiting-Cm" { model.pending = DetectedKey(pitchClass: 0, minor: true) }
            let view = HUDView(model: model)
                .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
                .environment(\.cornerLabelsShown, variant == "-labels")
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
    exit(0)
}
