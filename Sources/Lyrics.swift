import Foundation
import SwiftUI

/// The lyrics of a song, one entry per line, with the second in the song where each line starts.
struct Lyrics: Hashable, Sendable {
    struct Line: Hashable, Sendable {
        let time: Double
        /// Empty for a break between verses.
        let text: String
    }

    enum Timing: Hashable, Sendable {
        /// The times come with the lyrics.
        case synced
        /// Estimated from the length of each line, and the panel scrolls by them without marking a line as the one
        /// sung now.
        case estimated
        /// From the words that Muskey heard in the song.
        case heard
        /// Written by Whisper from what it heard, for a song that LRCLIB doesn't have.
        case written
    }

    var lines: [Line]
    var timing: Timing
    /// The service that the lyrics came from, for the credit under them. Nil for lyrics added by hand or written by
    /// Whisper.
    var source: LyricsSource? = nil
    /// The times come from a version of the song of another length, like a music video with an intro. The lines keep
    /// their spacing, and the song is heard to find where they start.
    var otherVersion = false

    /// The lyrics as text for editing: LRC when they come with times, plain otherwise.
    var text: String {
        timing == .synced || timing == .written ? lrc : lines.map(\.text).joined(separator: "\n")
    }

    var lrc: String {
        lines.map { line in
            let minutes = Int(line.time) / 60
            let seconds = line.time - Double(minutes * 60)
            return String(format: "[%02d:%05.2f] %@", minutes, seconds, line.text)
        }.joined(separator: "\n")
    }

    /// The line sung at `position`, or nil before the first line.
    func line(at position: Double) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// LRC lines like `[01:23.45] text`. A line can carry several times, for a chorus that repeats, and tags like
    /// `[ar: …]` carry no time and are skipped.
    static func parse(lrc: String) -> Lyrics? {
        var lines: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex) ..< close]
                let parts = stamp.split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { break }
                times.append(minutes * 60 + seconds)
                rest = rest[rest.index(after: close)...]
            }
            // Word-timed LRC puts a stamp like `<00:31.41>` before each word.
            let text = rest.replacing(Self.wordStamp, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            lines += times.map { Line(time: $0, text: text) }
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Lyrics(lines: lines.sorted { $0.time < $1.time }, timing: .synced)
    }

    private static let wordStamp = try! Regex(#"<\d+:\d+(?:[.:]\d+)?>"#)

    /// Times for lyrics that come without them: the lines are spread over the part of the song that most likely
    /// has vocals, each one taking time in proportion to its syllables, with a pause at each break between verses.
    static func estimate(plain: String, duration: Double) -> Lyrics? {
        // Lines of a pasted text can come with spaces, and blank lines in a row are one break between verses.
        var texts: [String] = []
        for raw in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, texts.last?.isEmpty != false { continue }
            texts.append(text)
        }
        while texts.last?.isEmpty == true { texts.removeLast() }
        guard !texts.isEmpty else { return nil }
        let times = LyricsAligner.estimate(texts, duration: duration)
        return Lyrics(lines: zip(times, texts).map { Line(time: $0, text: $1) }, timing: .estimated)
    }
}

enum LyricsState: Equatable, Sendable {
    case none
    case loading
    case found(Lyrics)
    case instrumental
    case notFound
    case failed
}

