import AppKit
import AudioToolbox
import CoreAudio
import ScriptingBridge

/// Songs that the tool or the web remote name by a Spotify link: Spotify plays them, and Muskey listens to it as it
/// listens to any player. Spotify's AppleScript plays a track, an album, a playlist or an artist by its URI.
enum Spotify {
    static let bundleID = "com.spotify.client"

    /// `spotify:track:ID` from that URI, or from a link like `https://open.spotify.com/intl-de/track/ID?si=…`.
    static func uri(from text: String) -> String? {
        let kinds = ["track", "album", "playlist", "artist", "episode", "show"]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("spotify:") {
            let parts = trimmed.split(separator: ":").map(String.init)
            guard parts.count >= 3, kinds.contains(parts[parts.count - 2].lowercased()), isID(parts[parts.count - 1]) else { return nil }
            return "spotify:\(parts[parts.count - 2].lowercased()):\(parts[parts.count - 1])"
        }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "open.spotify.com" || host == "play.spotify.com" else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard let at = parts.firstIndex(where: { kinds.contains($0.lowercased()) }), at + 1 < parts.count, isID(parts[at + 1]) else { return nil }
        return "spotify:\(parts[at].lowercased()):\(parts[at + 1])"
    }

    /// A link to Spotify's site or app, which only Spotify can play.
    static func isLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("spotify:") || URL(string: text)?.host?.lowercased().hasSuffix("spotify.com") == true
    }

    private static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    enum Outcome { case playing, refused, needsConsent, failed(String) }

    /// Opens Spotify when it isn't running and plays the URI there. `done` runs on the main thread.
    static func play(_ uri: String, done: @escaping (Outcome) -> Void) {
        Task { @MainActor in
            var app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            if app == nil {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return done(.failed("Spotify isn't installed")) }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                // Spotify answers AppleScript once its window loaded, a few seconds after launch.
                try? await Task.sleep(for: .seconds(4))
            }
            guard let pid = app?.processIdentifier else { return done(.failed("Spotify didn't open")) }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                switch PlayerScript.permission(pid, ask: false) {
                case noErr: break
                case OSStatus(errAEEventNotPermitted): return .refused
                case OSStatus(errAEEventWouldRequireUserConsent):
                    // A play from the remote can't wait for an answer that only someone at the Mac can give, so the
                    // question waits on the Mac's screen for the next time.
                    Task.detached { _ = PlayerScript.permission(pid) }
                    return .needsConsent
                case let status: return .failed("Spotify can't be scripted (\(status))")
                }
                guard let spotify = SBApplication(processIdentifier: pid) else { return .failed("ScriptingBridge can't reach Spotify") }
                // `play track "spotify:…"`, which plays an album, a playlist or an artist from its start.
                _ = spotify.perform(NSSelectorFromString("playTrack:inContext:"), with: uri, with: nil)
                return .playing
            }.value
            done(outcome)
        }
    }
}

/// The sound output of the Mac, muted while a song plays for the web remote or for the tool run over SSH, so that it
/// doesn't play through the speakers of a Mac that nobody sits at. A device without a mute control gets its volume
/// set to zero instead.
enum OutputMute {
    private static var device: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func settable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address) && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// The output is muted, or its volume is at zero. Nil without an output device.
    static var muted: Bool? {
        guard let device else { return nil }
        if settable(device, kAudioDevicePropertyMute) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = address(kAudioDevicePropertyMute)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value != 0 }
        }
        return volume(device).map { $0 == 0 }
    }

    /// The volume that a mute through the volume replaced, so an unmute sets it back.
    private static var volumeBefore: Float32?

    @discardableResult static func set(_ mute: Bool) -> Bool {
        guard let device else { return false }
        if settable(device, kAudioDevicePropertyMute) {
            var value: UInt32 = mute ? 1 : 0
            var address = address(kAudioDevicePropertyMute)
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        }
        guard settable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) else { return false }
        if mute { volumeBefore = volume(device) ?? volumeBefore }
        var value: Float32 = mute ? 0 : (volumeBefore ?? 0.5)
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func volume(_ device: AudioObjectID) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
