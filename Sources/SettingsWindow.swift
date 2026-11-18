import Carbon.HIToolbox
import SwiftUI

/// The panes of Settings, in the sidebar's order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, hud, listening, lyrics, stems, permissions, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .hud: "HUD"
        case .listening: "Listening"
        case .lyrics: "Lyrics"
        case .stems: "Instruments and vocals"
        case .permissions: "Permissions"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hud: "rectangle.on.rectangle"
        case .listening: "ear"
        case .lyrics: "quote.bubble"
        case .stems: "slider.vertical.3"
        case .permissions: "hand.raised"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }

    var hue: SidebarHue {
        switch self {
        case .general: .stone
        case .hud: .skin
        case .listening: .dustyBlue
        case .lyrics: .plum
        case .stems: .sage
        case .permissions: .terracotta
        case .updates: .ochre
        }
    }
}

/// A muted, earthy sidebar colour with a light and a dark tone, the palette that every lowtechguys app uses for the
/// tiles of its Settings sidebar (kept in step with Cling, rcmd, Lunar, Clop, Pipiri and Crank).
struct SidebarHue {
    static let sage = rgb(0.39, 0.49, 0.26, 0.60, 0.66, 0.50)
    static let dustyBlue = rgb(0.24, 0.43, 0.63, 0.53, 0.64, 0.75)
    static let terracotta = rgb(0.74, 0.35, 0.23, 0.82, 0.52, 0.40)
    static let skin = rgb(0.74, 0.47, 0.30, 0.80, 0.64, 0.52)
    static let plum = rgb(0.58, 0.30, 0.55, 0.68, 0.55, 0.67)
    static let stone = rgb(0.45, 0.43, 0.37, 0.66, 0.64, 0.57)
    static let ochre = rgb(0.78, 0.56, 0.16, 0.83, 0.68, 0.40)

    let light: Color
    let dark: Color

    func color(for scheme: ColorScheme) -> Color { scheme == .dark ? dark : light }

    private static func rgb(_ lr: Double, _ lg: Double, _ lb: Double, _ dr: Double, _ dg: Double, _ db: Double) -> SidebarHue {
        SidebarHue(light: Color(.sRGB, red: lr, green: lg, blue: lb), dark: Color(.sRGB, red: dr, green: dg, blue: db))
    }
}

