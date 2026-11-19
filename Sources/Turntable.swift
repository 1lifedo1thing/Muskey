import AppKit
import SwiftUI

extension Color {
    /// A colour in OKLCH, which keeps the same lightness across hues, so one lightness works for every tint.
    /// It is drawn in Display P3, so a vivid red isn't clipped to the sRGB gamut.
    static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double, opacity: Double = 1) -> Color {
        let a = chroma * cos(hue * .pi / 180), b = chroma * sin(hue * .pi / 180)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        // Linear sRGB, then linear Display P3.
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func encode(_ value: Double) -> Double {
            let v = min(1, max(0, value))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(
            .displayP3,
            red: encode(0.8224621 * r + 0.1775380 * g),
            green: encode(0.0331941 * r + 0.9668058 * g),
            blue: encode(0.0170827 * r + 0.0723974 * g + 0.9105199 * bl),
            opacity: opacity
        )
    }
}

/// The colours of the key strip: the selected key, the keys a fourth or a fifth away, the keys a whole step away,
/// and the ‹ › buttons with the shift under the key, muted blue going down and honey going up.
struct StripColors {
    enum Hue {
        case red, honey, sage, blue

        var hue: Double {
            switch self {
            case .red: 26
            case .honey: 74
            case .sage: 150
            case .blue: 245
            }
        }

        var chroma: Double {
            switch self {
            case .red: 0.21
            case .honey: 0.13
            case .sage: 0.065
            case .blue: 0.055
            }
        }
    }

    var selected: Hue
    var strong: Hue
    var light: Hue

    static let current = StripColors(selected: .honey, strong: .red, light: .sage)

    static let down = Hue.blue
    static let up = Hue.honey

    /// The selected key: a solid chip, with white text on the darker ones in light mode and dark text otherwise.
    static func solid(_ hue: Hue, _ scheme: ColorScheme) -> (fill: Color, text: Color) {
        let dark = scheme == .dark
        switch hue {
        case .honey: return (.oklch(0.84, hue.chroma, hue.hue), Color(red: 0.18, green: 0.11, blue: 0.03))
        case .red: return dark ? (.oklch(0.72, hue.chroma, hue.hue), Color(red: 0.16, green: 0.05, blue: 0.06)) : (.oklch(0.58, hue.chroma, hue.hue), .white)
        case .sage: return dark ? (.oklch(0.78, hue.chroma, hue.hue), Color(red: 0.07, green: 0.13, blue: 0.06)) : (.oklch(0.56, hue.chroma, hue.hue), .white)
        case .blue: return dark ? (.oklch(0.78, hue.chroma, hue.hue), Color(red: 0.06, green: 0.09, blue: 0.15)) : (.oklch(0.56, hue.chroma, hue.hue), .white)
        }
    }

    /// A tint behind a harmonic key, a step button or the shift: `strong` for a fourth or a fifth.
    static func tint(_ hue: Hue, strong: Bool, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        let opacity = strong ? (dark ? 0.34 : 0.36) : (dark ? 0.18 : 0.17)
        return .oklch(dark ? 0.66 : 0.74, hue.chroma, hue.hue, opacity: opacity)
    }

    static func text(_ hue: Hue, _ scheme: ColorScheme) -> Color {
        .oklch(scheme == .dark ? 0.85 : 0.45, hue.chroma, hue.hue)
    }
}

/// The song that plays, on a record that spins on a platter, with the title, artist, album and time under it.
/// The tonearm moves in toward the label as the song plays.
struct TurntableDeck: View {
    let track: NowPlaying.Track
    let artwork: NSImage?
    /// The song plays, as far as the HUD knows: Space shows the change before the player reports it. A paused song
    /// has the tonearm lifted off the record, on its rest.
    let playing: Bool
    /// The record spins only while the HUD is up and the song plays: a timeline keeps redrawing in an
    /// ordered-out window otherwise.
    let spinning: Bool
    var flash: PlayFlash?
    let palette: Palette
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.songArriving) private var arriving
    /// The arm swings off the record while one record leaves the platter and the next one comes on.
    @State private var swapping = false

    static let size: CGFloat = 184
    /// How long a song change takes on the deck.
    static let swap = 0.7

    /// The song that the record and the details belong to; another song swaps both.
    private var song: String { track.song.map { $0 ?? "" }.joined(separator: "\u{1F}") }

    var body: some View {
        VStack(spacing: 11) {
            TimelineView(.animation(minimumInterval: 1, paused: !spinning)) { context in
                let progress = track.duration.flatMap { duration in track.position(at: context.date).map { duration > 0 ? $0 / duration : 0 } } ?? 0
                ZStack {
                    Platter()
                    ZStack {
                        if renderingPreview {
                            Record(artwork: artwork)
                        } else {
                            SpinningRecord(artwork: artwork, spinning: spinning && arriving == nil, side: Self.size * 0.9)
                                // The shadow stays still under the turning record.
                                .background(Circle().fill(Color(white: 0.09)).shadow(color: .black.opacity(0.35), radius: 7, y: 4))
                        }
                        Sheen()
                    }
                    .opacity(arriving == nil ? 1 : 0.55)
                    .overlay { if let arriving { ArrivalRing(arriving: arriving, diameter: Self.size * 0.9 * 0.66 + 8) } }
                    .padding(Self.size * 0.05)
                    .id(song)
                    // The old record slides off to the left as the new one comes on from the right.
                    .transition(.asymmetric(
                        insertion: .modifier(active: Slide(x: Self.size * 0.6), identity: Slide(x: 0)),
                        removal: .modifier(active: Slide(x: -Self.size * 0.6), identity: Slide(x: 0))
                    ))
                    // The innermost animation whose value changed wins: a swap, then a play or a pause, then the
                    // slow move along the grooves.
                    Tonearm(angle: swapping || !playing || arriving != nil ? Tonearm.rest : 10 * min(1, max(0, progress)))
                        .animation(.linear(duration: 1), value: progress)
                        .animation(.smooth(duration: 0.45), value: playing)
                        .animation(.smooth(duration: 0.45), value: arriving == nil)
                        .animation(.smooth(duration: Self.swap / 2), value: swapping)
                    PlayFlashView(flash: flash, size: 58)
                }
                .frame(width: Self.size, height: Self.size)
                // On the rims, where the tonearm never passes.
                .modifier(RecordControls(diameter: Self.size * 0.9, label: 0.66))
            }
            ZStack {
                Details(track: track, ticking: spinning, palette: palette)
                    .id(song)
                    .transition(.push(from: .trailing))
            }
            .clipped()
        }
        // One width whatever the title, so the HUD measures the same width that it lays out, and long titles
        // get cut with an ellipsis.
        .frame(width: Self.size + 16)
        .animation(.smooth(duration: Self.swap), value: song)
        .onChange(of: song) {
            swapping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.swap) { swapping = false }
        }
    }
}

