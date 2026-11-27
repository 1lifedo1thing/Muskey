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

/// Every service at once: LRCLIB, lrc.red, and NetEase Cloud Music with the AMLL TTML DB, which keeps word-timed
/// lyrics under NetEase's song numbers. A result counts with the same title once both are cleaned and the same first
/// artist. Within two seconds of the length that the player reports, it is this version of the song. A version that is
/// longer or shorter, like a music video with an intro, is used when no service has this one: its lines keep their
/// spacing, and the song is heard to find where they start.
extension LyricsFinder {
    struct Candidate: Sendable {
        let rank: Int
        var lyrics: Lyrics
        /// This version of the song, as opposed to one of another length.
        let exact: Bool
        /// Seconds between the length of this version and the length of the song that plays, which orders the
        /// candidates of the same rank.
        var off = 0.0
    }

    /// The lyrics that one service has for the song.
    struct Candidates: Sendable {
        var list: [Candidate] = []
        var instrumental = false
        /// LRCLIB says that this version of the song is an instrumental, which nothing else changes.
        var decisive = false
        var failed = false
    }

    /// The services in the order they are preferred in, for lyrics of the same kind: LRCLIB, AMLL's word-timed files
    /// that people wrote by hand, lrc.red, NetEase's own lyrics, then the lyrics that lrc.red marks as written by a model.
    private enum Service: Int { case lrclib, amll, lrcRed, netease, lrcRedModel }

    /// Synced lyrics of this version first, then synced lyrics of another version, then plain lyrics, which are timed
    /// by ear from an estimate.
    private static func candidate(_ lyrics: Lyrics, _ service: Service, exact: Bool, length: Double?, duration: Double?) -> Candidate {
        Candidate(rank: (lyrics.timing == .synced ? 0 : 20) + (exact ? 0 : 10) + service.rawValue, lyrics: lyrics, exact: exact,
                  off: abs((length ?? duration ?? 0) - (duration ?? 0)))
    }

    /// lrc.red asks every app for its name, a link and a contact address in the User-Agent.
    private static let lrcRedAgent = "Muskey/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (https://lowtechguys.com/muskey; support@lowtechguys.com)"

    /// Asks the services at once. LRCLIB's synced lyrics end the wait as soon as they come. Synced lyrics of this
    /// version from another service wait 0.6 seconds more for a service that is preferred to it. Whisper starts only
    /// once the lookup ends, so the lookup ends after nine seconds with what came by then. A service that fails or
    /// takes too long only leaves its lyrics out, and the lookup fails only when every service failed.
    func lookup(title: String, artist: String, album: String?, duration: Double?) async -> LyricsState {
        let song = Self.clean(title, artist: artist)
        let only = LyricsSource.forced
        let found: [Candidates] = await withTaskGroup(of: Candidates?.self) { group in
            var running = 0
            if only == nil || only == "lrclib" {
                running += 1
                group.addTask { await self.lrclib(title: title, artist: artist, album: album, duration: duration, song: song) }
            }
            if only == nil || only == "lrcred" {
                running += 1
                group.addTask { await self.lrcRed(song, duration: duration) }
            }
            if only == nil || only == "netease" || only == "amll" {
                running += 1
                group.addTask { await self.netease(song, duration: duration, amllOnly: only == "amll") }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(9))
                return nil
            }
            var found: [Candidates] = []
            var waiting = false
            while running > 0, let next = await group.next() {
                // The nine seconds, or the moment that preferred services got, are over.
                guard let next else { break }
                running -= 1
                found.append(next)
                if next.decisive || next.list.contains(where: { $0.rank == 0 }) { break }
                if !waiting, found.contains(where: { $0.list.contains { $0.rank < 10 } }) {
                    waiting = true
                    group.addTask {
                        try? await Task.sleep(for: .seconds(0.6))
                        return nil
                    }
                }
            }
            group.cancelAll()
            return found
        }