/// The glyph of a pane on a soft tile of the same hue.
struct SidebarIcon: View {
    let symbol: String
    let hue: SidebarHue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = hue.color(for: scheme)
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: 12, height: 12)
            .frame(width: 20, height: 20)
            .background(color.opacity(scheme == .dark ? 0.22 : 0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A window that isn't a SwiftUI scene opens its sidebar at the split view's default width, whatever the column width
/// asks for, which cuts "Instruments and vocals" short. This sets the width on the split view itself, once, and keeps
/// the sidebar from collapsing, since the toolbar has no button to bring it back.
private struct SidebarWidth: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context _: Context) -> NSView { Probe(width: width) }
    func updateNSView(_: NSView, context _: Context) {}

    private final class Probe: NSView {
        let width: CGFloat
        private var done = false

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard !done else { return }
            var view = superview
            for _ in 0 ..< 40 where view != nil && !(view is NSSplitView) { view = view?.superview }
            guard let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else { return }
            done = true
            for item in controller.splitViewItems { item.canCollapse = false }
            sidebar.minimumThickness = width
            split.setPosition(width, ofDividerAt: 0)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var hud: HUDModel
    let keyCache: KeyCache
    let setLayout: (Bool) -> Void

    /// `--settings-pane NAME` opens Settings on that pane, for checking each one without clicks.
    @State private var selection: SettingsPane = TestFlags.value("--settings-pane").flatMap(SettingsPane.init) ?? .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    row(.general)
                    row(.hud)
                    row(.listening)
                }
                Section("Music") {
                    row(.lyrics)
                    row(.stems)
                }
                Section("Support") {
                    row(.permissions)
                    row(.updates)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane(prefs: prefs)
                case .hud: HUDPane(prefs: prefs, hud: hud, setLayout: setLayout)
                case .listening: ListeningPane(prefs: prefs, keyCache: keyCache)
                case .lyrics: LyricsPane(prefs: prefs)
                case .stems: StemsPane(prefs: prefs)
                case .permissions: PermissionsPane()
                case .updates: UpdatesPane()
                }
            }
            // The toolbar names the pane, as System Settings does.
            .navigationTitle(selection.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SidebarWidth(width: 210))
            .background(WindowTitle(title: selection.title))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, idealWidth: 740, minHeight: 500, idealHeight: 540)
    }

    private func row(_ pane: SettingsPane) -> some View {
        NavigationLink(value: pane) {
            Label { Text(pane.title) } icon: { SidebarIcon(symbol: pane.symbol, hue: pane.hue) }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Keyboard") {
                LabeledContent("Hotkey") {
                    ShortcutRecorder(shortcut: $prefs.hotkey, recording: $prefs.recordingHotkey, failed: prefs.hotkeyFailed)
                }
            }
            Section("Menu bar icon") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Always", selected: prefs.menuBarIcon == .always) { prefs.menuBarIcon = .always } preview: {
                        MiniMenuBar(idle: true)
                    }
                    ChoiceTile(title: "During a pitch change", selected: prefs.menuBarIcon == .pitchChange) { prefs.menuBarIcon = .pitchChange } preview: {
                        MiniMenuBar(idle: false)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HUDPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var hud: HUDModel
    let setLayout: (Bool) -> Void

    var body: some View {
        Form {
            Section("Layout") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Wide", selected: !hud.card, height: 150, wallpaper: true) { setLayout(false) } preview: {
                        HUDSampleView(card: false, relative: prefs.relativeKeys)
                    }
                    ChoiceTile(title: "Card", selected: hud.card, height: 150, wallpaper: true) { setLayout(true) } preview: {
                        HUDSampleView(card: true, relative: prefs.relativeKeys)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Relative keys") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Song's mode", selected: !prefs.relativeKeys, height: 130, wallpaper: true) { prefs.relativeKeys = false } preview: {
                        HUDSampleView(card: false, relative: false, keysOnly: true)
                    }
                    ChoiceTile(title: "Both modes", selected: prefs.relativeKeys, height: 130, wallpaper: true) { prefs.relativeKeys = true } preview: {
                        HUDSampleView(card: false, relative: true, keysOnly: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ListeningPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var keyCache: KeyCache
    @State private var confirmForget = false

    var body: some View {
        let songs = keyCache.songs
        Form {
            Section("Listen") {
                Toggle(isOn: $prefs.alwaysListen) {
                    Text("Always listening")
                    Text("Detect the key of each song in the background")
                }
                Picker(selection: $prefs.listenSeconds) {
                    ForEach(Preferences.listenLengths, id: \.self) { Text("\($0) seconds").tag($0) }
                } label: {
                    Text("Listen length")
                    Text("Audio analysed to detect a key")
                }
            }
            Section("Song keys") {
                Toggle(isOn: $prefs.onlineKeys) {
                    Text("Online key lookup")
                    Text("Fetch keys from noiseblend.com by song title and artist")
                }
                Toggle(isOn: $prefs.rememberKeys) {
                    Text("Remember song keys")
                    Text("Save detected keys and reuse them for the same song")
                }
                LabeledContent("Remembered songs") {
                    HStack {
                        Pill(text: "\(songs.count)", color: .secondary)
                        Button("Forget All…") { confirmForget = true }
                            .disabled(songs.isEmpty)
                    }
                }
            }
            if !songs.isEmpty {
                RememberedSongs(songs: songs) { keyCache.forget($0) }
            }
        }
        .formStyle(.grouped)
        .alert(songs.count == 1 ? "Forget the key of 1 song?" : "Forget the keys of \(songs.count) songs?", isPresented: $confirmForget) {
            Button(songs.count == 1 ? "Forget 1 Key" : "Forget \(songs.count) Keys", role: .destructive) { keyCache.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The songs that have a remembered key, the most recent listen first, each with a button that forgets its key.
/// A grouped Form lays out every row it holds, which took seconds and gigabytes with thousands of songs, so the songs
/// scroll in a List of their own inside one row of the form. Its table makes views only for the rows on screen.
private struct RememberedSongs: View {
    let songs: [KeyCache.Song]
    let forget: (String) -> Void
    @State private var search = ""

    /// A short list is read at a glance, so the search bar appears only for a longer one.
    private static let searchFrom = 11
    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 8

    private var shown: [KeyCache.Song] {
        let words = search.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return songs }
        return songs.filter { song in
            let text = [song.title, song.artist, song.album].compactMap { $0 }.joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        Section {
            if songs.count >= Self.searchFrom {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search songs", text: $search, prompt: Text("Search songs"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                }
            }
            let shown = shown
            if shown.isEmpty {
                Text("No songs match").foregroundStyle(.secondary)
            } else {
                List(shown) { song in
                    SongKeyRow(song: song) { forget(song.id) }
                        .frame(height: Self.rowHeight)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                        // Separators span the text, like the separators between the form's rows.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(min(shown.count, Self.visibleRows)) * Self.rowHeight)
            }
        }
    }
}

private struct SongKeyRow: View {
    let song: KeyCache.Song
    let forget: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                if let detail = song.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Pill(text: song.key.name, color: .secondary)
            Button(action: forget) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Forget this song's key")
                .accessibilityLabel("Forget Key")
        }
    }
}

private struct LyricsPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var whisperDownload = ModelDownload.whisper
    @ObservedObject private var stemDownload = ModelDownload.stems

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Engine", selection: $prefs.lyricsTranscription) {
                    Text("Apple speech").tag(LyricsTranscription.apple)
                    Text("Whisper server").tag(LyricsTranscription.server)
                    Text("Whisper model").tag(LyricsTranscription.model)
                }
                switch prefs.lyricsTranscription {
                case .apple:
                    EmptyView()
                case .server:
                    TextField("Server URL", text: $prefs.whisperServer, prompt: Text("http://127.0.0.1:8000/v1"))
                case .model:
                    ModelRow(title: "Whisper model", download: whisperDownload)
                }
            }
            Section("Karaoke") {
                // Muting the vocals takes the common instruments model, so the toggle waits for it.
                Toggle(isOn: $prefs.karaokeMutesVocals) {
                    Text("Mute vocals in karaoke")
                    if !stemDownload.installed { Text("Needs the common instruments model") }
                }
                .disabled(!stemDownload.installed)
                Toggle("Restart song in karaoke", isOn: $prefs.karaokeRestarts)
                Toggle("Blur screen in karaoke", isOn: $prefs.karaokeBackdrop)
                Toggle("Show record in karaoke", isOn: $prefs.karaokeRecord)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            whisperDownload.refresh()
            stemDownload.refresh()
        }
    }
}

private struct StemsPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var stemDownload = ModelDownload.stems
    @ObservedObject private var windsDownload = ModelDownload.winds

    var body: some View {
        Form {
            Section("Models") {
                ModelRow(title: "Common instruments model", download: stemDownload)
                // The winds are taken out of the Other stem of the common instruments model, so it needs that model
                // first.
                if stemDownload.installed || windsDownload.installed {
                    ModelRow(title: "Exotic instruments model", download: windsDownload)
                }
            }
            // The song steps back seconds when the separated instruments take over, in karaoke and when the lyrics
            // delay starts.
            Section("Playback") {
                Picker("Rewind effect", selection: $prefs.rewindEffect) {
                    Text("Scratch").tag(RewindEffect.scratch)
                    Text("Fade").tag(RewindEffect.fade)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            stemDownload.refresh()
            windsDownload.refresh()
        }
    }
}

private struct PermissionsPane: View {
    @State private var permission = AudioCapturePermission.status

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("System Audio Recording") {
                    HStack {
                        switch permission {
                        case .granted:
                            Pill(text: "Allowed", color: .green)
                        case .denied:
                            Pill(text: "Not allowed", color: .red)
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        case .undetermined:
                            Pill(text: "Not asked", color: .secondary)
                            Button("Request Access") {
                                AudioCapturePermission.request { _ in permission = AudioCapturePermission.status }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permission = AudioCapturePermission.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission = AudioCapturePermission.status }
    }
}

private struct UpdatesPane: View {
    /// Sparkle's own settings, which it reads at each check.
    enum Automatic: Hashable { case off, notify, install }

    @State private var automatic = Self.currentAutomatic
    @State private var interval = Updates.shared.updater.updateCheckInterval
    @AppStorage(Updates.channelKey) private var beta = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    HStack {
                        Pill(text: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", color: .secondary)
                        Button("Check for Updates") { Updates.shared.check() }
                    }
                }
                Picker("Automatic updates", selection: $automatic) {
                    Text("Off").tag(Automatic.off)
                    Text("Check and notify").tag(Automatic.notify)
                    Text("Install silently").tag(Automatic.install)
                }
                .onChange(of: automatic) { _, mode in
                    let updater = Updates.shared.updater
                    updater.automaticallyChecksForUpdates = mode != .off
                    updater.automaticallyDownloadsUpdates = mode == .install
                }
                Picker("Check interval", selection: $interval) {
                    Text("Daily").tag(TimeInterval(86400))
                    Text("Every 3 days").tag(TimeInterval(3 * 86400))
                    Text("Weekly").tag(TimeInterval(7 * 86400))
                }
                .disabled(automatic == .off)
                .onChange(of: interval) { Updates.shared.updater.updateCheckInterval = $1 }
                // A Picker in a Form row keeps room for its label even when the row shows the label on the left, and
                // that room appears as a gap on the right of the segments. The row carries the label instead.
                LabeledContent("Update channel") {
                    Picker("Update channel", selection: $beta) {
                        Text("Release").tag(false)
                        Text("Beta").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .onChange(of: beta) { Updates.shared.updater.resetUpdateCycleAfterShortDelay() }
            } header: {
                Text("Updates")
            } footer: {
                HStack(spacing: 16) {
                    Link("lowtechguys.com/muskey", destination: URL(string: "https://lowtechguys.com/muskey")!)
                    Link("Source code", destination: URL(string: "https://github.com/FuzzyIdeas/Muskey")!)
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            automatic = Self.currentAutomatic
            interval = Self.nearestInterval(Updates.shared.updater.updateCheckInterval)
        }
    }

    private static var currentAutomatic: Automatic {
        let updater = Updates.shared.updater
        return !updater.automaticallyChecksForUpdates ? .off : updater.automaticallyDownloadsUpdates ? .install : .notify
    }

    /// Sparkle's default of one day, or a value set elsewhere, shows as the closest choice.
    private static func nearestInterval(_ seconds: TimeInterval) -> TimeInterval {
        [86400, 3 * 86400, 7 * 86400].min { abs($0 - seconds) < abs($1 - seconds) } ?? 86400
    }
}

// MARK: - Picture tiles

/// A choice drawn as a small picture of what it does, with its name under it. The one not picked steps back,
/// dimmer and nearly grey.
private struct ChoiceTile<Preview: View>: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 112
    /// The Mac's wallpaper behind the picture, as the HUD has it.
    var wallpaper = false
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack { preview() }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background {
                        if wallpaper, let image = Wallpaper.image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            MiniGlass.backdrop(scheme)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .saturation(selected ? 1 : 0.15)
                    .opacity(selected ? 1 : 0.55)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                    }
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

/// The warm backdrop of the pictures in Settings, where the wallpaper can't be read.
private enum MiniGlass {
    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.2, green: 0.17, blue: 0.19), Color(red: 0.12, green: 0.1, blue: 0.11)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.93, green: 0.87, blue: 0.84), Color(red: 0.86, green: 0.8, blue: 0.79)], startPoint: .top, endPoint: .bottom)
    }
}

/// A strip of the menu bar with Muskey's item, while no pitch change runs and during one. Without a pitch change
/// the item shows only when Settings has it always shown.
private struct MiniMenuBar: View {
    let idle: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            strip(shift: nil).opacity(idle ? 1 : 0.35)
            strip(shift: "+2")
        }
        .padding(.horizontal, 18)
    }

    private func strip(shift: String?) -> some View {
        let ink = Palette.of(scheme).ink
        return HStack(spacing: 6) {
            Spacer(minLength: 0)
            Capsule().fill(ink.opacity(0.2)).frame(width: 14, height: 4)
            if shift != nil || idle {
                Image(nsImage: StatusItem.pill(DetectedKey(pitchClass: 4, minor: true)))
                    .renderingMode(.template)
                    .foregroundStyle(ink)
                if let shift {
                    Text(shift).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                }
            }
            Capsule().fill(ink.opacity(0.2)).frame(width: 10, height: 4)
            Capsule().fill(ink.opacity(0.2)).frame(width: 22, height: 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.75)))
    }
}

