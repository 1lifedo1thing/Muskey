import AppKit
import AVFoundation
import CoreTransferable
import CryptoKit
import Foundation

/// A file or a link dropped on the HUD: a file from Finder, a link from a browser, or a link dragged as text.
struct DroppedSong: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in DroppedSong(url: url) })
        ProxyRepresentation(importing: { (text: String) in
            guard let url = FilePlayer.url(from: text) else { throw CocoaError(.fileReadUnknown) }
            return DroppedSong(url: url)
        })
    }
}

/// For the small requests around a download, so that a stalled one never holds the song for long.
let quickSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 20
    return URLSession(configuration: configuration)
}()

/// What the activity pill shows while Muskey opens a song: a download, or a failure with what recovers from it.
enum OpenActivity: Equatable {
    /// A link downloads, with its title once yt-dlp names it, or its site before that.
    case downloading(name: String, progress: Double?)
    /// yt-dlp downloads into Muskey's folder, after Install yt-dlp.
    case installing(progress: Double?)
    /// The download failed, and Retry tries it again.
    case failed(name: String)
    /// The link needs yt-dlp, which isn't on the Mac.
    case needsDownloader(name: String)
    /// yt-dlp couldn't be downloaded, and Retry tries it again.
    case installFailed
    /// AVFoundation can't play the file.
    case unplayable(name: String)
    /// A song is saved with its changes: rendered, or recorded as it plays from another player, with the time left.
    case saving(name: String, progress: Double?)
    case recording(name: String, left: String, progress: Double? = nil)
    /// The song was saved, and Show in Finder shows the file.
    case saved(name: String)
    /// Saving failed, and Retry saves it again.
    case saveFailed(name: String)
}

/// Plays the songs that Muskey opens: files, links to audio and video files, and pages that yt-dlp downloads from.
/// Muskey Player (Contents/Helpers) plays them as an app of its own, so that Now Playing, the play key and Muskey's
/// taps treat it like any music app. Files dropped together play one after the other, and previous and next step
/// through them. Main thread only.
final class FilePlayer {
    static let bundleID = "com.lowtechguys.Muskey.Player"

    var onActivity: (OpenActivity?) -> Void = { _ in }
    /// The song plays.
    var onPlaying: () -> Void = {}
    /// Pauses the song of another app before Muskey Player starts one, and calls its argument once that is done.
    var pauseOthers: (@escaping () -> Void) -> Void = { $0() }
    var log: (String) -> Void = { _ in }
    /// Muskey Player starts or stops having a song, for Stop Playing in the menu.
    var onChange: () -> Void = {}
    /// Muskey Player moved its song to a place, in seconds, for any move. Now Playing reports some of them seconds later.
    var onMove: (Double) -> Void = { _ in }

    /// Muskey Player has a song, playing or paused. Without one, the songs that it plays next start at their tempo.
    private(set) var hasSong = false {
        didSet {
            if !hasSong {
                speed = 1
                current = nil
            }
            if hasSong != oldValue { onChange() }
        }
    }

    /// The song that Muskey Player plays, once it said that it plays it, for saving it with its changes.
    private(set) var current: Song?
    /// The song sent to Muskey Player, until it plays it.
    private var starting: Song?

    /// The rate that Muskey Player plays its songs at, from 0.5 to 1.5, faster or slower with the pitch.
    private(set) var speed = 1.0

    func setSpeed(_ rate: Double) {
        speed = rate
        send(String(format: "speed %.3f", rate))
    }

    private var process: Process?
    private var input: Pipe?
    private var buffer = Data()
    /// Muskey Player's process, while it runs.
    var pid: pid_t? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    /// The queue: the songs opened or added together, in the order they play.
    private(set) var queue: [QueueItem] = [] {
        didSet { onQueue() }
    }
    /// The song of the queue that plays, or nil after it was removed while it played. `resume` is then the place of
    /// the song that plays next.
    private(set) var currentID: UUID? {
        didSet { if currentID != oldValue { onQueue() } }
    }
    private var resume = 0
    /// The queue changed: songs added, removed or moved, details read, or another song started.
    var onQueue: () -> Void = {}
    private var index: Int { currentID.flatMap { id in queue.firstIndex { $0.id == id } } ?? resume }
    /// The link or file being opened, for Retry.
    private var opening: URL?
    private var download: LinkDownload?
    private var install: DownloaderInstall?
    private let cache = LinkCache()