/// What a click on the record and the buttons at its sides do: play or pause the song, and skip to the previous or
/// the next one.
struct RecordActions {
    var playPause: () -> Void = {}
    var skip: (Int) -> Void = { _ in }
    /// Where the time bar tells a scroll and the HUD's drag where it is.
    var scroll: ScrollFeel?
    /// Where a scroll over the time bar moves the song, from 0 to 1.
    var scrub: Double?
    /// Moves the song to a fraction of its length, from the time bar.
    var seek: (Double) -> Void = { _ in }
    /// The song moves at once in its player, so the time bar takes clicks and drags.
    var seekable = false
}

/// Previous, play or pause, and next in karaoke, apart from the record, whose cover shows the instruments and vocals
/// under the pointer.
struct KaraokeTransport: View {
    var size: CGFloat = 34
    let ink: Color
    @Environment(\.recordActions) private var actions
    @Environment(\.recordPlaying) private var playing

    var body: some View {
        HStack(spacing: 0) {
            RimGlyph(symbol: "backward.end.fill", size: size, help: "Play the previous song", label: "Previous song", ink: ink) { actions.skip(-1) }
            RimGlyph(symbol: playing ? "pause.fill" : "play.fill", size: size, help: playing ? "Pause" : "Play", label: playing ? "Pause" : "Play",
                     ink: ink, action: actions.playPause)
            RimGlyph(symbol: "forward.end.fill", size: size, help: "Play the next song", label: "Next song", ink: ink) { actions.skip(1) }
        }
    }
}

extension EnvironmentValues {
    @Entry var recordActions = RecordActions()
    /// The song plays, so the button in the middle of the record pauses it.
    @Entry var recordPlaying = false
    /// `--render` shows the buttons on the record, as the pointer over the record does.
    @Entry var recordHovered = false
    /// The buttons show on the record, so the glyph that a play, a pause or a skip flashes on it doesn't.
    @Entry var recordButtonsShown = false
    /// The pointer is over the cover, which shows this glyph.
    @Entry var recordGlyph: RecordGlyph?
    /// `--render` shows the pill of the key change at its full width, as the pointer over it does.
    @Entry var keyPillExpanded = false
}

/// A click on the record plays or pauses the song, as Space does. The pointer over the record shrinks its cover a
/// little, which widens the rim around it, and shows previous and next as bare glyphs on the rim, on the same line
/// as the play glyph. On the deck they are drawn over the tonearm. The cover itself is the play and pause button: it
/// is dimmed and blurred a little under a white glyph, and more while the pointer is over it. Nothing gets a cap or a
/// plate, so the cover art stays the thing to look at. `diameter` is the record's width, `label` the cover's width against it, and `lift` how
/// far above the centre the glyphs sit, for karaoke's record, which shows its top half only.
struct RecordControls: ViewModifier {
    let diameter: CGFloat
    let label: CGFloat
    var lift: CGFloat = 0
    @Environment(\.recordActions) private var actions
    @Environment(\.recordPlaying) private var playing
    @Environment(\.recordHovered) private var previewHover
    @State private var hovering = false
    @State private var coverHovered = false
    @State private var leave: Task<Void, Never>?

    /// The cover's width while the pointer is over the record.
    static let shrink: CGFloat = 0.8

    private var cover: CGFloat { diameter * label * Self.shrink }
    /// The middle of the rim, between the shrunk cover and the edge of the record.
    private var spread: CGFloat { diameter * (label * Self.shrink + 1) / 4 }
    private var rim: CGFloat { min(34, diameter * (1 - label * Self.shrink) / 2 * 0.86) }

    private var glyph: RecordGlyph? {
        guard hovering || previewHover else { return nil }
        return RecordGlyph(symbol: playing ? "pause.fill" : "play.fill", size: min(lift > 0 ? 40 : 54, cover * 0.36), lift: lift, hot: hovering && coverHovered)
    }