/// Finds lyrics on LRCLIB (lrclib.net), lrc.red, NetEase Cloud Music and the AMLL TTML DB at once
/// (LyricsSources.swift). Only the title,
/// artist, album and length of the song are sent, and only while the lyrics panel is open. Each song is asked for
/// once: lyrics, a song without lyrics and a failed request are kept until the app quits, and a failed request is
/// asked again only by Retry. Main thread only, apart from the requests.
final class LyricsFinder: @unchecked Sendable {
    private var results: [String: LyricsState] = [:]
    private var waiting: [String: [(LyricsState) -> Void]] = [:]
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Muskey/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (https://lowtechguys.com/muskey)",
        ]
        return URLSession(configuration: configuration)
    }()

    static let maxBytes = 1_000_000

    /// The key that a song's lyrics are kept under.
    static func id(_ track: NowPlaying.Track) -> String? {
        guard let title = track.title, !title.isEmpty else { return nil }
        let length: String = track.duration.map { String(Int($0.rounded())) } ?? ""
        let parts: [String] = track.song.map { $0 ?? "" } + [length]
        return parts.joined(separator: "\u{1F}")
    }

    /// The lyrics known for the song, if it was asked for already.
    func known(_ track: NowPlaying.Track) -> LyricsState? { Self.id(track).flatMap { results[$0] } }

    func forget(_ track: NowPlaying.Track) {
        if let id = Self.id(track) { results[id] = nil }
    }

    /// Lyrics that came from elsewhere, for a test with a made-up song.
    func keep(_ state: LyricsState, for track: NowPlaying.Track) {
        if let id = Self.id(track) { results[id] = state }
    }

    func find(_ track: NowPlaying.Track, done: @escaping (LyricsState) -> Void) {
        guard let id = Self.id(track), let title = track.title else { return done(.notFound) }
        if let result = results[id] { return done(result) }
        if waiting[id] != nil { waiting[id]?.append(done); return }
        waiting[id] = [done]
        let artist = track.artist ?? ""
        let album = track.album, duration = track.duration
        Task { [self] in
            let result = await lookup(title: title, artist: artist, album: album, duration: duration)
            DispatchQueue.main.async { [self] in
                results[id] = result
                for callback in waiting.removeValue(forKey: id) ?? [] { callback(result) }
            }
        }
    }

    struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// A 404 means LRCLIB has no such song, which is an answer and not a failure.
    func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200, data.count <= Self.maxBytes else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The title without what streaming and video sites add to it (`Song - Remastered 2011`, `Song (feat. X)`,
    /// `Artist - Song (Official Video)`), and the artist, taken from the title when a video site puts it there.
    static func clean(_ title: String, artist: String) -> (title: String, artist: String) {
        var title = title
        var artist = artist
        if let dash = title.range(of: " - ") {
            let before = title[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = title[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            let named = normalized(artist), first = normalized(before)
            // `Artist - Song` on a video site, where the artist field holds a channel like `Artist Official`.
            if !first.isEmpty, !named.isEmpty, named.contains(first) || first.contains(named) {
                title = after
                artist = before
            } else {
                title = before
            }
        }
        // Brackets that name a version or a video go, and the rest, like `(Remix)`, stay part of the title.
        let original = title
        title = title.replacing(Self.brackets) { match in
            let inside = original[match.range].lowercased().trimmingCharacters(in: .whitespaces)
            let version = ["(feat", "[feat", "(ft.", "(with "].contains { inside.hasPrefix($0) }
                || ["remaster", "official", "video", "audio", "lyric", "visualizer", "live"].contains { inside.contains($0) }
            return version ? "" : String(original[match.range])
        }
        return (title.trimmingCharacters(in: .whitespaces), artist)
    }

    /// The first artist of each, one inside the other: `Daft Punk` and `Daft Punk, Pharrell Williams` match.
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        func first(_ text: String) -> String {
            let cut = [",", "&", " feat", " ft.", " x ", " and "].compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
            return normalized(cut.map { String(text[..<$0]) } ?? text)
        }
        let x = first(a), y = first(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }

    private static let brackets = try! Regex(#"\s*[\(\[][^\)\]]*[\)\]]"#)

    /// Letters and digits only, in lowercase and without accents, for comparing titles and artists.
    static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }
}

/// The ring and the seconds of a countdown. The ring warms from amber to red over the last six seconds, and it pulses
/// with each second, harder and more often as the countdown nears its end: once a second, then twice, then three
/// times. A countdown is a wait that people sit through, so it moves more than the rest of the HUD; with Reduce Motion
/// it keeps only the colour.
private struct CountdownRing: View {
    let seconds: Int?
    let total: Int
    let palette: Palette
    @State private var tickAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// From 0 to 1 over the last six seconds, or the whole countdown when it is shorter.
    private func urgency(_ left: Double) -> Double {
        let span = Double(max(2, min(total, 6)))
        return max(0, min(1, (span - left) / (span - 1)))
    }

    var body: some View {
        GeometryReader { space in
            let ring = min(space.size.width, space.size.height)
            TimelineView(.animation) { context in
                let since = max(0, context.date.timeIntervalSince(tickAt))
                // The seconds left as they run down between the ticks, so the colour moves smoothly.
                let left = seconds.map { Double($0) - min(1, since) } ?? Double(total)
                let heat = urgency(left)
                let accent = Color(red: 0.97 + 0.03 * heat, green: 0.71 - 0.39 * heat, blue: 0.36)
                let beats = seconds.map { 1 + Int(urgency(Double($0)) * 2.99) } ?? 1
                let phase = (since * Double(beats)).truncatingRemainder(dividingBy: 1)
                let pulse = seconds == nil || reduceMotion ? 0 : exp(-phase * 5)
                let fraction = seconds.map { min(1, CGFloat($0) / CGFloat(max(1, total))) } ?? 0
                ZStack {
                    Circle().stroke(palette.ink.opacity(0.08), lineWidth: ring * 0.05)
                    if let seconds {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(AngularGradient(colors: [accent.opacity(0.55), accent], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * fraction)),
                                    style: StrokeStyle(lineWidth: ring * (0.05 + 0.015 * heat * pulse), lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .shadow(color: accent.opacity(0.6 + 0.3 * heat), radius: ring * (0.04 + 0.12 * heat * pulse))
                            .animation(.linear(duration: 1), value: fraction)
                        Text("\(seconds)s")
                            .font(.system(size: ring * 0.32, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.ink.mix(with: accent, by: 0.55 * heat))
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy(duration: 0.3), value: seconds)
                    } else {
                        // The seconds aren't known while the model loads, so a quarter of the ring turns instead.
                        Circle()
                            .trim(from: 0, to: 0.25)
                            .stroke(accent, style: StrokeStyle(lineWidth: ring * 0.05, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                            .shadow(color: accent.opacity(0.6), radius: ring * 0.04)
                    }
                }
                .scaleEffect(1 + (0.02 + 0.08 * heat) * pulse)
            }
        }
        .onChange(of: seconds) { tickAt = Date() }
    }
}

/// Karaoke's countdown while the vocals are separated, before the song rewinds or starts over.
struct KaraokeCountdown: Equatable {
    /// Seconds left, nil while the model loads.
    var seconds: Int?
    /// Seconds that the whole countdown lasts, which its ring empties over.
    var total: Int
    /// The song started over when karaoke opened, and rewinds to its beginning after the countdown (Settings > Lyrics >
    /// Karaoke > Start song from beginning).
    var restart: Bool
    /// Seconds that the song rewinds after the countdown, back to the moment karaoke opened; nil while the model loads.
    var rewind: Int?
}

/// The lyrics in place of the key, scrolling with the song so the line sung now stays a third of the way down.
/// Scrolling by hand stops that for a few seconds after the scroll ends.
/// The timing of lyrics that don't come with times, and the service that the lyrics came from, with a link to it.
struct LyricsBadges: View {
    let lyrics: Lyrics
    var downloading = false
    var writing = false
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            if lyrics.timing == .estimated || lyrics.timing == .written {
                LyricsTimingStatus(timing: lyrics.timing, downloading: downloading, writing: writing, palette: palette)
            }
            if let source = lyrics.source { LyricsCredit(source: source, palette: palette) }
        }
    }
}

struct LyricsPanel: View {
    let state: LyricsState
    /// The line sung now, which the app updates a few times a second while the panel shows.
    let line: Int?
    let palette: Palette
    let width: CGFloat
    let height: CGFloat
    /// The large lyrics, for singing along.
    var large = false
    /// The speech model for timing the lyrics is downloading.
    var downloading = false
    /// Whisper listens and writes the lyrics.
    var writing = false
    /// Seconds until the song steps back so the written lines come before they are sung.
    var waiting: Int?
    /// Karaoke's countdown while the vocals are separated, in place of the lines.
    var rewind: KaraokeCountdown?
    var retry: () -> Void = {}
    var add: () -> Void = {}
    var edit: () -> Void = {}
    /// The timing and the service under the lines. The wide layout shows them in its top row instead.
    var showsFooter = true

    @State private var scrolling = false
    /// The last scroll by hand, with a trackpad, a mouse wheel or the scroll bar.
    @State private var scrolledAt = Date.distantPast
    /// Scrolls before this moment are the panel following the song, not a scroll by hand.
    @State private var followingUntil = Date.distantPast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.songLoop) private var songLoop
    @Environment(\.songChords) private var chords

    private static let pause: TimeInterval = 4

    var body: some View {
        Group {
            if let rewind {
                // The lines heard during the countdown are heard again after it, or the song hasn't started yet.
                countdown(rewind.seconds, of: rewind.total,
                          title: rewind.seconds == nil ? "Loading the common instruments model" : "Separating instruments and vocals",
                          detail: rewind.restart ? "Song will rewind to the start after the countdown"
                              : rewind.rewind.map { "Song will rewind \($0) seconds after the countdown" } ?? "Song will rewind after the countdown")
            } else {
                content
            }
        }
        .frame(width: width, height: height)
        // At the top right, where the lines, which start at the left, rarely reach.
        .overlay(alignment: .topTrailing) {
            if rewind == nil, let chords, chords.shift != 0 || chords.capo != 0 { ChordsBadges(chords: chords, palette: palette, large: large) }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        // The song plays as it is while Whisper collects the first 30 seconds, then steps back: the countdown
        // takes the place of the lines, which would be heard only after the step back.
        case let .found(lyrics) where lyrics.timing == .written && writing && waiting != nil:
            countdown(waiting ?? 0, of: Self.collectSeconds, title: "Collecting song data for transcribing lyrics", detail: "Song will rewind after the countdown")
        case let .found(lyrics) where lyrics.lines.isEmpty:
            // Whisper listens for the first phrase of a song that LRCLIB doesn't have.
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                LyricsTimingStatus(timing: lyrics.timing, downloading: downloading, writing: writing, palette: palette, large: large)
            }
        case let .found(lyrics): lines(lyrics)
        case .loading: ProgressView().controlSize(.small)
        case .instrumental: empty("Instrumental")
        case .none: empty("No song playing")
        case .notFound:
            VStack(spacing: 10) {
                empty("No lyrics found")
                Button("Add lyrics", action: add)
                    .controlSize(.small)
            }
        case .failed:
            HStack(spacing: 8) {
                Text("Lyrics unavailable")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(StripColors.text(.red, colorScheme))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(StripColors.tint(.red, strong: false, colorScheme)))
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(palette.muted)
    }

    @ViewBuilder private func lines(_ lyrics: Lyrics) -> some View {
        if renderingPreview {
            // ImageRenderer draws no scroll view content, so `--render` gets the lines around the line sung now.
            VStack(alignment: .leading, spacing: large ? 22 : 10) {
                ForEach(Array(lyrics.lines.enumerated()).dropFirst(max(0, (line ?? 0) - 2)), id: \.offset) { index, line in
                    text(line, index: index, lyrics: lyrics)
                }
            }
            .padding(.top, height * 0.1)
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .mask(fade)
            .overlay(alignment: .bottom) { if !large, showsFooter { footer(lyrics) } }
        } else {
            // Another song starts at its top, without the offset or the pause of the last one. New times for the same
            // lines, as the song is heard, keep the scroll.
            scrolling(lyrics)
                .id(lyrics.lines.map(\.text))
                .contextMenu { Button("Edit lyrics", action: edit) }
                .onAppear { scrolledAt = .distantPast }
        }
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.14),
            .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The timing of lyrics that don't come with times, and the service that the lyrics came from, with a link to it.
    /// Karaoke shows both in its top row instead.
    private func footer(_ lyrics: Lyrics) -> some View {
        LyricsBadges(lyrics: lyrics, downloading: downloading, writing: writing, palette: palette)
    }

    /// How long Whisper collects the song before the song steps back, which the ring of the countdown empties over.
    static let collectSeconds = 30

    /// The seconds left before the song steps back, large in a ring that empties over `total` seconds, with what happens
    /// meanwhile and after it under them. A spinner takes the place of the seconds while they aren't known yet.
    private func countdown(_ seconds: Int?, of total: Int, title: String, detail: String) -> some View {
        // The wide layout's lyrics can be as short as 144 points, under the stems.
        let ring = min(large ? 150 : 92, max(52, height * 0.42))
        return VStack(spacing: ring * 0.12) {
            CountdownRing(seconds: seconds, total: total, palette: palette)
                .frame(width: ring, height: ring)
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: large ? 15 : 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink.opacity(0.85))
                Text(detail)
                    .font(.system(size: large ? 13 : 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
            }
            .multilineTextAlignment(.center)
            .fixedSize()
        }
        .frame(width: width, height: height)
    }

    private func scrolling(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: large ? 22 : 10) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        text(line, index: index, lyrics: lyrics)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room above the first line and below the last, so either can sit a third of the way down.
                .padding(.top, height * 0.34)
                .padding(.bottom, height * 0.6)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrolling = true }
                if phase == .idle, scrolling {
                    scrolling = false
                    scrolledAt = Date()
                }
            }
            // A mouse wheel scrolls without the phases of a trackpad, so any move that the panel didn't make
            // counts as a scroll by hand.
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                guard abs(new - old) > 0.5, Date() >= followingUntil else { return }
                scrolledAt = Date()
            }
            .onAppear { follow(proxy, animated: false) }
            .onChange(of: line) { follow(proxy, animated: true) }
            // Back to the line sung now once the pause after a scroll by hand is over.
            .task(id: scrolledAt) {
                guard scrolledAt != .distantPast else { return }
                try? await Task.sleep(for: .seconds(Self.pause))
                follow(proxy, animated: true)
            }
            .mask(fade)
            .overlay(alignment: .bottom) { if !large, showsFooter { footer(lyrics) } }
        }
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !scrolling, Date().timeIntervalSince(scrolledAt) >= Self.pause else { return }
        // Before the first line, as in an intro or after a seek back to it, the first line waits a third of the way down.
        let target = line ?? 0
        followingUntil = Date().addingTimeInterval(animated ? 0.9 : 0.2)
        if animated {
            withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.34)) }
        } else {
            proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.34))
        }
    }

    @ViewBuilder private func text(_ line: Lyrics.Line, index: Int, lyrics: Lyrics) -> some View {
        // With estimated times, no line is marked as the one sung now: a wrong mark would look like a bug.
        let timed = lyrics.timing != .estimated
        let current = timed && index == self.line
        let past = timed && (self.line.map { index < $0 } ?? false)
        // The large lyrics keep the eye on the line sung now: the lines around it are fainter.
        let faded = large ? (past ? 0.35 : 0.65) : (past ? 0.55 : 0.9)
        // The lines that the region loop repeats get a honey bar along their left edge, and every line moves right
        // to make room for it while a loop is set.
        let next = lyrics.lines.indices.contains(index + 1) ? lyrics.lines[index + 1].time : .infinity
        let looped = songLoop.map { loop in timed && next > loop.start + 0.05 && line.time < (loop.end ?? .infinity) - 0.05 } ?? false
        // The chords that change during the line sit over it, as far along it as they come in time.
        let marks = timed ? (chords.map { chords in chords.marks.filter { $0.time >= line.time - 0.3 && $0.time < next - 0.3 } } ?? []) : []
        let chordHeight: CGFloat = marks.isEmpty ? 0 : large ? 28 : 15
        Text(line.text.isEmpty ? (timed ? "♪" : " ") : line.text)
            .font(.system(size: large ? 36 : 18, weight: .bold, design: .rounded))
            .foregroundStyle(current ? palette.ink : palette.muted.opacity(faded))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, chordHeight)
            .overlay(alignment: .topLeading) {
                if let chords, !marks.isEmpty {
                    let length = max(0.5, (next.isFinite ? next : line.time + 4) - line.time)
                    ChordRow(fractions: marks.map { CGFloat(min(1, max(0, ($0.time - line.time) / length))) }) {
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                            Text(mark.name(moved: chords.move))
                                .font(.system(size: large ? 22 : 12, weight: .heavy, design: .rounded))
                                .foregroundStyle(StripColors.text(.honey, colorScheme).opacity(current || !timed ? 1 : faded))
                                .fixedSize()
                        }
                    }
                    .frame(height: chordHeight, alignment: .top)
                }
            }
            .padding(.leading, songLoop == nil ? 0 : large ? 18 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if looped {
                    Capsule().fill(StripColors.solid(.honey, colorScheme).fill)
                        .frame(width: large ? 4 : 3)
                        .padding(.vertical, 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: current)
            .animation(.snappy(duration: 0.2), value: looped)
    }
}

