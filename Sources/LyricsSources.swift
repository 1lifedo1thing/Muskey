import Foundation

/// Where a song's lyrics came from, for the credit under them.
enum LyricsSource: Hashable, Sendable {
    case lrclib
    case lrcRed(isrc: String)
    case netease(id: Int)
    case amll(neteaseID: Int)

    var name: String {
        switch self {
        case .lrclib: "LRCLIB"
        case .lrcRed: "lrc.red"
        case .netease: "NetEase Cloud Music"
        case .amll: "AMLL TTML DB"
        }
    }

    var url: URL {
        switch self {
        case .lrclib: URL(string: "https://lrclib.net")!
        case let .lrcRed(isrc): URL(string: "https://lrc.red/s/\(isrc)")!
        case let .netease(id): URL(string: "https://music.163.com/#/song?id=\(id)")!
        case let .amll(id): URL(string: "https://github.com/amll-dev/amll-ttml-db/blob/main/ncm-lyrics/\(id).ttml")!
        }
    }

    /// `--lyrics-source lrclib|lrcred|netease|amll` asks only that source, for testing the ones that LRCLIB comes before.
    static let forced = TestFlags.value("--lyrics-source")
}

/// The services that Muskey asks after LRCLIB, for a song that LRCLIB has no synced lyrics for: lrc.red, and NetEase
/// Cloud Music with the AMLL TTML DB, which keeps word-timed lyrics under NetEase's song numbers. A result counts only
/// with the same rules as LRCLIB's search: the same title, the same first artist and a length within two seconds.
extension LyricsFinder {
    /// The best lyrics that the other services have, `synced` before `plain`.
    struct Others: Sendable {
        var synced: Lyrics?
        var plain: Lyrics?
        var instrumental = false
        /// Every service failed or ran out of time, as opposed to having no lyrics for the song.
        var failed = false
    }

    /// lrc.red asks every app for its name, a link and a contact address in the User-Agent.
    private static let lrcRedAgent = "Muskey/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (https://lowtechguys.com/muskey; support@lowtechguys.com)"

    func others(_ song: (title: String, artist: String), duration: Double?, only: String?) async -> Others {
        // Whisper starts only once the lookup ends, so the services get nine seconds between them.
        let found = await Self.within(9) { [self] in
            async let red = only == nil || only == "lrcred" ? lrcRed(song, duration: duration) : Candidates()
            async let ncm = only == nil || only == "netease" || only == "amll" ? netease(song, duration: duration, amllOnly: only == "amll") : Candidates()
            return await [red, ncm]
        }
        guard let found else { return Others(failed: true) }
        let all = found.flatMap(\.list).sorted { $0.rank < $1.rank }
        var others = Others()
        others.synced = all.first { $0.lyrics.timing == .synced }?.lyrics
        others.plain = all.first { $0.lyrics.timing != .synced }?.lyrics
        others.instrumental = found.contains { $0.instrumental }
        others.failed = all.isEmpty && !others.instrumental && found.allSatisfy(\.failed)
        return others
    }

    /// Lyrics from one service, each with its place in the order that the services are preferred in.
    struct Candidates: Sendable {
        var list: [(rank: Int, lyrics: Lyrics)] = []
        var instrumental = false
        var failed = false
    }

    // The order: AMLL's word-timed files that people wrote by hand, then lrc.red, then NetEase's own lyrics, then the
    // lyrics that lrc.red marks as written by a model.
    private static let amllRank = 0, lrcRedRank = 1, neteaseRank = 2, lrcRedModelRank = 3

    // MARK: lrc.red

    private struct RedSearch: Decodable {
        struct Hit: Decodable {
            let isrc: String?
            let title: String?
            let artist: String?
            let duration: Double?
            let byModel: Bool?
        }

        let hits: [Hit]?
    }