    func body(content: Content) -> some View {
        let shown = hovering || previewHover
        content
            // The record shrinks its cover, and the glyph that Space flashes on it stays hidden behind the buttons.
            .environment(\.recordButtonsShown, shown)
            .environment(\.recordGlyph, glyph)
            .preference(key: RecordButtonsShown.self, value: shown)
            .contentShape(Circle())
            .onTapGesture { actions.playPause() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Record")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.playPause() }
            .onHover(perform: hover)
            .overlay {
                if shown {
                    ZStack {
                        CoverButton(size: cover, glyph: glyph, playing: playing, action: actions.playPause) { coverHovered = $0 }
                        RimGlyph(symbol: "backward.end.fill", size: rim, help: "Play the previous song", label: "Previous song") { actions.skip(-1) }
                            .offset(x: -spread, y: -lift)
                        RimGlyph(symbol: "forward.end.fill", size: rim, help: "Play the next song", label: "Next song") { actions.skip(1) }
                            .offset(x: spread, y: -lift)
                    }
                    .onHover(perform: hover)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: shown)
    }

    private func hover(_ inside: Bool) {
        leave?.cancel()
        if inside { return hovering = true }
        // Moving from the record onto a glyph leaves the record a moment before the pointer enters the glyph.
        leave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { hovering = false }
        }
    }
}

/// The buttons show on a record, for a flash of a glyph that is drawn outside it, as on karaoke's record.
struct RecordButtonsShown: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The play or pause glyph in the middle of the cover: white with a soft shadow, over the cover dimmed and blurred a
/// little, and more while the pointer is over the cover. The spinning record draws it in its own layer tree, with the
/// blurred cover turning under it.
struct RecordGlyph: Equatable {
    let symbol: String
    let size: CGFloat
    /// Points above the middle of the cover, on karaoke's record.
    let lift: CGFloat
    /// The pointer is over the cover, which is the button.
    var hot = false

    /// The black over the cover, while the record shows its buttons and while the pointer is over the cover.
    static let dim = 0.3
    static let hotDim = 0.5
    /// The blur of the cover in points, likewise.
    static let blur: CGFloat = 0.6
    static let hotBlur: CGFloat = 3

    var dim: Double { hot ? Self.hotDim : Self.dim }
    var blur: CGFloat { hot ? Self.hotBlur : Self.blur }

    /// The triangle's weight sits left of its box, so it moves right to look centred.
    var nudge: CGFloat { symbol == "play.fill" ? size * 0.07 : 0 }

    var image: some View {
        Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
    }

    /// The shadow under the glyph, which keeps it apart from a light cover.
    static let shadowOpacity = 0.6
    var shadowRadius: CGFloat { size * 0.14 }
}

/// The shrunk cover as the play and pause button: a thin ring while the pointer is over it, and nothing otherwise.
/// The record draws the dim, the blur and the glyph, since the blur has to turn with the cover.
private struct CoverButton: View {
    let size: CGFloat
    let glyph: RecordGlyph?
    let playing: Bool
    let action: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.renderingPreview) private var renderingPreview

    var body: some View {
        // No ring of its own: the glyph and the blur of the cover show that it is a button.
        Button(action: action) {
            Color.clear
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover(perform: hover)
        .help(playing ? "Pause" : "Play")
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

/// Previous or next on the rim of the record: a bare glyph, and a translucent circle of the accent red under it while
/// the pointer is over it.
struct RimGlyph: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let label: String
    /// The glass's ink, for the glyphs that sit on the glass instead of on the vinyl.
    var ink: Color?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle((ink ?? .white).opacity(hovered ? 1 : 0.85))
                .shadow(color: .black.opacity(ink == nil ? 0.4 : 0), radius: 2)
                .frame(width: size, height: size)
                .background(Circle().fill(StripColors.tint(.red, strong: true, colorScheme).opacity(hovered ? 0.75 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The record alone, in the middle of the single card: the same vinyl and label as on the deck, with no platter or
/// tonearm, since the ring around it shows the listen and the keys. Another song fades the new record in.
struct RecordDisc: View {
    let track: NowPlaying.Track
    let artwork: NSImage?
    let spinning: Bool
    let side: CGFloat
    var flash: PlayFlash?
    /// Off while a song is saved: the record only shows the save, and the song can't be played, paused or skipped.
    var controls = true
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.songArriving) private var arriving

    private var song: String { track.song.map { $0 ?? "" }.joined(separator: "\u{1F}") }

    var body: some View {
        Group {
            if controls {
                // Inside the record, since the ring of keys sits around it.
                disc.modifier(RecordControls(diameter: side, label: 0.66))
            } else {
                disc
            }
        }
        .animation(.smooth(duration: TurntableDeck.swap), value: song)
    }

    private var disc: some View {
        ZStack {
            ZStack {
                if renderingPreview {
                    Record(artwork: artwork)
                } else {
                    SpinningRecord(artwork: artwork, spinning: spinning && arriving == nil, side: side)
                        .background(Circle().fill(Color(white: 0.09)).shadow(color: .black.opacity(0.35), radius: 7, y: 4))
                }
                Sheen()
            }
            .opacity(arriving == nil ? 1 : 0.55)
            .overlay { if let arriving { ArrivalRing(arriving: arriving, diameter: side * 0.66 + 8) } }
            .id(song)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            PlayFlashView(flash: flash, size: 58)
        }
        .frame(width: side, height: side)
    }
}

/// An empty platter in the middle of the single card, while no player reports a song.
struct EmptyPlatter: View {
    let side: CGFloat

    var body: some View {
        Platter().frame(width: side, height: side)
    }
}

/// A record on its way on or off the platter: moved sideways, a little smaller, and faded.
private struct Slide: ViewModifier {
    let x: CGFloat

    func body(content: Content) -> some View {
        let away = min(1, abs(x) / (TurntableDeck.size * 0.6))
        content
            .offset(x: x)
            .scaleEffect(1 - 0.08 * away)
            .opacity(1 - away)
    }
}

private struct Platter: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: Color(white: 0.16), location: 0.6),
                .init(color: Color(white: 0.22), location: 0.61),
                .init(color: Color(white: 0.22), location: 0.64),
                .init(color: Color(white: 0.16), location: 0.65),
            ], center: .center, startRadius: 0, endRadius: TurntableDeck.size / 2))
            .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
    }
}

/// The vinyl with its grooves, and the cover on the label, or a plain cream label when the player sends no cover.
private struct Record: View {
    enum Part { case whole, vinyl, cover }

