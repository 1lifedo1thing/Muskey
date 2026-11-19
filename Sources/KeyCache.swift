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
        /// The tempo that the last full listen found, in beats per minute.
        var bpm: Double?

        var key: DetectedKey { DetectedKey(pitchClass: pitchClass, minor: minor) }
    }

    /// A remembered song, for the list in Settings.
    struct Song: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let key: DetectedKey
        let bpm: Double?
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
    private let file: StoreFile<[String: Entry]>
    private var entries: [String: Entry]? {
        didSet { songList = nil }
    }
    private var songList: [Song]?

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Muskey/keys.json")) {
        self.url = url
        file = StoreFile(label: "muskey.keys", read: { Self.read(url) }, write: { Self.write($0, to: url) })
    }

    /// A song without a title can't be told apart from another one.
    static func id(_ song: [String?]) -> String? {
        guard let title = song.first ?? nil, !title.isEmpty else { return nil }
        return song.map { $0 ?? "" }.joined(separator: "\u{1F}")
    }

    func key(for song: [String?]) -> DetectedKey? {
        Self.id(song).flatMap { load()[$0]?.key }
    }

    func bpm(for song: [String?]) -> Double? {
        Self.id(song).flatMap { load()[$0]?.bpm }
    }

    /// A full listen of the song found `key`. A listen that finds another key replaces the remembered one only when
    /// it is at least as sure of its key as the listen that found the remembered one, since the Mac may have played
    /// something other than the song that Now Playing named, and the tempo goes with the key that is kept. Returns a
    /// line for the log.
    func store(_ key: DetectedKey, strength: Float, bpm: Double? = nil, for song: [String?]) -> String {
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
                entry.bpm = bpm ?? entry.bpm
                entries[id] = entry
                result = "confirmed the remembered \(key.name), found by \(entry.count) listens"
            } else if strength >= entry.strength {
                entries[id] = Entry(pitchClass: key.pitchClass, minor: key.minor, strength: strength, count: 1, date: Date(), bpm: bpm ?? entry.bpm)
                result = String(format: "remembered %@ instead of %@ (strength %.3f, was %.3f)", key.name, entry.key.name, strength, entry.strength)
            } else {
                result = String(format: "kept the remembered %@ over %@ (strength %.3f, this listen %.3f)", entry.key.name, key.name, entry.strength, strength)
            }
        } else {
            entries[id] = Entry(pitchClass: key.pitchClass, minor: key.minor, strength: strength, count: 1, date: Date(), bpm: bpm)
            result = "remembered \(key.name)"
        }
        if entries.count > Self.limit {
            for (old, _) in entries.sorted(by: { $0.value.date < $1.value.date }).prefix(entries.count - Self.limit) { entries[old] = nil }
        }
        objectWillChange.send()
        self.entries = entries
        file.save(entries)
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
                        key: entry.key, bpm: entry.bpm, date: entry.date)
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
        file.save(entries)
        onForget?(id)
    }

    func clear() {
        objectWillChange.send()
        entries = [:]
        file.perform { [url] in try? FileManager.default.removeItem(at: url) }
        onForget?(nil)
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let loaded = file.load()
        entries = loaded
        return loaded
    }

    /// Runs on the file's queue.
    private static func read(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: Entry].self, from: data) {
            return decoded.filter { (0 ..< 12).contains($0.value.pitchClass) && $0.value.strength.isFinite }
        }
        // Kept aside instead of being overwritten by the next listen, so the keys can still be recovered.
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return [:]
    }

    /// Runs on the file's queue.
    private static func write(_ entries: [String: Entry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The JSON file of a store that keeps its entries in memory on the main thread. The file is read on a serial queue as
/// soon as the store is made, and each save is encoded and written on that queue in order, so the main thread waits
/// for the disk only when it needs the entries before that first read is done. Saves still queued when the app exits
/// are written first.
final class StoreFile<Entries>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let read: () -> Entries
    private let write: (Entries) -> Void
    /// The entries of the first read, until `load()` takes them. Only touched on `queue`.
    private var preloaded: Entries?
    /// Counts the saves, so a save with a newer one queued behind it is skipped: the newer one writes it all.
    private let lock = NSLock()
    private var saves = 0

    init(label: String, read: @escaping () -> Entries, write: @escaping (Entries) -> Void) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.read = read
        self.write = write
        queue.async { [self] in preloaded = read() }
        StoreFiles.add(queue)
    }

    /// The entries in the file. Waits for the first read when it isn't done yet.
    func load() -> Entries {
        queue.sync {
            defer { preloaded = nil }
            return preloaded ?? read()
        }
    }

    func save(_ entries: Entries) {
        let number = lock.withLock {
            saves += 1
            return saves
        }
        queue.async { [self] in
            guard lock.withLock({ saves }) == number else { return }
            write(entries)
        }
    }

    /// Runs `change` after the saves queued before it, such as deleting the file.
    func perform(_ change: @escaping () -> Void) {
        queue.async(execute: change)
    }
}

/// The queues that write the files of the stores and of the links cache, which the app waits for when it exits.
enum StoreFiles {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [DispatchQueue] = []
    private static let flushOnExit: Void = { atexit { StoreFiles.flush() } }()

    static func add(_ queue: DispatchQueue) {
        _ = flushOnExit
        lock.withLock { queues.append(queue) }
    }

    private static func flush() {
        for queue in lock.withLock({ queues }) { queue.sync {} }
    }
}
