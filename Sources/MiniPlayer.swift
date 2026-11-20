import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// What the mini player can show besides the song: in the line under the song, or as a pill on the top or the bottom
/// of the record.
enum MiniElement: String, Codable, CaseIterable, Identifiable {
    case key, tempo, pitch, speed, loop, timeLeft, vocals, next

    var id: String { rawValue }

    var name: String {
        switch self {
        case .key: "Key"
        case .tempo: "Tempo"
        case .pitch: "Pitch change"
        case .speed: "Speed"
        case .loop: "Region loop"
        case .timeLeft: "Time left"
        case .vocals: "Vocals"
        case .next: "Next in queue"
        }
    }

    /// What the editor in Settings shows for the element, since the song in its preview has no live values.
    var sample: String {
        switch self {
        case .key: "G major"
        case .tempo: "124 BPM"
        case .pitch: "+2"
        case .speed: "90%"
        case .loop: "↻ 0:42–0:58"
        case .timeLeft: "−2:41"
        case .vocals: "Vocals off"
        case .next: "⏭ Glass Harbour"
        }
    }

    var hue: StripColors.Hue? {
        switch self {
        case .pitch, .loop: .honey
        case .speed: .blue
        case .vocals: .red
        default: nil
        }
    }
}

/// The three places for the elements: on the top of the record, on its bottom, and in the line under the song.
enum MiniPlace: String, Codable, CaseIterable {
    case top, bottom, line
}

/// Which parts of the song the mini player shows, and where its elements go.
struct MiniLayout: Codable, Equatable {
    var top: MiniElement?
    var bottom: MiniElement?
    var line: [MiniElement] = [.key, .tempo]
    var track = true
    var artist = true
    var album = true

    /// The line under the song stays short, so the player stays small.
    static let lineLimit = 3

    func place(of element: MiniElement) -> MiniPlace? {
        if top == element { return .top }
        if bottom == element { return .bottom }
        return line.contains(element) ? .line : nil
    }

    mutating func put(_ element: MiniElement, at place: MiniPlace) {
        remove(element)
        switch place {
        case .top: top = element
        case .bottom: bottom = element
        case .line: line = Array((line + [element]).suffix(Self.lineLimit))
        }
    }

    mutating func remove(_ element: MiniElement) {
        if top == element { top = nil }
        if bottom == element { bottom = nil }
        line.removeAll { $0 == element }
    }
}

/// The side of the record that the song goes on.
enum MiniTextSide: Equatable {
    case below, above, left, right

    /// The screen is cut in thirds each way. In a corner, the song goes along the long side of the screen, away from
    /// the edges: beside the record on a landscape screen, above or below it on a portrait or nearly square one. Near
    /// the bottom edge it goes above, and everywhere else below. A side without room for the song gives its place to
    /// the next one. `center` is the middle of the record, in points from the top left of the visible screen.
    static func choose(center: CGPoint, screen: CGSize, record: CGFloat, text: CGSize) -> MiniTextSide {
        let gap: CGFloat = 6
        let half = record / 2
        let fits: [MiniTextSide: Bool] = [
            .below: screen.height - (center.y + half) >= text.height + gap,
            .above: center.y - half >= text.height + gap,
            .right: screen.width - (center.x + half) >= text.width + gap,
            .left: center.x - half >= text.width + gap,
        ]
        let column = center.x < screen.width / 3 ? -1 : center.x > screen.width * 2 / 3 ? 1 : 0
        let row = center.y < screen.height / 3 ? -1 : center.y > screen.height * 2 / 3 ? 1 : 0
        let landscape = screen.width / max(1, screen.height) >= 1.4
        var order: [MiniTextSide]
        if column != 0, row != 0 {
            let side: MiniTextSide = column < 0 ? .right : .left
            let vertical: MiniTextSide = row < 0 ? .below : .above
            order = landscape ? [side, vertical] : [vertical, side]
        } else {
            order = row > 0 ? [.above] : [.below]
        }
        order += [.below, .above, column > 0 ? .left : .right, column > 0 ? .right : .left]
        return order.first { fits[$0] == true } ?? .below
    }
}

