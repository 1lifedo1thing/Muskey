import SwiftUI

/// The HUD's view of a recording from the microphone while it records.
struct MicState: Equatable {
    var analysis: RecordingAnalysis
    var seconds: Double = 0
    var key: DetectedKey?
    /// Stop was pressed, and the song file is being written.
    var finishing = false
    /// The microphone didn't start.
    var failed = false
    var hotkey = ""
    /// The microphone that records.
    var device = ""
    /// The microphone picked in Settings that wasn't there or didn't start, while the default one records instead.
    var tried: String?

    /// The kind of the last part that the classifier has heard, nil before its first window.
    var current: SoundKind? {
        guard let last = analysis.music.lastIndex(where: { $0 >= 0 }) else { return nil }
        return analysis.kind(at: last)
    }

    var heardMusic: Bool { analysis.included().contains(true) }

    /// The level of the last quarter second, from 0 to 1.
    var level: Double {
        guard let last = analysis.levels.last else { return 0 }
        return Double(min(1, max(0, (last + 60) / 60)))
    }

    /// For the menu bar: what the recording hears now.
    var status: String { current.map(\.title) ?? "Waiting" }
}

extension SoundKind {
    var title: String {
        switch self {
        case .music: "Music"
        case .speech: "Speech"
        case .noise: "Noise"
        case .silence: "Silence"
        }
    }

    func color(_ palette: Palette, _ scheme: ColorScheme) -> Color {
        switch self {
        case .music: StripColors.solid(.honey, scheme).fill
        case .speech: StripColors.solid(.blue, scheme).fill
        case .noise: palette.ink.opacity(0.38)
        case .silence: palette.ink.opacity(0.16)
        }
    }
}

/// The HUD while the microphone records: a red orb that glows with the level, what is heard now, the key of the music
/// so far, the recording with its parts coloured by kind and the music used for the key behind them, the sensitivity of
/// each kind, and Stop.
struct MicCard: View {
    let mic: MicState
    let palette: Palette
    let stop: () -> Void
    let edit: (RecordingAnalysis) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                MicOrb(level: mic.level, music: mic.current == .music)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Recording")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(palette.ink)
                            .fixedSize()
                        Text(Self.time(mic.seconds))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.muted)
                            .contentTransition(.numericText(value: mic.seconds))
                        KindPill(kind: mic.current, palette: palette)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    }
                    keyLine
                }
                Spacer(minLength: 12)
                if mic.finishing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finishing")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.muted)
                } else {
                    HUDButton(title: mic.failed ? "Close" : "Stop", symbol: mic.failed ? "xmark" : "stop.fill", palette: palette, small: true, action: stop)
                        .help(mic.failed ? "Close" : "Stop recording and play it back (\(mic.hotkey))")
                }
            }
            deviceLine
                .padding(.top, -6)
            RecordingStrip(analysis: mic.analysis, bars: true, minimumDuration: 30, palette: palette, edit: edit)
                .frame(height: 64)
            SensitivityRow(sensitivity: mic.analysis.sensitivity, palette: palette) { sensitivity in
                var analysis = mic.analysis
                analysis.sensitivity = sensitivity
                edit(analysis)
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
        .frame(width: 560)
        .animation(.snappy(duration: 0.2), value: mic.current)
        .animation(.snappy(duration: 0.2), value: mic.finishing)
    }

    @ViewBuilder private var keyLine: some View {
        if let key = mic.key {
            Accidental.text(key.name, color: palette.ink)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
                .opacity(mic.heardMusic ? 1 : 0.5)
        } else {
            Text(mic.heardMusic ? "Finding the key" : "Waiting for music")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted)
        }
    }

    /// The microphone that records, or the picked one that didn't, in red, with the one that records in its place.
    @ViewBuilder private var deviceLine: some View {
        if mic.failed {
            HStack(spacing: 5) {
                Image(systemName: "mic.slash.fill").font(.system(size: 9, weight: .bold))
                Text("No microphone input")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(StripColors.text(.red, scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StripColors.tint(.red, strong: false, scheme)))
            .fixedSize()
        } else if let tried = mic.tried {
            HStack(spacing: 5) {
                Image(systemName: "mic.slash.fill").font(.system(size: 9, weight: .bold))
                Text("\(tried) unavailable")
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                Text(mic.device)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(StripColors.text(.red, scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StripColors.tint(.red, strong: false, scheme)))
            .help("\(tried) isn't connected or didn't start, so \(mic.device) records")
            .fixedSize()
        } else if !mic.device.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill").font(.system(size: 9, weight: .semibold))
                Text(mic.device)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(palette.muted)
        }
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// What the recording hears now, in the colour of its parts on the strip.
private struct KindPill: View {
    let kind: SoundKind?
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = kind?.color(palette, scheme) ?? palette.ink.opacity(0.3)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(kind?.title ?? "Listening")
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.ink.opacity(0.08)))
        .fixedSize()
    }
}

