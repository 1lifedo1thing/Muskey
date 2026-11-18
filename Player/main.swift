// Muskey Player plays the songs that Muskey opens: files, and links that Muskey downloaded. It runs as an app of its
// own, so that Now Playing, the play key and every part of Muskey that listens to the Mac treat it like any music
// app. Muskey's taps leave Muskey's own process out, so a song that Muskey played itself would never be heard.
//
// Muskey writes one line per command to stdin:
//   open <json>    {"path": "/file.m4a", "title": "…", "artist": "…", "album": "…", "artwork": "/cover.jpg"}, with
//                  every field but the path optional. The title, artist, album and cover that the file carries fill
//                  in the rest, then the file name.
//   play, pause, toggle, seek <seconds>
// and reads one line per event from stdout:
//   ready <seconds>   the song plays, and lasts that long
//   failed <reason>   the song can't be played
//   ended             the song played to its end
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
}

final class Player: NSObject, NSApplicationDelegate {
    private let player = AVPlayer()
    private var info: [String: Any] = [:]
    private var opened = 0
    /// Says `ended` when the song that plays reaches its end.
    private var endWatch: Task<Void, Never>?
    private var rateObserver: NSKeyValueObservation?

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
        case "play": _ = play(true)
        case "pause": _ = play(false)
        case "toggle": _ = play(player.rate == 0)
        case "seek":
            if parts.count == 2, let seconds = Double(parts[1]) { seek(to: seconds) }
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
                guard try await asset.load(.isPlayable) else { return say("failed not playable") }
                let duration = try await asset.load(.duration).seconds
                guard current == opened else { return }
                let read = await Self.metadata(asset, url: url)
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
                endWatch?.cancel()
                endWatch = Task { @MainActor [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                        self?.report()
                        self?.say("ended")
                    }
                }
                player.replaceCurrentItem(with: item)
                player.play()
                report()
                say(String(format: "ready %.3f", duration))
            } catch {
                guard current == opened else { return }
                say("failed \(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }

    /// The title, artist, album and cover that the file carries. A file without a title is named after the file,
    /// and a name like `Artist - Title` gives both.
    private static func metadata(_ asset: AVURLAsset, url: URL) async -> (title: String, artist: String?, album: String?, artwork: NSImage?) {
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
            let name = url.deletingPathExtension().lastPathComponent
            if artist == nil, let dash = name.range(of: " - ") {
                artist = String(name[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
                title = String(name[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                title = name
            }
        }
        return (title ?? url.lastPathComponent, artist, album, artwork)
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
            if item.currentTime() >= item.duration - CMTime(seconds: 0.2, preferredTimescale: 600) { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
        report()
        return .success
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.report() }
        }
        report(at: max(0, seconds))
    }

    /// Tells Now Playing where the song is and whether it plays. Now Playing moves the time on by itself between reports.
    private func report(at position: Double? = nil) {
        guard !info.isEmpty else { return }
        let center = MPNowPlayingInfoCenter.default()
        var info = info
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position ?? player.currentTime().seconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(player.rate)
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