    private static var playerURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/Muskey Player.app/Contents/MacOS/Muskey Player")
    }

    private static func playable(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// Files and links of the web, the first one played now and the rest after it. They replace the queue.
    func open(_ urls: [URL]) {
        let urls = Self.playable(urls)
        guard !urls.isEmpty else { return }
        queue = urls.map { QueueItem(url: $0, cached: cache.song(for: $0)) }
        play(queue[0].id)
        readDetails()
    }

    /// Adds songs to the end of the queue, or after the song that plays with `next`. A queue with nothing playing
    /// starts with them.
    func add(_ urls: [URL], next: Bool) {
        let items = Self.playable(urls).map { QueueItem(url: $0, cached: cache.song(for: $0)) }
        guard !items.isEmpty else { return }
        log("adding \(items.count) song\(items.count == 1 ? "" : "s") to the queue\(next ? " after the song that plays" : "")")
        let at = next ? min(queue.count, (currentID == nil ? resume : index + 1)) : queue.count
        queue.insert(contentsOf: items, at: at)
        if !hasSong, download == nil { play(items[0].id) }
        readDetails()
    }

    /// Plays a song of the queue.
    func play(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        currentID = id
        start(item.url)
    }

    /// Takes songs out of the queue. The song that plays goes on to its end, and then the song after it plays.
    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let place = index
        let before = queue.prefix(place).filter { ids.contains($0.id) }.count
        if let currentID, ids.contains(currentID) {
            resume = place - before
            self.currentID = nil
        } else if currentID == nil {
            resume = max(0, resume - before)
        }
        queue.removeAll { ids.contains($0.id) }
    }

    /// Moves songs to `offset` in the queue, keeping their order, as a drag in the list does.
    func move(_ ids: Set<UUID>, to offset: Int) {
        let moving = queue.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let target = offset - queue.prefix(offset).filter { ids.contains($0.id) }.count
        var rest = queue.filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, target)))
        queue = rest
    }

    /// Moves a song right after the one that plays.
    func playNext(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }), id != currentID else { return }
        var rest = queue.filter { $0.id != id }
        let place = currentID.flatMap { current in rest.firstIndex { $0.id == current } }.map { $0 + 1 } ?? min(resume, rest.count)
        rest.insert(item, at: place)
        if currentID == nil { resume = place }
        queue = rest
    }

    /// Previous or next, for the songs in the queue. Previous on the first song starts it over.
    func skip(_ direction: Int) {
        let target = currentID == nil && direction > 0 ? resume : index + (direction > 0 ? 1 : -1)
        if queue.indices.contains(target) {
            play(queue[target].id)
        } else if direction < 0 {
            send("seek 0")
        }
    }

    /// Reads the title, artist, album, length and cover of each song in the queue that doesn't have them yet.
    private func readDetails() {
        // A link has its details once it is downloaded, and is read then.
        for item in queue where !item.read {
            guard let file = item.file else { continue }
            Task { [weak self] in
                let details = await QueueItem.details(file)
                guard let self, let at = queue.firstIndex(where: { $0.id == item.id }) else { return }
                queue[at].apply(details)
            }
        }
    }

    /// Sets the key and the tempo of a song in the queue, once they are known.
    func setAnalysis(_ id: UUID, key: DetectedKey?, bpm: Double?) {
        guard let at = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[at].key = key ?? queue[at].key
        queue[at].bpm = bpm ?? queue[at].bpm
        queue[at].analysed = true
    }

    /// Moves the song to `seconds` from its start.
    func seek(_ seconds: Double) { send(String(format: "seek %.3f", seconds)) }

    /// Repeats the song from `region.start` to `region.end` seconds, or plays on with nil. Muskey Player moves the song
    /// back at the exact end of the region, without waiting for Muskey.
    func loop(_ region: (start: Double, end: Double)?) {
        send(region.map { String(format: "loop %.3f %.3f", $0.start, $0.end) } ?? "loop off")
    }

    /// Stop Playing: Muskey Player quits, with the songs opened together.
    func close() {
        log("stop playing")
        download?.cancel()
        download = nil
        queue = []
        currentID = nil
        resume = 0
        opening = nil
        show(nil)
        stop()
    }

    private func send(_ line: String) {
        try? input?.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// A link or a path that was pasted or typed, with or without `https://`.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "file" { return url }
            return ["http", "https"].contains(scheme) && url.host?.contains(".") == true ? url : nil
        }
        guard !text.contains(" "), let url = URL(string: "https://" + text), url.host?.contains(".") == true else { return nil }
        return url
    }

    func retry() {
        if install != nil { return }
        if case .installFailed? = lastActivity { return installDownloader() }
        if let opening { start(opening) }
    }

    /// Install yt-dlp, from the pill of a link that needs it. The link opens once it is installed.
    func installDownloader() {
        guard install == nil else { return }
        show(.installing(progress: nil))
        let install = DownloaderInstall()
        self.install = install
        install.log = log
        install.onProgress = { [weak self] progress in self?.show(.installing(progress: progress)) }
        install.start { [weak self] ok in
            guard let self else { return }
            self.install = nil
            guard ok else { return show(.installFailed) }
            show(nil)
            if let opening, !opening.isFileURL { start(opening) }
        }
    }

    func dismiss() {
        download?.cancel()
        download = nil
        show(nil)
    }

    /// Muskey quits: the player quits with it, once its stdin closes.
    func stop() {
        download?.cancel()
        try? input?.fileHandleForWriting.close()
        input = nil
        process = nil
        hasSong = false
    }

    private var lastActivity: OpenActivity?

    private func show(_ activity: OpenActivity?) {
        lastActivity = activity
        onActivity(activity)
    }

    private func start(_ url: URL) {
        download?.cancel()
        download = nil
        opening = url
        if url.isFileURL { return play(Song(path: url.path)) }
        if let song = cache.song(for: url) {
            log("opening a link that was downloaded before")
            return play(song)
        }
        let name = url.host().map { $0.replacingOccurrences(of: "www.", with: "") } ?? url.absoluteString
        let direct = LinkDownload.directExtensions.contains(url.pathExtension.lowercased())
        guard direct || Downloader.find() != nil else {
            log("a link needs yt-dlp, which isn't installed")
            return show(.needsDownloader(name: name))
        }
        show(.downloading(name: name, progress: nil))
        let download = LinkDownload(url: url, folder: cache.folder, direct: direct)
        self.download = download
        download.log = log
        download.onProgress = { [weak self, weak download] title, progress in
            guard let self, self.download === download else { return }
            show(.downloading(name: title ?? name, progress: progress))
        }
        download.start { [weak self, weak download] song in
            guard let self, self.download === download else { return }
            self.download = nil
            guard let song else { return show(.failed(name: name)) }
            cache.keep(song, for: url)
            if let at = queue.firstIndex(where: { $0.url == url }) { queue[at].apply(cached: song) }
            readDetails()
            play(song)
        }
    }

    /// A song for Muskey Player, with the title, artist, album and cover that a download knows. A file fills in the rest.
    struct Song: Codable {
        var path: String
        var title: String?
        var artist: String?
        var album: String?
        var artwork: String?
    }

    private func play(_ song: Song) {
        guard FileManager.default.fileExists(atPath: song.path) else { return show(.unplayable(name: (song.path as NSString).lastPathComponent)) }
        guard let data = try? JSONEncoder().encode(song), let json = String(data: data, encoding: .utf8) else { return }
        pauseOthers { [weak self] in
            guard let self else { return }
            guard launch(), let input else { return show(.unplayable(name: (song.path as NSString).lastPathComponent)) }
            log("opening \(song.title == nil ? "a file" : "a downloaded song") in Muskey Player")
            starting = song
            try? input.fileHandleForWriting.write(contentsOf: Data("open \(json)\n".utf8))
        }
    }

    /// Starts Muskey Player if it isn't running.
    private func launch() -> Bool {
        if process?.isRunning == true { return true }
        let process = Process()
        process.executableURL = Self.playerURL
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At its end, a pipe stays readable and would call the handler again at once, without end.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.received(data) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.log("Muskey Player exited (\(ended.terminationStatus))")
                self.process = nil
                self.input = nil
                self.hasSong = false
            }
        }
        do {
            try process.run()
        } catch {
            log("starting Muskey Player failed: \(error)")
            return false
        }
        self.process = process
        self.input = input
        buffer.removeAll()
        return true
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex ..< end], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ... end)
            event(line)
        }
    }

    private func event(_ line: String) {
        if line.hasPrefix("ready") {
            log("Muskey Player plays the song (\(line.dropFirst(6)) seconds)")
            show(nil)
            current = starting
            hasSong = true
            onPlaying()
        } else if line.hasPrefix("failed") {
            log("Muskey Player can't play the song: \(line.dropFirst(7))")
            current = nil
            show(.unplayable(name: opening.map { $0.isFileURL ? $0.lastPathComponent : ($0.host() ?? $0.absoluteString) } ?? "Song"))
        } else if line == "ended", currentID == nil ? resume < queue.count : index + 1 < queue.count {
            skip(1)
        } else if line.hasPrefix("moved "), let seconds = Double(line.dropFirst(6)) {
            onMove(seconds)
        } else if line == "next" || line == "previous" {
            log("\(line) song in Muskey Player")
            skip(line == "next" ? 1 : -1)
        }
    }
}