        if found.contains(where: \.decisive) { return .instrumental }
        let all = found.flatMap(\.list).sorted { ($0.rank, $0.off) < ($1.rank, $1.off) }
        if var best = all.first, best.lyrics.timing == .synced {
            if !best.exact {
                // Another version's times are off by its intro, so the song is heard to find where the lines start.
                best.lyrics.timing = .estimated
                best.lyrics.otherVersion = true
            }
            return .found(best.lyrics)
        }
        if found.contains(where: \.instrumental) { return .instrumental }
        if let plain = all.first { return .found(plain.lyrics) }
        return found.allSatisfy(\.failed) ? .failed : .notFound
    }

    // MARK: LRCLIB

    /// The exact song and a search at once. The exact song needs the album and the length to match. The search finds an
    /// album that LRCLIB names differently or a title that a video site decorates.
    private func lrclib(title: String, artist: String, album: String?, duration: Double?, song: (title: String, artist: String)) async -> Candidates {
        var result = Candidates()
        async let exact = exactRecord(title: title, artist: artist, album: album, duration: duration)
        async let searched = searchRecords(song)
        var records: [(record: Record, exact: Bool)] = []
        var failures = 0
        do {
            if let record = try await exact { records.append((record, true)) }
        } catch { failures += 1 }
        do {
            for record in try await searched {
                if let exact = Self.match(title: record.trackName, artist: record.artistName, length: record.duration, song: song, duration: duration) {
                    records.append((record, exact))
                }
            }
        } catch { failures += 1 }
        // Without an album or a length the exact song isn't asked for, so the search is the only request that can fail.
        let asked = duration != nil && album?.isEmpty == false ? 2 : 1
        result.failed = failures >= asked
        for (record, exact) in records {
            if record.instrumental == true {
                if exact { result.instrumental = true; result.decisive = true }
                continue
            }
            if let synced = record.syncedLyrics, var lyrics = Lyrics.parse(lrc: synced) {
                lyrics.source = .lrclib
                result.list.append(Self.candidate(lyrics, .lrclib, exact: exact, length: record.duration, duration: duration))
            } else if let plain = record.plainLyrics, let length = duration ?? record.duration, var lyrics = Lyrics.estimate(plain: plain, duration: length) {
                lyrics.source = .lrclib
                result.list.append(Self.candidate(lyrics, .lrclib, exact: exact, length: record.duration, duration: duration))
            }
        }
        return result
    }

    private func exactRecord(title: String, artist: String, album: String?, duration: Double?) async throws -> Record? {
        guard let duration, let album, !album.isEmpty else { return nil }
        return try await get("get", ["track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded()))])
    }

    private func searchRecords(_ song: (title: String, artist: String)) async throws -> [Record] {
        let records: [Record] = try await get("search", ["track_name": song.title, "artist_name": song.artist]) ?? []
        if !records.isEmpty { return records }
        return try await get("search", ["q": "\(song.artist) \(song.title)"]) ?? []
    }

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

    /// Searches lrc.red, then reads the TTML of the closest recordings, which carries the timing and the text.
    private func lrcRed(_ song: (title: String, artist: String), duration: Double?) async -> Candidates {
        var result = Candidates()
        do {
            var search = URLComponents(string: "https://lrc.red/search.json")!
            search.queryItems = [URLQueryItem(name: "q", value: "\(song.artist) \(song.title)")]
            guard let data = try await fetch(search.url!, agent: Self.lrcRedAgent) else { return result }
            let hits = try JSONDecoder().decode(RedSearch.self, from: data).hits ?? []
            // An ISRC is twelve letters and digits, and it goes into the address of the file.
            let matches = hits.compactMap { hit -> (hit: RedSearch.Hit, isrc: String, exact: Bool)? in
                guard let isrc = hit.isrc, isrc.wholeMatch(of: Self.isrcPattern) != nil,
                      let exact = Self.match(title: hit.title, artist: hit.artist, length: hit.duration, song: song, duration: duration) else { return nil }
                return (hit, isrc, exact)
            }
            .sorted { a, b in
                let order = { (m: (hit: RedSearch.Hit, isrc: String, exact: Bool)) in
                    (m.exact ? 0 : 1, m.hit.byModel == true ? 1 : 0, abs((m.hit.duration ?? 0) - (duration ?? 0)))
                }
                return order(a) < order(b)
            }
            for match in matches.prefix(2) {
                guard let file = try await fetch(URL(string: "https://lrc.red/s/\(match.isrc).ttml")!, agent: Self.lrcRedAgent),
                      var lyrics = TTML.lyrics(file, duration: duration ?? match.hit.duration) else { continue }
                lyrics.source = .lrcRed(isrc: match.isrc)
                result.list.append(Self.candidate(lyrics, match.hit.byModel == true ? .lrcRedModel : .lrcRed, exact: match.exact, length: match.hit.duration,
                                                  duration: duration))
                if lyrics.timing == .synced { break }
            }
        } catch {
            result.failed = result.list.isEmpty
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
            // This version first, then the others by how close their length is.
            let ids = songs.compactMap { found -> (id: Int, exact: Bool, length: Double?)? in
                let artists = (found.ar ?? []).compactMap(\.name).joined(separator: ", ")
                let length = found.dt.map { $0 / 1000 }
                guard let exact = Self.match(title: found.name, artist: artists, length: length, song: song, duration: duration) else { return nil }
                return (found.id, exact, length)
            }
            .sorted { a, b in
                (a.exact ? 0 : 1, abs((a.length ?? 0) - (duration ?? 0))) < (b.exact ? 0 : 1, abs((b.length ?? 0) - (duration ?? 0)))
            }
            guard let first = ids.first else { return result }

            async let amll = withTaskGroup(of: (Int, Lyrics?).self) { group in
                for match in ids.prefix(3) {
                    group.addTask { [self] in
                        let url = URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/ncm-lyrics/\(match.id).ttml")!
                        return (match.id, (try? await fetch(url)).flatMap { TTML.lyrics($0, duration: duration) })
                    }
                }
                var found: [(Int, Lyrics)] = []
                for await (id, lyrics) in group { if let lyrics { found.append((id, lyrics)) } }
                return found.min { a, b in
                    (ids.firstIndex { $0.id == a.0 } ?? 0) < (ids.firstIndex { $0.id == b.0 } ?? 0)
                }
            }
            async let own = amllOnly ? nil : try? fetch(URL(string: "https://music.163.com/api/song/lyric?id=\(first.id)&lv=1")!)

            if let best = await amll, best.1.timing == .synced {
                var lyrics = best.1
                lyrics.source = .amll(neteaseID: best.0)
                let match = ids.first { $0.id == best.0 }
                result.list.append(Self.candidate(lyrics, .amll, exact: match?.exact ?? false, length: match?.length, duration: duration))
            }
            if let data = await own ?? nil, let text = (try? JSONDecoder().decode(NeteaseLyric.self, from: data))?.lrc?.lyric {
                // NetEase's words for an instrumental: "pure music, please enjoy".
                if text.contains("纯音乐，请欣赏") {
                    result.instrumental = first.exact
                } else if var lyrics = Lyrics.parse(lrc: text).map(Self.withoutCredits), lyrics.lines.contains(where: { !$0.text.isEmpty }) {
                    lyrics.source = .netease(id: first.id)
                    result.list.append(Self.candidate(lyrics, .netease, exact: first.exact, length: first.length, duration: duration))
                }
            }
        } catch {
            result.failed = result.list.isEmpty
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

    /// Whether a result is the song: nil for another song, true for this version of it, and false for a version
    /// whose length is off by more than two seconds and less than 45 seconds or a third of the song.
    static func match(title: String?, artist: String?, length: Double?, song: (title: String, artist: String), duration: Double?) -> Bool? {
        guard normalized(clean(title ?? "", artist: artist ?? "").title) == normalized(song.title), sameArtist(artist ?? "", song.artist) else { return nil }
        guard let duration else { return true }
        guard let length else { return false }
        let off = abs(length - duration)
        if off <= 2 { return true }
        return off <= max(45, duration / 3) ? false : nil
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
