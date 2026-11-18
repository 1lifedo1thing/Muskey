import AppKit
import Carbon.HIToolbox
import Combine

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

/// What listens to the song to time its lyrics, and to write lyrics that LRCLIB doesn't have.
/// How the song steps back in itself when the separated stems take over, or the lyrics delay starts.
enum RewindEffect: String, CaseIterable {
    /// A backspin, like a record pulled back by hand.
    case scratch
    /// A fade out of what plays, then a fade in of the earlier moment.
    case fade
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
    /// Karaoke blurs and dims the rest of the screen around the glass.
    @Published var karaokeBackdrop: Bool {
        didSet { defaults.set(karaokeBackdrop, forKey: "karaokeBackdrop") }
    }
    /// The base URL of the Whisper server, up to `/v1`.
    @Published var whisperServer: String {
        didSet { defaults.set(whisperServer, forKey: "whisperServer") }
    }

    private init() {
        defaults.register(defaults: ["launchAtLogin": true, "rememberKeys": true, "onlineKeys": false, "relativeKeys": false, "listenSeconds": 20, "karaokeMutesVocals": true, "karaokeRestarts": true, "karaokeBackdrop": true])
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
    }
}
