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
    /// Moves an end of the region loop to a time, from its arrows, a drag or a typed time.
    var setLoop: (LoopEnd, Double) -> Void = { _, _ in }
    /// A time of the region loop is typed in, which turns off the keys over the HUD until the field closes.
    var typing: (Bool) -> Void = { _ in }
    /// The pointer moves over the waveform or leaves it, which shows its keys in place of the hints row.
    var hovered: (Bool) -> Void = { _ in }
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
        .onHover { hovered($0) }
        // A scroll over the waveform moves the song as one over the time bar does, and a press on it seeks instead of
        // dragging the HUD.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.scroll?.place(.waveform, at: $0, by: token) }
        .onDisappear {
            actions.scroll?.remove(by: token)
            hovered(false)
        }
        .gesture(drag, isEnabled: actions.seekable)
        .opacity(actions.seekable || !ticking ? 1 : 0.8)
        .help(actions.seekable ? "Move the song (drag, scroll, ⌘ scroll to zoom)" : "Seeking is off while instruments and vocals are separated as the song plays")
        // The ends of the region loop sit over the waveform's edges, outside the shape that takes its clicks and its
        // drag, so that their tabs, arrows and times get the pointer.
        .overlay(alignment: .topLeading) { loopFlags }
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
            drawLoop(&context, size: size, from: 0, span: duration, now: seconds)
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
    private func drawLoop(_ context: inout GraphicsContext, size: CGSize, from: Double, span: Double, now: Double? = nil) {
        guard let loop, span > 0 else { return }
        let a = (loop.start - from) / span * size.width
        let b = ((loop.end ?? max(loop.start, now ?? loop.start)) - from) / span * size.width
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
            drawLoop(&context, size: size, from: 0, span: duration, now: seconds)
            drawHead(&context, x: fraction * size.width, height: size.height, seconds: seconds)
        }
    }

    @ViewBuilder private var loopFlags: some View {
        if let loop {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !ticking || renderingPreview)) { context in
                let seconds = dragged.map { $0 * duration } ?? actions.scrub.map { $0 * duration } ?? track.position(at: context.date) ?? 0
                LoopFlags(loop: loop, from: zoomed ? seconds - span / 2 : 0, span: zoomed ? span : duration, width: width,
                          height: zoomed ? height - 12 : height, now: seconds, duration: duration, beat: bpm.map { 60 / $0 },
                          color: played, palette: palette, set: setLoop, typing: typing)
            }
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
            drawLoop(&context, size: size, from: from, span: span, now: seconds)
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
                         zoom: wave.zoom, lanes: wave.lanes, muted: muted, loop: loop, setLoop: setLoop, typing: typing,
                         hovered: { [wave] inside in if wave.hovered != inside { wave.hovered = inside } }, palette: palette)
        } else {
            // The place stays while the waveform is read, so the key row doesn't move when it arrives.
            Color.clear.frame(width: width, height: height)
        }
    }
}

/// The ends of the region loop on the waveform: a line at each end, with an A tab on the left of the start's line and
/// a B tab on the right of the end's line. The pointer over a tab turns it into ‹ › arrows on both sides of its line,
/// which nudge the end, and a drag on an arrow moves the end freely. The time of the end shows under its line while
/// the pointer is over it, after a nudge and during a drag, and a click on the time lets it be typed.
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
    @State private var nudged: (end: LoopEnd, at: Date)?
    @State private var editing: LoopEnd?
    @State private var text = ""
    @FocusState private var focused: Bool

    /// A click on an arrow moves the end by 10 ms, and by a beat with ⌥.
    static let nudge = 0.01

    var body: some View {
        ZStack(alignment: .topLeading) {
            end(.start, time: dragged?.end == .start ? dragged!.time : loop.start, press: loop.startPress)
            if let end = loop.end {
                self.end(.end, time: dragged?.end == .end ? dragged!.time : end, press: loop.endPress)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func x(_ time: Double) -> CGFloat { CGFloat((time - from) / max(span, 0.001)) * width }

    @ViewBuilder private func end(_ end: LoopEnd, time: Double, press: Double?) -> some View {
        let x = x(time)
        if x > -20, x < width + 20 {
            // The dashed line where R was pressed, which shows how far the end moved when it snapped.
            if let press, abs(press - time) > 0.005 {
                Path { $0.move(to: CGPoint(x: self.x(press), y: -5)); $0.addLine(to: CGPoint(x: self.x(press), y: height + 5)) }
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
            if showsTime(end) {
                timeLabel(end, time: time)
                    .offset(x: min(max(x - 30, 0), width - 60), y: height - 15)
                    .transition(.opacity)
            }
        }
    }

    private func showsTime(_ end: LoopEnd) -> Bool {
        hovered == end || dragged?.end == end || editing == end || (nudged.map { $0.end == end && Date().timeIntervalSince($0.at) < 1.5 } ?? false)
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

    private func hover(_ end: LoopEnd, _ part: String, _ inside: Bool) {
        if inside { hoveredParts.insert("\(end)-\(part)") } else { hoveredParts.remove("\(end)-\(part)") }
    }

    /// A press nudges the end, and a drag moves it with the pointer.
    private func arrow(_ end: LoopEnd, _ direction: Double, time: Double) -> some View {
        Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(Color(red: 0.18, green: 0.11, blue: 0.03))
            .frame(width: 14, height: 12)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(color))
            .contentShape(Rectangle())
            .gesture(move(end, time: time, direction: direction))
            .pointerStyle(.columnResize)
            .help("Nudge \(end == .start ? "A" : "B") by 10 ms, or a beat with ⌥ (drag to move it)")
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
                    let step = NSEvent.modifierFlags.contains(.option) ? (beat ?? 0.5) : Self.nudge
                    set(end, clamp(end, time + direction * step))
                    nudged = (end, Date())
                } else if actions.seekable {
                    actions.seek(min(1, max(0, time / max(duration, 0.001))))
                }
            }
    }

    /// The ends stay in the song, and at least a quarter of a second apart.
    private func clamp(_ end: LoopEnd, _ time: Double) -> Double {
        switch end {
        case .start: min(max(0, time), (loop.end ?? duration) - 0.25)
        case .end: max(min(duration, time), loop.start + 0.25)
        }
    }

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
                Text(Self.format(time))
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
