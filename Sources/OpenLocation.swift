import AppKit
import SwiftUI

/// Open Location: a field for a link or the path of a file, in a glass bar like the HUD's near the top of the screen,
/// with the songs downloaded from links before listed under it. It closes when another window is clicked, and the
/// app that was in front gets the keyboard back.
final class OpenLocationPanel: NSObject, NSWindowDelegate {
    var onOpen: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Where the panel's keyboard went, for `--log-keys`.
    var onLog: (String) -> Void = { _ in }

    static let size = CGSize(width: 600, height: 520)
    private let model = OpenLocationModel()
    private let cache = LinkCache()

    private lazy var panel: LocationPanel = {
        let panel = LocationPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        // The transparent part of the panel lets clicks through to what is under it, which closes the panel.
        panel.contentView = FirstClickHostingView(rootView: OpenLocationView(model: model))
        return panel
    }()

    override init() {
        super.init()
        model.open = { [weak self] url in self?.open(url) }
        model.close = { [weak self] in self?.close() }
    }

    var isShown: Bool { panel.isVisible }

    /// Shows the panel on the screen with the pointer, with the link or the path on the clipboard in the field. It
    /// shows at once, since it comes from a menu item or ⌘L.
    func show() {
        model.reset(text: Self.clipboardLocation() ?? "", recent: cache.recent(6).map(OpenLocationModel.Recent.init))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - visible.height * 0.18 - Self.size.height))
        }
        panel.alphaValue = 1
        // macOS gives the keyboard to a panel of an app in the background only right after a click in that app, so
        // Muskey comes in front while the panel is open.
        NSApp.takeFocus()
        panel.makeKeyAndOrderFront(nil)
        model.focus += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            onLog("open location: key \(panel.isKeyWindow), Muskey in front \(NSApp.isActive), first responder \(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        }
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        closing = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self else { return }
            panel.orderOut(nil)
            closing = false
            onClose()
        }
    }

    private var closing = false

    private func open(_ url: URL) {
        close()
        onOpen(url)
    }

    func windowDidResignKey(_: Notification) {
        onLog("open location: lost the keyboard to \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "another app")")
        close()
    }

    /// A file copied in Finder, or a link or a path copied as text.
    private static func clipboardLocation() -> String? {
        let pasteboard = NSPasteboard.general
        if let file = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            return file.path
        }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              FilePlayer.url(from: text) != nil else { return nil }
        return text
    }
}

/// Takes the keyboard as a borderless panel, and gives the field the editing shortcuts in case the main menu doesn't
/// answer them.
final class LocationPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector? = switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class OpenLocationModel: ObservableObject {
    /// A song downloaded from a link before.
    struct Recent: Identifiable {
        let link: URL
        let title: String
        let artist: String?
        let site: String
        let cover: NSImage?
        var id: String { link.absoluteString }

        init(link: URL, song: FilePlayer.Song) {
            self.link = link
            title = song.title ?? ((song.path as NSString).lastPathComponent as NSString).deletingPathExtension
            artist = song.artist
            site = link.host().map { $0.replacingOccurrences(of: "www.", with: "") } ?? link.absoluteString
            cover = song.artwork.flatMap(NSImage.init(contentsOfFile:))
        }

        init(title: String, artist: String?, site: String) {
            link = URL(string: "https://\(site)/\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")!
            self.title = title
            self.artist = artist
            self.site = site
            cover = nil
        }
    }

    /// Live state of the text in the field, in a pill at its right end. The failures show only after Return.
    enum Note: Equatable {
        case downloaded, needsDownloader, notALink, fileNotFound

        var text: String {
            switch self {
            case .downloaded: "Downloaded"
            case .needsDownloader: "Needs yt-dlp"
            case .notALink: "Not a link"
            case .fileNotFound: "File not found"
            }
        }

        var failed: Bool { self == .notALink || self == .fileNotFound }
    }

    enum Command { case up, down, open, close }

    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            selection = nil
            update()
        }
    }

    @Published private(set) var note: Note?
    @Published private(set) var recent: [Recent] = []
    /// The highlighted row of Recent, which Return plays. Nil while the field has the keyboard.
    @Published var selection: Int?
    /// Bumped to give the field the keyboard with its text selected.
    @Published var focus = 0
    /// Bumped to shake the field when Return finds nothing to open.
    @Published private(set) var shakes = 0

    var open: (URL) -> Void = { _ in }
    var close: () -> Void = {}
    private let cache = LinkCache()

    func reset(text: String, recent: [Recent]) {
        self.recent = recent
        self.text = text
        selection = nil
        update()
    }

    private func update() {
        guard let url = FilePlayer.url(from: text), !url.isFileURL else { return note = nil }
        if cache.has(url) { note = .downloaded }
        else if !LinkDownload.directExtensions.contains(url.pathExtension.lowercased()), Downloader.find() == nil { note = .needsDownloader }
        else { note = nil }
    }

    /// The keys that the field passes on: the arrows move through Recent, Return opens and Esc closes.
    func command(_ command: Command) -> Bool {
        switch command {
        case .down:
            guard !recent.isEmpty else { return false }
            selection = min((selection ?? -1) + 1, recent.count - 1)
        case .up:
            guard let selection else { return false }
            self.selection = selection == 0 ? nil : selection - 1
        case .open:
            submit()
        case .close:
            close()
        }
        return true
    }

    func submit() {
        if let selection, recent.indices.contains(selection) { return open(recent[selection].link) }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        if let url = FilePlayer.url(from: typed) { return open(url) }
        note = typed.hasPrefix("/") || typed.hasPrefix("~") ? .fileNotFound : .notALink
        shakes += 1
    }
}

