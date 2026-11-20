import SwiftUI

/// The look of the waveform, from Settings > HUD.
enum WaveformStyle: String, CaseIterable {
    /// Mirrored bars under the key row, as wide as the row.
    case ribbon
    /// Bars that grow up from the hints bar across the whole key column, behind the stems.
    case strip

    var name: String {
        switch self {
        case .ribbon: "Ribbon"
        case .strip: "Strip"
        }
    }
}

/// The waveform of the whole song, with the played part filled in and a playhead that moves with the song. A click
/// or a drag moves the song, as the time bar does. Zoomed in, a close-up of the moments around the playhead scrolls
/// past a fixed playhead, over a thin strip of the whole song. With the stems of the whole song, ⌥W splits it into
/// a lane for each stem.
struct WaveformView: View {
    let waveform: SongWaveform
    let track: NowPlaying.Track
    var style: WaveformStyle = .ribbon
    let width: CGFloat
    var height: CGFloat = 40
    /// The song plays and the HUD shows, so the playhead moves.
    let ticking: Bool
    var bpm: Double?
    /// 1 shows the whole song, and more shows a close-up that spans the song's length divided by it.
    var zoom: Double = 1
    /// One lane per stem, when the stems of the whole song are known.
    var lanes = false
    var muted: Set<Stem> = []
    var loop: LoopRegion?
    let palette: Palette

