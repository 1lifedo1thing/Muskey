// Muskey Player plays the songs that Muskey opens: files, and links that Muskey downloaded. It runs as an app of its
// own, so that Now Playing, the play key and every part of Muskey that listens to the Mac treat it like any music
// app. Muskey's taps leave Muskey's own process out, so a song that Muskey played itself would never be heard.
//
// Muskey writes one line per command to stdin:
//   open <json>    {"path": "/file.m4a", "title": "…", "artist": "…", "album": "…", "artwork": "/cover.jpg"}, with
//                  every field but the path optional. The title, artist, album and cover that the file carries fill
//                  in the rest, then the file name.
//   cancel         drops the song that `open` named while it is still read, before `ready`
//   play, pause, toggle, seek <seconds>
//   speed <rate>  every song plays at this rate from then on, faster or slower with its pitch, like a turntable
//                 (Muskey's pitch change shifts the pitch back to the key)
// and reads one line per event from stdout:
//   ready <seconds>   the song plays, and lasts that long
//   failed <reason>   the song can't be played
//   ended             the song played to its end
//   moved <seconds>   the song moved to that place, for any move: Muskey's, Control Center's scrubber, Previous that
//                     starts the song over, or play at the end. Now Playing reports some of these seconds later.
//   at <seconds> <time> <rate>   with every report to Now Playing: the song was at that place at that Unix time and
//                     moves on at that rate. Now Playing stamps a report when it gets to it, about half a second later,
//                     so Muskey takes the song's place from these lines.
//   next, previous    the next or previous track command came, from the media keys, Control Center or Muskey's HUD;
//                     Muskey keeps the songs, so it opens the other one. Previous more than 3 seconds into a song
//                     starts it over, as music apps do, and says nothing.
// The player quits when stdin closes, which happens when Muskey quits or crashes.
import AppKit
import AVFoundation
import MediaPlayer

struct Request: Decodable {
    var path: String
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?
    /// Names a song whose file carries no title: the name of the file that a link points to.
    var name: String?
}

final class Player: NSObject, NSApplicationDelegate {
    private let player = AVPlayer()
    private var info: [String: Any] = [:]
    private var opened = 0
    /// Says `ended` when the song that plays reaches its end.
    private var endWatch: Task<Void, Never>?
    private var rateObserver: NSKeyValueObservation?
    /// The rate that play starts the song at, from `speed`.
    private var speed: Float = 1
    /// The region loop: where it starts, and the observer that moves the song back there at its end.
    private var loopStart: Double?
    /// Counts the moves of the song, so that only the last one gets its second report.
    private var moves = 0
    private var loopObserver: Any?