/// A red orb that glows brighter with the level, and fuller while music plays.
private struct MicOrb: View {
    let level: Double
    let music: Bool
    private static let red = Color(red: 0.93, green: 0.26, blue: 0.24)

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Self.red.opacity(0.55), Self.red.opacity(0)], center: .center, startRadius: 8, endRadius: 30))
                .scaleEffect(1 + level * 0.35)
                .opacity(0.35 + level * 0.65)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.5), Self.red], center: UnitPoint(x: 0.38, y: 0.32), startRadius: 1, endRadius: 16))
                .frame(width: 26, height: 26)
                .shadow(color: Self.red.opacity(music ? 0.7 : 0.35), radius: 6 + level * 8)
        }
        .frame(width: 52, height: 52)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeOut(duration: 0.3), value: music)
        .accessibilityLabel("Recording")
    }
}

/// The parts of a recording along its time: each quarter second in the colour of its kind, as a bar as tall as its
/// level when `bars`, and the parts used for the key behind them, with an edge at each end. A click on a part used for
/// the key leaves it out, a click on another part adds it, and a drag of an edge moves it.
struct RecordingStrip: View {
    let analysis: RecordingAnalysis
    var bars = false
    /// The strip spans at least this many seconds, so a recording that just started fills it from the left.
    var minimumDuration: Double = 0
    let palette: Palette
    let edit: (RecordingAnalysis) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var dragged: (region: ClosedRange<Double>, start: Bool, to: Double)?
    @State private var hovered: Double?

    private static let edgeReach: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = max(analysis.duration, minimumDuration, RecordingAnalysis.cell)
            let regions = shownRegions
            Canvas { context, size in
                let x = { (time: Double) in CGFloat(time / span) * size.width }
                let honey = StripColors.solid(.honey, scheme).fill
                for region in regions {
                    let rect = CGRect(x: x(region.lowerBound), y: 0, width: max(2, x(region.upperBound) - x(region.lowerBound)), height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(honey.opacity(scheme == .dark ? 0.22 : 0.2)))
                }
                let kinds = analysis.kinds()
                if bars {
                    // Bars 2 points wide every 3 points, each as tall as the loudest quarter second under it.
                    let columns = max(1, Int(size.width / 3))
                    // Under a quarter second a column early on, when some columns get no quarter second of their own.
                    let cellsPerColumn = span / RecordingAnalysis.cell / Double(columns)
                    for column in 0 ..< columns {
                        let first = Int(Double(column) * cellsPerColumn), last = min(kinds.count, Int(Double(column + 1) * cellsPerColumn))
                        guard first < last else { continue }
                        var loudest = first
                        for i in first ..< last where analysis.levels[i] > analysis.levels[loudest] { loudest = i }
                        let level = CGFloat(min(1, max(0, (analysis.levels[loudest] + 60) / 60)))
                        let height = max(2, level * (size.height - 6))
                        let rect = CGRect(x: CGFloat(column) * 3, y: (size.height - height) / 2, width: 2, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(kinds[loudest].color(palette, scheme)))
                    }
                } else {
                    for segment in analysis.segments() {
                        let rect = CGRect(x: x(segment.start), y: size.height / 2 - 2, width: max(1, x(segment.end) - x(segment.start)), height: 4)
                        context.fill(Path(rect), with: .color(segment.kind.color(palette, scheme)))
                    }
                }
                // An edge at each end of the parts used for the key.
                for region in regions {
                    for edge in [region.lowerBound, region.upperBound] {
                        let rect = CGRect(x: x(edge) - 1.5, y: 2, width: 3, height: size.height - 4)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(honey))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = Double(value.location.x / max(width, 1)) * span
                    if dragged == nil, value.translation == .zero || abs(value.translation.width) < 3 {
                        guard let edge = edge(at: value.startLocation.x, width: width, span: span) else { return }
                        dragged = (edge.region, edge.start, time)
                    } else if let current = dragged {
                        dragged = (current.region, current.start, time)
                    }
                }
                .onEnded { value in
                    var changed = analysis
                    if let dragged, abs(value.translation.width) >= 3 {
                        changed.moveEdge(of: dragged.region, start: dragged.start, to: dragged.to)
                    } else {
                        changed.toggle(at: Double(value.location.x / max(width, 1)) * span)
                    }
                    dragged = nil
                    edit(changed)
                })
            .onContinuousHover { phase in
                if case let .active(point) = phase { hovered = Double(point.x / max(width, 1)) * span } else { hovered = nil }
            }
            .help(hovered.map { time in analysis.regions().contains { $0.contains(time) } }.map {
                $0 ? "Leave this part out of the key (click), move its edges (drag)" : "Use this part for the key (click)"
            } ?? "")
        }
    }

    /// The parts used for the key, with the edge that is being dragged where the pointer has it.
    private var shownRegions: [ClosedRange<Double>] {
        var regions = analysis.regions()
        if let dragged, let index = regions.firstIndex(of: dragged.region) {
            let region = dragged.region
            regions[index] = dragged.start ? min(dragged.to, region.upperBound - RecordingAnalysis.cell) ... region.upperBound
                : region.lowerBound ... max(dragged.to, region.lowerBound + RecordingAnalysis.cell)
        }
        return regions
    }

    private func edge(at x: CGFloat, width: CGFloat, span: Double) -> (region: ClosedRange<Double>, start: Bool)? {
        let position = { (time: Double) in CGFloat(time / span) * width }
        for region in analysis.regions() {
            if abs(position(region.lowerBound) - x) <= Self.edgeReach { return (region, true) }
            if abs(position(region.upperBound) - x) <= Self.edgeReach { return (region, false) }
        }
        return nil
    }
}