    @Environment(\.recordActions) private var actions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderingPreview) private var renderingPreview
    /// Where a drag along the waveform is, from 0 to 1, until the player reports the move.
    @State private var dragged: Double?
    /// The song's place when a drag on the close-up began, which the drag moves like a tape under the playhead.
    @State private var tapeStart: Double?
    @State private var token = UUID()

    static let barStep: CGFloat = 3.4
    static let barWidth: CGFloat = 2

    private var duration: Double { track.duration.flatMap { $0 > 0 ? $0 : nil } ?? waveform.duration }
    private var zoomed: Bool { zoom > 1.05 && style == .ribbon }
    private var shownLanes: [Stem] { lanes && waveform.stems != nil ? Stem.shown : [] }

    var body: some View {
        let count = max(8, Int(width / Self.barStep))
        // The bars of the whole song only change when more of it is heard, so they are worked out once per change and
        // not on every frame.
        let overview = waveform.bars(count)
        let laneBars = shownLanes.map { ($0, waveform.bars(count, stem: $0)) }
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !ticking || renderingPreview)) { context in
            let seconds = dragged.map { $0 * duration } ?? actions.scrub.map { $0 * duration } ?? track.position(at: context.date) ?? 0
            let fraction = min(1, max(0, seconds / max(duration, 0.001)))
            Group {
                if zoomed {
                    VStack(spacing: 4) {
                        closeUp(seconds: seconds, count: count, height: height - 12)
                        strip(overview, fraction: fraction, height: 8)
                            .overlay { window(fraction: fraction) }
                    }
                } else if !laneBars.isEmpty {
                    lanesView(laneBars, fraction: fraction, seconds: seconds)
                } else {
                    bars(overview, fraction: fraction, seconds: seconds, height: height)
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        // A scroll over the waveform moves the song as one over the time bar does, and a press on it seeks instead of
        // dragging the HUD.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.scroll?.place(.waveform, at: $0, by: token) }
        .onDisappear { actions.scroll?.remove(by: token) }
        .gesture(drag, isEnabled: actions.seekable)
        .opacity(actions.seekable || !ticking ? 1 : 0.8)
        .help(actions.seekable ? "Move the song (drag, scroll, ⌘ scroll to zoom)" : "Seeking is off while instruments and vocals are separated as the song plays")
        .animation(.snappy(duration: 0.25), value: zoomed)
        .animation(.snappy(duration: 0.25), value: shownLanes)
    }

    private var played: Color { StripColors.solid(.honey, scheme).fill }
    private var unplayed: Color { palette.ink.opacity(scheme == .dark ? 0.22 : 0.2) }

    /// Mirrored bars, or bars growing up from the bottom in the strip style. A moment not heard yet is a dot on the
    /// centre line, which turns into a bar once the song reaches it.
    private func bars(_ values: [Float], fraction: Double, seconds: Double, height: CGFloat) -> some View {
        Canvas { context, size in
            let count = values.count
            let step = size.width / CGFloat(count)
            let head = fraction * Double(count)
            let mid = style == .strip ? size.height : size.height / 2
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * step + (step - Self.barWidth) / 2
                let isPlayed = Double(i) + 0.5 <= head
                if value < 0 {
                    let dot = CGRect(x: x + Self.barWidth / 2 - 0.9, y: mid - (style == .strip ? 2 : 0.9), width: 1.8, height: 1.8)
                    context.fill(Path(ellipseIn: dot), with: .color(palette.ink.opacity(0.3)))
                    continue
                }
                let scale = reduceMotion ? 1 : lens(behind: head - Double(i))
                let full = style == .strip ? size.height - 2 : size.height - 4
                let h = max(1.5, CGFloat(value) * full * scale)
                let rect = style == .strip
                    ? CGRect(x: x, y: mid - h, width: Self.barWidth, height: h)
                    : CGRect(x: x, y: mid - h / 2, width: Self.barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(isPlayed ? played : unplayed))
            }
            drawLoop(&context, size: size, from: 0, span: duration)
            drawHead(&context, x: fraction * size.width, height: size.height, seconds: seconds)
        }
        .frame(height: height)
    }

    /// The bars just behind the playhead rise a little and settle back, like a spring catching up with it.
    private func lens(behind distance: Double) -> CGFloat {
        guard distance > -0.5, distance < 5 else { return 1 }
        let k = distance < 0 ? max(0, 1 + distance * 2) * 0.12 : exp(-distance * 0.9) * cos(distance * 1.6) * 0.42
        return CGFloat(1 + max(-0.08, k))
    }

    /// A white line with a honey glow, which pulses on the beat when the tempo is known.
    private func drawHead(_ context: inout GraphicsContext, x: CGFloat, height: CGFloat, seconds: Double) {
        var pulse = 0.0
        if let bpm, bpm > 0, !reduceMotion, ticking {
            let phase = (seconds * bpm / 60).truncatingRemainder(dividingBy: 1)
            pulse = max(0, 1 - phase / 0.6)
        }
        let grow = 3 + 3 * pulse
        let rect = CGRect(x: x - 1, y: -grow / 2, width: 2, height: height + grow)
        var glow = context
        glow.addFilter(.shadow(color: played.opacity(0.55 + 0.4 * pulse), radius: 4 + 3 * pulse))
        glow.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color((scheme == .dark ? Color.white : palette.ink).opacity(0.85 + 0.15 * pulse)))
    }

    /// The region loop as a honey band over the bars, with a line at each end.
    private func drawLoop(_ context: inout GraphicsContext, size: CGSize, from: Double, span: Double) {
        guard let loop, span > 0 else { return }
        let a = (loop.start - from) / span * size.width
        let b = ((loop.end ?? loop.start) - from) / span * size.width
        guard b >= -2, a <= size.width + 2 else { return }
        let band = CGRect(x: a, y: -4, width: max(0, b - a), height: size.height + 8)
        context.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(played.opacity(loop.end == nil ? 0.12 : 0.2)))
    }

    /// Every stem in a lane of its own, as a strip of cells as tall as the lane, whose colour gets stronger where the
    /// stem is louder. Six or seven lanes leave each one a few points, where bars would read as dots, and the strength
    /// of a colour still reads at that height. The played part takes the stem's colour, and a muted stem stays grey.
    private func lanesView(_ rows: [(Stem, [Float])], fraction: Double, seconds: Double) -> some View {
        Canvas { context, size in
            let gap: CGFloat = 1.5
            let laneHeight = (size.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
            for (row, (stem, values)) in rows.enumerated() {
                let top = CGFloat(row) * (laneHeight + gap)
                let step = size.width / CGFloat(max(1, values.count))
                let head = fraction * Double(values.count)
                let isMuted = muted.contains(stem)
                let lane = CGRect(x: 0, y: top, width: size.width, height: laneHeight)
                context.fill(Path(roundedRect: lane, cornerRadius: 1.5), with: .color(palette.ink.opacity(0.04)))
                for (i, value) in values.enumerated() where value > 0.02 {
                    let strength = Double(value * value)
                    let color = isMuted ? palette.ink.opacity(0.12 + 0.2 * strength)
                        : Double(i) + 0.5 <= head ? stem.color(scheme, opacity: 0.15 + 0.85 * strength) : palette.ink.opacity(0.06 + 0.3 * strength)
                    context.fill(Path(CGRect(x: CGFloat(i) * step, y: top, width: step + 0.3, height: laneHeight)), with: .color(color))
                }
            }
            drawLoop(&context, size: size, from: 0, span: duration)
            drawHead(&context, x: fraction * size.width, height: size.height, seconds: seconds)
        }
    }

    /// The seconds that the close-up spans: the song divided by the zoom, and never under 4 seconds.
    private var span: Double { max(4, duration / zoom) }

    /// The moments around the playhead, which scroll past it while it stays in the middle.
    private func closeUp(seconds: Double, count: Int, height: CGFloat) -> some View {
        let from = seconds - span / 2
        let values = waveform.bars(count, from: from, to: from + span)
        return Canvas { context, size in
            let step = size.width / CGFloat(max(1, values.count))
            let mid = size.height / 2
            if let bpm, bpm > 0 {
                // Faint lines a beat apart, counted from the song's start, which the loop's snapping lines up later.
                let beat = 60 / bpm
                var t = (from / beat).rounded(.up) * beat
                while t < from + span {
                    let x = (t - from) / span * size.width
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(palette.ink.opacity(0.1)))
                    t += beat
                }
            }
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * step + (step - Self.barWidth) / 2
                let time = from + span * (Double(i) + 0.5) / Double(values.count)
                guard time >= 0, time <= duration else { continue }
                if value < 0 {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: mid - 0.9, width: 1.8, height: 1.8)), with: .color(palette.ink.opacity(0.3)))
                    continue
                }
                let h = max(1.5, CGFloat(value) * (size.height - 2))
                context.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: Self.barWidth, height: h), cornerRadius: 1),
                             with: .color(time <= seconds ? played : unplayed))
            }
            drawLoop(&context, size: size, from: from, span: span)
            drawHead(&context, x: size.width / 2, height: size.height, seconds: seconds)
        }
        .frame(height: height)
        .background(palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The whole song as a thin strip, under the close-up.
    private func strip(_ values: [Float], fraction: Double, height: CGFloat) -> some View {
        Canvas { context, size in
            let step = size.width / CGFloat(max(1, values.count))
            for (i, value) in values.enumerated() where value >= 0 {
                let h = max(1, CGFloat(value) * size.height)
                let x = CGFloat(i) * step + (step - Self.barWidth) / 2
                context.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: Self.barWidth * 0.8, height: h)),
                             with: .color(Double(i) / Double(values.count) <= fraction ? played.opacity(0.8) : unplayed))
            }
            drawLoop(&context, size: size, from: 0, span: duration)
        }
        .frame(height: height)
    }

    /// The box on the strip that shows which part of the song the close-up shows.
    private func window(fraction: Double) -> some View {
        GeometryReader { geo in
            let w = max(6, geo.size.width * span / max(duration, 0.001))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(palette.ink.opacity(0.7), lineWidth: 1.2)
                .frame(width: w, height: geo.size.height + 4)
                .offset(x: fraction * geo.size.width - w / 2, y: -2)
        }
        .allowsHitTesting(false)
    }

    /// A press seeks. On the whole song a drag moves the place under the pointer; on the close-up it pulls the song
    /// under the playhead like a tape, and a click without a drag moves the song to the moment clicked.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                HUDPanel.controlTracksDrag = true
                if zoomed, value.startLocation.y < height - 12 {
                    let start = tapeStart ?? (dragged.map { $0 * duration } ?? track.position(at: Date()) ?? 0)
                    if tapeStart == nil { tapeStart = start }
                    let moved = start - Double(value.translation.width / width) * span
                    dragged = min(1, max(0, moved / duration))
                } else {
                    dragged = min(1, max(0, value.location.x / width))
                }
            }
            .onEnded { value in
                HUDPanel.controlTracksDrag = false
                var target = dragged ?? 0
                if zoomed, value.startLocation.y < height - 12, abs(value.translation.width) < 3, let now = track.position(at: Date()) {
                    target = min(1, max(0, (now + (Double(value.location.x / width) - 0.5) * span) / duration))
                    dragged = target
                }
                tapeStart = nil
                actions.seek(target)
                // The waveform holds the place until the player reports the move.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dragged = nil }
            }
    }
}

/// The part of the song that the region loop repeats: its start, and its end once the second press set it.
struct LoopRegion: Equatable {
    var start: Double
    var end: Double?
}

/// The waveform in the key column or on the card. It watches only the waveform's own object, so the waveform redraws
/// as more of a song is heard without redrawing the rest of the HUD.
struct WaveformHost: View {
    @ObservedObject var wave: WaveState
    let track: NowPlaying.Track?
    let style: WaveformStyle
    let width: CGFloat
    var height: CGFloat = 40
    let ticking: Bool
    let bpm: Double?
    let muted: Set<Stem>
    let palette: Palette

    var body: some View {
        if let waveform = wave.waveform, let track {
            WaveformView(waveform: waveform, track: track, style: style, width: width, height: height, ticking: ticking, bpm: bpm,
                         zoom: wave.zoom, lanes: wave.lanes, muted: muted, loop: wave.loop, palette: palette)
        } else {
            // The place stays while the waveform is read, so the key row doesn't move when it arrives.
            Color.clear.frame(width: width, height: height)
        }
    }
}
