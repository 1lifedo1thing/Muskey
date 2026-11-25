import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps

/// A key with Carbon modifiers, the way `RegisterEventHotKey` takes it.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    static let `default` = Shortcut(keyCode: kVK_ANSI_M, modifiers: controlKey | cmdKey, key: "M")

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil for a key without ⌘, ⌃ or ⌥, which would take a key that other apps need for typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        let code = Int(event.keyCode)
        self.init(keyCode: code, modifiers: modifiers, key: Self.names[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?")
    }

    var symbols: String {
        (modifiers & controlKey != 0 ? "⌃" : "") + (modifiers & optionKey != 0 ? "⌥" : "")
            + (modifiers & shiftKey != 0 ? "⇧" : "") + (modifiers & cmdKey != 0 ? "⌘" : "") + key
    }

    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        return (key.count == 1 ? key.lowercased() : "", flags)
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

enum MenuBarIcon: String, CaseIterable {
    case always, pitchChange
}

/// How long cached stems and songs downloaded from links are kept after they were last played. The same periods as
/// Clop's cleanup of its working folder.
/// How fast the record turns in the HUD and the mini player, in turns a minute like a turntable's speeds. Karaoke's
/// calmer record keeps the same ratio to it.
enum RecordSpeed: Double, CaseIterable {
    case still = 0
    case crawl = 2
    case slowest = 4
    case slower = 8.333
    case slow = 16.667
    case standard = 33.333
    case fast = 45
    case fastest = 78

    var title: String {
        switch self {
        case .still: "Still"
        case .crawl: "2 rpm"
        case .slowest: "4 rpm"
        case .slower: "8⅓ rpm"
        case .slow: "16⅔ rpm"
        case .standard: "33⅓ rpm"
        case .fast: "45 rpm"
        case .fastest: "78 rpm"
        }
    }

    /// The speed against 33⅓ turns a minute, which the record's turn is drawn at.
    var rate: Double { rawValue / RecordSpeed.standard.rawValue }
}

enum CacheCleanup: TimeInterval, CaseIterable {
    case every10Minutes = 600
    case hourly = 3600
    case every12Hours = 43200
    case daily = 86400
    case every3Days = 259_200
    case weekly = 604_800
    case monthly = 2_592_000
    case never = 0

    var title: String {
        switch self {
        case .every10Minutes: "10 minutes"
        case .hourly: "1 hour"
        case .every12Hours: "12 hours"
        case .daily: "1 day"
        case .every3Days: "3 days"
        case .weekly: "1 week"
        case .monthly: "1 month"
        case .never: "Never"
        }
    }
}

/// What listens to the song to time its lyrics, and to write lyrics that LRCLIB doesn't have.
/// How the song steps back in itself when the separated stems take over, or the lyrics delay starts.
enum RewindEffect: String, CaseIterable {
    /// A backspin, like a record pulled back by hand.
    case scratch
    /// A fade out of what plays, then a fade in of the earlier moment.
    case fade
}

/// When the lyrics timing is checked and fitted without a click (Settings > Lyrics > Timing detection conditions).
/// A click on the Fix timing pill checks in every case.
enum TimingConditions: String, CaseIterable {
    case always
    /// Not while Low Power Mode is on, which asks apps to hold back on work that can wait.
    case notLowPower
    /// Only while the Mac runs on its power adapter.
    case onAdapter

    /// The conditions hold at this moment.
    var hold: Bool {
        switch self {
        case .always: true
        case .notLowPower: !ProcessInfo.processInfo.isLowPowerModeEnabled
        case .onAdapter: Self.runsOnAdapter
        }
    }

    private static var runsOnAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? != kIOPMBatteryPowerKey
    }
}

enum LyricsTranscription: String, CaseIterable {
    /// Apple's speech model on the Mac. It only times lyrics, and writes none.
    case apple
    /// A Whisper server with the OpenAI transcription API, like whisper.cpp's server or a dictation app's.
    case server
    /// Whisper Turbo on the Mac, from a model downloaded in Settings.
    case model
}

