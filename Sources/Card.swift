import SwiftUI

/// The key name, or Listening before the first estimate, filling with ink from the left as the listen goes on: the
/// title is the listen's progress bar. Once the listen is over it is plain ink.
struct ListenTitle: View {
    let text: String
    let size: CGFloat
    /// Nil once the listen is over.
    let progress: Double?
    let palette: Palette

    var body: some View {
        // The sharp or flat dims once the listen is over, since the fill runs across the whole title until then.
        (progress == nil ? Accidental.text(text, color: palette.ink) : Text(text))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(style)
            .animation(.linear(duration: 0.1), value: progress)
    }

    private var style: AnyShapeStyle {
        guard let progress else { return AnyShapeStyle(palette.ink) }
        let filled = min(1, max(0, progress))
        let faint = palette.ink.opacity(0.28)
        return AnyShapeStyle(LinearGradient(stops: [
            .init(color: palette.ink, location: 0),
            .init(color: palette.ink, location: filled),
            .init(color: faint, location: filled),
            .init(color: faint, location: 1),
        ], startPoint: .leading, endPoint: .trailing))
    }
}

/// The symbol before the title: a waveform that ripples while listening, a note on the result, and the reason
/// when there is no result.
struct HUDSymbol: View {
    @ObservedObject var model: HUDModel
    let size: CGFloat
    let palette: Palette

    var body: some View {
        Image(systemName: name)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.shown && model.phase == .listening)
            .symbolEffect(.bounce, value: model.phase == .done)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(model.phase == .silent ? palette.muted : palette.accent)
    }

    private var name: String {
        switch model.phase {
        case .listening: "waveform"
        case .done: "music.note"
        case .silent: "speaker.slash"
        case .failed: "exclamationmark.triangle"
        case .denied: "lock"
        }
    }
}

/// The title line of both layouts: the symbol, then the key that is heard with its relative on the same line, or
/// Listening before the first estimate. While a new song waits for its key, the kept key that it is going to, faded.
struct TitleLine: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    var symbolSize: CGFloat = 30
    var keySize: CGFloat = 30
    var relativeSize: CGFloat = 17
    var listeningSize: CGFloat = 40

    private var progress: Double? { model.phase == .listening ? model.progress : nil }

    var body: some View {
        HStack(spacing: 10) {
            HUDSymbol(model: model, size: symbolSize, palette: palette)
            if let key = model.pending ?? model.heard {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    ListenTitle(text: key.name, size: keySize, progress: progress, palette: palette)
                    Accidental.text(key.relative.name, color: palette.muted)
                        .font(.system(size: relativeSize, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                }
                // Less faded than before the title filled, since the part that hasn't filled is already faint.
                .opacity(model.pending == nil ? 1 : 0.65)
                .contentTransition(.interpolate)
            } else if model.phase == .listening {
                ListenTitle(text: "Listening", size: listeningSize, progress: progress, palette: palette)
                    .transition(.opacity)
            }
        }
        .lineLimit(1)
    }
}

/// The pills under the title: the shift and the move that Lock Key made, the kept key that a new song waits for, or
/// a pitch change that failed.
struct ShiftPills: View {
    @ObservedObject var model: HUDModel
    let palette: Palette