struct OpenLocationView: View {
    @ObservedObject var model: OpenLocationModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?

    static let width: CGFloat = 560

    private var palette: Palette { Palette.of(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !model.recent.isEmpty {
                Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1)
                recent
            }
            Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1)
            hints
        }
        .frame(width: Self.width)
        .modifier(HUDBackground(tint: .current, scheme: colorScheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var field: some View {
        HStack(spacing: 11) {
            Image(systemName: "link")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.muted)
            Group {
                if renderingPreview {
                    // ImageRenderer draws no AppKit view, so a preview shows the text the field would hold.
                    Text(model.text.isEmpty ? "Link or file path" : model.text)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(model.text.isEmpty ? palette.muted.opacity(0.6) : palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LocationField(text: $model.text, focus: model.focus, palette: palette, command: model.command)
                }
            }
            .modifier(Shake(amount: reduceMotion ? 0 : CGFloat(model.shakes)))
            .animation(.linear(duration: 0.32), value: model.shakes)
            if let note = model.note {
                Text(note.text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(note.failed ? StripColors.text(.red, colorScheme) : palette.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(note.failed ? StripColors.tint(.red, strong: false, colorScheme) : palette.ink.opacity(0.07)))
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.note)
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.muted.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 3)
            ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, song in
                row(song, highlighted: model.selection == index || (model.selection == nil && hovered == song.id))
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(song.link) }
                    .onHover { hovered = $0 ? song.id : (hovered == song.id ? nil : hovered) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.open(song.link) }
            }
        }
        .padding(8)
    }

    private func row(_ song: OpenLocationModel.Recent, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let cover = song.cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        palette.ink.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.muted.opacity(0.7))
                    }
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink)
                if let artist = song.artist {
                    Text(artist)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Text(song.site)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted.opacity(0.8))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.ink.opacity(highlighted ? 0.09 : 0)))
    }

    private var hints: some View {
        HStack(spacing: 13) {
            hint(["↩"], "open")
            if !model.recent.isEmpty { hint(["↑", "↓"], "recent") }
            hint(["esc"], "close")
            Spacer(minLength: 0)
        }
        .opacity(0.62)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func hint(_ keys: [String], _ name: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0, palette: palette) } }
            Text(name)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted)
                .fixedSize()
        }
    }
}

/// A short sideways shake, for Return on text that can't be opened. The red pill stays with Reduce Motion.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size _: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(amount * .pi * 4), y: 0))
    }
}

/// The text field of Open Location. An AppKit field, since its field editor reports the arrows, Return and Esc,
/// and selects the text that the clipboard filled in.
private struct LocationField: NSViewRepresentable {
    @Binding var text: String
    let focus: Int
    let palette: Palette
    let command: (OpenLocationModel.Command) -> Bool

    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 17, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 17) } ?? base
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingField {
        let field = FocusingField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = Self.font
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Link or file path")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = NSColor(palette.ink)
        field.placeholderAttributedString = NSAttributedString(
            string: "Link or file path",
            attributes: [.font: Self.font, .foregroundColor: NSColor(palette.muted).withAlphaComponent(0.55)]
        )
        guard context.coordinator.focused != focus else { return }
        context.coordinator.focused = focus
        field.focus()
    }

    /// Takes the keyboard with its text selected, once it is in the panel: on the first open, SwiftUI makes the field
    /// before it puts it in the window.
    final class FocusingField: NSTextField {
        private var wantsFocus = false

        func focus() {
            wantsFocus = true
            DispatchQueue.main.async { [weak self] in self?.focusInWindow() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusInWindow()
        }

        private func focusInWindow() {
            guard wantsFocus, let window else { return }
            wantsFocus = false
            window.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LocationField
        var focused = 0

        init(_ parent: LocationField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.command(.up)
            case #selector(NSResponder.moveDown(_:)): parent.command(.down)
            case #selector(NSResponder.insertNewline(_:)): parent.command(.open)
            case #selector(NSResponder.cancelOperation(_:)): parent.command(.close)
            default: false
            }
        }
    }
}

extension NSApplication {
    /// Brings Muskey in front with the keyboard. The cooperative `activate()` of macOS 14 is refused when Muskey wasn't
    /// clicked just before, as when a menu item is picked through `--menu` or Accessibility, so this asks the older way.
    func takeFocus() { activate(ignoringOtherApps: true) }
}