/// What the mini player shows that the HUD's model doesn't keep: the key of the song that plays, and where the song
/// goes around the record.
final class MiniState: ObservableObject {
    @Published var key: DetectedKey?
    @Published var side = MiniTextSide.below
    @Published var layout = Preferences.shared.miniLayout
    /// The size of the song's text, which decides which sides have room for it.
    var textSize = CGSize(width: 180, height: 60)
    /// The record and the text, in the coordinates of the panel from its top left, which take the pointer. The rest
    /// of the panel lets clicks through to the windows under it.
    var hitFrames: [String: CGRect] = [:]
    var onHide: () -> Void = {}
    var onShowHUD: () -> Void = {}
    var onSettings: () -> Void = {}
}

/// The floating mini player: the record, with the song beside it on the side that the screen has room for, and the
/// elements that Settings > Mini player places.
struct MiniPlayerView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var mini: MiniState
    /// The editor in Settings: sample values for every element, and the places drawn and taking drops.
    var editing = false
    var onDrop: (MiniElement, MiniPlace) -> Void = { _, _ in }
    var onRemove: (MiniElement) -> Void = { _ in }

    static let record: CGFloat = 132
    /// Room around the record for the pills on its rim.
    static let margin: CGFloat = 12
    static var box: CGFloat { record + margin * 2 }
    /// The widest that the song's text gets beside the record, and under or over it.
    static let sideWidth: CGFloat = 190
    static let stackWidth: CGFloat = 230
    static let textHeight: CGFloat = 70
    /// The panel has room for the text on every side, so the record stays where it is when the text moves.
    static var panelSize: CGSize { CGSize(width: box + (sideWidth + 6) * 2, height: box + (textHeight + 6) * 2) }

    @State private var target: MiniPlace?

    private var layout: MiniLayout { mini.layout }

    var body: some View {
        if editing {
            // Settings stacks the song under the record, with the places drawn.
            VStack(spacing: 2) {
                vinyl
                text
            }
            .frame(width: Self.stackWidth)
            .environment(\.colorScheme, .dark)
        } else {
            player
        }
    }

    private var player: some View {
        ZStack {
            vinyl
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mini.hitFrames["record"] = $0 }
            if hasText {
                text
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { mini.textSize = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mini.hitFrames["text"] = $0 }
                    .frame(width: textWidth, height: Self.textHeight, alignment: textAlignment)
                    .offset(textOffset)
                    .animation(.easeOut(duration: 0.15), value: mini.side)
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .environment(\.recordActions, RecordActions(playPause: { model.onPlayPause() }, skip: { model.onSkip($0) }, scroll: model.scroll, scrub: model.scrub,
                                                    seek: { model.onSeekFraction($0) }, seekable: model.seekable))
        .environment(\.recordPlaying, model.playing)
        .environment(\.recordRewinds, model.rewinds)
        .environment(\.colorScheme, .dark)
    }

    // MARK: The record

    private var vinyl: some View {
        Group {
            if let track = model.track, track.title?.isEmpty == false {
                MiniRecord(track: track, artwork: model.artwork, spinning: model.playing && !editing, side: Self.record, flash: editing ? nil : model.playFlash)
            } else {
                EmptyPlatter(side: Self.record)
            }
        }
        .padding(Self.margin)
        .overlay(alignment: .top) { pill(at: .top).padding(.top, Self.margin - 10) }
        .overlay(alignment: .bottom) { pill(at: .bottom).padding(.bottom, Self.margin - 10) }
        .contextMenu {
            if !editing {
                Button("Show HUD") { mini.onShowHUD() }
                Button("Mini Player Settings…") { mini.onSettings() }
                Divider()
                Button("Hide Mini Player") { mini.onHide() }
            }
        }
    }

    @ViewBuilder private func pill(at place: MiniPlace) -> some View {
        let element = place == .top ? layout.top : layout.bottom
        if editing {
            slot(place, filled: element != nil) {
                if let element { chip(element, removable: true) }
            }
        } else if let element, let value = value(element) {
            MiniChip(text: value, hue: element.hue)
        }
    }

    // MARK: The song

    private var hasText: Bool {
        editing || (layout.track && model.track?.title?.isEmpty == false) || (layout.artist && model.track?.artist?.isEmpty == false)
            || (layout.album && model.track?.album?.isEmpty == false) || layout.line.contains { value($0) != nil }
    }

    private var alignment: HorizontalAlignment {
        if editing { return .center }
        switch mini.side {
        case .left: return .trailing
        case .right: return .leading
        case .above, .below: return .center
        }
    }

    private var textAlignment: Alignment {
        if editing { return .top }
        switch mini.side {
        case .left: return .trailing
        case .right: return .leading
        case .above: return .bottom
        case .below: return .top
        }
    }

    private var textWidth: CGFloat { mini.side == .left || mini.side == .right ? Self.sideWidth : Self.stackWidth }

    /// Where the text box sits against the record in the middle of the panel.
    private var textOffset: CGSize {
        if editing { return .zero }
        let gap: CGFloat = 6
        switch mini.side {
        case .below: return CGSize(width: 0, height: Self.box / 2 + gap + Self.textHeight / 2 - Self.margin + 4)
        case .above: return CGSize(width: 0, height: -(Self.box / 2 + gap + Self.textHeight / 2 - Self.margin + 4))
        case .right: return CGSize(width: Self.box / 2 + Self.sideWidth / 2 - Self.margin + gap, height: 0)
        case .left: return CGSize(width: -(Self.box / 2 + Self.sideWidth / 2 - Self.margin + gap), height: 0)
        }
    }

    private var text: some View {
        let track = editing ? HUDSample.track : model.track
        let title = layout.track ? track?.title.flatMap { $0.isEmpty ? nil : $0 } : nil
        let album = layout.album ? track?.album.flatMap { $0.isEmpty ? nil : $0 } : nil
        let artist = layout.artist ? track?.artist.flatMap { $0.isEmpty ? nil : $0 } : nil
        return VStack(alignment: alignment, spacing: 1) {
            // The album shares the line of the track, so the player stays short.
            if title != nil || album != nil {
                Text("\(Text(title ?? "").font(.system(size: 13.5, weight: .heavy, design: .rounded)))\(Text(title != nil && album != nil ? " · " : "").foregroundStyle(.white.opacity(0.6)))\(Text(album ?? "").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.62)))")
            }
            if let artist {
                Text(artist)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if editing {
                slot(.line, filled: !layout.line.isEmpty) {
                    HStack(spacing: 4) { ForEach(layout.line) { chip($0, removable: true) } }
                }
                .padding(.top, 4)
            } else {
                let chips = layout.line.compactMap { element in value(element).map { (element, $0) } }
                if !chips.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(chips, id: \.0) { element, value in MiniChip(text: value, hue: element.hue) }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.93))
        .multilineTextAlignment(alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
        .shadow(color: .black.opacity(0.75), radius: 6, y: 1)
    }

    // MARK: Elements

    /// The element's live value, or nil when it has nothing to show, like the speed of a song at its own tempo.
    private func value(_ element: MiniElement) -> String? {
        switch element {
        case .key:
            return mini.key?.name
        case .tempo:
            guard let tempo = model.tempo, tempo.song == nil || tempo.song == model.track?.song else { return nil }
            return "\(Int((tempo.bpm * model.speed).rounded())) BPM"
        case .pitch:
            return model.shift == 0 ? nil : Shift.short(model.shift)
        case .speed:
            return abs(model.speed - 1) < 0.005 ? nil : "\(Int((model.speed * 100).rounded()))%"
        case .loop:
            guard let loop = model.loop, let end = loop.end else { return nil }
            return "↻ \(Self.time(loop.start))–\(Self.time(end))"
        case .timeLeft:
            guard let track = model.track, let duration = track.duration, let position = track.position(at: Date()) else { return nil }
            return "−" + Self.time(max(0, duration - position))
        case .vocals:
            return model.stemsMuted.contains(.vocals) ? "Vocals off" : nil
        case .next:
            guard let current = model.queueCurrent, let index = model.queue.firstIndex(where: { $0.id == current }), index + 1 < model.queue.count else { return nil }
            return "⏭ " + model.queue[index + 1].title
        }
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: Editing

    private func chip(_ element: MiniElement, removable: Bool) -> some View {
        MiniChip(text: element.sample, hue: element.hue)
            .draggable(element.rawValue)
            .onTapGesture { if removable { onRemove(element) } }
            .help("Drag to another place, or click to remove")
    }

    private func slot(_ place: MiniPlace, filled: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(minWidth: place == .line ? 120 : 64, minHeight: 20)
            .padding(2)
            .background {
                Capsule()
                    .fill(target == place ? StripColors.solid(.honey, .dark).fill.opacity(0.35) : .white.opacity(filled ? 0 : 0.06))
                    .overlay(Capsule().strokeBorder(.white.opacity(filled && target != place ? 0 : 0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .dropDestination(for: String.self) { items, _ in
                guard let element = items.first.flatMap(MiniElement.init) else { return false }
                onDrop(element, place)
                return true
            } isTargeted: { target = $0 ? place : (target == place ? nil : target) }
            .animation(.easeOut(duration: 0.1), value: target)
    }
}

/// A dark pill with the value of an element, against the record or under the song.
struct MiniChip: View {
    let text: String
    var hue: StripColors.Hue?

    var body: some View {
        let colors = hue.map { StripColors.solid($0, .dark) }
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(hue.map { StripColors.text($0, .dark) } ?? Color(red: 0.96, green: 0.95, blue: 0.93))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(colors.map { $0.fill.mix(with: Color(red: 0.09, green: 0.07, blue: 0.08), by: 0.72) } ?? Color(red: 0.09, green: 0.07, blue: 0.08).opacity(0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .fixedSize()
    }
}

/// The panel of the mini player, above other windows on every Space. A drag anywhere on the record or the song moves
/// it, and the song moves to the side that the new place has room for once the drag ends.
final class MiniPlayerPanel: NSPanel {
    private let mini: MiniState
    /// The middle of the record, in screen points, which is where the player is kept.
    private(set) var center: CGPoint
    private var pressStart: (mouse: NSPoint, center: CGPoint)?
    private var draggingPanel = false
    private var monitors: [Any] = []
    /// The fingers' travel in a sideways swipe over the record, and whether it skipped already.
    private var swipeTravel: CGFloat = 0
    private var swiped = false
    var onSkip: (Int) -> Void = { _ in }
    var naturalSwipes: () -> Bool = { false }
    var onHover: (Bool) -> Void = { _ in }
    private(set) var hovering = false

    init(model: HUDModel, mini: MiniState) {
        self.mini = mini
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: "miniPlayerCenter") as? [Double], saved.count == 2 {
            center = CGPoint(x: saved[0], y: saved[1])
        } else {
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            center = CGPoint(x: visible.maxX - 130, y: visible.minY + 150)
        }
        let size = MiniPlayerView.panelSize
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = FirstClickHostingView(rootView: MiniPlayerView(model: model, mini: mini))
        hosting.sizingOptions = []
        contentView = hosting
        keepOnScreen()
        place()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }

    func show() {
        guard !isVisible else { return }
        keepOnScreen()
        chooseSide()
        place()
        orderFrontRegardless()
        watchPointer(true)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        watchPointer(false)
        setHovering(false)
    }

    private func place() {
        let size = MiniPlayerView.panelSize
        setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
    }

    /// A player that was left on a screen that is gone comes back to the main one.
    private func keepOnScreen() {
        guard !NSScreen.screens.contains(where: { $0.frame.contains(center) }), let visible = NSScreen.main?.visibleFrame else { return }
        center = CGPoint(x: visible.maxX - 130, y: visible.minY + 150)
    }

    /// The side of the record that the song goes on, by where the record is on its screen.
    func chooseSide() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let point = CGPoint(x: center.x - visible.minX, y: visible.maxY - center.y)
        let side = MiniTextSide.choose(center: point, screen: visible.size, record: MiniPlayerView.box, text: mini.textSize)
        if mini.side != side { mini.side = side }
    }

    // MARK: Clicks through the empty parts

    private func watchPointer(_ on: Bool) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard on else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.updatePassThrough() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited], handler: { [weak self] event in
            self?.updatePassThrough()
            return event
        }) {
            monitors.append(local)
        }
        updatePassThrough()
    }

    /// The panel takes the pointer only over the record and the song.
    private func updatePassThrough() {
        guard !draggingPanel else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let record = mini.hitFrames["record"].map { frame in
            hypot(point.x - frame.midX, point.y - frame.midY) <= MiniPlayerView.record / 2 + 4
                || CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height).insetBy(dx: frame.width * 0.3, dy: 0).contains(point)
        } ?? false
        let over = record || (mini.hitFrames["text"]?.insetBy(dx: -4, dy: -4).contains(point) ?? false)
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
        setHovering(over)
    }

    private func setHovering(_ over: Bool) {
        guard hovering != over else { return }
        hovering = over
        onHover(over)
    }

    // MARK: Moving

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressStart = (NSEvent.mouseLocation, center)
            draggingPanel = false
        case .leftMouseDragged:
            guard let start = pressStart else { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
            if !draggingPanel {
                guard hypot(dx, dy) >= 4 else { break }
                draggingPanel = true
            }
            center = CGPoint(x: start.center.x + dx, y: start.center.y + dy)
            place()
            return
        case .leftMouseUp:
            pressStart = nil
            guard draggingPanel else { break }
            draggingPanel = false
            UserDefaults.standard.set([Double(center.x), Double(center.y)], forKey: "miniPlayerCenter")
            chooseSide()
            // The button under the pointer would take this release as a click, so SwiftUI gets it far away instead.
            if let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10000, y: -10000), modifierFlags: event.modifierFlags,
                                                timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                                eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0)
            {
                super.sendEvent(outside)
            }
            updatePassThrough()
            return
        case .scrollWheel:
            // A sideways swipe over the record plays the next or the previous song, as over the HUD.
            if event.phase == .began { swipeTravel = 0; swiped = false }
            guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { break }
            swipeTravel += event.scrollingDeltaX
            if !swiped, abs(swipeTravel) > 60 {
                swiped = true
                let towardsLeft = swipeTravel < 0
                onSkip(towardsLeft != naturalSwipes() ? 1 : -1)
            }
            return
        default: break
        }
        super.sendEvent(event)
    }
}

/// Settings > Mini player > Elements: the player with its three places, and the elements to drag onto them.
struct MiniLayoutEditor: View {
    @ObservedObject var prefs: Preferences
    @StateObject private var sample: HUDModel = HUDSample.model(card: false, relative: false)
    @StateObject private var mini = MiniState()

    var body: some View {
        VStack(spacing: 14) {
            MiniPlayerView(model: sample, mini: mini, editing: true, onDrop: { element, place in
                prefs.miniLayout.put(element, at: place)
            }, onRemove: { element in
                prefs.miniLayout.remove(element)
            })
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.16, green: 0.13, blue: 0.14)))
            FlowRow(spacing: 6) {
                ForEach(MiniElement.allCases) { element in
                    let placed = prefs.miniLayout.place(of: element) != nil
                    Text(element.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.primary.opacity(placed ? 0.04 : 0.1)))
                        .foregroundStyle(placed ? .secondary : .primary)
                        .draggable(element.rawValue)
                        .help(placed ? "On the player" : "Drag onto a place")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { mini.layout = prefs.miniLayout }
        .onChange(of: prefs.miniLayout) { _, layout in mini.layout = layout }
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
