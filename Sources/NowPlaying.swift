import AppKit
import ImageIO
import Foundation

/// Watches the song that the Mac plays, through the helper in Contents/Helpers that reads MediaRemote. It calls
/// `onTrack` on every update, for the record in the HUD, and `onSongChange` when another song starts playing.
/// Main thread only.
final class NowPlaying {
    struct Track: Decodable, Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var timestamp: Double?
        var rate: Double?
        var bundleID: String?
        /// The process that Now Playing knows the player by, which the seek command goes to.
        var pid: Int32?
        var artworkBytes = 0
        /// Sent only when the cover changed, so `NowPlaying.artwork` keeps the last one.
        var artwork: Data?

        /// Seek, pause and new cover art leave these the same, so only a song change moves them.
        var song: [String?] { [title, artist, album] }
        var playing: Bool { (rate ?? 0) > 0 }
        var label: String { [artist, title].compactMap { $0 }.joined(separator: " – ") }

        /// Seconds into the song at `date`, moving on at the playback rate since the player last reported it.
        func position(at date: Date) -> Double? {
            guard let elapsed else { return nil }
            guard playing, let timestamp else { return elapsed }
            let position = elapsed + (date.timeIntervalSince1970 - timestamp) * (rate ?? 1)
            return duration.map { min(position, $0) } ?? position
        }

