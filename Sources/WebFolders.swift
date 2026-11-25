import Foundation

/// The songs in the folders of Settings > Remote as a tree of folders, for the Files screen of the web remote: the
/// folders to browse, the songs of each one by name or by the date they were added, the newest songs, and a search
/// over every name. It is built off the main thread from one walk of the folders.
struct FolderIndex: Sendable {
    struct Song: Sendable {
        let url: URL
        let id: String
        /// The file's name without its extension, which the page shows.
        let name: String
        /// The name without case or accents, which a search is checked against.
        let search: String
        let added: Date
        let folder: Int
    }

    struct Folder: Sendable {
        let path: String
        let id: String
        let name: String
        let parent: Int?
        var folders: [Int] = []
        var songs: [Int] = []
        /// The songs in the folder and in every folder inside it.
        var count = 0
    }

    /// The folders of Settings > Remote that exist.
    let roots: [Int]
    let folders: [Folder]
    let songs: [Song]
    /// Every song, newest first.
    let newest: [Int]
    let songIDs: [String: Int]
    let folderIDs: [String: Int]
    /// The walk stopped at `limit` songs.
    let full: Bool

    static let limit = 100_000
    static let empty = FolderIndex(roots: [], folders: [], songs: [], newest: [], songIDs: [:], folderIDs: [:], full: false)

    /// Walks the folders, skipping hidden files, packages and the library of the Music app.
    static func build(_ paths: [String], id: (URL) -> String) -> FolderIndex {
        let fm = FileManager.default
        let extensions = SongName.mediaExtensions.subtracting(["mid", "midi"])
        let musicLibrary = fm.urls(for: .musicDirectory, in: .userDomainMask)[0].appending(path: "Music").standardizedFileURL.path
        var folders: [Folder] = []
        var songs: [Song] = []
        var roots: [Int] = []
        var byPath: [String: Int] = [:]
        var full = false
        for path in paths {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard byPath[root.path] == nil, (try? root.checkResourceIsReachable()) == true,
                  let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .addedToDirectoryDateKey, .creationDateKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            byPath[root.path] = folders.count
            roots.append(folders.count)
            folders.append(Folder(path: root.path, id: id(root), name: root.lastPathComponent, parent: nil))
            for case let url as URL in walker {
                guard let parent = byPath[url.deletingLastPathComponent().path] else { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .addedToDirectoryDateKey, .creationDateKey])
                if values?.isDirectory == true {
                    if url.standardizedFileURL.path == musicLibrary {
                        walker.skipDescendants()
                        continue
                    }
                    byPath[url.path] = folders.count
                    folders[parent].folders.append(folders.count)
                    folders.append(Folder(path: url.path, id: id(url), name: url.lastPathComponent, parent: parent))
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                folders[parent].songs.append(songs.count)
                songs.append(Song(url: url, id: id(url), name: name, search: name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                                  added: values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast, folder: parent))
                if songs.count >= limit {
                    full = true
                    break
                }
            }
            if full { break }
        }
        // A folder comes after the folder that holds it, so the counts add up from the last one back to the first.
        for index in folders.indices.reversed() {
            folders[index].count += folders[index].songs.count
            if let parent = folders[index].parent { folders[parent].count += folders[index].count }
        }
        let names = folders.map(\.name)
        for index in folders.indices {
            folders[index].folders.sort { names[$0].localizedStandardCompare(names[$1]) == .orderedAscending }
            folders[index].songs.sort { songs[$0].name.localizedStandardCompare(songs[$1].name) == .orderedAscending }
        }
        let newest = songs.indices.sorted { songs[$0].added > songs[$1].added }
        return FolderIndex(
            roots: roots, folders: folders, songs: songs, newest: newest,
            songIDs: Dictionary(songs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first }),
            folderIDs: Dictionary(folders.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first }),
            full: full
        )
    }
}
