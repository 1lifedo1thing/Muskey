import Foundation

/// The songs that Muskey Player played last, files and links, the newest first. They show on the back of the record
/// while nothing plays, and a click plays one again. Kept in the defaults as `recentSongs`. Main thread only.
enum RecentSongs {
    struct Entry: Codable {
        /// The file, or the link that a song was downloaded from.
        var url: URL
        /// The download of a link, with the title, artist and cover that the download found. Nil for a file, whose
        /// details are read from the file.
        var song: FilePlayer.Song?
        var played: Date
    }

    static let limit = 20
    private static let key = "recentSongs"

    /// The songs played last. A file that is gone is left out, and a link whose download is gone stays, since it
    /// downloads again.
    static func load() -> [Entry] {
        let entries = stored ?? seed()
        // A file on a network volume is taken as there: asking a server that went away blocks for as long as the
        // mount takes to give up, and this runs on the main thread whenever the HUD shows Recents.
        return entries.filter { !$0.url.isFileURL || Volumes.remote($0.url.path) || FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Muskey Player started a song: it moves to the top of the list.
    static func add(_ url: URL, song: FilePlayer.Song?) {
        var entries = stored ?? seed()
        entries.removeAll { same($0.url, url) }
        entries.insert(Entry(url: url, song: url.isFileURL ? nil : song, played: Date()), at: 0)
        save(Array(entries.prefix(limit)))
    }

    static func remove(_ url: URL) {
        save((stored ?? seed()).filter { !same($0.url, url) })
    }

    private static var stored: [Entry]? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Before the first song is kept, the list starts with the links downloaded before, so it isn't empty after an
    /// update. Muskey kept no list of the files it played.
    private static func seed() -> [Entry] {
        LinkCache().recent(limit).map { Entry(url: $0.link, song: $0.song, played: Date.distantPast) }
    }

    /// A dropped file and the same file opened by its path can name it through /private/tmp and /tmp.
    static func same(_ a: URL, _ b: URL) -> Bool {
        guard a.isFileURL, b.isFileURL else { return a.absoluteString == b.absoluteString }
        return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }
}

/// Which paths are on a network volume, from the list of mounts that the kernel keeps, which answers at once also when
/// a server doesn't.
enum Volumes {
    private static var cache: (at: Date, remote: [String])?

    static func remote(_ path: String) -> Bool {
        if cache == nil || Date().timeIntervalSince(cache!.at) > 2 {
            var mounts: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mounts, MNT_NOWAIT)
            var remote: [String] = []
            if let mounts, count > 0 {
                for mount in UnsafeBufferPointer(start: mounts, count: Int(count)) where mount.f_flags & UInt32(MNT_LOCAL) == 0 {
                    var name = mount.f_mntonname
                    let point = withUnsafePointer(to: &name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                    if point != "/" { remote.append(point.hasSuffix("/") ? point : point + "/") }
                }
            }
            cache = (Date(), remote)
        }
        return cache?.remote.contains { path.hasPrefix($0) } ?? false
    }
}