    let artwork: NSImage?
    /// Off when the record is drawn into the spinning layer, whose image would cut the shadow off and turn it.
    var shadow = true
    /// The width of the label against the record's. Karaoke's label is smaller, which leaves the grooves above it
    /// for the song's details.
    var label: CGFloat = 0.66
    /// The spinning record draws the vinyl and the cover apart, so the cover can shrink while it turns with it.
    var part = Part.whole
    @Environment(\.recordButtonsShown) private var buttonsShown
    @Environment(\.recordGlyph) private var glyph

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            if part == .cover {
                cover(side)
            } else {
                ZStack {
                    Circle().fill(Color(white: 0.09))
                    // The grooves run under the cover too, for the rim that shows when it shrinks.
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let first = size.width * (label * RecordControls.shrink / 2 + 0.03)
                        for radius in stride(from: first, to: size.width / 2 - 1.5, by: 1.6) {
                            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                            context.stroke(ring, with: .color(.white.opacity(0.045)), lineWidth: 0.6)
                        }
                    }
                    if part == .whole {
                        cover(side * label, blur: glyph?.blur ?? 0)
                            .scaleEffect(buttonsShown ? RecordControls.shrink : 1)
                            .animation(.easeOut(duration: 0.18), value: buttonsShown)
                        if let glyph {
                            Circle().fill(.black.opacity(glyph.dim))
                                .frame(width: side * label * RecordControls.shrink, height: side * label * RecordControls.shrink)
                            glyph.image
                                .shadow(color: .black.opacity(RecordGlyph.shadowOpacity), radius: glyph.shadowRadius)
                                .offset(x: glyph.nudge, y: -glyph.lift)
                        }
                    }
                }
                .frame(width: side, height: side)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 7, y: 4)
    }

    /// The cover on the label, or a plain cream label, with the spindle in its middle.
    private func cover(_ width: CGFloat, blur: CGFloat = 0) -> some View {
        ZStack {
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(red: 0.93, green: 0.88, blue: 0.80)
                }
            }
            .frame(width: width, height: width)
            .blur(radius: blur, opaque: true)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
            Circle()
                .fill(Color(red: 0.93, green: 0.90, blue: 0.89))
                .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
                .frame(width: 8, height: 8)
        }
        .frame(width: width, height: width)
    }
}

/// The record drawn once into a layer that Core Animation turns, so the window server spins it without Muskey
/// drawing every frame.
private struct SpinningRecord: NSViewRepresentable {
    let artwork: NSImage?
    let spinning: Bool
    let side: CGFloat
    var label: CGFloat = 0.66
    /// Seconds for one turn: 33⅓ turns a minute on the deck, and a calmer turn in karaoke.
    var period = 1.8

    final class Coordinator {
        var artwork: NSImage?
        var drawn = false
        /// The backspins seen so far. A record that appears doesn't turn back for the ones before it.
        var rewinds: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context _: Context) -> SpinView { SpinView(period: period, label: label) }