/// yt-dlp, from Homebrew, pipx or Muskey's folder, where Install yt-dlp puts the official build for macOS. A GUI app
/// has no shell PATH, so the places are listed.
enum Downloader {
    static let installed = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Muskey/yt-dlp")

    static func find() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "\(home)/.local/bin/yt-dlp", installed.path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// ffmpeg lets yt-dlp take any audio and convert it. Without it, yt-dlp takes only the formats that AVFoundation
    /// plays.
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return environment
    }()
}

/// Downloads the official yt-dlp build for macOS from its GitHub releases into Muskey's folder, checks it against the
/// SHA-256 sums published with it, and runs it once to see that it works.
final class DownloaderInstall: NSObject, URLSessionDownloadDelegate {
    var onProgress: (Double?) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    private var done: ((Bool) -> Void)?
    private var session: URLSession?
    private static let release = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"

    func start(_ done: @escaping (Bool) -> Void) {
        self.done = done
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: URL(string: Self.release + "yt-dlp_macos")!).resume()
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        onProgress(total > 0 ? Double(written) / Double(total) : nil)
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` goes away when this returns, so it is moved first.
        let staged = FileManager.default.temporaryDirectory.appending(path: "muskey-yt-dlp-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            return finish(false, "moving yt-dlp failed: \(error)")
        }
        Task { [self] in
            let ok = await verify(staged)
            await MainActor.run { finish(ok, ok ? "yt-dlp installed" : "yt-dlp didn't pass its checks") }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(false, "downloading yt-dlp failed: \(error.localizedDescription)") }
    }

    private func verify(_ staged: URL) async -> Bool {
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let sums = try? await quickSession.data(from: URL(string: Self.release + "SHA2-256SUMS")!).0,
              let line = String(decoding: sums, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(" yt-dlp_macos") }),
              let data = try? Data(contentsOf: staged)
        else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard line.hasPrefix(digest) else { return false }
        let target = Downloader.installed
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.copyItem(at: staged, to: target)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let version = await LinkDownload.run(target, ["--version"], seconds: 60)
        return version?.isEmpty == false
    }

    private func finish(_ ok: Bool, _ line: String) {
        guard let done else { return }
        self.done = nil
        log(line)
        session?.invalidateAndCancel()
        done(ok)
    }
}

/// Downloads a link into Muskey's cache: a link to an audio or video file directly, and any other page with yt-dlp.
/// The audio is kept in an M4A file that AVFoundation plays with the right length, with the title, artist and cover
/// that the page gives.
final class LinkDownload: NSObject, URLSessionDownloadDelegate {
    static let directExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "mp4", "m4v", "mov"]

    var onProgress: (String?, Double?) -> Void = { _, _ in }
    var log: (String) -> Void = { _ in }
    private let url: URL
    private let folder: URL
    private let direct: Bool
    private var done: ((FilePlayer.Song?) -> Void)?
    private var process: Process?
    private var session: URLSession?
    private var title: String?
    private var cancelled = false

    init(url: URL, folder: URL, direct: Bool) {
        self.url = url
        self.folder = folder
        self.direct = direct
    }

    func start(_ done: @escaping (FilePlayer.Song?) -> Void) {
        self.done = done
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        direct ? downloadFile() : downloadPage(updated: false)
    }

    func cancel() {
        cancelled = true
        process?.terminate()
        session?.invalidateAndCancel()
        done = nil
    }

    private func finish(_ song: FilePlayer.Song?) {
        guard let done else { return }
        self.done = nil
        done(song)
    }

    // MARK: A file

    private func downloadFile() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        onProgress(nil, total > 0 ? Double(written) / Double(total) : nil)
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return finish(nil) }
        let name = url.deletingPathExtension().lastPathComponent
        let target = folder.appending(path: "link-\(Self.key(url)).\(url.pathExtension.lowercased())")
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: location, to: target)) != nil else { return finish(nil) }
        // The player reads the file's own title, and the name of the file when it has none.
        let named = folder.appending(path: "link-\(Self.key(url))-\(name.prefix(80)).\(url.pathExtension.lowercased())")
        try? FileManager.default.removeItem(at: named)
        let path = (try? FileManager.default.moveItem(at: target, to: named)) != nil ? named.path : target.path
        finish(FilePlayer.Song(path: path))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !cancelled {
            log("downloading a link failed: \(error.localizedDescription)")
            finish(nil)
        }
    }

    // MARK: A page, with yt-dlp

    /// Lines of yt-dlp's output that Muskey reads, from its `--print` and `--progress-template` options.
    private static let progressTag = "muskey-progress ", titleTag = "muskey-title ", fileTag = "muskey-file "

    /// yt-dlp downloads the audio alone, in a format that AVFoundation plays. With ffmpeg, it converts any audio to
    /// M4A. The link comes after `--`, so a link can't pass options, and no config file or playlist is read.
    private func downloadPage(updated: Bool) {
        guard let downloader = Downloader.find() else { return finish(nil) }
        let base = "page-\(Self.key(url))"
        var arguments = ["--ignore-config", "--no-playlist", "--no-mtime", "--no-part", "--write-info-json", "--no-write-playlist-metafiles",
                         "-o", folder.appending(path: "\(base).download.%(ext)s").path,
                         "--progress", "--newline", "--progress-template",
                         "download:\(Self.progressTag)%(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
                         "--print", "before_dl:\(Self.titleTag)%(title)s", "--print", "after_move:\(Self.fileTag)%(filepath)s"]
        if let ffmpeg = Downloader.ffmpeg {
            arguments += ["--ffmpeg-location", ffmpeg, "-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
        } else {
            arguments += ["-f", "ba[ext=m4a]/ba[ext=mp3]/b[ext=mp4]"]
        }
        arguments += ["--", url.absoluteString]

        let process = Process()
        process.executableURL = downloader
        process.arguments = arguments
        process.environment = Downloader.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        self.process = process

        var file: String?
        var errorText = ""
        var pending = Data()
        var lastLine = Date()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At its end, a pipe stays readable and would call the handler again at once, without end.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !data.isEmpty else { return }
                pending.append(data)
                while let end = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex ..< end], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex ... end)
                    lastLine = Date()
                    if line.hasPrefix(Self.titleTag) {
                        self.title = String(line.dropFirst(Self.titleTag.count))
                        self.onProgress(self.title, nil)
                    } else if line.hasPrefix(Self.progressTag) {
                        let numbers = line.dropFirst(Self.progressTag.count).split(separator: " ").map { Double($0) }
                        let total = numbers.count == 3 ? numbers[1] ?? numbers[2] : nil
                        if let downloaded = numbers.first ?? nil, let total, total > 0 { self.onProgress(self.title, min(1, downloaded / total)) }
                    } else if line.hasPrefix(Self.fileTag) {
                        file = String(line.dropFirst(Self.fileTag.count))
                    }
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { if errorText.count < 4000 { errorText += String(decoding: data, as: UTF8.self) } }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { [weak self] in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                guard let self, !cancelled else { return }
                self.process = nil
                if ended.terminationStatus == 0, let file {
                    Task { await self.finishPage(file: file, base: base) }
                    return
                }
                let error = errorText.split(separator: "\n").last { $0.hasPrefix("ERROR") }.map(String.init) ?? "exit \(ended.terminationStatus)"
                log("yt-dlp failed: \(error)")
                // Sites change faster than yt-dlp's releases, so the copy that Muskey installed updates itself once.
                if !updated, downloader == Downloader.installed {
                    Task {
                        _ = await Self.run(downloader, ["-U"], seconds: 120)
                        await MainActor.run { self.downloadPage(updated: true) }
                    }
                    return
                }
                finish(nil)
            }
        }
        do {
            try process.run()
        } catch {
            log("starting yt-dlp failed: \(error)")
            return finish(nil)
        }
        // A download that writes nothing for two minutes is stuck, and none takes longer than 20 minutes.
        let started = Date()
        func watch() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.process === process, process.isRunning else { return }
                if Date().timeIntervalSince(lastLine) > 120 || Date().timeIntervalSince(started) > 1200 {
                    log("yt-dlp stopped answering, ending it")
                    process.terminate()
                    return
                }
                watch()
            }
        }
        watch()
    }

    /// Writes the audio into an M4A that AVFoundation reads with the right length (the DASH M4A from YouTube reads
    /// as twice as long), and reads the title, artist, album and cover that the page gives.
    private func finishPage(file: String, base: String) async {
        let source = URL(fileURLWithPath: file)
        let target = folder.appending(path: "\(base).m4a")
        let ok = await Self.remux(source, to: target)
        if ok { try? FileManager.default.removeItem(at: source) }
        let infoURL = folder.appending(path: "\(base).download.info.json")
        let info = (try? Data(contentsOf: infoURL)).flatMap { try? JSONDecoder().decode(PageInfo.self, from: $0) }
        try? FileManager.default.removeItem(at: infoURL)
        var song = FilePlayer.Song(path: ok ? target.path : file)
        if let info {
            let named = info.song
            song.title = named.title
            song.artist = named.artist
            song.album = info.album
            if let thumbnail = info.thumbnail.flatMap(URL.init(string:)), thumbnail.scheme == "https",
               let (data, response) = try? await quickSession.data(from: thumbnail),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count < 10_000_000, NSImage(data: data) != nil
            {
                let cover = folder.appending(path: "\(base).cover")
                if (try? data.write(to: cover)) != nil { song.artwork = cover.path }
            }
        }
        let found = song
        await MainActor.run { finish(found) }
    }

    /// Copies the audio into a new M4A without converting it, or converts the audio of a video into M4A.
    static func remux(_ source: URL, to target: URL) async -> Bool {
        try? FileManager.default.removeItem(at: target)
        let asset = AVURLAsset(url: source)
        let video = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
        guard let export = AVAssetExportSession(asset: asset, presetName: video ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough) else { return false }
        do {
            try await export.export(to: target, as: .m4a)
            return true
        } catch {
            return false
        }
    }

    /// What yt-dlp says about the page.
    struct PageInfo: Decodable {
        let title: String?
        let track: String?
        let artist: String?
        let album: String?
        let uploader: String?
        let channel: String?
        let thumbnail: String?

        /// The title and artist for Now Playing. Music sites name the track and the artist. A video names the
        /// artist in its title, as `Artist - Title (Official Video)`, or by its channel.
        var song: (title: String?, artist: String?) {
            if let track, !track.isEmpty, let artist, !artist.isEmpty { return (track, artist.components(separatedBy: ", ").first) }
            guard let title else { return (nil, nil) }
            let channel = Self.channelName(uploader ?? channel ?? "")
            if let dash = title.range(of: " - ") ?? title.range(of: " – ") {
                let named = String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(title[dash.upperBound...])
                return (LyricsFinder.clean(rest, artist: named).title, named)
            }
            return (LyricsFinder.clean(title, artist: channel).title, channel.isEmpty ? nil : channel)
        }

        /// `Artist - Topic`, `ArtistVEVO` and `Artist Official` name the artist.
        static func channelName(_ name: String) -> String {
            var name = name
            for suffix in [" - Topic", "VEVO", " Official", " official"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            return name.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Runs a program for its output, which comes back nil when it fails or takes longer than `seconds`.
    static func run(_ program: URL, _ arguments: [String], seconds: Double) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = program
            process.arguments = arguments
            process.environment = Downloader.environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let lock = NSLock()
            var resumed = false
            let resume = { (text: String?) in
                lock.withLock {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: text)
                }
            }
            do { try process.run() } catch { return resume(nil) }
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                resume(process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if process.isRunning { process.terminate() }
                resume(nil)
            }
        }
    }

    /// A name for the files of a link, the same each time.
    static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The songs that links were downloaded into, in `~/Library/Caches/Muskey/Links`, so a link opened again plays at
/// once. The oldest songs go once the folder holds more than 2 GB.
final class LinkCache {
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Links")
    private var index: URL { folder.appending(path: "links.json") }
    private static let limit = 2_000_000_000
    /// Every read and write of the index, from every instance and from the cleanup, one at a time. A song kept
    /// after a download is written there off the main thread, and a read waits for it, as does quitting.
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "muskey.links", qos: .utility)
        StoreFiles.add(queue)
        return queue
    }()

    func song(for url: URL) -> FilePlayer.Song? {
        guard let song = Self.queue.sync(execute: load)[url.absoluteString], FileManager.default.fileExists(atPath: song.path) else { return nil }
        // Opened again, so it is the newest for the limit.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: song.path)
        return song
    }

    /// The link was downloaded before, and its song plays at once.
    func has(_ url: URL) -> Bool {
        Self.queue.sync(execute: load)[url.absoluteString].map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The links that songs were downloaded from, the song opened last first.
    func recent(_ limit: Int) -> [(link: URL, song: FilePlayer.Song)] {
        Self.queue.sync(execute: load).compactMap { key, song -> (URL, FilePlayer.Song, Date)? in
            guard let link = URL(string: key),
                  let date = try? URL(fileURLWithPath: song.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (link, song, date)
        }
        .sorted { $0.2 > $1.2 }
        .prefix(limit)
        .map { (link: $0.0, song: $0.1) }
    }

    /// Adds the song to the index, after deleting the oldest songs past the limit, which lists the whole folder.
    func keep(_ song: FilePlayer.Song, for url: URL) {
        Self.queue.async { [self] in
            var songs = load()
            songs[url.absoluteString] = song
            trim(&songs)
            if let data = try? JSONEncoder().encode(songs) { try? data.write(to: index, options: .atomic) }
        }
    }

    private func load() -> [String: FilePlayer.Song] {
        (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode([String: FilePlayer.Song].self, from: $0) } ?? [:]
    }

    /// Deletes the songs that weren't opened for `age`, except the ones at `kept`, and forgets their links.
    func sweep(olderThan age: TimeInterval, keeping kept: Set<String>) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let deadline = Date().addingTimeInterval(-age)
        var removed = 0
        for file in files where file.lastPathComponent != "links.json" && !kept.contains(file.path) {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < deadline else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        guard removed > 0 else { return 0 }
        Self.queue.sync {
            let songs = load().filter { FileManager.default.fileExists(atPath: $0.value.path) }
            if let data = try? JSONEncoder().encode(songs) { try? data.write(to: index, options: .atomic) }
        }
        return removed
    }

    private func trim(_ songs: inout [String: FilePlayer.Song]) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let sized = files.filter { $0.lastPathComponent != "links.json" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = sized.reduce(0) { $0 + $1.1 }
        for (file, size, _) in sized where total > Self.limit {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
        songs = songs.filter { FileManager.default.fileExists(atPath: $0.value.path) }
    }
}