        static func == (a: Track, b: Track) -> Bool {
            a.title == b.title && a.artist == b.artist && a.album == b.album && a.duration == b.duration && a.elapsed == b.elapsed
                && a.timestamp == b.timestamp && a.rate == b.rate && a.bundleID == b.bundleID && a.pid == b.pid
                && a.artworkBytes == b.artworkBytes
        }
    }

    var onSongChange: (Track) -> Void = { _ in }
    var onTrack: () -> Void = {}
    /// The song as it is heard: the player's report, or what `heard` makes of it while a song is slowed down.
    private(set) var track: Track?
    /// The player's own report, for moving its song and for recording it.
    private(set) var player: Track?
    /// While set, makes the song as it is heard out of the player's report.
    var heard: ((Track) -> Track)?
    /// Every report of the player, before `track` is made from it.
    var onPlayerReport: (Track) -> Void = { _ in }
    /// The cover of `track`, nil when the player sends none.
    private(set) var artwork: NSImage?
    private var playerArtwork: NSImage?

    /// Runs the helper while true. The first track it reports counts as the song that was already playing.
    var watching = false {
        didSet {
            guard watching != oldValue else { return }
            watching ? start() : stop()
        }
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    /// The song that the last change was reported for, or that was playing when watching started.
    private var reported: [String?]?
    private var pending: DispatchWorkItem?
    var log: (String) -> Void = { _ in }

    private static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/com.apple.controlcenter.Muskey.NowPlaying")
    }

    private func start() {
        let process = Process()
        process.executableURL = Self.helperURL
        process.arguments = ["watch"]
        // The helper exits when its stdin closes, which happens when Muskey quits or crashes.
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // A line can hold a cover of megabytes, so the lines are decoded, and the covers made into thumbnails, on the
        // handler's queue, and the main thread gets the tracks.
        let reader = Reader()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            // At its end, a pipe stays readable and would call the handler again at once, without end.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let reports = reader.read(data)
            guard !reports.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let process, self.process === process else { return }
                for report in reports { self.update(report.track, cover: report.cover) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.log("now playing helper exited (\(ended.terminationStatus))")
                self.process = nil
                self.watching = false
            }
        }
        do {
            try process.run()
        } catch {
            log("starting the now playing helper failed: \(error)")
            watching = false
            return
        }
        self.process = process
        stdinPipe = input
        reported = nil
        track = nil
        player = nil
        artwork = nil
        playerArtwork = nil
    }

    /// Plays or pauses the song, the way the play key does, through the helper while it runs.
    func togglePlayPause() {
        guard let stdinPipe else { return log("play or pause: the now playing helper isn't running") }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("playpause\n".utf8))
    }

    /// Plays or pauses the song whatever it does now, through the helper while it runs.
    func play(_ on: Bool) {
        guard let stdinPipe else { return log("\(on ? "play" : "pause"): the now playing helper isn't running") }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((on ? "play\n" : "pause\n").utf8))
    }

    /// Skips to the next or the previous song, the way the media keys do, through the helper.
    func skip(_ direction: Int) {
        let command = direction > 0 ? "next" : "previous"
        guard let stdinPipe else { return Self.run([command]) { _ in } }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
    }

    /// Moves the song to `seconds` into it, the way dragging the time in Control Center does, through the helper.
    func seek(to seconds: Double) {
        guard let stdinPipe else { return log("seek: the now playing helper isn't running") }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(String(format: "seek %.3f\n", seconds).utf8))
    }

    /// Sends the seek command with the time to the player running as `pid`, the way Control Center's scrubber does,
    /// for players that leave the elapsed time alone.
    func seek(to seconds: Double, pid: Int32) {
        guard let stdinPipe else { return log("seek: the now playing helper isn't running") }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(String(format: "seekclient %d %.3f\n", pid, seconds).utf8))
    }

    /// Pauses the song that another app plays, before Muskey Player starts one, then calls `done` on the main thread.
    /// The helper is asked what plays when it isn't watching. `done` waits 0.3 seconds after the pause, so the pause
    /// reaches the other app before Muskey Player becomes the app that Now Playing names. Every step has a bound.
    func pauseOthers(except bundleID: String, then done: @escaping () -> Void) {
        let other = { (track: Track?) in track.map { $0.playing && $0.bundleID != bundleID } ?? false }
        if let stdinPipe, track != nil {
            guard other(track) else { return done() }
            log("pausing \(track?.bundleID ?? "the other player") before playing")
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("pause\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            return
        }
        Self.run(["get"]) { [weak self] track in
            guard other(track) else { return done() }
            self?.log("pausing \(track?.bundleID ?? "the other player") before playing")
            Self.run(["pause"]) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
        }
    }

    /// Runs the helper once with `arguments`, and calls `done` on the main thread with the track that it printed, or
    /// nil when it printed none, failed or took longer than 3 seconds.
    private static func run(_ arguments: [String], done: @escaping (Track?) -> Void) {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        var finished = false
        let finish = { (track: Track?) in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                done(track)
            }
        }
        do { try process.run() } catch { return finish(nil) }
        // The output holds the cover, more than a pipe buffers, so it is read while the helper writes it, and decoded
        // here too.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            finish(process.terminationStatus == 0 ? try? JSONDecoder().decode(Track.self, from: data) : nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
            finish(nil)
        }
    }

    private func stop() {
        pending?.cancel()
        pending = nil
        let process = process
        self.process = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        process?.terminate()
        reported = nil
        track = nil
        player = nil
        move = nil
        artwork = nil
        playerArtwork = nil
        onTrack()
    }

    /// Splits the helper's output into lines and decodes them, on the queue of the pipe's readability handler, which
    /// calls it one chunk at a time.
    private final class Reader: @unchecked Sendable {
        private var buffer = Data()

        /// The tracks of the lines that `data` ends, each with its cover: nil when the line sent none, and nil inside
        /// when the cover can't be decoded.
        func read(_ data: Data) -> [(track: Track, cover: NSImage??)] {
            buffer.append(data)
            // A line holds one cover at most, so a buffer this big means the helper stopped ending its lines.
            if buffer.count > 64_000_000 { buffer.removeAll() }
            // The lines before `data` were taken already, so only a newline in `data` ends one.
            guard data.contains(0x0A) else { return [] }
            var reports: [(track: Track, cover: NSImage??)] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< end]
                buffer.removeSubrange(buffer.startIndex ... end)
                guard var track = try? JSONDecoder().decode(Track.self, from: line) else { continue }
                let cover = track.artwork.map(NowPlaying.cover)
                track.artwork = nil
                reports.append((track, cover))
            }
            return reports
        }
    }

    /// Covers come from whatever app or web page plays, so only common image types are decoded, as a thumbnail the
    /// size of the record.
    private static func cover(_ data: Data) -> NSImage? {
        guard data.count < 16_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png", "public.heic", "org.webmproject.webp"].contains(type)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// The time of Muskey Player's last move, which the track keeps until Now Playing reports a later one. Now Playing
    /// ignores a report whose elapsed time is the one it already holds, which a region loop sends on every pass, and
    /// the song then seemed to play on past the loop.
    private var move: (elapsed: Double, at: Double, bundleID: String)?

    /// Muskey Player moved its song to `seconds`, which the track shows at once.
    func moved(to seconds: Double, bundleID: String) {
        move = (seconds, Date().timeIntervalSince1970, bundleID)
        guard let player, player.bundleID == bundleID else { return }
        update(player, cover: nil)
    }

    private func update(_ track: Track, cover: NSImage??) {
        var track = track
        if let move {
            if track.bundleID == move.bundleID, (track.timestamp ?? 0) < move.at {
                track.elapsed = move.elapsed
                track.timestamp = move.at
            } else {
                self.move = nil
            }
        }
        if let cover {
            playerArtwork = cover
        } else if track.artworkBytes == 0, track.song != player?.song {
            // Players report no cover for a moment on pause and resume, so the cover only goes with its song.
            playerArtwork = nil
        }
        player = track
        onPlayerReport(track)
        publish()
    }

    /// Makes `track` again from the player's last report, after the song as it is heard changed.
    func refresh() {
        guard player != nil else { return }
        publish()
    }

    private func publish() {
        guard let player else { return }
        let track = heard?(player) ?? player
        // A song heard behind the player keeps its cover until the output reaches the player's song.
        if track.song == player.song { artwork = playerArtwork }
        self.track = track
        onTrack()
        guard let reported else { return self.reported = track.song }
        // A paused song that changed counts once it plays, so a listen never starts on silence.
        guard track.title != nil, track.song != reported, track.playing else { return }
        // Some players send the title before the artist and album, so the song has to hold for a moment.
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let current = self.track, current.song == track.song, current.song != self.reported else { return }
            self.reported = current.song
            self.onSongChange(current)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}
