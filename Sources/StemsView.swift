import SwiftUI

extension Stem {
    /// A warm hue for each stem, from rose to gold, which sits with the warm glass and still tells the stems apart.
    var hue: Double {
        switch self {
        case .vocals: 20
        case .piano: 30
        case .drums: 45
        case .other: 58
        case .bass: 70
        case .winds: 82
        case .guitar: 95
        }
    }

    var symbol: String {
        switch self {
        case .vocals: "music.mic"
        case .drums: "metronome.fill"
        case .bass: "hifispeaker.fill"
        case .guitar: "guitars.fill"
        case .piano: "pianokeys"
        case .other: "music.quarternote.3"
        case .winds: "wind"
        }
    }

    /// The ring that pulses with the sound.
    func color(_ scheme: ColorScheme, opacity: Double = 1) -> Color {
        scheme == .dark ? .oklch(0.74, 0.13, hue, opacity: opacity) : .oklch(0.66, 0.14, hue, opacity: opacity)
    }

    /// The circle's colour: a calm tone of the stem's hue while it is quiet, which gets more saturated and brighter
    /// as the stem gets louder (`level` from 0 to 1). Over the loudest fifth it climbs steeply, so the circle flashes
    /// on the peaks.
    func fill(_ scheme: ColorScheme, level: Double) -> Color {
        let level = min(max(level, 0), 1), peak = pow(level, 4)
        return scheme == .dark
            ? .oklch(0.4 + 0.14 * level + 0.24 * peak, 0.05 + 0.07 * level + 0.05 * peak, hue)
            : .oklch(0.86 + 0.03 * level + 0.07 * peak, 0.05 + 0.06 * level + 0.07 * peak, hue)
    }

    /// The symbol on the circle, a deeper tone of the same hue.
    func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .oklch(0.9, 0.07, hue) : .oklch(0.45, 0.11, hue)
    }
}

/// What the stems wait for after a stem is muted, while the song keeps playing whole.
enum StemsProgress: Equatable {
    /// Core ML prepares the model for the GPU, the first time in a while.
    case loading
    /// The first seconds are heard and separated: how far along, from 0 to 1.
    case separating(Double)
}

/// Under the key row in the wide layout and above Lock Key on the card, while the stems aren't separated: separates
/// the song and shows the stems in its place.
struct SeparateButton: View {
    let palette: Palette
    let action: () -> Void

    var body: some View {
        HUDButton(title: "Separate instruments and vocals", symbol: "slider.vertical.3", palette: palette, small: true, action: action)
    }
}