    func updateNSView(_ view: SpinView, context: Context) {
        if !context.coordinator.drawn || context.coordinator.artwork !== artwork {
            context.coordinator.artwork = artwork
            context.coordinator.drawn = true
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let vinyl = ImageRenderer(content: Record(artwork: artwork, shadow: false, label: label, part: .vinyl).frame(width: side, height: side))
            vinyl.scale = scale
            view.record.contents = vinyl.cgImage
            let cover = ImageRenderer(content: Record(artwork: artwork, shadow: false, label: label, part: .cover).frame(width: side * label, height: side * label))
            cover.scale = scale
            view.cover.contents = cover.cgImage
            // The art alone, square and without the label's edge, for the blur: a blur of the round label would let
            // the transparent corners bleed in at its edge.
            let art = ImageRenderer(content: Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(red: 0.93, green: 0.88, blue: 0.80)
                }
            }.frame(width: side * label, height: side * label).clipped())
            art.scale = scale
            view.coverChanged(art: art.cgImage)
        }
        view.shrunk = context.environment.recordButtonsShown
        view.show(context.environment.recordGlyph)
        let rewinds = context.environment.recordRewinds
        if let seen = context.coordinator.rewinds, rewinds > seen { view.rewind() }
        context.coordinator.rewinds = rewinds
        view.spinning = spinning
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: SpinView, context _: Context) -> CGSize? { CGSize(width: side, height: side) }

    final class SpinView: NSView {
        let record = CALayer()
        /// The cover, in a layer of its own that turns with the record. It is outside the record, in `coverScale`,
        /// since the paused record stops the clock of every layer inside it, and the cover has to shrink while the
        /// song is paused too.
        let cover = CALayer()
        private let coverScale = CALayer()
        /// The cover blurred a little and blurred more, over the cover. Each fades in its holder and turns inside it,
        /// since a layer that a pause stops can't fade either.
        private let softHolder = CALayer()
        private let hotHolder = CALayer()
        private let softBlur = CALayer()
        private let hotBlur = CALayer()
        private var blurDrawn = false
        private var art: CGImage?
        /// The play or pause glyph, which stays upright over the turning cover.
        private let glyph = CALayer()
        /// The dim on the shrunk cover, under the glyph and still, since it is a plain circle.
        private let tint = CALayer()
        private var shownGlyph: RecordGlyph?
        private var glyphImageKey: String?
        private static let blurContext = CIContext()

        /// The cover was drawn again, so its blurred copies are drawn again too.
        func coverChanged(art: CGImage?) {
            self.art = art
            blurDrawn = false
            if shownGlyph != nil { drawBlur() }
        }
        private let label: CGFloat

        init(period: Double, label: CGFloat) {
            self.label = label
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            record.contentsGravity = .resizeAspect
            cover.contentsGravity = .resizeAspect
            layer?.addSublayer(record)
            layer?.addSublayer(coverScale)
            coverScale.addSublayer(cover)
            for (holder, blur) in [(softHolder, softBlur), (hotHolder, hotBlur)] {
                holder.opacity = 0
                holder.masksToBounds = true
                blur.contentsGravity = .resizeAspect
                holder.addSublayer(blur)
                coverScale.addSublayer(holder)
            }
            tint.backgroundColor = NSColor.black.cgColor
            tint.opacity = 0
            layer?.addSublayer(tint)
            glyph.contentsGravity = .center
            glyph.opacity = 0
            glyph.shadowColor = NSColor.black.cgColor
            glyph.shadowOpacity = Float(RecordGlyph.shadowOpacity)
            glyph.shadowOffset = .zero
            layer?.addSublayer(glyph)
            // Clockwise, one turn every `period` seconds.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = period
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            for layer in turning { layer.add(turn, forKey: "turn") }
            pause()
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            record.bounds = bounds
            record.position = CGPoint(x: bounds.midX, y: bounds.midY)
            coverScale.bounds = CGRect(x: 0, y: 0, width: bounds.width * label, height: bounds.height * label)
            coverScale.position = CGPoint(x: bounds.midX, y: bounds.midY)
            cover.bounds = coverScale.bounds
            cover.position = CGPoint(x: coverScale.bounds.midX, y: coverScale.bounds.midY)
            for layer in [softHolder, hotHolder, softBlur, hotBlur] {
                layer.bounds = coverScale.bounds
                layer.position = cover.position
            }
            softHolder.cornerRadius = coverScale.bounds.width / 2
            hotHolder.cornerRadius = coverScale.bounds.width / 2
            // The buttons can show before the first layout, which gives the cover its size.
            if shownGlyph != nil { drawBlur() }
            let shrunkSide = bounds.width * label * RecordControls.shrink
            tint.bounds = CGRect(x: 0, y: 0, width: shrunkSide, height: shrunkSide)
            tint.cornerRadius = shrunkSide / 2
            tint.position = coverScale.position
            placeGlyph()
            CATransaction.commit()
        }

        /// Shows the glyph over the dimmed and blurred cover, or fades them out with nil.
        func show(_ new: RecordGlyph?) {
            guard new != shownGlyph else { return }
            if let new {
                shownGlyph = new
                drawGlyph()
                drawBlur()
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            placeGlyph()
            glyph.opacity = new == nil ? 0 : 1
            tint.opacity = Float(new?.dim ?? 0)
            softHolder.opacity = new == nil ? 0 : 1
            hotHolder.opacity = new?.hot == true ? 1 : 0
            CATransaction.commit()
            if new == nil { shownGlyph = nil }
        }

        private func drawGlyph() {
            guard let new = shownGlyph else { return }
            let key = "\(new.symbol) \(new.size)"
            guard key != glyphImageKey else { return }
            glyphImageKey = key
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let renderer = ImageRenderer(content: new.image)
            renderer.scale = scale
            glyph.contents = renderer.cgImage
            glyph.contentsScale = scale
            if let image = renderer.cgImage {
                glyph.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            }
            glyph.shadowRadius = new.shadowRadius
            CATransaction.commit()
            placeGlyph()
        }

        /// Blurs the cover the two ways, once for each cover and only when the buttons first show on it.
        private func drawBlur() {
            guard !blurDrawn, let image = art, cover.bounds.width > 0 else { return }
            blurDrawn = true
            let pixels = CGFloat(image.width) / cover.bounds.width
            let input = CIImage(cgImage: image)
            func blurred(_ points: CGFloat) -> CGImage? {
                let output = input.clampedToExtent().applyingGaussianBlur(sigma: points * pixels).cropped(to: input.extent)
                return Self.blurContext.createCGImage(output, from: input.extent)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            softBlur.contents = blurred(RecordGlyph.blur)
            hotBlur.contents = blurred(RecordGlyph.hotBlur)
            CATransaction.commit()
        }

        private func placeGlyph() {
            let lift = shownGlyph?.lift ?? 0
            // The view isn't flipped, so a lift is a move up in its coordinates.
            glyph.position = CGPoint(x: bounds.midX + (shownGlyph?.nudge ?? 0), y: bounds.midY + lift)
        }

        var shrunk = false {
            didSet {
                guard shrunk != oldValue else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.18)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                coverScale.transform = shrunk ? CATransform3DMakeScale(RecordControls.shrink, RecordControls.shrink, 1) : CATransform3DIdentity
                CATransaction.commit()
            }
        }

        var spinning = false {
            didSet { if spinning != oldValue { spinning ? resume() : pause() } }
        }

        /// Turns the record back, fast and slowing to a stop, with the backspin that the output plays when it steps
        /// back in the song. It adds to the turn, so the record carries on from where the spin left it.
        func rewind() {
            let back = CABasicAnimation(keyPath: "transform.rotation.z")
            back.fromValue = 0
            back.toValue = 2.6 * Double.pi
            back.duration = 0.9
            back.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.8, 0.3, 1)
            back.isAdditive = true
            for layer in turning { layer.add(back, forKey: "rewind") }
        }

        /// The vinyl, the cover and its blurred copies, which turn and pause together.
        private var turning: [CALayer] { [record, cover, softBlur, hotBlur] }

        /// Holds the record at its angle; the animation starts again from there.
        private func pause() {
            for layer in turning {
                let now = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = now
            }
        }

        private func resume() {
            for layer in turning {
                let paused = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
            }
        }
    }
}

/// Light on the vinyl stays still while the record turns.
private struct Sheen: View {
    var body: some View {
        Circle()
            .fill(AngularGradient(stops: [
                .init(color: .clear, location: 0.07),
                .init(color: .white.opacity(0.14), location: 0.12),
                .init(color: .clear, location: 0.18),
                .init(color: .clear, location: 0.5),
                .init(color: .white.opacity(0.1), location: 0.62),
                .init(color: .clear, location: 0.68),
            ], center: .center, angle: .degrees(25)))
            .overlay(Circle().strokeBorder(Color(white: 0.04), lineWidth: 1.5))
            .allowsHitTesting(false)
    }
}