    var body: some View {
        if model.pitchFailed {
            ShiftPill(text: "Pitch change failed", palette: palette)
        } else if let pending = model.pending {
            // In the red of Lock Key, which turns it into the move once the song's key is found.
            ShiftPill(text: "→ \(pending.name)", hue: .red, waiting: true, palette: palette)
                .transition(.opacity)
        } else if model.shift != 0 || model.moved != nil {
            HStack(spacing: 6) {
                if model.shift != 0 {
                    ShiftPill(text: Shift.text(model.shift), hue: model.shift > 0 ? StripColors.up : StripColors.down, palette: palette)
                        .contentTransition(.numericText(value: Double(model.shift)))
                }
                // In the red of Lock Key, which made the change.
                if let moved = model.moved {
                    ShiftPill(text: moved, hue: .red, palette: palette)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }
}

/// Lock Key, and Stop Pitch Change while a pitch change runs or a new song waits to be moved.
struct PitchControls: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    var small = false

    var body: some View {
        HStack(spacing: small ? 6 : 8) {
            HUDButton(title: "Lock Key", symbol: model.keepKey ? "lock.fill" : "lock.open", palette: palette, isOn: model.keepKey, small: small, action: model.onKeep)
                .help(model.heard.map { "Play the next songs in \($0.name) (K)" } ?? "Lock Key (K)")
            // Also while a new song plays in its own key and waits for the move: the pitch change still runs.
            if model.shift != 0 || model.pending != nil {
                HUDButton(title: "Stop Pitch Change", symbol: "stop.fill", palette: palette, small: small, action: model.onStop)
                    .transition(.opacity)
            }
        }
    }
}

/// The single card: the record in the middle, with a ring around it that fills as the listen goes on, and from the
/// first estimate the twelve keys around it by fifths. The title, the pills and the song go under it, and Lock Key and
/// Stop Pitch Change along the bottom, with the keyboard shortcuts behind a ? button.
struct HUDCard: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    let showsKeys: Bool
    let track: NowPlaying.Track?

    /// The rings of keys: the song's mode outside, and the other mode inside, far enough from the outer ring that
    /// the chips of a column don't touch where the rings run diagonally. Without the inner ring, the record is
    /// bigger and the ring of keys is closer to it.
    private var record: CGFloat { model.relativeKeys ? 136 : 160 }
    private var radius: CGFloat { model.relativeKeys ? 132 : 110 }
    private static let innerRadius: CGFloat = 96
    private var ring: CGFloat { radius * 2 + 40 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The shortcuts take the place of the record and the keys, until the ? button is pressed again.
                if model.shortcuts, showsKeys, let key = model.key {
                    KeyHints(style: .list, otherMode: key.minor ? "major" : "minor", palette: palette)
                        .frame(width: ring, height: ring)
                        .background(RoundedRectangle(cornerRadius: 22).fill(palette.ink.opacity(0.06)))
                        .transition(.opacity)
                } else if model.lyricsShown, showsKeys {
                    LyricsPanel(state: model.lyrics, line: model.lyricLine, palette: palette, width: ring - 24, height: ring, downloading: model.lyricsDownloading,
                                writing: model.lyricsWriting && !model.lyricsSkipped, waiting: model.lyricsWaiting, retry: model.onLyricsRetry, add: model.onLyricsEdit, edit: model.onLyricsEdit)
                        .transition(.opacity)
                } else {
                    if let track {
                        RecordDisc(track: track, artwork: model.artwork, spinning: model.shown && model.playing, side: record, flash: model.playFlash)
                            .transition(.opacity)
                    } else {
                        EmptyPlatter(side: record)
                            .transition(.opacity)
                    }
                    if model.phase == .listening {
                        ListenRing(progress: model.progress, palette: palette)
                            .frame(width: record + 14, height: record + 14)
                            .transition(.opacity)
                    }
                }
                // Over the lyrics or the shortcuts, which take the place of the record.
                if (model.shortcuts || model.lyricsShown) && showsKeys {
                    PlayFlashView(flash: model.playFlash, size: 72)
                }
                if !model.shortcuts, !model.lyricsShown, showsKeys, let key = model.key {
                    FifthsRing(original: key, shift: model.shift, relative: model.relative, palette: palette, radius: radius,
                               innerRadius: Self.innerRadius, showsRelatives: model.relativeKeys, flipped: model.flipped, select: model.onShift)
                        // The ring still has the last song's keys while a new song waits for its key.
                        .opacity(model.pending == nil ? 1 : 0.4)
                        .allowsHitTesting(model.pending == nil)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(width: ring, height: ring)

            TitleLine(model: model, palette: palette, symbolSize: 22, keySize: 26, relativeSize: 15, listeningSize: 32)
                .padding(.top, 8)
            ShiftPills(model: model, palette: palette)
                .padding(.top, 5)

            if let track {
                VStack(spacing: 2) {
                    Text(track.title ?? "")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.ink)
                    let byline = [track.artist, track.album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                    if !byline.isEmpty {
                        Text(byline)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(palette.muted)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: ring)
                .padding(.top, 10)
                .id(track.song.map { $0 ?? "" }.joined(separator: "\u{1F}"))
                .transition(.opacity)
            }

            if showsKeys, model.stemsAvailable, !model.shortcuts {
                if model.stemsOpen {
                    StemsRow(model: model, palette: palette, compact: true, card: true)
                        .padding(.top, 14)
                        // The half of the hints pill that hangs below the tray.
                        .padding(.bottom, StemsRow.pillHeight / 2)
                        .transition(.opacity)
                } else {
                    SeparateButton(palette: palette, action: model.onSeparate)
                        // Quiet until the pointer is over it, so the ring and the key read first.
                        .modifier(FocusDim(on: true))
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }

            if showsKeys {
                HStack(spacing: 8) {
                    // As wide as the ? button, so Lock Key and Stop Pitch Change sit in the middle.
                    Color.clear.frame(width: 20, height: 1)
                    Spacer(minLength: 0)
                    PitchControls(model: model, palette: palette, small: true)
                        .modifier(FocusDim(on: true))
                    Spacer(minLength: 0)
                    RoundButton(text: "?", help: "Keyboard Shortcuts", isOn: model.shortcuts, palette: palette) { model.shortcuts.toggle() }
                }
                .padding(.top, 14)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, showsKeys ? 12 : 18)
        // Wide enough for Lock Key and Stop Pitch Change on one line between the two 20-point ends of the bottom row.
        .frame(width: ring + 84)
        .animation(.snappy(duration: 0.25), value: model.shortcuts)
        .animation(.snappy(duration: 0.25), value: model.lyricsShown)
        .animation(.snappy(duration: 0.3), value: model.relativeKeys)
    }
}

/// A thin ring around the record of the single card, which fills clockwise from the top as the listen goes on.
private struct ListenRing: View {
    let progress: Double
    let palette: Palette

    var body: some View {
        ZStack {
            Circle().stroke(palette.ink.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(palette.muted, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}