/// The stems of the song in a tray of their own: a circle for each stem that mutes it or plays it again, with a halo
/// that grows with how loud the stem plays and the number key that mutes it. Option-click plays only that stem. The
/// keys are listed in a pill on the bottom edge of the tray, since nothing else in the HUD shows them.
struct StemsRow: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    /// Smaller circles, in the left column of the wide layout and on the card.
    var compact = false
    /// The narrower card, where seven stems get smaller circles still.
    var card = false

    /// The hints pill, half of which hangs below the tray.
    static let pillHeight: CGFloat = 19

    @Environment(\.colorScheme) private var colorScheme
    @State private var pillSize = CGSize.zero
    @State private var trayWidth: CGFloat = 0

    /// The card's tray is narrower than the hints, which shrink to fit it rather than run past the edges of the card.
    private var pillScale: CGFloat {
        guard pillSize.width > 0, trayWidth > 0 else { return 1 }
        return min(1, (trayWidth - 12) / pillSize.width)
    }

    /// The keys work only while the pointer is over the HUD, so their numbers and the hints show only then, and the
    /// circles are smaller otherwise.
    private var expanded: Bool { model.keysActive }
    /// Play all is the hint of 0 in the pill on the bottom edge, which shows only with the pointer over the HUD.
    private var showsPlayAll: Bool { model.stemsAdjusted && expanded }
    /// The stems aren't separated yet: the progress takes the place of the Separate button, centred, and no circle
    /// shows until the stems play.
    private var separating: StemsProgress? { model.stemsFailed ? nil : model.stemsProgress }

    var body: some View {
        // The progress and the failure sit where the tray is going to be, at its height, so the HUD doesn't change
        // its height again when the stems arrive.
        if let progress = separating {
            tray.hidden()
                .overlay { ProgressPill(progress: progress, palette: palette) }
                .transition(.opacity)
        } else if model.stemsFailed {
            tray.hidden()
                .overlay { FailedPill(palette: palette, retry: model.onStemsRetry, dismiss: { model.stemsFailed = false }) }
                .transition(.opacity)
        } else {
            tray.transition(.opacity)
        }
    }

    private var tray: some View {
        StemHalos(model: model, meters: model.stemMeters, palette: palette, compact: compact, card: card, expanded: expanded)
            .padding(.horizontal, 12)
            // The halos reach a few points past the circles, so they keep that much room under the top edge.
            .padding(.top, 10)
            // Room for the top half of the hints pill, which sits on the bottom edge.
            .padding(.bottom, expanded ? 14 : 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trayWidth = $0 }
            .background {
                // The tray is cut around the pill, so its edge doesn't run behind the hints.
                // Only while the pointer is over the HUD, which is when the stems take keys.
                RoundedRectangle(cornerRadius: 13).fill(palette.ink.opacity(expanded ? 0.06 : 0))
                    .mask {
                        Rectangle()
                            .overlay(alignment: .bottom) {
                                if expanded {
                                    Capsule()
                                        .frame(width: pillSize.width * pillScale + 4, height: pillSize.height * pillScale + 4)
                                        .offset(y: Self.pillHeight / 2 + 2)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .compositingGroup()
                    }
            }
            .overlay(alignment: .topTrailing) {
                if expanded {
                    Button(action: model.onStemsClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Color(red: 0.93, green: 0.33, blue: 0.3)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Close the stems")
                    .offset(x: 5, y: -5)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if expanded {
                    // Nearly clear, with a hairline, so it reads as a quiet note on the edge of the tray rather than a control.
                    KeyHints(style: .stems, vocals: !model.lyricsShown, volumeChanged: !model.stemVolumes.isEmpty,
                             playAll: showsPlayAll ? { model.onStemsReset() } : nil, otherMode: "", palette: palette)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.ink.opacity(0.025)))
                        .overlay(Capsule().strokeBorder(palette.ink.opacity(0.09), lineWidth: 0.5))
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { pillSize = $0 }
                        .scaleEffect(pillScale)
                        .offset(y: Self.pillHeight / 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.keysActive)
            .animation(.easeOut(duration: 0.15), value: showsPlayAll)
            .animation(.snappy(duration: 0.2), value: model.stemsMuted)
            .animation(.snappy(duration: 0.2), value: model.stemsFailed)
    }
}

/// The separation failed: a red pill that separates the song again, in place of the Separate button and with its
/// symbol, and Cancel after it, which goes back to the Separate button.
private struct FailedPill: View {
    let palette: Palette
    let retry: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: retry) {
                Label("Retry instrument separation", systemImage: "slider.vertical.3")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(StripColors.text(.red, colorScheme))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(StripColors.tint(.red, strong: false, colorScheme)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Separate the instruments and vocals again")
            Button("Cancel", action: dismiss)
                .buttonStyle(PillButtonStyle(palette: palette))
                .focusable(false)
                .help("Show the Separate button again")
        }
    }
}

/// What the stems wait for, with a ring that fills as the first seconds are separated.
private struct ProgressPill: View {
    let progress: StemsProgress
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            switch progress {
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Loading model")
            case let .separating(fraction):
                ZStack {
                    Circle().stroke(palette.ink.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: fraction)
                }
                .frame(width: 10, height: 10)
                Text("Separating")
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(palette.ink.opacity(0.07)))
    }
}

/// The halos are a view of their own, so the levels redraw 20 times a second without the rest of the HUD.
private struct StemHalos: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var meters: StemMeters
    let palette: Palette
    let compact: Bool
    let card: Bool
    let expanded: Bool

    var body: some View {
        let shown = Stem.shown
        // Seven stems on the narrower card get smaller circles, so the rings of neighbours don't touch.
        let crowded = card && shown.count > 6
        // Spread over the tray while the pointer is over the HUD, and drawn together in the middle otherwise.
        HStack(spacing: expanded ? (crowded ? 2 : 6) : 12) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, stem in
                ScrollLifted(region: .stem(stem), scroll: model.scroll, scale: 1.1, depth: 3.5) { inner, adjusting in
                    StemHalo(stem: stem, key: index + 1, on: !model.stemsMuted.contains(stem),
                             level: model.stemsEngaged ? stemFill(meters.levels[stem.rawValue]) : 0,
                             volume: model.stemVolumes[stem] ?? 1, adjusting: adjusting, lift: inner,
                             palette: palette, compact: compact, crowded: crowded, expanded: expanded, solo: model.flipped) { solo in model.onStem(stem, solo) }
                }
                .frame(maxWidth: expanded ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Karaoke's Vocals pill under the key, which shows whether the vocals play and mutes or plays them with a click, as V
/// does. Karaoke often mutes the vocals by itself, so the pill shows fully for 3 seconds when karaoke opens and after
/// each change, then dims to stay out of the way of the lyrics, until the pointer is over the HUD.
struct KaraokeVocalsPill: View {
    let muted: Bool
    let hudHovered: Bool
    let palette: Palette
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var fresh = true
    @State private var hovering = false
    @State private var dim: Task<Void, Never>?

    var body: some View {
        let shown = fresh || hudHovered
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "music.mic").font(.system(size: 11, weight: .bold))
                Text(muted ? "Vocals muted" : "Vocals").font(.system(size: 12, weight: .semibold, design: .rounded))
                Keycap(text: "V", palette: palette, small: true)
            }
            .foregroundStyle(muted ? palette.muted.opacity(hovering ? 0.95 : 0.75) : Stem.vocals.ink(scheme))
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background { background }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(muted ? "Play the vocals (V)" : "Mute the vocals (V)")
        // Dims slowly, out of the corner of the eye, and comes back at once under the pointer.
        .opacity(shown ? 1 : 0.2)
        .animation(shown ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.8), value: shown)
        .onAppear(perform: showFully)
        .onChange(of: muted) { showFully() }
        .onDisappear { dim?.cancel() }
    }

    @ViewBuilder private var background: some View {
        if muted {
            // The muted look of the instruments: stripes, a faint red tint and a faint red ring.
            let red = { (opacity: Double) in Color.oklch(scheme == .dark ? 0.68 : 0.6, 0.2, 25, opacity: opacity) }
            ZStack {
                Capsule().fill(palette.ink.opacity(hovering ? 0.1 : 0.07))
                MutedStripes().stroke(palette.muted.opacity(0.22), lineWidth: 1.5).clipShape(Capsule())
                Capsule().fill(red(0.05))
                Capsule().strokeBorder(red(0.2), lineWidth: 2)
            }
        } else {
            Capsule().fill(Stem.vocals.fill(scheme, level: hovering ? 0.35 : 0.15))
        }
    }

    private func showFully() {
        fresh = true
        dim?.cancel()
        dim = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            fresh = false
        }
    }
}

