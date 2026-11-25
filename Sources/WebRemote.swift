import AppKit
import os

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "WebRemote")

/// The notes of a song as the sheet in a browser reads them: a transcription and the artist for the line under its title.
struct WebNotes: Encodable {
    let title: String
    let stem: String
    let key: String?
    let bpm: Double
    let duration: Double
    let beats: [Double]
    let notes: [TranscribedNote]
    let artist: String?

    init(fixture: NotesFixture, artist: String?) {
        title = fixture.title
        stem = fixture.stem
        key = fixture.key
        bpm = fixture.bpm
        duration = fixture.duration
        beats = fixture.beats
        notes = fixture.notes
        self.artist = artist
    }
}

/// The web remote: a page that a paired phone or computer opens to pick a song of Recents, play it on the Mac with a
/// change of key, tempo or instruments, hear that change in the browser, and read its notes. The page asks Muskey for
/// the same plays and jobs as the `muskey` tool, through `CLIService`.
///
/// Pairing is a link with a random key, which sets a cookie on the device that opens it. A request that changes
/// anything also needs the page's own origin, and the Host of every request must be one of the Mac's addresses, so a
/// web page elsewhere can't reach the remote through a DNS name that points here. A song is named by an ID from
/// Recents, never by a path.
@MainActor final class WebRemote {
    static let shared = WebRemote()

    /// The songs of Recents with what Muskey knows of them, the newest first. Set by the app.
    var recents: () async -> [QueueItem] = { [] }
    /// The HUD's song and key, the cover of the song that plays, and the switch for the Mac's sound. Set by the app.
    var state: () -> State? = { nil }
    var nowCover: () -> NSImage? = { nil }
    var mute: (Bool) -> Void = { _ in }
    /// Plays or pauses the song that plays on the Mac, or moves it, as the HUD's Space and arrow keys do.
    var transport: (WebTransport) -> Void = { _ in }
    /// A change of the region loop from the phone.
    var loop: (WebLoop) -> Void = { _ in }
    /// The waveform of the song that plays, as the HUD draws it.
    var waveform: () -> SongWaveform? = { nil }
    /// The phone shows the song that plays, where a tap on an instrument can come at any moment.
    var songShown: () -> Void = {}
    private var pageLines: [Date] = []

    /// A line from the page, at most 30 a minute and 400 characters each.
    func pageLog(_ text: String) {
        let now = Date()
        pageLines = pageLines.filter { now.timeIntervalSince($0) < 60 }
        guard pageLines.count < 30 else { return }
        pageLines.append(now)
        let line = String(text.replacingOccurrences(of: "\n", with: " ").prefix(400))
        log.info("remote page: \(line, privacy: .public)")
    }

    /// What the remote shows of the song that plays on the Mac.
    struct State: Encodable {
        var title: String?
        var artist: String?
        /// The player, like Spotify or Muskey.
        var app: String?
        var playing: Bool
        /// Muskey listens for the key now.
        var listening: Bool
        /// The key that the song was found in, like `Em`, and the change.
        var key: String?
        var shift: Int
        var relative: Bool
        var bpm: Double?
        var speed: Double
        var cover: Bool
        /// The Mac's sound output is muted. Nil without an output device.
        var muted: Bool?
        /// Settings > HUD shows the keys in both modes.
        var relativeKeys: Bool
        /// The file that Muskey plays, left out of the answer.
        var file: String?
        /// The song of Recents that Muskey plays, by its ID.
        var song: String?
        /// Seconds into the song, and its length, when the player gives them.
        var position: Double?
        var duration: Double?
        /// The player takes seeks now.
        var seekable: Bool
        /// The Mac's name, from Settings > General > Sharing.
        var mac: String
        /// The instruments that don't play, by their names in lowercase.
        var mutedStems: [String] = []
        /// Phones that hear the Mac's output.
        var listeners = 0
        /// The region loop: its start, and its end once it is set.
        var loop: Loop?
        /// Changes whenever the waveform has more of the song, so the page fetches it again only then.
        var wave: Int?