/// How readily silence, noise and speech are heard, with a dot of each kind's colour, which the strip uses too.
struct SensitivityRow: View {
    let sensitivity: RecordingSensitivity
    let palette: Palette
    /// The word Sensitivity before the sliders, where the row has the width for it.
    var titled = true
    let set: (RecordingSensitivity) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            if titled {
                Text("Sensitivity")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .fixedSize()
            }
            slider("Silence", .silence, \.silence)
            slider("Noise", .noise, \.noise)
            slider("Speech", .speech, \.speech)
        }
    }

    private func slider(_ title: String, _ kind: SoundKind, _ path: WritableKeyPath<RecordingSensitivity, Double>) -> some View {
        HStack(spacing: 6) {
            Circle().fill(kind.color(palette, scheme)).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.ink)
                .fixedSize()
            Slider(value: Binding(get: { sensitivity[keyPath: path] }, set: { value in
                var changed = sensitivity
                changed[keyPath: path] = value
                set(changed)
            }), in: 0 ... 1)
                .controlSize(.mini)
                .frame(width: 70)
        }
    }
}

extension RecordingAnalysis {
    /// A made-up recording for the renders: talk, then a song with a pause in it, then noise and silence.
    static func sample() -> RecordingAnalysis {
        var analysis = RecordingAnalysis(rate: 48000)
        for i in 0 ..< 216 {
            let t = Double(i) * RecordingAnalysis.cell
            let wobble = Float(sin(t * 7) * 4 + sin(t * 2.3) * 3)
            switch t {
            case ..<8: analysis.addCell(level: -30 + wobble); analysis.score(from: t, to: t + 0.25, music: 0.1, speech: 0.85, silence: 0)
            case ..<10: analysis.addCell(level: -58); analysis.score(from: t, to: t + 0.25, music: 0, speech: 0, silence: 0.9)
            case ..<44: analysis.addCell(level: -18 + wobble); analysis.score(from: t, to: t + 0.25, music: 0.92, speech: 0.2, silence: 0)
            case ..<49: analysis.addCell(level: -36 + wobble); analysis.score(from: t, to: t + 0.25, music: 0.25, speech: 0.1, silence: 0)
            default: analysis.addCell(level: -57); analysis.score(from: t, to: t + 0.25, music: 0, speech: 0, silence: 0.8)
            }
        }
        return analysis
    }

}
