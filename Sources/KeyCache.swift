import Combine
import Foundation

/// The key that a full listen found for each song, by the title, artist and album that macOS's Now Playing info
/// reports, so a song that plays again starts on its key. Kept in `~/Library/Application Support/Muskey/keys.json`.
/// Main thread only.
final class KeyCache: ObservableObject {
    struct Entry: Codable {
        var pitchClass: Int
        var minor: Bool
        var strength: Float
        /// Full listens that found this key.
        var count: Int
        var date: Date

        var key: DetectedKey { DetectedKey(pitchClass: pitchClass, minor: minor) }
    }

    /// A remembered song, for the list in Settings.
    struct Song: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let key: DetectedKey
        let date: Date

        /// `Artist – Album`, with the parts that Now Playing reported.
        var detail: String? {
            let parts = [artist, album].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " – ")
        }
    }

    private static let limit = 5000
    /// The song whose key was forgotten, or nil when every key was. Lets the app stop showing a key that it no longer
    /// remembers.
    var onForget: ((String?) -> Void)?
    private let url: URL
    private var entries: [String: Entry]? {
        didSet { songList = nil }
    }
    private var songList: [Song]?

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Muskey/keys.json")) {
        self.url = url
    }

    /// A song without a title can't be told apart from another one.
    static func id(_ song: [String?]) -> String? {
        guard let title = song.first ?? nil, !title.isEmpty else { return nil }
        return song.map { $0 ?? "" }.joined(separator: "\u{1F}")
    }

    func key(for song: [String?]) -> DetectedKey? {
        Self.id(song).flatMap { load()[$0]?.key }
    }

    /// A full listen of the song found `key`. A listen that finds another key replaces the remembered one only when
    /// it is at least as sure of its key as the listen that found the remembered one, since the Mac may have played
    /// something other than the song that Now Playing named. Returns a line for the log.
    func store(_ key: DetectedKey, strength: Float, for song: [String?]) -> String {
        guard let id = Self.id(song) else { return "no title to remember the key by" }
        // JSONEncoder refuses NaN, which would make every later save fail.
        let strength = strength.isFinite ? strength : 0
        var entries = load()
        let result: String
        if var entry = entries[id] {
            if entry.key == key {
                entry.count += 1
                entry.strength = max(entry.strength, strength)
                entry.date = Date()
                entries[id] = entry
                result = "confirmed the remembered \(key.name), found by \(entry.count) listens"
            } else if strength >= entry.strength {
                entries[id] = Entry(pitchClass: key.pitchClass, minor: key.minor, strength: strength, count: 1, date: Date())
                result = String(format: "remembered %@ instead of %@ (strength %.3f, was %.3f)", key.name, entry.key.name, strength, entry.strength)
            } else {
                result = String(format: "kept the remembered %@ over %@ (strength %.3f, this listen %.3f)", entry.key.name, key.name, entry.strength, strength)
            }
        } else {
            entries[id] = Entry(pitchClass: key.pitchClass, minor: key.minor, strength: strength, count: 1, date: Date())
            result = "remembered \(key.name)"
        }
        if entries.count > Self.limit {
            for (old, _) in entries.sorted(by: { $0.value.date < $1.value.date }).prefix(entries.count - Self.limit) { entries[old] = nil }
        }
        objectWillChange.send()
        self.entries = entries
        save(entries)
        return result
    }

    var count: Int { load().count }

    /// Every remembered song, the most recent listen first.
    var songs: [Song] {
        if let songList { return songList }
        let list = load().compactMap { id, entry -> Song? in
            let parts = id.split(separator: "\u{1F}", omittingEmptySubsequences: false).map { $0.isEmpty ? nil : String($0) }
            guard let title = parts.first ?? nil else { return nil }
            return Song(id: id, title: title, artist: parts.count > 1 ? parts[1] : nil, album: parts.count > 2 ? parts[2] : nil,
                        key: entry.key, date: entry.date)
        }
        .sorted { $0.date > $1.date }
        songList = list
        return list
    }

    func forget(_ id: String) {
        var entries = load()
        guard entries[id] != nil else { return }
        objectWillChange.send()
        entries[id] = nil
        self.entries = entries
        save(entries)
        onForget?(id)
    }

    func clear() {
        objectWillChange.send()
        entries = [:]
        try? FileManager.default.removeItem(at: url)
        onForget?(nil)
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? decoder.decode([String: Entry].self, from: data) {
                loaded = decoded.filter { (0 ..< 12).contains($0.value.pitchClass) && $0.value.strength.isFinite }
            } else {
                // Kept aside instead of being overwritten by the next listen, so the keys can still be recovered.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
            }
        }
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