/// Diagonal lines 6 points apart over the whole rect, for the circle of a muted stem.
private struct MutedStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        repeat {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        } while x < rect.maxX
        return path
    }
}

/// How far a level reaches: −48 dB at nothing, −6 dB at the most.
func stemFill(_ level: Float) -> CGFloat {
    guard level > 0 else { return 0 }
    return CGFloat(min(1, max(0, (20 * log10(Double(level)) + 48) / 42)))
}

private struct StemHalo: View {
    let stem: Stem
    let key: Int
    let on: Bool
    /// How loud the stem plays, from 0 to 1, while the stems are separated.
    let level: CGFloat
    /// The volume that a scroll over the stem set, from 0 to 1.5, shown in place of its name while it isn't 1.
    var volume = 1.0
    /// A scroll over the stem changes its volume now.
    var adjusting = false
    /// The extra lift of the symbol while the scroll lasts.
    var lift: CGFloat = 0
    let palette: Palette
    let compact: Bool
    var crowded = false
    /// The pointer is over the HUD: full size, with the number key on the edge of the circle.
    var expanded = true
    /// Option is held, so a click plays only this stem: every circle shows headphones.
    var solo = false
    let action: (Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    /// A scroll changed the volume since the pointer came over the stem: its tooltip would cover the volume.
    @State private var scrolled = false

    private var side: CGFloat { (crowded ? 28 : compact ? 32 : 40) * (expanded ? 1 : 0.8) }

    /// A volume other than 100% shows as a ring around the circle, and the halo of the level moves out past it.
    private var ringShown: Bool { volume != 1 || adjusting }
    /// Seven stems on the card leave no room for the halo past the ring, so the ring sits inside the halo's reach.
    private var ringInset: CGFloat { crowded ? -2.5 : -4.5 }

    var body: some View {
        Button { action(NSEvent.modifierFlags.contains(.option)) } label: {
            VStack(spacing: compact ? 5 : 6) {
                ZStack {
                    Circle()
                        .stroke(stem.color(scheme, opacity: on ? 0.25 + 0.5 * level : 0), lineWidth: 2)
                        .padding((crowded ? -2 - 3 * level : -3 - 5 * level) + (ringShown && !crowded ? ringInset - 1 : 0))
                    if ringShown {
                        VolumeRing(volume: volume, color: on ? stem.color(scheme, opacity: 0.95) : Color.oklch(scheme == .dark ? 0.68 : 0.6, 0.2, 25, opacity: 0.45),
                                   track: palette.ink.opacity(0.12), tick: palette.ink.opacity(0.4), width: crowded ? 2 : 2.5)
                            .padding(ringInset)
                            .transition(.opacity)
                    }
                    // In the stem's colour even while it is quiet, more saturated and brighter as it gets louder, so the
                    // circles move with the song as well as their rings. A muted stem is grey with stripes, a faint red
                    // tint and a faint red ring, which tell it apart from a quiet one at a glance.
                    Circle()
                        .fill(palette.ink.opacity(hovering ? 0.1 : 0.07))
                        .overlay {
                            if on {
                                Circle().fill(stem.fill(scheme, level: 1.1 * level + (hovering ? 0.15 : 0)))
                            } else if !solo {
                                let red = { (opacity: Double) in Color.oklch(scheme == .dark ? 0.68 : 0.6, 0.2, 25, opacity: opacity) }
                                MutedStripes().stroke(palette.muted.opacity(0.22), lineWidth: 1.5).clipShape(Circle())
                                Circle().fill(red(0.05))
                                Circle().strokeBorder(red(0.2), lineWidth: 2)
                            }
                        }
                    Image(systemName: solo ? "headphones" : stem.symbol)
                        .font(.system(size: (crowded ? 11 : compact ? 12 : 15) * (expanded ? 1 : 0.85), weight: .semibold))
                        .offset(y: lift)
                        .foregroundStyle(on ? stem.ink(scheme) : solo ? palette.ink : palette.muted.opacity(0.45))
                        // Option is a key held for a moment, so the swap runs at three times the usual speed.
                        .contentTransition(.symbolEffect(.replace, options: .speed(3)))
                }
                .frame(width: side, height: side)
                .overlay(alignment: .bottomTrailing) {
                    if expanded {
                        StemKeyBadge(key: key, palette: palette)
                            .offset(x: crowded ? 5 : 4, y: 3)
                            .transition(.opacity)
                    }
                }
                Text(adjusting || volume != 1 ? "\(Int((volume * 100).rounded()))%" : stem.name)
                    .contentTransition(.numericText(value: volume))
                    .monospacedDigit()
                    .font(.system(size: crowded ? 10 : compact ? 10.5 : 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(on ? palette.ink : palette.muted.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, compact ? 4 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: ringShown)
        .onHover { inside in
            hovering = inside
            if !inside { scrolled = false }
        }
        .onChange(of: adjusting) { if adjusting { scrolled = true } }
        .help(adjusting || scrolled ? "" : "\(on ? "Mute" : "Play") the \(stem.name.lowercased()) (\(key)) · Play only the \(stem.name.lowercased()) (hold \(key) or ⌥-click)"
            + (volume != 1 || !on ? " · Play at 100% (double-click or press \(key) twice)" : ""))
    }
}

/// The volume of a stem as the web remote draws it: an arc that sweeps 270° from 0 to 150%, open at the bottom, over
/// a faint track, with a tick at 100%.
private struct VolumeRing: View {
    let volume: Double
    let color: Color
    let track: Color
    let tick: Color
    let width: CGFloat

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(track, style: StrokeStyle(lineWidth: width, lineCap: .round))
            Circle().trim(from: 0, to: 0.75 * min(1.5, max(0, volume)) / 1.5)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            HundredTick(length: width + 3).stroke(tick, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        // The arc starts at the bottom left and goes clockwise, so 100% sits at the top right.
        .rotationEffect(.degrees(135))
        .animation(.easeOut(duration: 0.12), value: volume)
    }

    /// A short line across the ring at 100%, two thirds of the way around, drawn before the rotation of the ring.
    private struct HundredTick: Shape {
        let length: CGFloat

        func path(in rect: CGRect) -> Path {
            let radius = min(rect.width, rect.height) / 2
            let angle = 0.75 * 2 * Double.pi / 1.5
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            var path = Path()
            path.move(to: CGPoint(x: rect.midX + direction.x * (radius - length / 2), y: rect.midY + direction.y * (radius - length / 2)))
            path.addLine(to: CGPoint(x: rect.midX + direction.x * (radius + length / 2), y: rect.midY + direction.y * (radius + length / 2)))
            return path
        }
    }
}

/// The number key of a stem, on the edge of its circle: a translucent disc in the colour of the glass, which keeps
/// the number readable over the coloured circle without outshining it.
private struct StemKeyBadge: View {
    let key: Int
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("\(key)")
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(palette.ink.opacity(0.75))
            .frame(width: 13, height: 13)
            .background(Circle().fill((scheme == .dark ? Color(red: 0.13, green: 0.12, blue: 0.12) : Color.white).opacity(0.7)))
            .overlay(Circle().strokeBorder(palette.ink.opacity(0.14), lineWidth: 0.5))
    }
}

/// A small capsule button in the header of the stems, for Play all: the capsule darkens and the text turns to ink
/// under the pointer, and dims while pressed.
private struct PillButtonStyle: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, palette: palette)
    }

    private struct PillButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let palette: Palette
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(hovering ? palette.ink : palette.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Capsule().fill(palette.ink.opacity(configuration.isPressed ? 0.2 : hovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}
