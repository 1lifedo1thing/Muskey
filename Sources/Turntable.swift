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
                .modifier(RecordControls(spread: Self.size / 2))
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
}

extension EnvironmentValues {
    @Entry var recordActions = RecordActions()
    /// `--render` shows the previous and next buttons, as the pointer over the record does.
    @Entry var recordHovered = false
}

/// A click on the record plays or pauses the song, as Space does. The pointer over the record shows the previous and
/// next buttons, `spread` points to its left and right and `lift` points above its centre. The buttons show only on
/// hover, since the record is the thing to look at, and they fade in quickly, as hover feedback does.
struct RecordControls: ViewModifier {
    let spread: CGFloat
    var lift: CGFloat = 0
    @Environment(\.recordActions) private var actions
    @Environment(\.recordHovered) private var previewHover
    @State private var hovering = false
    @State private var leave: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Circle())
            .onTapGesture { actions.playPause() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Record")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.playPause() }
            .onHover(perform: hover)
            .overlay {
                if hovering || previewHover {
                    HStack(spacing: 0) {
                        SkipButton(direction: -1) { actions.skip(-1) }.onHover(perform: hover)
                        Spacer(minLength: 0)
                        SkipButton(direction: 1) { actions.skip(1) }.onHover(perform: hover)
                    }
                    .frame(width: 2 * spread + SkipButton.size)
                    .offset(y: -lift)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func hover(_ inside: Bool) {
        leave?.cancel()
        if inside { return hovering = true }
        // The buttons stick out past the record, so moving onto one leaves the record a moment before it enters the
        // button.
        leave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { hovering = false }
        }
    }
}

private struct SkipButton: View {
    let direction: Int
    let action: () -> Void
    static let size: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: direction > 0 ? "forward.fill" : "backward.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(direction > 0 ? "Play the next song" : "Play the previous song")
        .accessibilityLabel(direction > 0 ? "Next song" : "Previous song")
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
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.songArriving) private var arriving

    private var song: String { track.song.map { $0 ?? "" }.joined(separator: "\u{1F}") }

    var body: some View {
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
        // Inside the record, since the ring of keys sits around it.
        .modifier(RecordControls(spread: side * 0.36))
        .animation(.smooth(duration: TurntableDeck.swap), value: song)
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
    let artwork: NSImage?
    /// Off when the record is drawn into the spinning layer, whose image would cut the shadow off and turn it.
    var shadow = true
    /// The width of the label against the record's. Karaoke's label is smaller, which leaves the grooves above it
    /// for the song's details.
    var label: CGFloat = 0.66

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                Circle().fill(Color(white: 0.09))
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var radius = size.width * (label / 2 + 0.03)
                    while radius < size.width / 2 - 1.5 {
                        let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(.white.opacity(0.045)), lineWidth: 0.6)
                        radius += 1.6
                    }
                }
                Group {
                    if let artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(red: 0.93, green: 0.88, blue: 0.80)
                    }
                }
                .frame(width: side * label, height: side * label)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
                Circle()
                    .fill(Color(red: 0.93, green: 0.90, blue: 0.89))
                    .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
                    .frame(width: 8, height: 8)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 7, y: 4)
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

    func makeNSView(context _: Context) -> SpinView { SpinView(period: period) }

    func updateNSView(_ view: SpinView, context: Context) {
        if !context.coordinator.drawn || context.coordinator.artwork !== artwork {
            context.coordinator.artwork = artwork
            context.coordinator.drawn = true
            let renderer = ImageRenderer(content: Record(artwork: artwork, shadow: false, label: label).frame(width: side, height: side))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            view.record.contents = renderer.cgImage
        }
        let rewinds = context.environment.recordRewinds
        if let seen = context.coordinator.rewinds, rewinds > seen { view.rewind() }
        context.coordinator.rewinds = rewinds
        view.spinning = spinning
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: SpinView, context _: Context) -> CGSize? { CGSize(width: side, height: side) }

    final class SpinView: NSView {
        let record = CALayer()

        init(period: Double) {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            record.contentsGravity = .resizeAspect
            layer?.addSublayer(record)
            // Clockwise, one turn every `period` seconds.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = period
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            record.add(turn, forKey: "turn")
            pause()
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            record.bounds = bounds
            record.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
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
            record.add(back, forKey: "rewind")
        }

        /// Holds the record at its angle; the animation starts again from there.
        private func pause() {
            let now = record.convertTime(CACurrentMediaTime(), from: nil)
            record.speed = 0
            record.timeOffset = now
        }

        private func resume() {
            let paused = record.timeOffset
            record.speed = 1
            record.timeOffset = 0
            record.beginTime = 0
            record.beginTime = record.convertTime(CACurrentMediaTime(), from: nil) - paused
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
}

/// The play or pause glyph, on the record or over the lyrics, at full opacity on the frame that the change lands
/// in, and faded out half a second later. Only the fade is animated, so a key press shows at once.
struct PlayFlashView: View {
    let flash: PlayFlash?
    var size: CGFloat = 58
    @Environment(\.renderingPreview) private var renderingPreview
    @State private var shown: PlayFlash?
    @State private var opacity = 0.0

    var body: some View {
        let current = renderingPreview ? flash : shown
        ZStack {
            if let current {
                Circle().fill(.black.opacity(0.55))
                Image(systemName: current.skip > 0 ? "forward.fill" : current.skip < 0 ? "backward.fill" : current.playing ? "play.fill" : "pause.fill")
                    .font(.system(size: size * (current.skip == 0 ? 0.38 : 0.32), weight: .bold))
                    .foregroundStyle(.white)
                    // The triangle's weight sits left of its box, so it moves right to look centred.
                    .offset(x: current.skip == 0 && current.playing ? size * 0.035 : 0)
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
            if let duration = track.duration, duration > 0 {
                TimelineView(.animation(minimumInterval: 1, paused: !ticking)) { context in
                    let position = min(duration, max(0, track.position(at: context.date) ?? 0))
                    HStack(spacing: 7) {
                        Text(Self.time(position))
                        Capsule().fill(palette.ink.opacity(0.15))
                            .overlay(alignment: .leading) {
                                GeometryReader { bar in Capsule().fill(palette.muted).frame(width: bar.size.width * position / duration) }
                            }
                            .frame(width: 84, height: 4)
                        Text(Self.time(duration))
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .padding(.top, 3)
                }
            }
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
                    if renderingPreview {
                        Record(artwork: artwork, shadow: false, label: Self.label)
                    } else {
                        SpinningRecord(artwork: artwork, spinning: spinning && arriving == nil, side: side, label: Self.label, period: 8)
                    }
                    Sheen()
                    GroovedLetters(track: track, side: side)
                }
                .frame(width: side, height: side)
                // On the part of the record above the edge of the glass, beside the cover.
                .modifier(RecordControls(spread: side * 0.38, lift: side * 0.1))
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
            .overlay { PlayFlashView(flash: flash, size: 64).offset(y: Self.above / 2) }
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