    /// Searches lrc.red, then reads the TTML of the matching recordings, which carries the timing and the text.
    private func lrcRed(_ song: (title: String, artist: String), duration: Double?) async -> Candidates {
        var result = Candidates()
        do {
            var search = URLComponents(string: "https://lrc.red/search.json")!
            search.queryItems = [URLQueryItem(name: "q", value: "\(song.artist) \(song.title)")]
            guard let data = try await fetch(search.url!, agent: Self.lrcRedAgent) else { return result }
            let hits = try JSONDecoder().decode(RedSearch.self, from: data).hits ?? []
            // An ISRC is twelve letters and digits, and it goes into the address of the file.
            let matches = hits.filter { hit in
                guard let isrc = hit.isrc, isrc.wholeMatch(of: Self.isrcPattern) != nil else { return false }
                return Self.matches(title: hit.title, artist: hit.artist, length: hit.duration, song: song, duration: duration)
            }
            .sorted { ($0.byModel == true ? 1 : 0) < ($1.byModel == true ? 1 : 0) }
            for hit in matches.prefix(2) {
                guard let isrc = hit.isrc, let file = try await fetch(URL(string: "https://lrc.red/s/\(isrc).ttml")!, agent: Self.lrcRedAgent),
                      var lyrics = TTML.lyrics(file, duration: duration ?? hit.duration) else { continue }
                lyrics.source = .lrcRed(isrc: isrc)
                result.list.append((hit.byModel == true ? Self.lrcRedModelRank : Self.lrcRedRank, lyrics))
                if lyrics.timing == .synced { break }
            }
        } catch {
            result.failed = true
        }
        return result
    }

    private static let isrcPattern = try! Regex("[A-Z0-9]{12}")

    // MARK: NetEase and AMLL