/// Drawn in a 100 by 100 box that matches the platter, with its pivot inside the box, so the arm never makes the
/// deck wider on one side. At 0° the stylus sits on the outer grooves, at 10° just outside the label, and at the
/// rest angle off the record. The arm is turned by a rotation effect rather than in the canvas, so it swings
/// smoothly from one angle to the next.
private struct Tonearm: View {
    let angle: Double

    static let rest = -16.0

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 100
            let pivot = CGPoint(x: 91 * unit, y: 9 * unit)
            var arm = Path()
            arm.move(to: pivot)
            arm.addLine(to: CGPoint(x: 79 * unit, y: 80 * unit))
            context.stroke(arm, with: .color(Color(white: 0.79)), style: StrokeStyle(lineWidth: 2.2 * unit, lineCap: .round))
            var head = context
            head.translateBy(x: 79 * unit, y: 80 * unit)
            head.rotate(by: .degrees(10))
            head.fill(Path(roundedRect: CGRect(x: -4 * unit, y: -3 * unit, width: 8 * unit, height: 6 * unit), cornerRadius: 1.2 * unit), with: .color(Color(white: 0.9)))
            context.fill(Path(ellipseIn: CGRect(x: pivot.x - 5 * unit, y: pivot.y - 5 * unit, width: 10 * unit, height: 10 * unit)), with: .color(Color(white: 0.54)))
            context.fill(Path(ellipseIn: CGRect(x: pivot.x - 2.2 * unit, y: pivot.y - 2.2 * unit, width: 4.4 * unit, height: 4.4 * unit)), with: .color(Color(white: 0.23)))
        }
        .rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.91, y: 0.09))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
        .allowsHitTesting(false)
    }
}

/// A play or a pause that the HUD shows: the state it shows, and a new id for each change.
struct PlayFlash: Equatable {
    var playing: Bool
    var id: Int
    var date = Date()
    /// 1 for the next song and -1 for the previous one, which show their own glyph.
    var skip = 0
    /// A seek: its symbol for the arrows, or the share of the song that a number key moved to, like `30%`.
    var seek: String?
}