        struct Loop: Encodable {
            let start: Double
            let end: Double?
        }

        enum CodingKeys: CodingKey {
            case title, artist, app, playing, listening, key, shift, relative, bpm, speed, cover, muted, relativeKeys, song, position, duration,
                 seekable, mac, mutedStems, listeners, loop, wave
        }
    }

    /// The symbols of the HUD that the page draws, which are the only ones that it can ask for.
    nonisolated static let symbols: Set<String> = [
        "music.mic", "metronome.fill", "hifispeaker.fill", "guitars.fill", "pianokeys", "music.quarternote.3", "wind", "headphones",
        "chevron.left", "chevron.right", "play.fill", "pause.fill", "macbook", "speaker.wave.2.fill", "speaker.slash.fill",
        "waveform", "music.note.list", "arrow.clockwise", "xmark", "music.note", "ear", "minus", "plus", "gobackward.5", "goforward.5", "iphone",
        "repeat", "checkmark", "exclamationmark.triangle.fill", "square.and.arrow.down",
    ]

    /// A symbol as a black PNG at three times its point size, which the page uses as a mask to colour it.
    func symbolPNG(_ name: String) -> Data? {
        guard Self.symbols.contains(name),
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                  .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 60, weight: .semibold))
        else { return nil }
        let size = symbol.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded(.up)), pixelsHigh: Int(size.height.rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSColor.black.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Starts the server when the remote is on, and stops it when nothing else needs it.
    func update() {
        WebUploads.target = Self.uploadTarget
        Task.detached(priority: .background) { Self.removeOldUploads() }
        guard Self.enabled else { return WebLinks.shared.stopIfIdle() }
        if Self.storedKey == nil { reset() }
        WebLinks.shared.start()
    }

    /// Songs sent from a phone, each in a folder named by a random token, kept like the songs downloaded from links.
    nonisolated static let uploads = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Uploads")

    /// Songs sent from a phone are deleted after a week.
    nonisolated static func removeOldUploads() {
        let fm = FileManager.default
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for folder in (try? fm.contentsOfDirectory(at: uploads, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < weekAgo { try? fm.removeItem(at: folder) }
        }
    }

    /// The file that the body of `POST /api/upload` goes to, for a paired phone of the remote's own page. The checks
    /// run on the headers alone, before any of the body is read.
    nonisolated static func uploadTarget(method: String, path: String, headers: [String: String], length: Int) -> URL? {
        guard method == "POST", path == "/api/upload", enabled, let key = storedKey,
              let host = host(headers["host"])?.lowercased(), WebAddresses.allowedHosts().contains(host),
              same(cookieValue(headers) ?? "", key),
              let origin = headers["origin"], origin == "http://\(headers["host"] ?? "")"
        else { return nil }
        let sent = (headers["x-file-name"]?.removingPercentEncoding ?? "song") as NSString
        var name = String(sent.lastPathComponent.filter { !"/:\\\0".contains($0) }.prefix(180))
        if name.isEmpty || name.hasPrefix(".") { name = "song" + name }
        if !SongName.mediaExtensions.contains((name as NSString).pathExtension.lowercased()) { name += ".m4a" }
        let folder = uploads.appending(path: randomHex())
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        return folder.appending(path: name)
    }

    /// A new pairing key: the devices that opened the old link lose the remote.
    func reset() {
        UserDefaults.standard.set(Self.randomHex(), forKey: Self.pairKey)
    }

    /// The link that pairs a device, at the address that reaches the furthest.
    var pairingLink: String? {
        // Settings can ask before `update` ran for the toggle that turned the remote on.
        if Self.storedKey == nil { reset() }
        guard let base = WebLinks.base, let key = Self.storedKey else { return nil }
        return "\(base)/pair/\(key)"
    }

    // MARK: Requests

    private nonisolated static let enabledKey = "webRemote"
    private nonisolated static let pairKey = "webRemoteKey"
    private nonisolated static let cookie = "muskey"

    nonisolated static var storedKey: String? { UserDefaults.standard.string(forKey: pairKey) }

    nonisolated static func randomHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares every character, so the time of an answer doesn't tell how much of a key was right.
    nonisolated private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The host of a Host header, without its port and brackets.
    nonisolated private static func host(_ header: String?) -> String? {
        guard let header else { return nil }
        if header.hasPrefix("["), let end = header.firstIndex(of: "]") { return String(header[header.index(after: header.startIndex) ..< end]) }
        return header.split(separator: ":").first.map(String.init)
    }

    nonisolated private static func cookieValue(_ request: WebRequest) -> String? {
        cookieValue(request.headers)
    }

    nonisolated private static func cookieValue(_ headers: [String: String]) -> String? {
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == cookie { return String(pair[1]) }
        }
        return nil
    }

    nonisolated static func handle(_ request: WebRequest) async -> WebResponse {
        guard enabled, let key = storedKey else { return .notFound }
        // DNS names are compared in lowercase, since a browser may keep the capitals of a name like Studio-Mac.local.
        guard let host = host(request.headers["host"])?.lowercased(), WebAddresses.allowedHosts().contains(host) else {
            return .text("Unknown host", status: 403)
        }
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if parts.count == 2, parts[0] == "pair" {
            guard request.method == "GET", same(parts[1], key) else { return .notFound }
            return WebResponse(status: 303, headers: [
                ("Location", "/"), ("Cache-Control", "no-store"),
                ("Set-Cookie", "\(cookie)=\(key); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax"),
            ])
        }
        let paired = same(cookieValue(request) ?? "", key)
        if parts.isEmpty, request.method == "GET" || request.method == "HEAD" {
            guard paired else { return page("pair") }
            // Phones paired by the first builds hold a Strict cookie, which Safari leaves out when the page opens from a
            // QR code or another app, so the cookie is set again as Lax.
            var response = page("remote")
            response.headers.append(("Set-Cookie", "\(cookie)=\(key); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax"))
            return response
        }
        guard paired else { return .text("This device isn't paired", status: 403) }
        if request.method == "POST" {
            guard let origin = request.headers["origin"], origin == "http://\(request.headers["host"] ?? "")" else {
                return .text("Wrong origin", status: 403)
            }
        }

        // A route of two parts, with an ID as the third for the routes that take one.
        let route = parts.prefix(2).joined(separator: "/")
        let id = parts.count == 3 ? parts[2] : nil
        let reads = request.method == "GET" || request.method == "HEAD"
        let response = await { () async -> WebResponse in
        switch route {
        case "web/sheet.js", "web/sheet.css", "web/remote.js", "web/remote.css":
            guard reads, parts.count == 2, let url = Bundle.main.url(forResource: parts[1], withExtension: nil, subdirectory: "Web") else { return .notFound }
            return WebLinks.file(url.path, request: request, extra: [("Cache-Control", "no-cache")])
        case "api/state" where reads && parts.count == 2:
            if request.query["view"] == "song" { await MainActor.run { shared.songShown() } }
            guard var state = await MainActor.run(body: { shared.state() }) else { return .notFound }
            if let file = state.file { state.song = await shared.songID(file: file) }
            state.listeners = WebStream.shared.listeners
            return json(state)
        case "api/nowcover" where reads && parts.count == 2:
            guard let jpeg = await MainActor.run(body: { SongTags.jpeg(shared.nowCover()) }) else { return .notFound }
            return WebResponse(status: 200, headers: [("Content-Type", "image/jpeg"), ("Cache-Control", "no-store")], body: .data(jpeg))
        case "api/symbol" where reads:
            guard let id, let png = await MainActor.run(body: { shared.symbolPNG(id) }) else { return .notFound }
            return WebResponse(status: 200, headers: [("Content-Type", "image/png"), ("Cache-Control", "private, max-age=86400")], body: .data(png))
        case "api/open" where request.method == "POST" && parts.count == 2:
            // A link of any site that yt-dlp reads plays in Muskey Player, and a Spotify link plays in Spotify.
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body), let link = body["link"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Spotify.uri(from: link) != nil || URL(string: link).map({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }) == true
            else {
                return json(WebJob(CLIResponse(error: "That isn't a link to a song", done: true)))
            }
            let request = CLIRequest(command: .play, inputs: [link])
            return json(WebJob(await MainActor.run { CLIService.shared.handle(request) }))
        case "api/upload" where request.method == "POST" && parts.count == 2:
            guard let file = request.bodyFile else { return .text("Send the song as the body", status: 400) }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            log.info("\(String(format: "remote: received %@ from a phone (%.1f MB)", file.lastPathComponent, Double(size) / 1_000_000), privacy: .public)")
            let play = CLIRequest(command: .play, inputs: [file.path])
            return json(WebJob(await MainActor.run { CLIService.shared.handle(play) }))
        case "api/files" where reads && parts.count == 2:
            return json(await shared.macFiles(matching: request.query["q"] ?? ""))
        case "api/spotify" where request.method == "POST" && parts.count == 2:
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body), let link = body["link"], Spotify.uri(from: link) != nil else {
                return json(WebJob(CLIResponse(error: "That isn't a Spotify link", done: true)))
            }
            // The Mac's sound follows the output picked on the phone, so the request itself doesn't mute it.
            let request = CLIRequest(command: .play, inputs: [link])
            return json(WebJob(await MainActor.run { CLIService.shared.handle(request) }))
        case "api/live" where request.method == "POST" && parts.count == 2:
            guard let action = try? JSONDecoder().decode(WebLive.self, from: request.body) else { return .text("Unreadable request", status: 400) }
            if let key = action.key, Int(key) == nil, key.range(of: #"^[A-G](#|b)?m?$"#, options: .regularExpression) == nil { return .text("Wrong key", status: 400) }
            if let speed = action.speed, !(0.5 ... 1.5).contains(speed) { return .text("Wrong speed", status: 400) }
            if let stems = action.stems, !stems.allSatisfy(muskeyStemNames.contains) { return .text("Wrong instruments", status: 400) }
            var play = CLIRequest(command: .play)
            play.key = action.key
            play.speed = action.speed
            play.stems = action.stems
            let request = play
            return json(WebJob(await MainActor.run { CLIService.shared.handle(request) }))
        case "api/stream" where request.method == "GET" && parts.count == 2:
            // The Mac's output with no end, at the rate in the header: AAC in ADTS frames with `format=aac`, or 16-bit
            // stereo PCM.
            let rate = WebStream.shared.rate
            let aac = request.query["format"] == "aac"
            return WebResponse(status: 200, headers: [
                ("Content-Type", aac ? "audio/aac" : "application/octet-stream"), ("Cache-Control", "no-store"), ("X-Sample-Rate", String(Int(rate))),
            ], body: .stream { sink in _ = WebStream.shared.add(sink, aac: aac) })
        case "api/log" where request.method == "POST" && parts.count == 2:
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body), let message = body["message"] else {
                return .text("Unreadable request", status: 400)
            }
            await MainActor.run { shared.pageLog(message) }
            return WebResponse(status: 204)
        case "api/transport" where request.method == "POST" && parts.count == 2:
            guard let action = try? JSONDecoder().decode(WebTransport.self, from: request.body), action.valid else {
                return .text("Unreadable request", status: 400)
            }
            await MainActor.run { shared.transport(action) }
            return WebResponse(status: 204)
        case "api/loop" where request.method == "POST" && parts.count == 2:
            guard let action = try? JSONDecoder().decode(WebLoop.self, from: request.body), action.valid else {
                return .text("Unreadable request", status: 400)
            }
            await MainActor.run { shared.loop(action) }
            return WebResponse(status: 204)
        case "api/waveform" where reads && parts.count == 2:
            // The levels as the HUD keeps them, 50 a second and one byte each, 0 for a moment that wasn't heard yet.
            guard let wave = await MainActor.run(body: { shared.waveform() }) else { return .notFound }
            return json(WebWave(duration: wave.duration, rate: SongWaveform.rate, levels: wave.levels.base64EncodedString()))
        case "api/mute" where request.method == "POST" && parts.count == 2:
            guard let body = try? JSONDecoder().decode([String: Bool].self, from: request.body), let muted = body["muted"] else {
                return .text("Unreadable request", status: 400)
            }
            await MainActor.run { shared.mute(muted) }
            return WebResponse(status: 204)
        case "api/songs" where reads && parts.count == 2:
            return json(await shared.songs().map(\.song))
        case "api/cover" where reads:
            guard let id, let jpeg = await shared.cover(id) else { return .notFound }
            return WebResponse(status: 200, headers: [("Content-Type", "image/jpeg"), ("Cache-Control", "private, max-age=600")], body: .data(jpeg))
        case "api/song" where reads:
            guard let id, let path = await shared.file(of: id) else { return .notFound }
            return WebLinks.file(path, request: request)
        case "api/play", "api/write":
            guard request.method == "POST", parts.count == 2 else { return .notFound }
            guard let action = try? JSONDecoder().decode(WebAction.self, from: request.body) else { return .text("Unreadable request", status: 400) }
            return await shared.run(action, write: parts[1] == "write")
        case "api/job" where reads:
            guard let id else { return .notFound }
            return json(WebJob(await MainActor.run { CLIService.shared.handle(CLIRequest(command: .job, job: id)) }))
        case "api/cancel" where request.method == "POST":
            guard let id else { return .notFound }
            _ = await MainActor.run { CLIService.shared.handle(CLIRequest(command: .cancel, job: id)) }
            return WebResponse(status: 204)
        case "api/file" where reads:
            guard let id, let path = await MainActor.run(body: { CLIService.shared.output(of: id) }) else { return .notFound }
            return WebLinks.file(path, request: request)
        default:
            return .notFound
        }
        }()
        // What the phone asked for and how it went, without the state, the jobs and the pictures that it asks for all
        // the time, and without the byte ranges of the audio unless one fails.
        let quiet = ["api/state", "api/job", "api/symbol", "api/cover", "api/nowcover", "api/songs", "api/log"].contains(route) || route.hasPrefix("web/")
        let media = route == "api/song" || route == "api/file"
        if request.method == "POST" && route != "api/log" || media && response.status >= 400 || !quiet && !media && response.status >= 400 {
            log.log(level: response.status >= 400 ? .error : .debug,
                    "remote: \(request.method, privacy: .public) /\(parts.joined(separator: "/"), privacy: .public) \(response.status)\(Self.errorText(response), privacy: .public)")
        }
        return response
    }

    /// The error of a job or a text answer, for the log.
    nonisolated private static func errorText(_ response: WebResponse) -> String {
        guard case let .data(data) = response.body, data.count < 2000, let text = String(data: data, encoding: .utf8) else { return "" }
        if response.status >= 400 { return ": \(text)" }
        if let range = text.range(of: #""error":"[^"]*""#, options: .regularExpression) { return ", \(text[range])" }
        return ""
    }

    nonisolated private static func page(_ name: String) -> WebResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "Web"), let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        return WebResponse(status: 200, headers: [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Cache-Control", "no-store"),
            ("X-Frame-Options", "DENY"),
            ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self'; connect-src 'self'; frame-ancestors 'none'"),
        ], body: .data(data))
    }

    nonisolated private static func json(_ value: some Encodable) -> WebResponse {
        guard let data = try? JSONEncoder().encode(value) else { return .text("Unencodable", status: 500) }
        return WebResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")], body: .data(data))
    }

    // MARK: Songs

    struct WebSong: Encodable {
        let id: String
        let title: String
        let artist: String?
        /// Like `Em` or `F#`.
        let key: String?
        let bpm: Double?
        let duration: Double?
        let cover: Bool
    }

    /// A change to the song that plays on the Mac: a key like `+2` or `Am`, a speed and the instruments to play.
    struct WebLive: Decodable {
        var key: String?
        var speed: Double?
        var stems: [String]?
    }

    /// What the page sends to play a song or write it with changes.
    struct WebAction: Decodable {
        var song: String
        /// Semitones like `+2`.
        var key: String?
        var stems: [String]?
        var speed: Double?
        var from: Double?
        var to: Double?
        var notes: String?
        /// m4a for the changed song, json for its notes.
        var format: String?
    }

    /// A job as the page reads it: the file is named by the job, never by its path.
    struct WebJob: Encodable {
        let error: String?
        let message: String?
        let job: String?
        let step: String?
        let progress: Double?
        let done: Bool
        let file: String?

        init(_ response: CLIResponse) {
            error = response.error
            message = response.message
            job = response.job
            step = response.step
            progress = response.progress
            done = response.done
            file = response.output != nil ? response.job.map { "/api/file/\($0)" } : nil
        }
    }

    /// An ID that stays the same for a song from one list to the next.
    nonisolated private static func id(_ url: URL) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private func songs() async -> [(song: WebSong, item: QueueItem)] {
        await recents().filter { $0.folder != $0.url }.map { item in
            (WebSong(id: Self.id(item.url), title: item.title, artist: item.artist, key: item.key?.code, bpm: item.bpm, duration: item.duration,
                     cover: item.artwork != nil), item)
        }
    }

    private func item(_ id: String) async -> QueueItem? {
        if let item = await songs().first(where: { $0.song.id == id })?.item { return item }
        guard let file = await folderFiles().first(where: { Self.id($0) == id }) else { return nil }
        return QueueItem(url: file, cached: nil)
    }

    // MARK: Files on the Mac

    struct WebFile: Encodable {
        let id: String
        let title: String
        let folder: String
    }

    struct WebFiles: Encodable {
        /// Settings > Remote > Folders names no folder.
        let folders: Int
        let files: [WebFile]
        /// More files matched than the list holds.
        let more: Bool
    }

    private var indexed: (folders: [String], at: Date, files: [URL])?
    private var indexing: Task<[URL], Never>?

    /// The songs in the folders of Settings > Remote, newest first, read again after a minute or a change of folders.
    /// The walk runs off the main thread, skips hidden files, packages and the library of the Music app, and stops at
    /// 20 000 songs.
    private func folderFiles() async -> [URL] {
        let folders = UserDefaults.standard.stringArray(forKey: "remoteFolders") ?? []
        if let indexed, indexed.folders == folders, Date().timeIntervalSince(indexed.at) < 60 { return indexed.files }
        if let indexing { return await indexing.value }
        let task = Task.detached(priority: .utility) { Self.walk(folders) }
        indexing = task
        let files = await task.value
        indexing = nil
        indexed = (folders, Date(), files)
        return files
    }

    nonisolated private static func walk(_ folders: [String]) -> [URL] {
        let fm = FileManager.default
        let extensions = SongName.mediaExtensions.subtracting(["mid", "midi"])
        let musicLibrary = fm.urls(for: .musicDirectory, in: .userDomainMask)[0].appending(path: "Music").standardizedFileURL.path
        var found: [(url: URL, date: Date)] = []
        for folder in folders {
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if url.standardizedFileURL.path == musicLibrary {
                    walker.skipDescendants()
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append((url, date))
                if found.count >= 20000 { break }
            }
        }
        return found.sorted { $0.date > $1.date }.map(\.url)
    }

    /// Up to 300 songs of the folders whose name has every word of `query`, newest first.
    private func macFiles(matching query: String) async -> WebFiles {
        let folders = UserDefaults.standard.stringArray(forKey: "remoteFolders") ?? []
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matches = await folderFiles().filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        return WebFiles(folders: folders.count, files: matches.prefix(300).map {
            WebFile(id: Self.id($0), title: $0.deletingPathExtension().lastPathComponent, folder: $0.deletingLastPathComponent().lastPathComponent)
        }, more: matches.count > 300)
    }

    /// The ID in Recents of the song whose audio is `file`: the file's own, or the link's that it was downloaded from.
    func songID(file: String) async -> String {
        let songs = await songs()
        let url = URL(fileURLWithPath: file)
        return songs.first { $0.item.file?.standardizedFileURL == url.standardizedFileURL }?.song.id ?? Self.id(url)
    }

    private func cover(_ id: String) async -> Data? {
        guard let image = await item(id)?.artwork else { return nil }
        return SongTags.jpeg(image)
    }

    /// The audio file of a song, as Muskey Player would play it: the file, or the download of a link.
    private func file(of id: String) async -> String? {
        guard let file = await item(id)?.file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file.path
    }

    private func run(_ action: WebAction, write: Bool) async -> WebResponse {
        if let key = action.key, Int(key) == nil || abs(Int(key) ?? 0) > 12 { return .text("Wrong key", status: 400) }
        if let stems = action.stems, !stems.allSatisfy(muskeyStemNames.contains) { return .text("Wrong instruments", status: 400) }
        if let speed = action.speed, !(0.5 ... 1.5).contains(speed) { return .text("Wrong speed", status: 400) }
        if let from = action.from, let to = action.to, to <= from { return Self.json(WebJob(CLIResponse(error: "The part ends before it starts", done: true))) }
        if (action.from ?? 0) < 0 || (action.to ?? 1) <= 0 { return .text("Wrong part", status: 400) }
        if let notes = action.notes, notes != "auto", !muskeyStemNames.contains(notes) || notes == "drums" { return .text("Wrong instrument", status: 400) }
        guard let item = await item(action.song) else { return Self.json(WebJob(CLIResponse(error: "That song is no longer on the Mac", done: true))) }
        var request = CLIRequest(command: write ? .write : .play)
        // A link plays from its download, which Muskey Player keeps in the cache.
        request.inputs = [item.url.isFileURL ? item.url.path : item.url.absoluteString]
        request.key = action.key
        request.stems = action.stems
        request.speed = action.speed
        request.from = action.from
        request.to = action.to
        request.notes = action.notes
        if write {
            guard let format = action.format, format == "m4a" || format == "json" else { return .text("Wrong format", status: 400) }
            request.format = CLIFormat(rawValue: format)
            if format == "json" {
                // The sheet moves the notes itself, with the key that the page shows.
                request.key = nil
                request.notes = request.notes ?? "auto"
            }
        }
        return Self.json(WebJob(CLIService.shared.handle(request)))
    }
}

/// A change of the region loop: `press` as R does it (start, end, then clear), `set` from `start` to `end` after a drag
/// across the waveform, `move` of the `which` end (`start` or `end`) to `seconds`, and `clear`.
struct WebLoop: Decodable {
    let action: String
    let start: Double?
    let end: Double?
    let which: String?
    let seconds: Double?

    var valid: Bool {
        let finite = { (value: Double?) in value.map { $0.isFinite && $0 >= 0 } ?? false }
        switch action {
        case "press", "clear": return true
        case "set": return finite(start) && finite(end)
        case "move": return (which == "start" || which == "end") && finite(seconds)
        default: return false
        }
    }
}

struct WebWave: Encodable {
    let duration: Double
    let rate: Double
    /// Base64 of one byte per level.
    let levels: String
}

/// A play, pause or move of the song that plays on the Mac: `play`, `pause`, `back`, `forward`, or `seek` to `seconds`.
struct WebTransport: Decodable {
    let action: String
    let seconds: Double?

    var valid: Bool {
        switch action {
        case "play", "pause", "back", "forward": true
        case "seek": seconds.map { $0.isFinite && $0 >= 0 } ?? false
        default: false
        }
    }
}