/// The timing of lyrics that don't come with times, as a dim status with no background, since it can't be clicked.
struct LyricsTimingStatus: View {
    let timing: Lyrics.Timing
    var downloading = false
    var writing = false
    let palette: Palette
    var large = false

    var body: some View {
        Label(downloading ? "Downloading speech model" : timing == .written ? (writing ? "Transcribing" : "Transcribed") : "Estimated timing",
              systemImage: downloading ? "arrow.down.circle" : timing == .written ? "waveform" : "clock")
            .labelStyle(.titleAndIcon)
            .font(.system(size: large ? 11 : 10, weight: .medium, design: .rounded))
            .foregroundStyle(palette.muted.opacity(0.8))
            .fixedSize()
    }
}

/// The service that the lyrics came from, in a pill that opens its page.
struct LyricsCredit: View {
    let source: LyricsSource
    let palette: Palette
    var large = false

    var body: some View {
        Link(destination: source.url) {
            HStack(spacing: 3) {
                Text(source.name)
                Image(systemName: "arrow.up.right").font(.system(size: large ? 8 : 7, weight: .bold))
            }
            .font(.system(size: large ? 11 : 10, weight: .semibold, design: .rounded))
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.ink.opacity(0.08)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Open \(source.name)")
    }
}

/// The chords of a line, each as far along the line as it comes in time, and never over the chord before it.
struct ChordRow: Layout {
    let fractions: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let fraction = fractions.indices.contains(index) ? fractions[index] : 0
            x = max(x, bounds.minX + fraction * max(0, bounds.width - size.width))
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .unspecified)
            x += size.width + 8
        }
    }
}

/// The pitch change and the capo of the chords, at the top of the lyrics, since the key row isn't there to show them.
struct ChordsBadges: View {
    let chords: SongChords
    let palette: Palette
    var large = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if chords.shift != 0 { badge(Shift.text(chords.shift), hue: chords.shift < 0 ? StripColors.down : StripColors.up) }
            if chords.capo != 0 { badge("Capo \(chords.capo)", hue: .honey) }
        }
        .font(.system(size: large ? 13 : 11, weight: .bold, design: .rounded))
        .padding(.top, large ? 6 : 2)
    }

    private func badge(_ text: String, hue: StripColors.Hue) -> some View {
        Text(text)
            .foregroundStyle(StripColors.text(hue, scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StripColors.tint(hue, strong: false, scheme)))
    }
}
