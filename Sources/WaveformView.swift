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
/// past a fixed playhead, over a thin strip of the whole song, and a region loop that fits in it holds still while
/// the playhead moves through it. With the stems of the whole song, ⌥W splits it into
/// a lane for each stem picked in the chips under the lanes, and the lanes zoom, move the song and carry the region
/// loop like the waveform of the whole song.
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
    /// One lane per picked stem, when the stems of the whole song are known.
    var lanes = false
    /// The share of the song separated while ⌥W waits for the stems of the whole song.
    var separating: Double?
    /// The stems that get a lane.
    var laneStems: Set<Stem> = []
    var toggleLane: (Stem) -> Void = { _ in }
    var muted: Set<Stem> = []
    var loop: LoopRegion?
    /// Moves an end of the region loop to a time, from its arrows, a drag or a typed time.
    var setLoop: (LoopEnd, Double) -> Void = { _, _ in }
    /// A time of the region loop is typed in, which turns off the keys over the HUD until the field closes.
    var typing: (Bool) -> Void = { _ in }
    /// The pointer moves over the waveform or leaves it, which shows its keys in place of the hints row.
    var hovered: (Bool) -> Void = { _ in }
    /// The pointer moves onto the tab of an end of the region loop or off it, which turns ← and → into its nudge keys.
    var hoveredEnd: (LoopEnd?) -> Void = { _ in }
    /// The pointer is over the waveform, where the number keys go to the bars that the close-up numbers.
    var showsBarKeys = false
    let palette: Palette

    @Environment(\.recordActions) private var actions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.displayScale) private var displayScale
    /// Where a drag along the waveform is, from 0 to 1, until the player reports the move.
    @State private var dragged: Double?
    /// The song's place when a drag on the close-up began, which the drag moves like a tape under the playhead.
    @State private var tapeStart: Double?
    @State private var token = UUID()

    static let barStep: CGFloat = 3.4
    static let barWidth: CGFloat = 2
    /// `--log-playhead` logs the time that the playhead is drawn at, ten times a second, for testing.
    nonisolated(unsafe) static var trace: ((Double) -> Void)?
    nonisolated(unsafe) private static var tracedAt = Date.distantPast

    private static func traced(_ seconds: Double, at date: Date) -> Bool {
        guard let trace, date.timeIntervalSince(tracedAt) >= 0.1 else { return true }
        tracedAt = date
        trace(seconds)
        return true
    }

    private var duration: Double { track.duration.flatMap { $0 > 0 ? $0 : nil } ?? waveform.duration }
    private var zoomed: Bool { zoom > 1.05 && style == .ribbon }
    /// The lanes and their chips show: ⌥W with the stems of the whole song, in the ribbon style.
    private var lanesOn: Bool { lanes && waveform.stems != nil && style == .ribbon }
    private var shownLanes: [Stem] { lanesOn ? Stem.shown.filter(laneStems.contains) : [] }

    // MARK: Sizes, shared by the drawing, the drag and the ends of the region loop

    static let laneGap: CGFloat = 3
    static let overviewHeight: CGFloat = 8

    /// The height of the lanes together: one lane as tall as the waveform, and more lanes that share a little more.
    static func lanesHeight(_ count: Int) -> CGFloat {
        switch count {
        case ...1: 40
        case 2: 64
        case 3: 84
        default: 100
        }
    }

    /// The bars, the lanes or the close-up, without the strip of the whole song under a close-up.
    private var mainHeight: CGFloat { !shownLanes.isEmpty ? Self.lanesHeight(shownLanes.count) : zoomed ? height - 12 : height }
    /// The part that takes clicks and drags: the main part, and the strip of the whole song under a close-up.
    private var areaHeight: CGFloat { mainHeight + (zoomed ? Self.overviewHeight + 4 : 0) }

    var body: some View {
        let count = max(8, Int(width / Self.barStep))
        // The bars of the whole song only change when more of it is heard, so they are worked out once per change and
        // not on every frame.
        let overview = waveform.bars(count)
        let ranges = lanesOn ? waveform.stemRanges() : [:]
        let laneBars = zoomed ? [] : shownLanes.map { ($0, waveform.bars(count, stem: $0, range: ranges[$0])) }
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: actions.seekWait == nil ? step : 1.0 / 30, paused: (!ticking && actions.seekWait == nil) || renderingPreview)) { context in
                let seconds = dragged.map { $0 * duration } ?? actions.scrub.map { $0 * duration } ?? shownSeconds(at: context.date)
                let fraction = min(1, max(0, seconds / max(duration, 0.001)))
                let _ = Self.traced(seconds, at: context.date)
                let pulse = actions.seekWait?.pulse(at: context.date, reduceMotion: reduceMotion) ?? 1
                Group {
                    if zoomed {
                        let from = closeUpStart(seconds, at: context.date)
                        VStack(spacing: 4) {
                            closeUp(seconds: seconds, from: from, count: count, ranges: ranges, pulse: pulse)
                            strip(overview, fraction: fraction, height: Self.overviewHeight)
                                .overlay { window(from: from) }
                        }
                    } else if !laneBars.isEmpty {
                        lanesView(laneBars, fraction: fraction, seconds: seconds, pulse: pulse)
                    } else {
                        bars(overview, fraction: fraction, seconds: seconds, height: mainHeight, pulse: pulse)
                    }
                }
            }
            .frame(width: width, height: areaHeight)
            .contentShape(Rectangle())
            // A scroll over the waveform moves the song as one over the time bar does, and a press on it seeks instead
            // of dragging the HUD.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.scroll?.place(.waveform, at: $0, by: token) }
            .onDisappear { actions.scroll?.remove(by: token) }
            .gesture(drag, isEnabled: actions.seekable)
            .opacity(actions.seekable || !ticking ? 1 : 0.8)
            .help(actions.seekable ? "Move the song (drag, scroll, ⌘ scroll to zoom)" : actions.seekOff)
            // The ends of the region loop sit over the waveform's edges, outside the shape that takes its clicks and
            // its drag, so that their tabs, arrows and times get the pointer.
            .overlay(alignment: .topLeading) { loopFlags }
            // ⌥W waits for the stems of the whole song, which the lanes are drawn from.
            .overlay {
                if let separating, !lanesOn {
                    LanesSeparating(fraction: separating, palette: palette)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            if lanesOn {
                laneChips
                    .transition(.opacity)
            }
        }
        // A clear background keeps the hover across the gap above the chips. A content shape on the stack would cut
        // off the tabs of the region loop, which stand above it.
        .background(Color.clear.contentShape(Rectangle()))
        .onHover { hovered($0) }
        .onDisappear { hovered(false) }
        .animation(.snappy(duration: 0.25), value: zoomed)
        .animation(.snappy(duration: 0.25), value: shownLanes)
        .animation(.snappy(duration: 0.25), value: lanesOn)
    }

    private var played: Color { StripColors.solid(.honey, scheme).fill }
    private var unplayed: Color { palette.ink.opacity(scheme == .dark ? 0.22 : 0.2) }

    /// Mirrored bars, or bars growing up from the bottom in the strip style. A moment not heard yet is a dot on the
    /// centre line, which turns into a bar once the song reaches it.
    private func bars(_ values: [Float], fraction: Double, seconds: Double, height: CGFloat, pulse: Double = 1) -> some View {
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
            drawLoop(&context, size: size, from: 0, span: duration, now: seconds)
            drawHead(&context, x: fraction * size.width, height: size.height, seconds: seconds, pulse: pulse)
        }
        .frame(height: height)
    }

    /// The bars just behind the playhead rise a little and settle back, like a spring catching up with it.
    private func lens(behind distance: Double) -> CGFloat {
        guard distance > -0.5, distance < 5 else { return 1 }
        let k = distance < 0 ? max(0, 1 + distance * 2) * 0.12 : exp(-distance * 0.9) * cos(distance * 1.6) * 0.42
        return CGFloat(1 + max(-0.08, k))
    }

    /// A white line with a honey glow, which pulses on the beat when the tempo is known. `wait` is the opacity of a
    /// seek that waits for the stems of the new place, which pulses instead of the beat.
    private func drawHead(_ context: inout GraphicsContext, x: CGFloat, height: CGFloat, seconds: Double, pulse wait: Double = 1) {
        var pulse = 0.0
        if wait == 1, let bpm, bpm > 0, !reduceMotion, ticking {
            let phase = (seconds * bpm / 60).truncatingRemainder(dividingBy: 1)
            pulse = max(0, 1 - phase / 0.6)
        }
        context.opacity = wait
        let grow = 3 + 3 * pulse
        let rect = CGRect(x: x - 1, y: -grow / 2, width: 2, height: height + grow)
        var glow = context
        glow.addFilter(.shadow(color: played.opacity(0.55 + 0.4 * pulse), radius: 4 + 3 * pulse))
        glow.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color((scheme == .dark ? Color.white : palette.ink).opacity(0.85 + 0.15 * pulse)))
    }

    /// The region loop as a honey band over the bars, with a line at each end.
    private func drawLoop(_ context: inout GraphicsContext, size: CGSize, from: Double, span: Double, now: Double? = nil) {
        guard let loop, span > 0 else { return }
        // An end outside the close-up stops the band at the waveform's edge.
        let a = max(-1, (loop.start - from) / span * size.width)
        let b = min(size.width + 1, ((loop.end ?? max(loop.start, now ?? loop.start)) - from) / span * size.width)
        guard b >= -1, a <= size.width + 1 else { return }
        let band = CGRect(x: a, y: -4, width: max(0, b - a), height: size.height + 8)
        context.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(played.opacity(loop.end == nil ? 0.12 : 0.2)))
    }

    /// The rows of the lanes, from the top, in an area `height` points tall.
    private static func laneRects(_ count: Int, width: CGFloat, height: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let lane = (height - laneGap * CGFloat(count - 1)) / CGFloat(count)
        return (0 ..< count).map { CGRect(x: 0, y: CGFloat($0) * (lane + laneGap), width: width, height: lane) }
    }

    /// One stem as mirrored bars in its lane, in the stem's colour where the song has played and grey where it hasn't.
    /// A muted stem stays grey, and a moment where the stem is silent is a thin line. The stem's name sits at the top
    /// left of the lane.
    private func drawLane(_ context: inout GraphicsContext, stem: Stem, values: [Float], in lane: CGRect, isPlayed: (Int) -> Bool) {
        let step = lane.width / CGFloat(max(1, values.count))
        let mid = lane.midY
        let isMuted = muted.contains(stem)
        let dark = scheme == .dark
        // The name sits on a capsule like a thin material, in the stem's colour: in the colour alone, the letters blurred
        // into loud bars of the same colour, in ink they lost the link to the lane's stem, and a plain translucent capsule
        // almost disappeared on paper.
        let name = context.resolve(Text(stem.name).font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(isMuted ? palette.ink.opacity(0.45) : stem.color(scheme)))
        let size = name.measure(in: CGSize(width: 200, height: 20))
        let origin = CGPoint(x: lane.minX + 4, y: lane.minY + 1)
        let plate = CGRect(x: origin.x - 3, y: origin.y - 0.5, width: size.width + 6, height: size.height + 1)
        let capsule = Path(roundedRect: plate, cornerRadius: plate.height / 2)

        context.fill(Path(roundedRect: lane, cornerRadius: 3), with: .color(palette.ink.opacity(0.035)))
        func drawBars(_ context: inout GraphicsContext) {
            for (i, value) in values.enumerated() {
                let x = lane.minX + CGFloat(i) * step + (step - Self.barWidth) / 2
                let color = isMuted ? palette.ink.opacity(isPlayed(i) ? 0.3 : 0.14) : isPlayed(i) ? stem.color(scheme) : unplayed
                guard value > 0.02 else {
                    context.fill(Path(CGRect(x: x, y: mid - 0.5, width: Self.barWidth, height: 1)), with: .color(color.opacity(0.6)))
                    continue
                }
                let h = max(1.5, CGFloat(value) * (lane.height - 3))
                context.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: Self.barWidth, height: h), cornerRadius: 1), with: .color(color))
            }
        }
        // Like an ultra thin material: the bars stay sharp around the capsule and blur under it.
        var outside = context
        outside.clip(to: capsule, options: .inverse)
        drawBars(&outside)
        var inside = context
        inside.clip(to: capsule)
        inside.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.5))
            drawBars(&layer)
        }
        context.fill(capsule, with: .color(dark ? Color.black.opacity(0.34) : Color.white.opacity(0.5)))
        context.stroke(capsule, with: .color(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)), lineWidth: 0.5)
        context.draw(name, at: origin, anchor: .topLeading)
    }

    /// Every picked stem in a lane of its own, over the whole song.
    private func lanesView(_ rows: [(Stem, [Float])], fraction: Double, seconds: Double, pulse: Double = 1) -> some View {
        Canvas { context, size in
            let lanes = Self.laneRects(rows.count, width: size.width, height: size.height)
            for ((stem, values), lane) in zip(rows, lanes) {
                let head = fraction * Double(values.count)
                drawLane(&context, stem: stem, values: values, in: lane) { Double($0) + 0.5 <= head }
            }
            drawLoop(&context, size: size, from: 0, span: duration, now: seconds)
            drawHead(&context, x: fraction * size.width, height: size.height, seconds: seconds, pulse: pulse)
        }
        .frame(height: mainHeight)
    }

    /// The stems that can get a lane, as chips in their colours, filled for the ones shown. Names fit in the key
    /// column, and a narrower waveform shows the stems' symbols.
    private var laneChips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(names: true)
            chipRow(names: false)
        }
        .frame(width: width)
    }

    private func chipRow(names: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(Stem.shown, id: \.self) { stem in
                let on = laneStems.contains(stem)
                Button { toggleLane(stem) } label: {
                    Group {
                        if names {
                            Text(stem.name).font(.system(size: 10.5, weight: .bold, design: .rounded))
                        } else {
                            Image(systemName: stem.symbol).font(.system(size: 9.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(on ? stem.color(scheme) : palette.muted)
                    .padding(.horizontal, names ? 8 : 7)
                    .frame(height: 18)
                    .background(Capsule().fill(stem.color(scheme, opacity: on ? 0.18 : 0)))
                    .overlay(Capsule().strokeBorder(on ? stem.color(scheme, opacity: 0.55) : palette.ink.opacity(0.14), lineWidth: 1))
                    .contentShape(Capsule())
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(on ? "Hide the \(stem.name.lowercased()) lane" : "Show the \(stem.name.lowercased()) lane")
            }
        }
    }

    @ViewBuilder private var loopFlags: some View {
        if let loop {
            TimelineView(.animation(minimumInterval: step, paused: !ticking || renderingPreview)) { context in
                let seconds = dragged.map { $0 * duration } ?? actions.scrub.map { $0 * duration } ?? track.position(at: context.date) ?? 0
                LoopFlags(loop: loop, from: zoomed ? closeUpStart(seconds, at: context.date) : 0, span: zoomed ? span : duration, width: width,
                          height: mainHeight, now: seconds, duration: duration, beat: bpm.map { 60 / $0 },
                          color: played, palette: palette, set: setLoop, typing: typing, hoveredEnd: hoveredEnd)
            }
        }
    }

    /// The seconds that the close-up spans: the song divided by the zoom, and never under 4 seconds.
    private var span: Double { max(4, duration / zoom) }

    /// The seconds in which the playhead moves a pixel, so the waveform draws only when something on it moved: for a
    /// song of 4 minutes, about 4 times a second instead of 60, and more often in a close-up.
    /// Where the song shows: on its way to the place of a seek that waits for the stems, or where the player has it.
    private func shownSeconds(at date: Date) -> Double {
        actions.seekWait?.seconds(at: date, reduceMotion: reduceMotion) ?? track.position(at: date) ?? 0
    }

    private var step: Double {
        let pixels = Double(width * max(1, displayScale))
        return min(0.5, max(1.0 / 60, (zoomed ? span : duration) / max(1, pixels)))
    }

    /// The region loop that the close-up holds still, centred, while the song plays inside it: a loop that fits in the
    /// close-up. The song's place decides it, not a drag, so the close-up stays still under the pointer during a drag.
    private func heldLoop(at date: Date) -> (start: Double, end: Double)? {
        guard zoomed, let loop, let end = loop.end, end - loop.start <= span * 0.9, let now = track.position(at: date),
              now >= loop.start - 0.05, now <= end + 0.3 else { return nil }
        return (loop.start, end)
    }

    /// Where the close-up starts: the playhead in the middle, or the region loop in the middle while it is held.
    private func closeUpStart(_ seconds: Double, at date: Date) -> Double {
        heldLoop(at: date).map { ($0.start + $0.end) / 2 - span / 2 } ?? seconds - span / 2
    }

    /// The moments around the playhead, which scroll past it while it stays in the middle: the whole song as bars, or
    /// each picked stem in its lane.
    private func closeUp(seconds: Double, from: Double, count: Int, ranges: [Stem: (low: Float, high: Float)], pulse: Double = 1) -> some View {
        let rows: [(Stem?, [Float])] = shownLanes.isEmpty ? [(nil, waveform.bars(count, from: from, to: from + span))]
            : shownLanes.map { ($0, waveform.bars(count, from: from, to: from + span, stem: $0, range: ranges[$0])) }
        return Canvas { context, size in
            let bars = WaveformBars.starts(loop: loop, bpm: bpm, closeUp: from ... from + span)
            if let beat = WaveformBars.beat(loop: loop, bpm: bpm) {
                // Faint lines a beat apart, counted from the start of the region loop, or from the song's start, as the
                // bars are.
                let anchor = WaveformBars.anchor(loop)
                var t = anchor + ((from - anchor) / beat).rounded(.up) * beat
                while t < from + span {
                    let x = (t - from) / span * size.width
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(palette.ink.opacity(0.1)))
                    t += beat
                }
                // The bars that the number keys go to start on a stronger line.
                for start in bars where start >= from && start < from + span {
                    let x = (start - from) / span * size.width
                    context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(palette.ink.opacity(0.22)))
                }
            }
            let time = { (i: Int, n: Int) in from + span * (Double(i) + 0.5) / Double(n) }
            if let (_, values) = rows.first, rows.first?.0 == nil {
                let step = size.width / CGFloat(max(1, values.count))
                let mid = size.height / 2
                for (i, value) in values.enumerated() {
                    let x = CGFloat(i) * step + (step - Self.barWidth) / 2
                    let t = time(i, values.count)
                    guard t >= 0, t <= duration else { continue }
                    if value < 0 {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: mid - 0.9, width: 1.8, height: 1.8)), with: .color(palette.ink.opacity(0.3)))
                        continue
                    }
                    let h = max(1.5, CGFloat(value) * (size.height - 2))
                    context.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: Self.barWidth, height: h), cornerRadius: 1),
                                 with: .color(t <= seconds ? played : unplayed))
                }
            } else {
                let lanes = Self.laneRects(rows.count, width: size.width, height: size.height)
                for ((stem, values), lane) in zip(rows, lanes) {
                    guard let stem else { continue }
                    // Moments before the song's start or after its end stay empty.
                    let shown = values.enumerated().map { i, value in (0 ... duration).contains(time(i, values.count)) ? value : 0 }
                    drawLane(&context, stem: stem, values: shown, in: lane) { time($0, values.count) <= seconds }
                }
            }
            drawLoop(&context, size: size, from: from, span: span, now: seconds)
            if showsBarKeys { drawBarKeys(&context, bars: bars, from: from, size: size) }
            drawHead(&context, x: (seconds - from) / span * size.width, height: size.height, seconds: seconds, pulse: pulse)
        }
        .frame(height: mainHeight)
        .background(palette.ink.opacity(shownLanes.isEmpty ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The number key of each bar, in a keycap at the top of its line, while the pointer is over the waveform. Bars
    /// closer together than a keycap get none, since the keycaps would cover each other.
    private func drawBarKeys(_ context: inout GraphicsContext, bars: [Double], from: Double, size: CGSize) {
        guard bars.count < 2 || (bars[1] - bars[0]) / span * size.width >= 14 else { return }
        for (index, start) in bars.prefix(9).enumerated() where start >= from && start < from + span {
            let x = (start - from) / span * size.width
            let cap = CGRect(x: x + 2, y: 2, width: 11, height: 11)
            let shape = Path(roundedRect: cap, cornerRadius: 3)
            context.fill(shape, with: .color(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)))
            context.stroke(shape, with: .color(palette.ink.opacity(0.3)), lineWidth: 0.5)
            context.draw(Text("\(index + 1)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(palette.ink.opacity(0.8)),
                         at: CGPoint(x: cap.midX, y: cap.midY))
        }
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
    private func window(from: Double) -> some View {
        GeometryReader { geo in
            let w = max(6, geo.size.width * span / max(duration, 0.001))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(palette.ink.opacity(0.7), lineWidth: 1.2)
                .frame(width: w, height: geo.size.height + 4)
                .offset(x: (from + span / 2) / max(duration, 0.001) * geo.size.width - w / 2, y: -2)
        }
        .allowsHitTesting(false)
    }

    /// A press seeks. On the whole song a drag moves the place under the pointer; on the close-up it pulls the song
    /// under the playhead like a tape, and a click without a drag moves the song to the moment clicked. The lanes
    /// move the song the same way as the waveform of the whole song.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                HUDPanel.controlTracksDrag = true
                if let held = heldLoop(at: Date()), value.startLocation.y < mainHeight {
                    // A held close-up stays still, so the song moves to the moment under the pointer.
                    let from = (held.start + held.end) / 2 - span / 2
                    dragged = min(1, max(0, (from + Double(value.location.x / width) * span) / duration))
                } else if zoomed, value.startLocation.y < mainHeight {
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
                if zoomed, value.startLocation.y < mainHeight, abs(value.translation.width) < 3, let now = track.position(at: Date()) {
                    target = min(1, max(0, (closeUpStart(now, at: Date()) + Double(value.location.x / width) * span) / duration))
                    dragged = target
                }
                tapeStart = nil
                actions.seek(target)
                // The waveform holds the place until the player reports the move.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dragged = nil }
            }
    }
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
    var loop: LoopRegion?
    var setLoop: (LoopEnd, Double) -> Void = { _, _ in }
    var typing: (Bool) -> Void = { _ in }
    let palette: Palette

    var body: some View {
        if let waveform = wave.waveform, let track {
            WaveformView(waveform: waveform, track: track, style: style, width: width, height: height, ticking: ticking, bpm: bpm,
                         zoom: wave.zoom, lanes: wave.lanes, separating: wave.lanesSeparating, laneStems: wave.laneStems,
                         toggleLane: { [wave] in wave.toggleLane($0) },
                         muted: muted, loop: loop, setLoop: setLoop, typing: typing,
                         hovered: { [wave] inside in if wave.hovered != inside { wave.hovered = inside } },
                         hoveredEnd: { [wave] end in if wave.loopEnd != end { wave.loopEnd = end } }, showsBarKeys: wave.hovered, palette: palette)
        } else {
            // The place stays while the waveform is read, so the key row doesn't move when it arrives.
            Color.clear.frame(width: width, height: height)
        }
    }
}

/// The bars of the waveform, four beats each, whose first 9 the keys 1 to 9 go to. While a region loop is set, the
/// whole loop is split into equal bars: as many as the song's tempo fits in it, rounded, so the last bar ends on the
/// loop's end. Otherwise they are the bars that start in the close-up, counted from the song's
/// start like its beat lines, and there are none while the whole song shows.
enum WaveformBars {
    static func starts(loop: LoopRegion?, bpm: Double?, closeUp: ClosedRange<Double>?) -> [Double] {
        guard let beat = beat(loop: loop, bpm: bpm) else { return [] }
        let bar = Double(Score.beatsPerBar) * beat
        if let loop, let end = loop.end {
            return Array(stride(from: loop.start, to: end - beat / 2, by: bar).prefix(64))
        }
        guard let closeUp else { return [] }
        let first = (max(0, closeUp.lowerBound) / bar).rounded(.up) * bar
        return Array(stride(from: first, to: closeUp.upperBound, by: bar).prefix(64))
    }

    /// The beat of the beat lines: the song's, or the one that fills the region loop with a whole number of bars.
    static func beat(loop: LoopRegion?, bpm: Double?) -> Double? {
        guard let bpm, bpm > 0 else { return nil }
        let beat = 60 / bpm
        guard let loop, let end = loop.end, end > loop.start else { return beat }
        let bar = Double(Score.beatsPerBar) * beat
        let bars = max(1, ((end - loop.start) / bar).rounded())
        return (end - loop.start) / (bars * Double(Score.beatsPerBar))
    }

    /// Where the beat lines of the close-up are counted from: the start of the region loop, or the song's start.
    static func anchor(_ loop: LoopRegion?) -> Double { loop?.end == nil ? 0 : loop?.start ?? 0 }
}

/// The ends of the region loop on the waveform: a line at each end, with an A tab on the left of the start's line and
/// a B tab on the right of the end's line. The pointer over a tab turns it into ‹ › arrows on both sides of its line,
/// which nudge the end on a click, as ← and → do while the pointer is there, and a drag on an arrow moves the end
/// freely. The time of the end shows under its line while the pointer is over it, after a nudge and during a drag,
/// and a click on the time lets it be typed.
struct LoopFlags: View {
    let loop: LoopRegion
    let from: Double
    let span: Double
    let width: CGFloat
    let height: CGFloat
    /// Where the song is, which the end of a loop that has no end yet follows.
    let now: Double
    let duration: Double
    /// The length of a beat, for ⌥ with the arrows.
    let beat: Double?
    let color: Color
    let palette: Palette
    let set: (LoopEnd, Double) -> Void
    let typing: (Bool) -> Void
    var hoveredEnd: (LoopEnd?) -> Void = { _ in }

    @Environment(\.recordActions) private var actions
    @Environment(\.colorScheme) private var scheme
    /// The parts under the pointer (the tab, the strip along the line, the time), so that moving from one part of an
    /// end to another keeps it open whatever order the two hover events come in.
    @State private var hoveredParts: Set<String> = LoopFlags.hoveredInRenders.map { ["\($0)-tab"] } ?? []
    /// An end open in `--render`, which has no pointer.
    nonisolated(unsafe) static var hoveredInRenders: LoopEnd?
    private var hovered: LoopEnd? {
        hoveredParts.contains { $0.hasPrefix("\(LoopEnd.start)") } ? .start : hoveredParts.isEmpty ? nil : .end
    }
    @State private var dragged: (end: LoopEnd, start: Double, time: Double)?
    @State private var lingering: LoopEnd?
    @State private var nudged: (end: LoopEnd, at: Date)?
    @State private var editing: LoopEnd?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            end(.start, time: dragged?.end == .start ? dragged!.time : loop.start, press: loop.startPress)
            if let end = loop.end {
                self.end(.end, time: dragged?.end == .end ? dragged!.time : end, press: loop.endPress)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onChange(of: hovered) { _, end in hoveredEnd(end) }
        .onDisappear { hoveredEnd(nil) }
    }

    private func x(_ time: Double) -> CGFloat { CGFloat((time - from) / max(span, 0.001)) * width }

    @ViewBuilder private func end(_ end: LoopEnd, time: Double, press: Double?) -> some View {
        let x = x(time)
        if x > -20, x < width + 20 {
            // The dashed line where R was pressed, which shows how far the end moved when it snapped.
            if let press, abs(press - time) > 0.005 {
                Path { $0.move(to: CGPoint(x: self.x(press), y: 0)); $0.addLine(to: CGPoint(x: self.x(press), y: height)) }
                    .stroke(palette.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            let active = hovered == end || dragged?.end == end
            Rectangle().fill(color)
                .frame(width: active ? 2.5 : 1.5, height: height + 4)
                .offset(x: x - (active ? 1.25 : 0.75), y: -2)
                .shadow(color: color.opacity(active ? 0.7 : 0), radius: 3)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: active)
            // A strip along the line that takes the pointer: a drag moves the end, and a click moves the song there.
            Color.clear
                .frame(width: 10, height: height + 4)
                .contentShape(Rectangle())
                .offset(x: x - 5, y: -2)
                .onHover { hover(end, "line", $0) }
                .gesture(move(end, time: time, direction: nil))
                .pointerStyle(.columnResize)
            // The A tab ends at its line and the B tab starts at its line; the arrows sit on both sides of the line.
            handle(end, time: time)
                .offset(x: x - (hovered == end || dragged?.end == end ? 17 : end == .start ? 13 : 21), y: -14)
            // The time sits inside the bottom of the waveform, under the line, so it covers no other part of the HUD.
            // Outside the band: left of A's line and right of B's, so it covers neither the loop nor the playhead in it.
            if showsTime(end) {
                timeLabel(end, time: time)
                    .offset(x: min(max(end == .start ? x - 64 : x + 4, 0), width - 60), y: height - 15)
                    .transition(.opacity)
            }
        }
    }

    private func showsTime(_ end: LoopEnd) -> Bool {
        hovered == end || lingering == end || dragged?.end == end || editing == end || (nudged.map { $0.end == end && Date().timeIntervalSince($0.at) < 1.5 } ?? false)
    }

    /// The A or B tab, or the arrows that take its place while the pointer is over it. The tab sits outside the
    /// region, beside its line; the arrows sit on both sides of the line.
    private func handle(_ end: LoopEnd, time: Double) -> some View {
        let open = hovered == end || dragged?.end == end
        return HStack(spacing: 0) {
            if open {
                arrow(end, -1, time: time)
                Color.clear.frame(width: 6)
                arrow(end, 1, time: time)
            } else {
                if end == .end { Color.clear.frame(width: 21) }
                Text(end == .start ? "A" : "B")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.11, blue: 0.03))
                    .frame(width: 13, height: 12)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 3.5, bottomLeadingRadius: end == .start ? 3.5 : 0,
                                                       bottomTrailingRadius: end == .end ? 3.5 : 0, topTrailingRadius: 3.5).fill(color))
                if end == .start { Color.clear.frame(width: 21) }
            }
        }
        .frame(width: 34, height: 12)
        .contentShape(Rectangle())
        .onHover { hover(end, "tab", $0) }
        .animation(.easeOut(duration: 0.12), value: open)
    }

    /// The time stays a moment after the pointer leaves the end, so that it can be reached from the tab to type a time.
    private func hover(_ end: LoopEnd, _ part: String, _ inside: Bool) {
        if inside {
            hoveredParts.insert("\(end)-\(part)")
            if lingering == end { lingering = nil }
            return
        }
        hoveredParts.remove("\(end)-\(part)")
        guard !hoveredParts.contains(where: { $0.hasPrefix("\(end)") }) else { return }
        lingering = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if lingering == end, hovered != end { lingering = nil }
        }
    }

    /// A press nudges the end, and a drag moves it with the pointer.
    private func arrow(_ end: LoopEnd, _ direction: Double, time: Double) -> some View {
        Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(Color(red: 0.18, green: 0.11, blue: 0.03))
            .frame(width: 14, height: 12)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(color))
            .contentShape(Rectangle())
            // The arrow pointer, as on a button: a click nudges, and the drag that also works is the strip's job.
            .gesture(move(end, time: time, direction: direction))
            .help("Move \(end == .start ? "A" : "B") \(Int(LoopRegion.nudge * 1000)) ms \(direction < 0 ? "earlier" : "later"), or a beat with ⌥ (\(direction < 0 ? "←" : "→"))")
    }

    /// A drag moves the end with the pointer. A click without a drag nudges it on an arrow (`direction`), or moves the
    /// song to the end on the strip along its line.
    private func move(_ end: LoopEnd, time: Double, direction: Double?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                HUDPanel.controlTracksDrag = true
                guard abs(value.translation.width) > 2 || dragged != nil else { return }
                let start = dragged?.start ?? time
                dragged = (end, start, clamp(end, start + Double(value.translation.width / width) * span))
            }
            .onEnded { _ in
                HUDPanel.controlTracksDrag = false
                if let dragged {
                    set(end, dragged.time)
                    self.dragged = nil
                    nudged = (end, Date())
                } else if let direction {
                    let step = NSEvent.modifierFlags.contains(.option) ? (beat ?? 0.5) : LoopRegion.nudge
                    set(end, clamp(end, time + direction * step))
                    nudged = (end, Date())
                } else if actions.seekable {
                    actions.seek(min(1, max(0, time / max(duration, 0.001))))
                }
            }
    }

    private func clamp(_ end: LoopEnd, _ time: Double) -> Double { loop.clamped(end, time, duration: duration) }

    /// The time under the line, which turns into a field for typing a time on a click.
    @ViewBuilder private func timeLabel(_ end: LoopEnd, time: Double) -> some View {
        Group {
            if editing == end {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { commit(end) }
                    .onExitCommand { stopEditing() }
                    .onAppear {
                        text = Self.format(time)
                        focused = true
                    }
            } else {
                // The digits roll on a nudge, which moves the line too little to see on the whole song.
                Text(Self.format(time))
                    .contentTransition(.numericText(value: time))
                    .animation(dragged == nil ? .snappy(duration: 0.2) : nil, value: time)
                    .onTapGesture {
                        editing = end
                        typing(true)
                    }
            }
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(palette.ink)
        .frame(width: 60, height: 15)
        .background(Capsule().fill(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97)))
        .overlay(Capsule().strokeBorder(color.opacity(editing == end ? 0.9 : 0.45), lineWidth: 1))
        .onHover { hover(end, "time", $0) }
        .help("Type a time for \(end == .start ? "A" : "B")")
    }

    private func commit(_ end: LoopEnd) {
        if let seconds = Self.parse(text) { set(end, clamp(end, seconds)) }
        stopEditing()
    }

    private func stopEditing() {
        editing = nil
        focused = false
        typing(false)
    }

    /// `1:42.35`: minutes, seconds and hundredths.
    static func format(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        return String(format: "%d:%05.2f", minutes, total - Double(minutes * 60))
    }

    /// Reads `1:42.35`, `102.35` or `1:42`, with a comma as the decimal mark as well.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (1 ... 2).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers.count == 2 ? numbers[0] * 60 + numbers[1] : numbers[0]
    }
}

/// The pill over the waveform while ⌥W waits for the stems of the whole song: a ring that fills with the share
/// separated, and the percent.
private struct LanesSeparating: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(palette.ink.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: fraction)
            }
            .frame(width: 10, height: 10)
            Text(String(format: "Separating %.0f%%", fraction * 100)).monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .background(Capsule().fill(palette.ink.opacity(0.07)))
    }
}
