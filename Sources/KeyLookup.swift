import Foundation

/// Keys looked up on noiseblend.com by the title, artist, album and length that macOS's Now Playing info reports.
/// Noiseblend answers with the key that Spotify lists for the song, so a song that Muskey hasn't heard before can
/// start on its key before the first estimate of a listen. The listen still runs, and a key that a full listen found
/// counts over a looked-up one.
///
/// A song is asked for once. Answers are kept in `~/Library/Application Support/Muskey/online-keys.json`, and a song
/// that Noiseblend doesn't know is asked for again after 30 days. A failed request is kept nowhere, so the song is
/// asked for again the next time that it needs a key. Main thread only, apart from the requests.
final class KeyLookup: @unchecked Sendable {
    struct Entry: Codable {
        /// Nil for a song that Noiseblend didn't find, or found without a key.
        var pitchClass: Int?
        var minor: Bool?
        var date: Date
        /// A full listen found another key, so Noiseblend's key is not used again.
        var overruled: Bool?

        var key: DetectedKey? {
            guard overruled != true, let pitchClass, (0 ..< 12).contains(pitchClass), let minor else { return nil }
            return DetectedKey(pitchClass: pitchClass, minor: minor)
        }
    }

    enum Answer: Equatable {
        case found(DetectedKey)
        /// Noiseblend doesn't know the song, or knows it without a key.
        case unknown
        /// Too many requests: none until the delay is over.
        case wait(TimeInterval)
        case failed(String)
    }

    var log: ((String) -> Void)?

    private static let limit = 5000
    private static let askAgainAfter: TimeInterval = 30 * 24 * 3600
    private static let endpoint = URL(string: "https://www.noiseblend.com/api/v1/key")!
    private static let maxBytes = 100_000