/// The play or pause glyph, on the record or over the lyrics, at full opacity on the frame that the change lands
/// in, and faded out half a second later. Only the fade is animated, so a key press shows at once.
struct PlayFlashView: View {
    let flash: PlayFlash?
    var size: CGFloat = 58
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.recordButtonsShown) private var buttonsShown
    @Environment(\.recordHovered) private var previewHover
    @State private var shown: PlayFlash?
    @State private var opacity = 0.0

    var body: some View {
        let current = buttonsShown || previewHover ? nil : renderingPreview ? flash : shown
        ZStack {
            if let current {
                Circle().fill(.black.opacity(0.55))
                if let seek = current.seek, seek.hasSuffix("%") {
                    Text(seek)
                        .font(.system(size: size * 0.26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                } else if let seek = current.seek {
                    Image(systemName: seek)
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: current.skip > 0 ? "forward.end.fill" : current.skip < 0 ? "backward.end.fill" : current.playing ? "play.fill" : "pause.fill")
                        .font(.system(size: size * (current.skip == 0 ? 0.38 : 0.32), weight: .bold))
                        .foregroundStyle(.white)
                        // The triangle's weight sits left of its box, so it moves right to look centred.
                        .offset(x: current.skip == 0 && current.playing ? size * 0.035 : 0)
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(renderingPreview ? 1 : opacity)
        .allowsHitTesting(false)
        .task(id: flash?.id) {
            // A view that appears later, as after a switch of layout, doesn't show an old change again.
            guard let flash, Date().timeIntervalSince(flash.date) < 0.3 else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                shown = flash
                opacity = 1
            }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
        }
    }
}

/// Title, artist and album, then the time with a bar, in a column as wide as the record.
private struct Details: View {
    let track: NowPlaying.Track
    let ticking: Bool
    let palette: Palette

    var body: some View {
        VStack(spacing: 2) {
            Text(track.title ?? "")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
            let byline = [track.artist, track.album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            if !byline.isEmpty {
                Text(byline)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
            }
            SongTimeBar(track: track, ticking: ticking, palette: palette)
                .padding(.top, 3)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .multilineTextAlignment(.center)
    }

    /// `1:42`, or `1:02:05` past an hour.
    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The time of the song with a bar between the time played and its length. While the song moves at once in its
/// player, a click on the bar or a drag along it moves the song there.
struct SongTimeBar: View {
    let track: NowPlaying.Track
    let ticking: Bool
    let palette: Palette
    var width: CGFloat = 84
    @Environment(\.recordActions) private var actions
    /// Where a drag along the bar is, from 0 to 1, until it ends.
    @State private var dragged: Double?
    @State private var hovering = false
    @State private var token = UUID()

    var body: some View {
        if let duration = track.duration, duration > 0 {
            TimelineView(.animation(minimumInterval: 1, paused: !ticking || dragged != nil || actions.scrub != nil)) { context in
                let played = min(1, max(0, (track.position(at: context.date) ?? 0) / duration))
                let fraction = dragged ?? actions.scrub ?? played
                HStack(spacing: 7) {
                    Text(Details.time(fraction * duration))
                    bar(fraction)
                    Text(Details.time(duration))
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.muted)
            }
        }
    }

    private func bar(_ fraction: Double) -> some View {
        let grows = actions.seekable && (hovering || dragged != nil || actions.scrub != nil)
        return Capsule().fill(palette.ink.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { bar in Capsule().fill(grows ? palette.ink.opacity(0.7) : palette.muted).frame(width: bar.size.width * fraction) }
            }
            // Under the pointer it grows about as tall as the digits beside it, which is easier to drag along.
            .frame(width: width, height: grows ? 9 : 4)
            // A taller strip to aim at than the bar itself.
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // A scroll over the strip moves the song, and a press on it seeks instead of dragging the HUD.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.scroll?.place(.timeBar, at: $0, by: token) }
            .onDisappear { actions.scroll?.remove(by: token) }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard actions.seekable else { return }
                        // The drag seeks, instead of moving the HUD.
                        HUDPanel.controlTracksDrag = true
                        dragged = min(1, max(0, drag.location.x / width))
                    }
                    .onEnded { drag in
                        HUDPanel.controlTracksDrag = false
                        guard actions.seekable else { return }
                        actions.seek(min(1, max(0, drag.location.x / width)))
                        // The bar holds the place until the player reports the move.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dragged = nil }
                    },
                isEnabled: actions.seekable
            )
            // Dimmed while a seek would have to separate the stems again, so the bar doesn't look broken.
            .opacity(actions.seekable ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: grows)
            .help(actions.seekable ? "Move the song (scroll, ← →, 0 for the start)" : "Seeking is off while instruments and vocals are separated as the song plays")
    }
}

/// An invented square cover for `--render`, with lettering near its edges like a real one.
@MainActor func sampleCover() -> NSImage? {
    let cover = ZStack(alignment: .topLeading) {
        LinearGradient(colors: [Color(red: 0.18, green: 0.42, blue: 0.52), Color(red: 0.11, green: 0.23, blue: 0.36), Color(red: 0.06, green: 0.11, blue: 0.2)], startPoint: .top, endPoint: .bottom)
        Circle().fill(Color(red: 1, green: 0.82, blue: 0.48)).frame(width: 68, height: 68).offset(x: 156, y: 134)
        Rectangle().fill(Color(red: 0.06, green: 0.11, blue: 0.2).opacity(0.55)).frame(height: 114).offset(y: 186)
        Text("MIRA VALE").font(.system(size: 15, weight: .bold)).kerning(4).foregroundStyle(.white).offset(x: 18, y: 20)
        Text("Paper Lanterns").font(.system(size: 26, weight: .semibold).italic()).foregroundStyle(.white).offset(x: 18, y: 250)
    }
    .frame(width: 300, height: 300)
    let renderer = ImageRenderer(content: cover)
    renderer.scale = 2
    return renderer.nsImage
}

/// Karaoke's record, rising from the bottom edge of the glass with half of it showing: the cover on its label, the
/// title, artist and album in letters cut from its grooves, and the time as a glowing line around its rim. The
/// letters and the line stay still while the record turns under them.
struct KaraokeRecord<Footer: View>: View {
    let track: NowPlaying.Track
    let artwork: NSImage?
    /// The record turns only while the HUD is up and the song plays.
    let spinning: Bool
    var flash: PlayFlash?
    let side: CGFloat
    /// The width of the glass, whose bottom corners hold the times.
    let width: CGFloat
    let palette: Palette
    /// The pointer is over the cover or near it.
    var hoverLabel: (Bool) -> Void = { _ in }
    @ViewBuilder let footer: Footer
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.songArriving) private var arriving
    @State private var buttonsShown = false

    /// How far the record shows below its centre, and the room above it for the glow of the line.
    static var below: CGFloat { 12 }
    static var above: CGFloat { 12 }
    /// The width of the label against the record's.
    static var label: CGFloat { 0.36 }
    static func height(side: CGFloat) -> CGFloat { above + side / 2 + below }
    /// The room around the record for the line and its glow.
    private static var margin: CGFloat { 15 }

    private static var honey: Color { Color(red: 0.97, green: 0.71, blue: 0.36) }
    private var song: String { track.song.map { $0 ?? "" }.joined(separator: "\u{1F}") }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !spinning)) { context in
            let duration = track.duration ?? 0
            let position = min(duration, max(0, track.position(at: context.date) ?? 0))
            ZStack {
                if duration > 0 {
                    RimLine(progress: position / duration, below: Self.below, palette: palette, glow: Self.honey)
                        .frame(width: side + 7, height: side + 7)
                }
                ZStack {
                    ZStack {
                        if renderingPreview {
                            Record(artwork: artwork, shadow: false, label: Self.label)
                        } else {
                            SpinningRecord(artwork: artwork, spinning: spinning && arriving == nil, side: side, label: Self.label, period: 8)
                        }
                        Sheen()
                        GroovedLetters(track: track, side: side)
                    }
                    .frame(width: side, height: side)
                    .opacity(arriving == nil ? 1 : 0.6)
                    .overlay { if let arriving { ArrivalRing(arriving: arriving, diameter: side * Self.label + 12) } }
                    .background(Circle().fill(Color(white: 0.09)).shadow(color: .black.opacity(0.3), radius: 12, y: -2))
                    .id(song)
                    .transition(.opacity)
                    // The cover and the grooves around it show the instruments and vocals while the pointer is over them.
                    Circle()
                        .fill(.clear)
                        .contentShape(Circle())
                        .frame(width: side * Self.label * 1.5, height: side * Self.label * 1.5)
                        .onHover(perform: hoverLabel)
                }
                .frame(width: side, height: side)
            }
            .frame(width: side + 2 * Self.margin, height: side + 2 * Self.margin)
            // The record's centre sits `below` above the bottom edge of the glass.
            .offset(y: Self.above - Self.margin)
            .frame(width: width, height: Self.height(side: side), alignment: .top)
            .overlay(alignment: .bottom) {
                if duration > 0 {
                    HStack {
                        Text(Details.time(position))
                        Spacer()
                        Text(Details.time(duration))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
            .overlay { PlayFlashView(flash: flash, size: 64).offset(y: Self.above / 2).environment(\.recordButtonsShown, buttonsShown) }
            .onPreferenceChange(RecordButtonsShown.self) { buttonsShown = $0 }
            .overlay(alignment: .bottom) { footer }
            // Cut along the bottom edge of the glass only, so the shadow and the glow above the record stay whole.
            .mask { UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26).padding(.top, -60) }
        }
    }
}

/// The time around the rim of karaoke's record: a faint line for the whole song, and a glowing one for the part
/// that played, from the bottom edge of the glass on the left, over the top, to the bottom edge on the right.
private struct RimLine: View {
    let progress: Double
    /// How far the record shows below its centre. The line starts a little further down, past the edge of the glass.
    let below: CGFloat
    let palette: Palette
    let glow: Color

    var body: some View {
        ZStack {
            Rim(below: below + 4).stroke(palette.ink.opacity(0.1), lineWidth: 3.5)
            Rim(below: below + 4)
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(glow, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .shadow(color: glow.opacity(0.9), radius: 3)
                .shadow(color: glow.opacity(0.5), radius: 7)
        }
        .animation(.linear(duration: 1), value: progress)
    }

    private struct Rim: Shape {
        let below: CGFloat

        func path(in rect: CGRect) -> Path {
            let radius = rect.width / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            // Angles as on paper, with y going up: from below the centre on the left (π + past), over the top
            // (π / 2), to below the centre on the right (−past).
            let past = asin(min(1, below / radius))
            let steps = 240
            var path = Path()
            for step in 0 ... steps {
                let angle = .pi + past - (.pi + 2 * past) * Double(step) / Double(steps)
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y - radius * sin(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }
}

/// The song's title, artist and album, in letters filled with rings that line up with the grooves of the record.
private struct GroovedLetters: View {
    let track: NowPlaying.Track
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.68)))
            for radius in stride(from: CGFloat(1), to: size.width / 2, by: 3) {
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(.white.opacity(0.96)), lineWidth: 2)
            }
        }
        .frame(width: side, height: side)
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Text(track.title ?? "")
                    .font(.system(size: side * 0.081, weight: .black, design: .rounded))
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: side * 0.033, weight: .bold, design: .rounded))
                        .padding(.top, side * 0.008)
                }
                if let album = track.album, !album.isEmpty {
                    Text(album)
                        .font(.system(size: side * 0.028, weight: .bold, design: .rounded))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            // About as wide as the record is at the height of the title.
            .frame(maxWidth: side * 0.66)
            .padding(.top, side * 0.12)
        }
        .allowsHitTesting(false)
    }
}

