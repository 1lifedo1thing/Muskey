import AppKit
import ScriptingBridge

/// How a seek reaches a player: the elapsed time that Now Playing shows, the seek command sent to the player's process,
/// or the player's AppleScript. Players differ in the one they take, and Muskey tries them in this order.
enum SeekPath: String {
    case elapsed, command, script

    var name: String {
        switch self {
        case .elapsed: "elapsed time"
        case .command: "seek command"
        case .script: "AppleScript"
        }
    }

    /// The path to try when this one left the song where it was.
    func next(for bundleID: String) -> SeekPath? {
        switch self {
        case .elapsed: .command
        case .command: PlayerScript.scriptable(bundleID) ? .script : nil
        case .script: nil
        }
    }
}

/// Moves the song through the player's AppleScript, for players that ignore the seeks that Now Playing sends. macOS
/// asks for the Automation permission the first time Muskey scripts a player, so only a seek that needs it asks.
enum PlayerScript {
    enum Outcome { case sent, refused, failed(String) }

    /// The property of each scriptable player that holds the time into the song, in seconds.
    private static let positionKey: [String: String] = [
        "com.spotify.client": "playerPosition",
        "com.apple.Music": "playerPosition",
        "com.apple.TV": "playerPosition",
        "com.swinsian.Swinsian": "playerPosition",
        "org.videolan.vlc": "currentTime",
    ]

    static func scriptable(_ bundleID: String) -> Bool { positionKey[bundleID] != nil }

    /// Sets the time in the player, off the main thread, since macOS may ask for the permission first and the event
    /// waits for the player to answer. The event goes to the running process of the player, as LaunchServices could
    /// pick another copy of the app by its bundle ID. `done` runs on the main thread.
    static func seek(_ bundleID: String, to seconds: Double, done: @escaping (Outcome) -> Void) {
        guard let key = positionKey[bundleID] else { return done(.failed("\(bundleID) has no AppleScript for its time")) }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
            return done(.failed("\(bundleID) isn't running"))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            switch permission(pid) {
            case noErr:
                if let app = SBApplication(processIdentifier: pid) {
                    app.setValue(max(0, seconds), forKey: key)
                    outcome = .sent
                } else {
                    outcome = .failed("ScriptingBridge can't reach \(bundleID)")
                }
            case OSStatus(errAEEventNotPermitted):
                outcome = .refused
            case let status:
                outcome = .failed("the Automation check for \(bundleID) failed (\(status))")
            }
            DispatchQueue.main.async { done(outcome) }
        }
    }

    /// Asks macOS whether Muskey may script the process, and lets macOS ask the person when nobody has answered yet.
    /// It waits for that answer.
    private static func permission(_ pid: pid_t) -> OSStatus {
        guard var target = NSAppleEventDescriptor(processIdentifier: pid).aeDesc?.pointee else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
    }
}