    private let url: URL
    private var entries: [String: Entry]?
    private var waiting: [String: [(DetectedKey?) -> Void]] = [:]
    /// No request goes out before this date, once Noiseblend asked for a pause.
    private var pausedUntil = Date.distantPast
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Muskey/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (https://lowtechguys.com/muskey)",
        ]
        return URLSession(configuration: configuration)
    }()

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Muskey/online-keys.json")) {
        self.url = url
    }

    /// The key that Noiseblend gave for the song before, if it knew one.
    func key(for song: [String?]) -> DetectedKey? {
        KeyCache.id(song).flatMap { load()[$0]?.key }
    }

    /// Calls `done` with the song's key, from an earlier answer or from a request, or with nil when Noiseblend doesn't
    /// know it or the request failed. A song that is asked for while its request runs waits for the same answer.
    func find(_ track: NowPlaying.Track, done: @escaping (DetectedKey?) -> Void) {
        // A title alone matches too many songs, so a song without an artist is never asked for.
        guard let id = KeyCache.id(track.song), let title = track.title, let artist = track.artist, !artist.isEmpty else { return done(nil) }
        if let entry = load()[id], entry.key != nil || Date().timeIntervalSince(entry.date) < Self.askAgainAfter {
            return done(entry.key)
        }
        guard Date() >= pausedUntil else { return done(nil) }
        if waiting[id] != nil { return waiting[id]!.append(done) }
        waiting[id] = [done]
        let song = Self.clean(title, artist: artist)
        let album = track.album, duration = track.duration
        let started = Date()
        Task { [self] in
            let answer = await request(title: song.title, artist: song.artist, album: album, duration: duration)
            DispatchQueue.main.async { [self] in
                let elapsed = Date().timeIntervalSince(started)
                var key: DetectedKey?
                switch answer {
                case let .found(found):
                    key = found
                    store(found, for: id)
                    log?(String(format: "online key: %@ (%.2fs)", found.name, elapsed))
                case .unknown:
                    store(nil, for: id)
                    log?(String(format: "online key: song not known (%.2fs)", elapsed))
                case let .wait(seconds):
                    pausedUntil = Date() + seconds
                    log?(String(format: "online key: asked to wait %.0fs", seconds))
                case let .failed(reason):
                    log?("online key: \(reason)")
                }
                for callback in waiting.removeValue(forKey: id) ?? [] { callback(key) }
            }
        }
    }

    /// A full listen of the song found `heard`. When Noiseblend gave another key, that key isn't used for the song
    /// again, even with Remember song keys off.
    func heard(_ heard: DetectedKey, for song: [String?]) {
        guard let id = KeyCache.id(song), var entry = load()[id], let key = entry.key, key != heard else { return }
        entry.overruled = true
        var entries = load()
        entries[id] = entry
        self.entries = entries
        save(entries)
        log?("online key: \(key.name) overruled by a listen that found \(heard.name)")
    }

    func forget(_ id: String) {
        var entries = load()
        guard entries[id] != nil else { return }
        entries[id] = nil
        self.entries = entries
        save(entries)
    }

    func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: url)
    }

    private func request(title: String, artist: String, album: String?, duration: Double?) async -> Answer {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "title", value: title)]
        if !artist.isEmpty { query.append(URLQueryItem(name: "artist", value: artist)) }
        if let album, !album.isEmpty { query.append(URLQueryItem(name: "album", value: album)) }
        if let duration, duration > 0 { query.append(URLQueryItem(name: "duration", value: String(format: "%.1f", duration))) }
        components.queryItems = query
        do {
            let (data, response) = try await session.data(from: components.url!)
            guard let http = response as? HTTPURLResponse else { return .failed("no HTTP response") }
            return Self.answer(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Noiseblend drops the parts of a title that name a version of the same recording, like `- Remastered 2009` or
    /// `(feat. X)`, and keeps the ones like `- Club Mix` that name another recording, whose key can differ. Titles of
    /// video sites, like `Artist - Song (Official Video)` from a channel named `Artist Official`, are cleaned the way
    /// the lyrics search cleans them, since Noiseblend matches none of them.
    static func clean(_ title: String, artist: String) -> (title: String, artist: String) {
        let cleaned = LyricsFinder.clean(title, artist: artist)
        let video = ["official", "video", "lyric", "visualizer"].contains { title.localizedCaseInsensitiveContains($0) }
        return cleaned.artist != artist || video ? cleaned : (title, artist)
    }

    private struct Response: Decodable {
        let key: String?
        let pitchClass: Int?
        let minor: Bool?
    }

    /// What an answer of Noiseblend means. Only a 404 says that the song is unknown: any other failure is asked
    /// again later.
    static func answer(status: Int, retryAfter: String?, body: Data) -> Answer {
        switch status {
        case 200:
            guard body.count <= maxBytes, let response = try? JSONDecoder().decode(Response.self, from: body) else {
                return .failed("unreadable answer")
            }
            if let pitchClass = response.pitchClass, (0 ..< 12).contains(pitchClass), let minor = response.minor {
                return .found(DetectedKey(pitchClass: pitchClass, minor: minor))
            }
            return response.key.flatMap(DetectedKey.init(camelot:)).map(Answer.found) ?? .unknown
        case 404: return .unknown
        case 429: return .wait(retryAfter.flatMap(TimeInterval.init).map { min(max($0, 1), 3600) } ?? 60)
        default: return .failed("HTTP \(status)")
        }
    }

    private func store(_ key: DetectedKey?, for id: String) {
        var entries = load()
        entries[id] = Entry(pitchClass: key?.pitchClass, minor: key?.minor, date: Date())
        if entries.count > Self.limit {
            for (old, _) in entries.sorted(by: { $0.value.date < $1.value.date }).prefix(entries.count - Self.limit) { entries[old] = nil }
        }
        self.entries = entries
        save(entries)
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }

    private func save(_ entries: [String: Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension DetectedKey {
    /// A key written as its code on the Camelot wheel, like `8A` for A minor or `1B` for B major.
    init?(camelot: String) {
        let code = camelot.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = code.last, letter == "A" || letter == "B", let number = Int(code.dropLast()), (1 ... 12).contains(number) else { return nil }
        // Number 8 is C major, and each step adds a fifth, which is 7 semitones. A minor key is the relative of the
        // major key with the same number.
        let major = DetectedKey(pitchClass: ((number - 8) * 7 % 12 + 12) % 12, minor: false)
        self = letter == "B" ? major : major.relative
    }
}
