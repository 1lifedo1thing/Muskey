import Foundation

/// Names for songs that come without a title: a player that reports the name of a file, and a link to a file that
/// carries no title tag.
enum SongName {
    /// The extensions of audio and video files that a title can end in. Apart from the extensions that a link is
    /// downloaded directly by, since a title never decides how a link opens.
    static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4v", "mp4", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "3gp",
        "aac", "flac", "alac", "wav", "wave", "aif", "aiff", "caf", "ogg", "oga", "ogv", "opus", "wma", "mka", "ape", "wv", "mid", "midi",
    ]

    /// A title without the extension of a media file, as browsers and video players report the name of the file that
    /// plays: `concert.mp4` reads `concert`. A title that ends in anything else stays whole, like `Mr. Brightside`.
    static func title(_ title: String) -> String {
        guard let dot = title.lastIndex(of: ".") else { return title }
        let name = title[..<dot].trimmingCharacters(in: .whitespaces)
        let ending = title[title.index(after: dot)...].lowercased()
        return mediaExtensions.contains(ending) && !name.isEmpty ? name : title
    }

    /// The name of the file that a link points to, without its extension and with its percent escapes decoded, for a
    /// song whose file carries no title. Nil for a link that names no media file, like the page of a video.
    static func link(_ url: URL) -> String? {
        guard !url.isFileURL, mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let file = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let name = title(file).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "/" ? nil : name
    }

    /// The title and the artist that a name gives: `Artist - Title` names both.
    static func split(_ name: String) -> (title: String, artist: String?) {
        guard let dash = name.range(of: " - ") else { return (name, nil) }
        let artist = name[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
        let title = name[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        return artist.isEmpty || title.isEmpty ? (name, nil) : (title, artist)
    }

    /// For `--selftest`.
    static func selfTest(report: (Bool, String) -> Void) {
        let titles = [
            ("concert.mp4", "concert"), ("concert.MP4", "concert"), ("Live at the Harbour Hall.mkv", "Live at the Harbour Hall"),
            ("take 3.final.webm", "take 3.final"), ("rehearsal.flac", "rehearsal"), ("voice memo.opus", "voice memo"),
            ("Mr. Brightside", "Mr. Brightside"), ("Never Gonna Give You Up", "Never Gonna Give You Up"), (".mp3", ".mp3"),
            ("Song feat. Someone", "Song feat. Someone"), ("notes.txt", "notes.txt"), ("Vol. 2", "Vol. 2"),
        ]
        let wrong = titles.filter { title($0.0) != $0.1 }.map { "\($0.0) → \(title($0.0))" }
        report(wrong.isEmpty, "titles lose a media file extension and nothing else\(wrong.isEmpty ? "" : ": " + wrong.joined(separator: ", "))")

        let links: [(String, String?)] = [
            ("https://example.com/music/Moonlight%20Sonata.mp3", "Moonlight Sonata"),
            ("https://example.com/download/Beethoven-MoonlightSonata.mp3?token=abc", "Beethoven-MoonlightSonata"),
            ("https://example.com/Daft%20Punk%20-%20Around%20the%20World.m4a", "Daft Punk - Around the World"),
            ("https://example.com/caf%C3%A9.FLAC", "café"), ("https://example.com/", nil), ("https://example.com/watch?v=abc.mp3", nil),
        ]
        let misnamed = links.filter { link(URL(string: $0.0)!) != $0.1 }.map { "\($0.0) → \(link(URL(string: $0.0)!) ?? "nil")" }
        report(misnamed.isEmpty, "a link to a file names its song by the file\(misnamed.isEmpty ? "" : ": " + misnamed.joined(separator: ", "))")
        let reported = NowPlaying.Track.decode(Data(#"{"title": "concert.mp4", "artist": "Mira Vale", "artworkBytes": 0}"#.utf8))
        let whole = NowPlaying.Track.decode(Data(#"{"title": "Mr. Brightside", "artworkBytes": 0}"#.utf8))
        report(reported?.title == "concert" && reported?.artist == "Mira Vale" && whole?.title == "Mr. Brightside",
               "a title from Now Playing loses its file extension where the report is read (\(reported?.title ?? "nil"), \(whole?.title ?? "nil"))")
        let both = split("Daft Punk - Around the World")
        report(both.title == "Around the World" && both.artist == "Daft Punk" && split("Moonlight Sonata").artist == nil, "a name like Artist - Title gives both")

        let pages: [(FilePlayer.Song?, String, String?)] = [
            (LinkDownload.named(#"{"title": "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)", "channel": "Rick Astley"}"#), "Never Gonna Give You Up", "Rick Astley"),
            (LinkDownload.named(#"{"title": "Midnight City (Official Video)", "uploader": "M83VEVO"}"#), "Midnight City", "M83"),
            (LinkDownload.named(#"{"title": "rehearsal take 3.mp4"}"#), "rehearsal take 3", nil),
            (LinkDownload.named(#"{"title": "Around the World - Remastered", "track": "Around the World", "artist": "Daft Punk, Someone"}"#), "Around the World", "Daft Punk"),
        ]
        let raw = pages.filter { $0.0?.title != $0.1 || $0.0?.artist != $0.2 }.map { "\($0.1) → \($0.0?.title ?? "nil") by \($0.0?.artist ?? "nil")" }
        report(raw.isEmpty, "a page that downloads shows its cleaned title and artist\(raw.isEmpty ? "" : ": " + raw.joined(separator: ", "))")
    }
}