/// Settings that Muskey reads as it runs. Each change is saved right away.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let listenLengths = [10, 15, 20, 30]

    private let defaults = UserDefaults.standard

    @Published var hotkey: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") }
    }
    /// The hotkey is taken by another app.
    @Published var hotkeyFailed = false
    /// The recorder in Settings waits for a shortcut, so the hotkey is off until it gets one.
    @Published var recordingHotkey = false
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var menuBarIcon: MenuBarIcon {
        didSet { defaults.set(menuBarIcon.rawValue, forKey: "menuBarIcon") }
    }
    @Published var listenSeconds: Int {
        didSet { defaults.set(listenSeconds, forKey: "listenSeconds") }
    }
    @Published var rememberKeys: Bool {
        didSet { defaults.set(rememberKeys, forKey: "rememberKeys") }
    }
    /// Asks noiseblend.com for the key of a song that a listen starts on, by its title, artist, album and length. Off
    /// by default, so that a new install finds keys only on the Mac until Online key lookup is turned on.
    @Published var onlineKeys: Bool {
        didSet { defaults.set(onlineKeys, forKey: "onlineKeys") }
    }
    /// Listens to each song that starts playing with no key known, without the HUD, for the key in the menu bar.
    @Published var alwaysListen: Bool {
        didSet { defaults.set(alwaysListen, forKey: "alwaysListen") }
    }
    /// A two-finger swipe to the left plays the next song, the way content follows the fingers with natural scrolling.
    /// Off by default: a swipe to the right plays the next song.
    @Published var naturalSwipes: Bool {
        didSet { defaults.set(naturalSwipes, forKey: "naturalSwipes") }
    }
    /// The second row of keys in the wide layout and the inner ring of the card, with the keys in the other mode.
    @Published var relativeKeys: Bool {
        didSet { defaults.set(relativeKeys, forKey: "relativeKeys") }
    }
    @Published var lyricsTranscription: LyricsTranscription {
        didSet { defaults.set(lyricsTranscription.rawValue, forKey: "lyricsTranscription") }
    }
    /// Karaoke mutes the vocals, and plays them again once it closes.
    @Published var karaokeMutesVocals: Bool {
        didSet { defaults.set(karaokeMutesVocals, forKey: "karaokeMutesVocals") }
    }
    /// Karaoke starts the song over from its beginning, which plays with the vocals while they are separated, and
    /// rewinds to the beginning once they are. Without it, karaoke rewinds only to the moment it opened.
    @Published var karaokeRestarts: Bool {
        didSet { defaults.set(karaokeRestarts, forKey: "karaokeRestarts") }
    }
    /// How the song steps back in itself (Settings > Instruments and vocals > Rewind effect).
    @Published var rewindEffect: RewindEffect {
        didSet { defaults.set(rewindEffect.rawValue, forKey: "rewindEffect") }
    }
    /// Lyrics with times of a song from another app are checked against its vocals, and lyrics without times are
    /// fitted onto them (Settings > Lyrics > Timing).
    @Published var lyricsLiveTiming: Bool {
        didSet { defaults.set(lyricsLiveTiming, forKey: "lyricsLiveTiming") }
    }
    @Published var timingConditions: TimingConditions {
        didSet { defaults.set(timingConditions.rawValue, forKey: "timingConditions") }
    }
    /// Karaoke blurs and dims the rest of the screen around the glass.
    @Published var karaokeBackdrop: Bool {
        didSet { defaults.set(karaokeBackdrop, forKey: "karaokeBackdrop") }
    }
    /// The format that Save Song writes, kept from the last save.
    @Published var saveFormat: SaveFormat {
        didSet { defaults.set(saveFormat.rawValue, forKey: "saveFormat") }
    }
    /// The pitch change, the tempo change and the stems stop once the song has been paused for `pauseStopSeconds` with
    /// the HUD hidden (Settings > General > Pause timeout).
    @Published var pauseStop: Bool {
        didSet { defaults.set(pauseStop, forKey: "pauseStop") }
    }
    @Published var pauseStopSeconds: Int {
        didSet { defaults.set(pauseStopSeconds, forKey: "pauseStopSeconds") }
    }
    /// The HUD closes `autoHideSeconds` after it shows a key (Settings > HUD > Auto-hide). Off, a HUD that a person
    /// opened stays up until it is closed.
    @Published var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: "autoHide") }
    }
    @Published var autoHideSeconds: Int {
        didSet { defaults.set(autoHideSeconds, forKey: "autoHideSeconds") }
    }
    /// Cached stems and downloaded songs that weren't played for this long are deleted (Settings > General > Cache).
    @Published var cacheCleanup: CacheCleanup {
        didSet { defaults.set(cacheCleanup.rawValue, forKey: "cacheCleanup") }
    }
    @Published var recordSpeed: RecordSpeed {
        didSet { defaults.set(recordSpeed.rawValue, forKey: "recordSpeed") }
    }
    /// The base URL of the Whisper server, up to `/v1`.
    @Published var whisperServer: String {
        didSet { defaults.set(whisperServer, forKey: "whisperServer") }
    }
    /// The waveform of the whole song in the HUD (Settings > HUD > Waveform, and W over the HUD).
    @Published var waveform: Bool {
        didSet { defaults.set(waveform, forKey: "waveform") }
    }
    @Published var waveformStyle: WaveformStyle {
        didSet { defaults.set(waveformStyle.rawValue, forKey: "waveformStyle") }
    }
    /// The stems that get a lane in the waveform (⌥W), from the chips under the lanes.
    @Published var waveformLanes: Set<Stem> {
        didSet { defaults.set(waveformLanes.map(\.rawValue).sorted(), forKey: "waveformLanes") }
    }
    /// The floating mini player (M over the HUD, Settings > Mini player).
    @Published var miniPlayer: Bool {
        didSet { defaults.set(miniPlayer, forKey: "miniPlayer") }
    }
    @Published var miniLayout: MiniLayout {
        didSet { defaults.set(try? JSONEncoder().encode(miniLayout), forKey: "miniLayout") }
    }
    /// The background behind the mini player's record and song (Settings > Mini player > Background).
    @Published var miniBackground: MiniBackground {
        didSet { defaults.set(try? JSONEncoder().encode(miniBackground), forKey: "miniBackground") }
    }
    /// Whether the song goes beside the record, above or below it, on the record itself, or where the screen has room
    /// (Settings > Mini player > Layout).
    @Published var miniDirection: MiniDirection {
        didSet { defaults.set(miniDirection.rawValue, forKey: "miniDirection") }
    }
    /// The size of the mini player's record against its usual size (Settings > Mini player > Record > Size).
    @Published var miniRecordScale: Double {
        didSet { defaults.set(miniRecordScale, forKey: "miniRecordScale") }
    }
    /// Settings > Remote > Web remote: the page that paired devices open to play and change songs of Recents.
    @Published var webRemote: Bool {
        didSet {
            defaults.set(webRemote, forKey: "webRemote")
            Task { @MainActor in WebRemote.shared.update() }
        }
    }
    /// Settings > Remote > Address: the host that the pairing link and the links of `muskey --link` carry, as it goes
    /// in a URL. Nil picks Tailscale, then the local network (`WebAddresses.linkHost`).
    @Published var remoteAddress: String? {
        didSet {
            if let remoteAddress {
                defaults.set(remoteAddress, forKey: WebAddresses.choiceKey)
            } else {
                defaults.removeObject(forKey: WebAddresses.choiceKey)
            }
        }
    }
    /// Settings > Remote > Hide HUD for phone actions: requests from the web remote run with the HUD hidden
    /// (`WebRemote.headless`, which reads the key itself off the main thread).
    @Published var remoteHeadless: Bool {
        didSet { defaults.set(remoteHeadless, forKey: "remoteHeadless") }
    }
    /// Settings > Remote > Folders: the folders whose songs the web remote lists, by path.
    @Published var remoteFolders: [String] {
        didSet { defaults.set(remoteFolders, forKey: "remoteFolders") }
    }
    /// Settings > General > Send error reports. The key is the one that the other Low Tech Guys apps use.
    @Published var errorReports: Bool {
        didSet { defaults.set(errorReports, forKey: "enableSentry") }
    }

    private init() {
        defaults.register(defaults: ["launchAtLogin": true, "rememberKeys": true, "onlineKeys": false, "relativeKeys": false, "listenSeconds": 20, "karaokeMutesVocals": true, "karaokeRestarts": true, "karaokeBackdrop": true, "lyricsLiveTiming": true, "pauseStop": true, "pauseStopSeconds": 10, "autoHide": false, "autoHideSeconds": 6, "cacheCleanup": CacheCleanup.weekly.rawValue, "waveform": true, "enableSentry": true])
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        menuBarIcon = defaults.string(forKey: "menuBarIcon").flatMap(MenuBarIcon.init) ?? .always
        let seconds = defaults.integer(forKey: "listenSeconds")
        listenSeconds = Self.listenLengths.contains(seconds) ? seconds : 20
        rememberKeys = defaults.bool(forKey: "rememberKeys")
        onlineKeys = defaults.bool(forKey: "onlineKeys")
        alwaysListen = defaults.bool(forKey: "alwaysListen")
        relativeKeys = defaults.bool(forKey: "relativeKeys")
        naturalSwipes = defaults.bool(forKey: "naturalSwipes")
        lyricsTranscription = defaults.string(forKey: "lyricsTranscription").flatMap(LyricsTranscription.init) ?? .apple
        whisperServer = defaults.string(forKey: "whisperServer") ?? ""
        karaokeMutesVocals = defaults.bool(forKey: "karaokeMutesVocals")
        karaokeRestarts = defaults.bool(forKey: "karaokeRestarts")
        rewindEffect = defaults.string(forKey: "rewindEffect").flatMap(RewindEffect.init) ?? .scratch
        karaokeBackdrop = defaults.bool(forKey: "karaokeBackdrop")
        lyricsLiveTiming = defaults.bool(forKey: "lyricsLiveTiming")
        timingConditions = defaults.string(forKey: "timingConditions").flatMap(TimingConditions.init) ?? .notLowPower
        pauseStop = defaults.bool(forKey: "pauseStop")
        pauseStopSeconds = min(max(defaults.integer(forKey: "pauseStopSeconds"), 1), 3600)
        autoHide = defaults.bool(forKey: "autoHide")
        autoHideSeconds = min(max(defaults.integer(forKey: "autoHideSeconds"), 1), 3600)
        cacheCleanup = CacheCleanup(rawValue: defaults.double(forKey: "cacheCleanup")) ?? .weekly
        recordSpeed = defaults.object(forKey: "recordSpeed") == nil ? .slow : RecordSpeed(rawValue: defaults.double(forKey: "recordSpeed")) ?? .slow
        waveform = defaults.bool(forKey: "waveform")
        waveformStyle = defaults.string(forKey: "waveformStyle").flatMap(WaveformStyle.init) ?? .ribbon
        waveformLanes = (defaults.array(forKey: "waveformLanes") as? [Int]).map { Set($0.compactMap(Stem.init)) } ?? [.vocals, .guitar]
        miniPlayer = defaults.bool(forKey: "miniPlayer")
        miniLayout = defaults.data(forKey: "miniLayout").flatMap { try? JSONDecoder().decode(MiniLayout.self, from: $0) } ?? MiniLayout()
        miniBackground = defaults.data(forKey: "miniBackground").flatMap { try? JSONDecoder().decode(MiniBackground.self, from: $0) } ?? MiniBackground()
        miniDirection = defaults.string(forKey: "miniDirection").flatMap(MiniDirection.init) ?? .automatic
        // The song on the record was a switch of its own before it became a layout.
        if defaults.bool(forKey: "miniSongOnRecord") {
            miniDirection = .onRecord
            defaults.set(MiniDirection.onRecord.rawValue, forKey: "miniDirection")
        }
        defaults.removeObject(forKey: "miniSongOnRecord")
        let scales = MiniPlayerView.scales
        miniRecordScale = (defaults.object(forKey: "miniRecordScale") as? Double).map { min(max($0, scales.lowerBound), scales.upperBound) } ?? 1
        errorReports = defaults.bool(forKey: "enableSentry")
        webRemote = defaults.bool(forKey: "webRemote")
        remoteAddress = defaults.string(forKey: WebAddresses.choiceKey)
        remoteFolders = defaults.stringArray(forKey: "remoteFolders") ?? []
        remoteHeadless = defaults.bool(forKey: "remoteHeadless")
        saveFormat = defaults.string(forKey: "saveFormat").flatMap(SaveFormat.init).flatMap { SaveFormat.available.contains($0) ? $0 : nil } ?? .m4a
    }
}