    func applicationDidFinishLaunching(_: Notification) {
        player.actionAtItemEnd = .pause
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [self] _ in play(true) }
        commands.pauseCommand.addTarget { [self] _ in play(false) }
        commands.togglePlayPauseCommand.addTarget { [self] _ in play(player.rate == 0) }
        // Control Center's scrubber, and the moves that Muskey asks for through MediaRemote, like karaoke's restart.
        commands.changePlaybackPositionCommand.addTarget { [self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seek(to: event.positionTime)
            return .success
        }
        commands.nextTrackCommand.addTarget { [self] _ in
            say("next")
            return .success
        }
        commands.previousTrackCommand.addTarget { [self] _ in
            if player.currentTime().seconds > 3 { seek(to: 0) } else { say("previous") }
            return .success
        }
        for command in [commands.skipForwardCommand, commands.skipBackwardCommand] {
            command.isEnabled = false
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.report() }
        }
        readCommands()
    }

    private func readCommands() {
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        var buffer = Data()
        input.setEventHandler { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            guard count > 0 else { exit(0) }
            buffer.append(contentsOf: chunk[0 ..< count])
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex ... newline)
                handle(line)
            }
        }
        input.resume()
        commandSource = input
    }

    private var commandSource: DispatchSourceRead?

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "open":
            guard parts.count == 2, let request = try? JSONDecoder().decode(Request.self, from: Data(parts[1].utf8)) else { return say("failed bad request") }
            open(request)
        // The song being read is dropped, and the one that plays goes on.
        case "cancel": opened += 1
        case "play": _ = play(true)
        case "pause": _ = play(false)
        case "toggle": _ = play(player.rate == 0)
        case "seek":
            if parts.count == 2, let seconds = Double(parts[1]) { seek(to: seconds) }
        case "speed":
            if parts.count == 2, let rate = Float(parts[1]), (0.25 ... 4).contains(rate) { setSpeed(rate) }
        case "loop":
            // `loop A B` repeats the song from A to B seconds, and `loop off` lets it play on.
            setLoop(parts.count == 2 ? parts[1].split(separator: " ").compactMap { Double($0) } : [])
        default: break
        }
    }

    private func open(_ request: Request) {
        opened += 1
        let current = opened
        let url = URL(fileURLWithPath: request.path)
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            do {
                let playable = try await asset.load(.isPlayable)
                // A song that was cancelled or replaced meanwhile says nothing.
                guard current == opened else { return }
                guard playable else { return say("failed not playable") }
                let duration = try await asset.load(.duration).seconds
                guard current == opened else { return }
                let read = await Self.metadata(asset, name: request.name ?? url.deletingPathExtension().lastPathComponent)
                var info: [String: Any] = [
                    MPMediaItemPropertyTitle: request.title ?? read.title,
                    MPMediaItemPropertyPlaybackDuration: duration,
                    MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                ]
                if let artist = request.artist ?? read.artist { info[MPMediaItemPropertyArtist] = artist }
                if let album = request.album ?? read.album { info[MPMediaItemPropertyAlbumTitle] = album }
                var cover = request.artwork.flatMap { NSImage(contentsOfFile: $0) } ?? read.artwork
                if cover == nil { cover = await Self.frame(asset, duration: duration) }
                if let cover {
                    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
                }
                guard current == opened else { return }
                self.info = info
                let item = AVPlayerItem(asset: asset)
                // Faster or slower with the pitch, which Muskey's Rubber Band shifts back in one pass with any key
                // change: of the stretches tried, this one kept the sound closest to the original.
                item.audioTimePitchAlgorithm = .varispeed
                endWatch?.cancel()
                endWatch = Task { @MainActor [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                        self?.report()
                        self?.say("ended")
                    }
                }
                setLoop([])
                player.replaceCurrentItem(with: item)
                player.play()
                report()
                reportAgain()
                say(String(format: "ready %.3f", duration))
            } catch {
                guard current == opened else { return }
                say("failed \(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }

    /// The title, artist, album and cover that the file carries. A file without a title is named after the file, or
    /// after the file that its link points to, and a name like `Artist - Title` gives both.
    private static func metadata(_ asset: AVURLAsset, name: String) async -> (title: String, artist: String?, album: String?, artwork: NSImage?) {
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first else { return nil }
            let value = try? await item.load(.stringValue)
            return value?.isEmpty == false ? value : nil
        }
        var title = await string(.commonKeyTitle)
        var artist = await string(.commonKeyArtist)
        let album = await string(.commonKeyAlbumName)
        var artwork: NSImage?
        if let item = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
           let data = try? await item.load(.dataValue)
        {
            artwork = NSImage(data: data)
        }
        if title == nil {
            if artist == nil, let dash = name.range(of: " - ") {
                artist = String(name[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
                title = String(name[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                title = name
            }
        }
        return (title ?? name, artist, album, artwork)
    }

    /// A frame from a tenth of the way into a video, as the cover of a video without one.
    private static func frame(_ asset: AVURLAsset, duration: Double) async -> NSImage? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: duration * 0.1, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func play(_ playing: Bool) -> MPRemoteCommandHandlerStatus {
        guard let item = player.currentItem else { return .noActionableNowPlayingItem }
        if playing {
            // Play at the end starts the song over, as music apps do.
            if item.currentTime() >= item.duration - CMTime(seconds: 0.2, preferredTimescale: 600) {
                player.seek(to: .zero)
                say("moved 0.000")
            }
            player.play()
        } else {
            player.pause()
        }
        report()
        return .success
    }

    /// The player says when the song reaches the end of the loop, at the exact time, and the song moves back to its
    /// start without waiting for Muskey. Each move is reported like any seek, so the lyrics and the stems follow it.
    private func setLoop(_ ends: [Double]) {
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        loopObserver = nil
        loopStart = nil
        guard ends.count == 2, ends[1] > ends[0] + 0.05 else { return }
        loopStart = ends[0]
        let end = NSValue(time: CMTime(seconds: ends[1], preferredTimescale: 48000))
        loopObserver = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak self] in
            guard let self, let start = loopStart else { return }
            seek(to: start)
        }
        // A snap can move the end a moment past the press, which the song can reach before the loop arrives here. The
        // boundary never fires for a time that already passed, and the song played on past the loop.
        if player.currentTime().seconds >= ends[1] { seek(to: ends[0]) }
    }

    private func setSpeed(_ rate: Float) {
        speed = rate
        player.defaultRate = rate
        if player.rate > 0 { player.rate = rate }
        report()
    }

    private func seek(to seconds: Double) {
        say(String(format: "moved %.3f", max(0, seconds)))
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.report() }
        }
        report(at: max(0, seconds))
        reportAgain()
    }

    /// Now Playing ignores a report whose elapsed time is the one it already holds, however long ago that one came: a
    /// region loop goes back to the same start on every pass, and the same file opened again starts at 0 like the
    /// last one. Control Center then showed the song playing on past the loop. A second report once the song has moved
    /// on gets through when the first one didn't. Muskey takes the time of a move from `moved` in any case.
    private func reportAgain() {
        moves += 1
        let move = moves
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, moves == move else { return }
            report()
        }
    }

    /// Tells Now Playing where the song is and whether it plays. Now Playing moves the time on by itself between reports.
    private func report(at position: Double? = nil) {
        guard !info.isEmpty else { return }
        let center = MPNowPlayingInfoCenter.default()
        var info = info
        let elapsed = position ?? player.currentTime().seconds
        say(String(format: "at %.4f %.4f %.3f", elapsed, Date().timeIntervalSince1970, Double(player.rate)))
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(player.rate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(speed)
        center.nowPlayingInfo = info
        center.playbackState = player.rate > 0 ? .playing : .paused
    }

    private func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

let app = NSApplication.shared
let delegate = Player()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