    private struct NeteaseSearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int
            let name: String?
            let ar: [Named]?
            /// Milliseconds.
            let dt: Double?
        }

        struct Named: Decodable { let name: String? }
        let result: Result?
    }

    private struct NeteaseLyric: Decodable {
        struct Text: Decodable { let lyric: String? }
        let lrc: Text?
    }

    /// Searches NetEase, then asks the AMLL TTML DB and NetEase for the lyrics of the matching songs at once. A song can
    /// have several numbers on NetEase, and AMLL keeps its file under any of them, so the first three are tried there.
    private func netease(_ song: (title: String, artist: String), duration: Double?, amllOnly: Bool) async -> Candidates {
        var result = Candidates()
        do {
            var search = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
            search.queryItems = [URLQueryItem(name: "s", value: "\(song.artist) \(song.title)"), URLQueryItem(name: "type", value: "1"),
                                 URLQueryItem(name: "limit", value: "10")]
            guard let data = try await fetch(search.url!) else { return result }
            let songs = try JSONDecoder().decode(NeteaseSearch.self, from: data).result?.songs ?? []
            let ids = songs.filter { found in
                let artists = (found.ar ?? []).compactMap(\.name).joined(separator: ", ")
                return Self.matches(title: found.name, artist: artists, length: found.dt.map { $0 / 1000 }, song: song, duration: duration)
            }.map(\.id)
            guard let first = ids.first else { return result }

            async let amll = withTaskGroup(of: (Int, Lyrics?).self) { group in
                for id in ids.prefix(3) {
                    group.addTask { [self] in
                        let url = URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/ncm-lyrics/\(id).ttml")!
                        return (id, (try? await fetch(url)).flatMap { TTML.lyrics($0, duration: duration) })
                    }
                }
                var found: [(Int, Lyrics)] = []
                for await (id, lyrics) in group { if let lyrics { found.append((id, lyrics)) } }
                // The first match on NetEase is the likeliest version.
                return found.min { a, b in ids.firstIndex(of: a.0)! < ids.firstIndex(of: b.0)! }
            }
            async let own: Data? = amllOnly ? nil : fetch(URL(string: "https://music.163.com/api/song/lyric?id=\(first)&lv=1")!)

            if let best = await amll, best.1.timing == .synced {
                var lyrics = best.1
                lyrics.source = .amll(neteaseID: best.0)
                result.list.append((Self.amllRank, lyrics))
            }
            if let data = try await own, let text = try JSONDecoder().decode(NeteaseLyric.self, from: data).lrc?.lyric {
                // NetEase's words for an instrumental: "pure music, please enjoy".
                if text.contains("纯音乐，请欣赏") {
                    result.instrumental = true
                } else if var lyrics = Lyrics.parse(lrc: text).map(Self.withoutCredits), lyrics.lines.contains(where: { !$0.text.isEmpty }) {
                    lyrics.source = .netease(id: first)
                    result.list.append((Self.neteaseRank, lyrics))
                }
            }
        } catch {
            result.failed = true
        }
        return result
    }

    /// NetEase starts most lyrics with the credits, as lines like `作曲 : Name` or `吉他：Name`, timed like the lyrics.
    /// A line goes when the words before its colon are Chinese or Japanese, or name a credit in English.
    static func withoutCredits(_ lyrics: Lyrics) -> Lyrics {
        var lyrics = lyrics
        lyrics.lines.removeAll { line in
            guard let colon = line.text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
            let label = line.text[..<colon].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count <= 16 else { return false }
            if label.unicodeScalars.contains(where: { (0x3040 ... 0x30FF).contains($0.value) || (0x4E00 ... 0x9FFF).contains($0.value) }) { return true }
            return Self.creditWords.contains(label.lowercased())
        }
        return lyrics
    }

    private static let creditWords: Set<String> = [
        "lyrics", "lyricist", "lyrics by", "words by", "composer", "composed by", "music", "music by", "written by", "arranger", "arranged by",
        "producer", "produced by", "mixed by", "mastered by", "mixing engineer", "mastering engineer", "recording engineer",
    ]

    // MARK: Shared

    /// The rule of LRCLIB's search, for every service: the same title once both are cleaned, the same first artist,
    /// and a length within two seconds of the one that the player reports.
    static func matches(title: String?, artist: String?, length: Double?, song: (title: String, artist: String), duration: Double?) -> Bool {
        guard normalized(clean(title ?? "", artist: artist ?? "").title) == normalized(song.title), sameArtist(artist ?? "", song.artist) else { return false }
        guard let duration else { return true }
        return length.map { abs($0 - duration) <= 2 } ?? false
    }

    /// The answer of a service, nil for a 404. Other answers fail.
    func fetch(_ url: URL, agent: String? = nil) async throws -> Data? {
        var request = URLRequest(url: url)
        if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200, data.count <= Self.maxBytes else { throw URLError(.badServerResponse) }
        return data
    }

    /// The result of `work`, or nil when it takes longer than `seconds`.
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Reads lyrics from TTML, the format of lrc.red and the AMLL TTML DB: one `<p>` per line, with the time it starts in
/// `begin`, and the words in `<span>`s. Translations, romanisations and background vocals are spans of their own,
/// and they are left out.
enum TTML {
    static func lyrics(_ data: Data, duration: Double?) -> Lyrics? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let lines = reader.lines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return nil }

        if lines.allSatisfy({ $0.begin != nil }) {
            var timed: [Lyrics.Line] = []
            for (index, line) in lines.enumerated() {
                timed.append(Lyrics.Line(time: line.begin!, text: line.text))
                // A break between verses, as LRC files mark it: an empty line where the singing pauses for a while.
                let next = index + 1 < lines.count ? lines[index + 1].begin! : nil
                if let end = line.end, next.map({ $0 - end >= 4 }) ?? true { timed.append(Lyrics.Line(time: end, text: "")) }
            }
            return Lyrics(lines: timed.sorted { $0.time < $1.time }, timing: .synced)
        }
        guard let duration else { return nil }
        let plain = lines.map { $0.stanzaEnd ? $0.text + "\n" : $0.text }.joined(separator: "\n")
        return Lyrics.estimate(plain: plain, duration: duration)
    }

    /// `00:31.410`, `1:02:03.4`, `31.41`, `31.41s` or `31410ms`.
    static func seconds(_ text: String?) -> Double? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("ms") { return Double(text.dropLast(2)).map { $0 / 1000 } }
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Line {
            var begin: Double?
            var end: Double?
            var text = ""
            var stanzaEnd = false
        }

        var lines: [Line] = []
        private var current: Line?
        /// Spans opened inside a span that is left out.
        private var skipping = 0
        private static let skipped: Set<String> = ["x-translation", "x-roman", "x-bg"]

        func parser(_: XMLParser, didStartElement element: String, namespaceURI _: String?, qualifiedName _: String?, attributes: [String: String] = [:]) {
            let name = element.split(separator: ":").last.map(String.init) ?? element
            let role = attributes.first { $0.key == "role" || $0.key.hasSuffix(":role") }?.value
            switch name {
            case "p":
                current = Line(begin: TTML.seconds(attributes["begin"]), end: TTML.seconds(attributes["end"]))
            case "span":
                if skipping > 0 || role.map(Self.skipped.contains) == true { skipping += 1 }
            case "br":
                if skipping == 0 { current?.text += " " }
            default: break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            if skipping == 0 { current?.text += string }
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            let name = element.split(separator: ":").last.map(String.init) ?? element
            switch name {
            case "span":
                if skipping > 0 { skipping -= 1 }
            case "p":
                if var line = current {
                    line.text = line.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    lines.append(line)
                }
                current = nil
            case "div":
                if !lines.isEmpty { lines[lines.count - 1].stanzaEnd = true }
            default: break
            }
        }
    }
}
