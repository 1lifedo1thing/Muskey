import SwiftUI

extension Stem {
    /// A hue for each stem, apart enough to tell them apart and soft enough for the warm glass.
    var hue: Double {
        switch self {
        case .vocals: 8
        case .drums: 75
        case .bass: 295
        case .guitar: 42
        case .piano: 210
        case .other: 150
        case .winds: 110
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

    func color(_ scheme: ColorScheme, opacity: Double = 1) -> Color {
        .oklch(scheme == .dark ? 0.78 : 0.62, 0.12, hue, opacity: opacity)
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
    /// The header holds Play all, which shows only with the pointer over the HUD.
    private var header: Bool { showsPlayAll }
    private var showsPlayAll: Bool { model.stemsAdjusted && expanded }
    /// The stems aren't separated yet: the progress takes the place of the Separate button, centred, and no circle
    /// shows until the stems play.
    private var separating: StemsProgress? { model.stemsFailed ? nil : model.stemsProgress }

    var body: some View {
        if let progress = separating {
            ProgressPill(progress: progress, palette: palette)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else if model.stemsFailed {
            FailedPill(palette: palette, retry: model.onStemsRetry, dismiss: { model.stemsFailed = false })
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else {
            tray.transition(.opacity)
        }
    }

    private var tray: some View {
        // Play all keeps clear of the rings around the circles, which reach up to 8 points past them at the loudest.
        VStack(alignment: .leading, spacing: (compact ? 4 : 6) + (header ? 7 : 0)) {
            if header { headerRow }
            StemHalos(model: model, meters: model.stemMeters, palette: palette, compact: compact, card: card, expanded: expanded)
        }
        .padding(.horizontal, 12)
        // The halos reach a few points past the circles, so they keep that much room under the top edge.
        .padding(.top, header ? 8 : 10)
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
                KeyHints(style: .stems, vocals: !model.lyricsShown, otherMode: "", palette: palette)
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
        .animation(.snappy(duration: 0.2), value: header)
        .animation(.easeOut(duration: 0.15), value: showsPlayAll)
        .animation(.snappy(duration: 0.2), value: model.stemsMuted)
        .animation(.snappy(duration: 0.2), value: model.stemsFailed)
    }

    private var headerRow: some View {
        Button("Play all") { model.onStemsReset() }
            .buttonStyle(PillButtonStyle(palette: palette))
            .focusable(false)
            .help("Play all instruments and vocals (0)")
            .transition(.opacity)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
    }
}

/// The separation failed: a red Retry pill takes the place of the Separate button, with the button's symbol, and an ✕
/// in its corner that dismisses it.
private struct FailedPill: View {
    let palette: Palette
    let retry: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: retry) {
            Label("Retry", systemImage: "slider.vertical.3")
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
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(Color(red: 0.93, green: 0.33, blue: 0.3)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Dismiss")
            .offset(x: 5, y: -5)
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

    var body: some View {
        Button { action(NSEvent.modifierFlags.contains(.option)) } label: {
            VStack(spacing: compact ? 5 : 6) {
                ZStack {
                    Circle()
                        .stroke(stem.color(scheme, opacity: on ? 0.25 + 0.5 * level : 0), lineWidth: 2)
                        .padding(crowded ? -2 - 3 * level : -3 - 5 * level)
                    Circle()
                        .fill(on ? stem.color(scheme, opacity: hovering ? 0.6 : 0.45) : palette.ink.opacity(hovering ? 0.08 : 0.05))
                        .overlay(Circle().strokeBorder(stem.color(scheme, opacity: on ? 0.75 : 0), lineWidth: 1))
                    Image(systemName: solo ? "headphones" : stem.symbol)
                        .font(.system(size: (crowded ? 11 : compact ? 12 : 15) * (expanded ? 1 : 0.85), weight: .semibold))
                        .offset(y: lift)
                        .foregroundStyle(on || solo ? palette.ink : palette.muted.opacity(0.4))
                        // Option is a key held for a moment, so the swap runs at three times the usual speed.
                        .contentTransition(.symbolEffect(.replace, options: .speed(3)))
                    if !on, !solo {
                        Capsule().fill(palette.muted.opacity(0.45)).frame(width: 2, height: side - 2).rotationEffect(.degrees(-45))
                    }
                }
                .frame(width: side, height: side)
                .overlay(alignment: .bottomTrailing) {
                    if expanded {
                        StemKeyBadge(key: key, palette: palette)
                            .offset(x: crowded ? 5 : 4, y: 3)
                            .transition(.opacity)
                    }
                }
                .shadow(color: on ? stem.color(scheme, opacity: 0.6 * level) : .clear, radius: 8)
                Text(adjusting || volume != 1 ? "\(Int((volume * 100).rounded()))%" : stem.name)
                    .contentTransition(.numericText(value: volume))
                    .monospacedDigit()
                    .font(.system(size: crowded ? 10 : compact ? 10.5 : 12, weight: .semibold, design: .rounded))
                    .strikethrough(!on, color: palette.muted.opacity(0.5))
                    .foregroundStyle(on ? palette.ink : palette.muted.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, compact ? 4 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if !inside { scrolled = false }
        }
        .onChange(of: adjusting) { if adjusting { scrolled = true } }
        .help(adjusting || scrolled ? "" : on ? "Mute the \(stem.name.lowercased()) (\(key)) · Play only the \(stem.name.lowercased()) (⌥-click)"
            : "Play the \(stem.name.lowercased()) (\(key)) · Play only the \(stem.name.lowercased()) (⌥-click)")
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
