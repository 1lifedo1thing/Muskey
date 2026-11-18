import Foundation

// Reads what is playing through the private MediaRemote framework and prints it as one JSON line per change.
// mediaremoted answers only processes whose code signing identifier starts with com.apple., so the Makefile
// signs this helper as com.apple.controlcenter.Muskey.
//
//   watch   a line at start and after every change, until stdin closes or the parent process exits. A line
//           `playpause` on stdin plays or pauses the song, `pause` pauses it, and `seek <seconds>` moves it to that
//           time.
//   get     one line, then exit
//   playpause  plays or pauses the song, then exits
//   pause   pauses the song, then exits
//   seek <seconds>  moves the song to that time, then exits

struct Track: Encodable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    /// Seconds into the track at `timestamp`, which moves on at `rate` while it plays.
    var elapsed: Double?
    var timestamp: Double?
    var rate: Double?
    var bundleID: String?
    var artworkBytes = 0
    /// The cover art, sent only when it differs from the one in the last line.
    var artwork: Data?
}

enum MediaRemote {
    private static let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))

    private static func function<T>(_ name: String, as _: T.Type) -> T? {
        guard let bundle, let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private typealias GetClient = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private typealias ClientString = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
    private typealias Register = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias SetElapsed = @convention(c) (Double) -> Void

    static var available: Bool { function("MRMediaRemoteGetNowPlayingInfo", as: GetInfo.self) != nil }

    static func register() {
        function("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self)?(.main)
    }

    /// The play or pause command that the media keys send to the player of the song (kMRTogglePlayPause).
    @discardableResult static func togglePlayPause() -> Bool {
        function("MRMediaRemoteSendCommand", as: SendCommand.self)?(2, nil) ?? false
    }

    /// The pause command (kMRPause), which leaves a paused song paused.
    @discardableResult static func pause() -> Bool {
        function("MRMediaRemoteSendCommand", as: SendCommand.self)?(1, nil) ?? false
    }

    /// Moves the song to `seconds` into it, the way dragging the time in Control Center does.
    @discardableResult static func seek(to seconds: Double) -> Bool {
        guard let setElapsed = function("MRMediaRemoteSetElapsedTime", as: SetElapsed.self) else { return false }
        setElapsed(max(0, seconds))
        return true
    }

    static func read(_ completion: @escaping (Track) -> Void) {
        guard let getInfo = function("MRMediaRemoteGetNowPlayingInfo", as: GetInfo.self) else { return completion(Track()) }
        var track = Track()
        let group = DispatchGroup()
        group.enter()
        getInfo(.main) { info in
            if let info {
                track.title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                track.artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                track.album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
                track.duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double
                track.elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double
                track.timestamp = (info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date)?.timeIntervalSince1970
                track.rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double
                track.artwork = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                track.artworkBytes = track.artwork?.count ?? 0
            }
            group.leave()
        }
        if let getClient = function("MRMediaRemoteGetNowPlayingClient", as: GetClient.self),
           let bundleID = function("MRNowPlayingClientGetBundleIdentifier", as: ClientString.self) {
            group.enter()
            getClient(.main) { client in
                track.bundleID = client.flatMap { bundleID($0)?.takeUnretainedValue() as String? }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(track) }
    }
}

func write(_ track: Track) {
    guard var data = try? JSONEncoder().encode(track) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

final class Watcher {
    private var last: Track?
    private var lastArtwork: Data?

    /// Prints the track when anything in it changed, with the cover art only when the art itself changed.
    func refresh() {
        MediaRemote.read { [self] track in
            var line = track
            if track.artwork == lastArtwork { line.artwork = nil } else { lastArtwork = track.artwork }
            var compared = line
            compared.artwork = nil
            guard compared != last || line.artwork != nil else { return }
            last = compared
            write(line)
        }
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "get"
guard MediaRemote.available else {
    FileHandle.standardError.write(Data("MediaRemote is not available\n".utf8))
    exit(2)
}

switch command {
case "get":
    MediaRemote.read { track in
        var line = track
        line.artwork = nil
        write(line)
        exit(0)
    }
    RunLoop.main.run(until: Date() + 3)
    exit(1)

case "watch":
    let watcher = Watcher()
    MediaRemote.register()
    for name in [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    ] {
        NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in watcher.refresh() }
    }
    // Some players change the track without a notification, so the state is read again every few seconds.
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in watcher.refresh() }
    watcher.refresh()

    // The parent holds the other end of stdin, so end of file means Muskey quit or crashed. Each line it writes is a
    // command.
    let stdin = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    var pending = ""
    stdin.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { exit(0) }
        pending += String(decoding: buffer[0 ..< count], as: UTF8.self)
        while let end = pending.firstIndex(of: "\n") {
            let line = pending[..<end]
            pending = String(pending[pending.index(after: end)...])
            if line == "playpause" { MediaRemote.togglePlayPause() }
            if line == "pause" { MediaRemote.pause() }
            if line.hasPrefix("seek "), let seconds = Double(line.dropFirst(5)) { MediaRemote.seek(to: seconds) }
        }
    }
    stdin.resume()
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parent.setEventHandler { exit(0) }
    parent.resume()
    RunLoop.main.run()

case "playpause", "pause":
    let sent = CommandLine.arguments[1] == "pause" ? MediaRemote.pause() : MediaRemote.togglePlayPause()
    // The command is sent from the main queue, so it is given a moment to leave before the helper exits.
    RunLoop.main.run(until: Date() + 0.3)
    exit(sent ? 0 : 1)

case "seek":
    guard let seconds = CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) else {
        FileHandle.standardError.write(Data("usage: \(CommandLine.arguments[0]) seek <seconds>\n".utf8))
        exit(64)
    }
    let sent = MediaRemote.seek(to: seconds)
    // The command is sent from the main queue, so it is given a moment to leave before the helper exits.
    RunLoop.main.run(until: Date() + 0.3)
    exit(sent ? 0 : 1)

default:
    FileHandle.standardError.write(Data("usage: \(CommandLine.arguments[0]) get|watch|playpause|pause|seek <seconds>\n".utf8))
    exit(64)
}