/// A model that Muskey downloads on demand: whether it is on the Mac, the download with its progress, and Remove.
private struct ModelRow: View {
    let title: String
    @ObservedObject var download: ModelDownload

    var body: some View {
        LabeledContent(title) {
            HStack {
                switch download.state {
                case let .downloading(fraction):
                    ProgressView(value: fraction)
                        .frame(width: 120)
                    Pill(text: "\(Int(fraction * 100))%", color: .secondary)
                    Button("Cancel") { download.cancel() }
                case .installing:
                    ProgressView().controlSize(.small)
                    Pill(text: "Installing", color: .secondary)
                case .failed:
                    Pill(text: "Download failed", color: .red)
                    Button("Retry") { download.start() }
                case .idle where download.installed:
                    Pill(text: "Installed", color: .green)
                    Button("Remove") { download.remove() }
                case .idle:
                    Pill(text: "Not installed", color: .secondary)
                    Button(download.size >= 1_000_000_000 ? String(format: "Download (%.1f GB)", Double(download.size) / 1e9)
                        : "Download (\(Int((Double(download.size) / 1e6).rounded())) MB)") { download.start() }
                }
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Records the next key pressed with ⌘, ⌃ or ⌥. Escape cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @Binding var recording: Bool
    let failed: Bool
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if shortcut != .default, !recording {
                Button { shortcut = .default } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(Shortcut.default.symbols)")
            }
            Button(action: recording ? stop : start) {
                Text(recording ? "press a shortcut" : shortcut.symbols)
                    .foregroundStyle(recording ? Color.secondary : failed ? Color.red : Color.primary)
                    .frame(minWidth: 100)
            }
            .tint(failed ? .red : nil)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let new = Shortcut(event: event) {
                shortcut = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Names the window after the pane, for the toolbar and the Window menu. A window that SwiftUI doesn't own ignores
/// `navigationTitle`.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context _: Context) {
        let title = title
        DispatchQueue.main.async { view.window?.title = title }
    }
}

/// The app has no Dock icon, so it shows one while Settings is open, to keep the window in ⌘Tab.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(view: some View) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Muskey Settings"
        // The sidebar runs up under the toolbar, and the toolbar shows the name of the pane, as System Settings does.
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = false
        window.setContentSize(NSSize(width: 740, height: 540))
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