/// The record of a song that isn't heard yet, while the stems or the lyrics delay still play the last one seconds
/// behind: it stands still, faded, and a ring around its label fills until the song is heard.
struct ArrivalRing: View {
    let arriving: ClosedRange<Date>
    let diameter: CGFloat

    private static var honey: Color { Color(red: 0.97, green: 0.71, blue: 0.36) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let total = arriving.upperBound.timeIntervalSince(arriving.lowerBound)
            let progress = total > 0 ? min(1, max(0, context.date.timeIntervalSince(arriving.lowerBound) / total)) : 1
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Self.honey, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Self.honey.opacity(0.7), radius: 3)
            }
            .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// `--glyph-sheet`: live records with the play and pause glyph over a set of covers, at the size of the wide layout's
/// record and of the card's, as the pointer over the record shows them, and as the pointer over the cover does.
struct GlyphSheet: View {
    let covers: [(name: String, image: NSImage)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(symbol: "play.fill", side: 165.6, hot: false)
            row(symbol: "play.fill", side: 165.6, hot: true)
            row(symbol: "pause.fill", side: 136, hot: false)
            row(symbol: "pause.fill", side: 136, hot: true)
        }
        .padding(18)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
    }

    private func row(symbol: String, side: CGFloat, hot: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(covers, id: \.name) { cover in
                let shown = side * 0.66 * RecordControls.shrink
                ZStack {
                    SpinningRecord(artwork: cover.image, spinning: false, side: side)
                    Circle().strokeBorder(.white.opacity(hot ? 0.22 : 0), lineWidth: 1).frame(width: shown, height: shown)
                }
                .frame(width: side, height: side)
                .environment(\.recordButtonsShown, true)
                .environment(\.recordGlyph, RecordGlyph(symbol: symbol, size: min(54, shown * 0.36), lift: 0, hot: hot))
            }
        }
    }

    /// The flat and split covers where a white glyph is hardest to read, then the covers of `--glyph-covers`. A flat
    /// black cover is left out, since a dark cover with a white glyph is the easy case.
    static func covers(paths: [String]) -> [(name: String, image: NSImage)] {
        func flat(_ name: String, _ draw: @escaping (CGRect) -> Void) -> (String, NSImage) {
            (name, NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
                draw(rect)
                return true
            })
        }
        var covers = [
            flat("white") { NSColor(white: 0.96, alpha: 1).setFill(); $0.fill() },
            flat("grey") { NSColor(white: 0.6, alpha: 1).setFill(); $0.fill() },
            flat("red") { NSColor(srgbRed: 0.86, green: 0.25, blue: 0.2, alpha: 1).setFill(); $0.fill() },
            flat("split") { rect in
                NSColor(white: 0.96, alpha: 1).setFill()
                rect.fill()
                NSColor(white: 0.04, alpha: 1).setFill()
                NSRect(x: rect.midX, y: 0, width: rect.width / 2, height: rect.height).fill()
            },
        ]
        for path in paths {
            if let image = NSImage(contentsOfFile: path) { covers.append(((path as NSString).lastPathComponent, image)) }
        }
        return covers
    }
}
