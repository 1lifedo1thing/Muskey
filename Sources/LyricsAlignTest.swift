import AVFoundation
import Foundation

/// `--lyrics-align FILE --lyrics-ref LYRICS` times the lyrics of a song file three ways and prints how far each lands
/// from the reference: by the words that Apple's speech model hears, as lyrics without times are timed while a song
/// plays, by fitting the text onto the vocals with the lyrics timing model, and by both together, as the lyrics show
/// them. LYRICS is a TTML or LRC file whose times are the reference, and whose text is what each way is given,
/// without its times. The stems come from the
/// cache (`--stems-cache-dir DIR` keeps it elsewhere) and are separated first when they aren't there.
///
/// `--lyrics-heard mix` lets the speech model hear the whole song instead of the vocals, and `--lyrics-heard none`
/// skips it. `--lyrics-align-out FILE` writes every time as JSON, for scoring the words elsewhere. The last line
/// printed is the offset that the reference would be moved by if it were the lyrics of the song.
enum LyricsAlignTest {
    struct Output: Encodable {
        struct Line: Encodable {
            var text: String
            var reference: Double
            /// The start of the line's first word by the heard words, and whether a heard word matched the line.
            var heard: Double?
            var heardMatched = false
            /// The start of the line's first word by the fit, for a line that was found.
            var aligned: Double?
            /// The start by the fit alone: the found lines, and the rest placed between them.
            var fitted: Double?
            /// The start as the lyrics show it: the lines that the fit found, and the heard words for the rest.
            var shown: Double?
            var words: [Word] = []
        }

        struct Word: Encodable {
            var index: Int
            var start: Double
            var end: Double
            var confidence: Float
        }

        /// A part of the song fitted alone, as a song from another app is fitted while it plays.
        struct Part: Encodable {
            var from: Double
            var to: Double
            /// The start of the first word of each line found, by the line's place in `lines`.
            var plain: [Int: Double] = [:]
            var plainSung = 0
            /// The same for the reference as lyrics with times, moved by `--lyrics-shift` seconds.
            var synced: [Int: Double] = [:]
            var syncedSung = 0
            /// What the part says about those lyrics: the seconds they are off by, 0 when they hold, nil when it
            /// can't tell.
            var offset: Double?
        }

        var parts: [Part] = []
        var lines: [Line] = []
        var heardSeconds: Double?
        var fitSeconds: Double?
        /// Whether enough lines were found to tell an offset of lyrics with times.
        var found: Bool?
        var offset: Double?
    }

    @MainActor static func run(file: String, reference: String) {
        let url = URL(fileURLWithPath: file)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reference)) else {
            print("can't read \(reference)")
            exit(1)
        }
        let builder = StemsCacheBuilder()
        builder.log = { print($0) }
        Task { @MainActor in
            let duration = await ChordDetector.duration(url)
            let parsed = reference.hasSuffix(".ttml") ? TTML.lyrics(data, duration: duration) : String(data: data, encoding: .utf8).flatMap { Lyrics.parse(lrc: $0) }
            guard let lyrics = parsed, lyrics.timing == .synced,
                  let plain = Lyrics.estimate(plain: lyrics.lines.map(\.text).joined(separator: "\n"), duration: duration)
            else {
                print("no times in \(reference)")
                exit(1)
            }
            // The lyrics without their times drop breaks in a row, so each of their lines is the next line of the
            // reference with its text.
            var place: [Int: Int] = [:]
            var next = 0
            for (index, line) in plain.lines.enumerated() where !line.text.isEmpty {
                guard let at = lyrics.lines[next...].firstIndex(where: { $0.text == line.text }) else { continue }
                next = at + 1
                place[index] = at
            }
            let vocals: [Float]
            var vocalsRate = StemsCache.rate
            if let path = TestFlags.value("--lyrics-vocals"), let audio = try? SongRender.read(URL(fileURLWithPath: path)) {
                // `--lyrics-vocals FILE` takes the vocals from a file, without separating the song.
                vocals = zip(audio.left, audio.right).map { ($0 + $1) * 0.5 }
                vocalsRate = audio.rate
            } else {
                guard let cache = await NotesPipeline.stems(for: file, builder: builder, log: { print($0) }) else {
                    print("the stems couldn't be separated")
                    exit(1)
                }
                vocals = NotesPipeline.stemSamples(cache, stem: .vocals)
            }
            let rate = vocalsRate
            var output = Output(lines: lyrics.lines.map { Output.Line(text: $0.text, reference: $0.time) })
            let aligner = LyricsAligner(texts: plain.lines.map(\.text), estimate: plain.lines.map(\.time))
            var heardAlignment = LyricsAligner.Alignment()

            let hearing = TestFlags.value("--lyrics-heard") ?? "vocals"
            if hearing != "none" {
                let started = Date()
                let samples: [Float], rate: Double
                if hearing == "mix", let song = try? SongRender.read(url) {
                    (samples, rate) = (zip(song.left, song.right).map { ($0 + $1) * 0.5 }, song.rate)
                } else {
                    (samples, rate) = (vocals, vocalsRate)
                }
                if let alignment = await heard(plain, aligner: aligner, samples: samples, rate: rate) {
                    heardAlignment = alignment
                    let times = aligner.times(alignment)
                    // Lines show half a second before their first word, which the comparison takes back.
                    for (index, at) in place {
                        output.lines[at].heard = times[index] + LyricsAligner.lead
                        output.lines[at].heardMatched = alignment.matchedLines.contains(index)
                    }
                }
                output.heardSeconds = Date().timeIntervalSince(started)
            }

            if AlignerModel.installed {
                do {
                    let started = Date()
                    let texts = plain.lines.map(\.text)
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        try LyricsFit.fit(texts, vocals: vocals, rate: rate)
                    }.value
                    output.fitSeconds = Date().timeIntervalSince(started)
                    if let outcome {
                        output.found = outcome.found
                        let times = aligner.times(aligner.alignment(fitted: outcome.starts))
                        let shown = aligner.times(aligner.alignment(heardAlignment, fitted: outcome.usable ? outcome.starts : [:]))
                        var moved: [Int: Double] = [:]
                        for (index, at) in place {
                            output.lines[at].aligned = outcome.starts[index]
                            output.lines[at].fitted = times[index] + LyricsAligner.lead
                            output.lines[at].shown = shown[index] + LyricsAligner.lead
                            if let start = outcome.starts[index] { moved[at] = start }
                        }
                        for word in outcome.words {
                            guard let at = place[word.line] else { continue }
                            output.lines[at].words.append(Output.Word(index: word.index, start: word.start, end: word.end, confidence: word.confidence))
                        }
                        output.offset = LyricsFit.offset(of: lyrics, LyricsFit.Outcome(starts: moved, words: [], sung: outcome.sung))
                        print("fit: \(outcome.starts.count) of \(outcome.sung) lines found\(outcome.usable ? "" : ", too few to time the lyrics by")")
                    }
                    if let spec = TestFlags.value("--lyrics-part") {
                        output.parts = try await parts(spec, plain: plain, lyrics: lyrics, place: place, aligner: aligner, heard: heardAlignment,
                                                       vocals: Dettato.resample(vocals, from: rate))
                    }
                } catch {
                    print("fit: \(error)")
                }
            } else {
                print("fit: no model in \(AlignerModel.folder.path)")
            }

            report(output)
            if let path = TestFlags.value("--lyrics-align-out") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try? encoder.encode(output).write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// `--lyrics-part 0-60,90-180` fits each of those parts of the song alone, the way a song from another app is
    /// fitted from what has played: once as lyrics without times, with the lines expected where the heard words and
    /// the estimate have them, and once with the reference as lyrics with times, moved by `--lyrics-shift` seconds.
    @MainActor private static func parts(_ spec: String, plain: Lyrics, lyrics: Lyrics, place: [Int: Int], aligner: LyricsAligner,
                                         heard: LyricsAligner.Alignment, vocals: [Float]) async throws -> [Output.Part]
    {
        let shift = TestFlags.value("--lyrics-shift").flatMap(Double.init) ?? 0
        let moved = lyrics.moved(by: shift)
        let expected = aligner.times(heard).map { $0 + LyricsAligner.lead }, heardLines = heard.firstWords
        let ranges = spec.split(separator: ",").compactMap { part -> (Double, Double)? in
            let ends = part.split(separator: "-").compactMap { Double($0) }
            return ends.count == 2 && ends[0] < ends[1] ? (ends[0], ends[1]) : nil
        }
        let texts = plain.lines.map(\.text), syncedTexts = moved.lines.map(\.text), syncedTimes = moved.lines.map(\.time)
        let duration = Double(vocals.count) / AlignerModel.rate
        return try await Task.detached(priority: .userInitiated) {
            try AlignerModel.use { reader in
                try ranges.map { from, to in
                    let first = min(vocals.count, Int(from * AlignerModel.rate)), last = min(vocals.count, Int(to * AlignerModel.rate))
                    // The song's position is reported five times a second, as the lyrics clock does.
                    let marks = stride(from: 0.0, through: Double(last - first) / AlignerModel.rate, by: 0.2).map { LiveFit.Mark(audio: $0, song: from + $0) }
                    let stretch = LiveFit.Stretch(samples: Array(vocals[first ..< last]), marks: marks)
                    var part = Output.Part(from: from, to: to)
                    if let found = try LiveFit.fit(texts, expected: expected, heard: heardLines, reach: .plain, stretches: [stretch], duration: duration, reader: reader) {
                        for (line, start) in found.starts { if let at = place[line] { part.plain[at] = start } }
                        part.plainSung = found.sung
                    }
                    if let found = try LiveFit.fit(syncedTexts, expected: syncedTimes, reach: .synced, stretches: [stretch], duration: duration, reader: reader) {
                        part.synced = found.starts
                        part.syncedSung = found.sung
                        switch LiveFit.verdict(of: moved, found) {
                        case let .off(offset): part.offset = offset
                        case .holds: part.offset = 0
                        case .unsure: part.offset = nil
                        }
                    }
                    print(String(format: "part %.0f–%.0f s: without times %d of %d lines found, with times %d of %d, %@", from, to, part.plain.count,
                                 part.plainSung, part.synced.count, part.syncedSung,
                                 part.offset.map { $0 == 0 ? "they hold" : String(format: "off by %+.2f s", $0) } ?? "can't tell"))
                    return part
                }
            }
        }.value
    }

    /// Today's way: the speech model hears the song whole, and the heard words are matched to the text.
    @MainActor private static func heard(_ lyrics: Lyrics, aligner: LyricsAligner, samples: [Float], rate: Double) async -> LyricsAligner.Alignment? {
        guard let locale = await LyricsListener.locale(for: lyrics.lines.map(\.text).joined(separator: "\n")) else {
            print("heard: no speech model for the language of the lyrics")
            return nil
        }
        let listener = LyricsListener(locale: locale, inputRate: rate)
        var words: [LyricsAligner.Heard] = []
        listener.onWords = { words = $0 }
        do {
            try await listener.start()
            let step = Int(rate)
            for start in stride(from: 0, to: samples.count, by: step) { listener.feed(Array(samples[start ..< min(samples.count, start + step)])) }
            try await listener.finish()
        } catch {
            print("heard: \(error)")
            return nil
        }
        // The last words come back on the main thread after the model is done.
        try? await Task.sleep(for: .milliseconds(300))
        let alignment = aligner.align(words)
        print("heard: \(words.count) words in \(locale.identifier), \(alignment.anchored) lines start at a heard word")
        return alignment
    }

    private static func report(_ output: Output) {
        let sung = output.lines.filter { !$0.text.isEmpty }
        func stats(_ name: String, _ time: (Output.Line) -> Double?) {
            let errors = sung.compactMap { line in time(line).map { $0 - line.reference } }
            guard !errors.isEmpty else { return print("\(name): no lines") }
            let signed = errors.sorted()
            // The reference can be off as a whole, so the errors are also counted around their median.
            let median = signed[signed.count / 2]
            let around = errors.map { abs($0 - median) }.sorted()
            func share(_ limit: Double) -> Double { 100 * Double(around.count { $0 < limit }) / Double(around.count) }
            print(String(format: "%@: %d of %d lines, median %+.0f ms from the reference, and around that median: median %.0f ms, 90th percentile %.0f ms, within 100 ms %.0f%%, 200 ms %.0f%%, 500 ms %.0f%%",
                         name, errors.count, sung.count, median * 1000, around[around.count / 2] * 1000, around[min(around.count - 1, around.count * 9 / 10)] * 1000,
                         share(0.1), share(0.2), share(0.5)))
        }
        stats("heard, every line", \.heard)
        stats("heard, matched lines", { $0.heardMatched ? $0.heard : nil })
        stats("fit, found lines", \.aligned)
        stats("fit alone, every line", \.fitted)
        stats("fit and heard, every line", \.shown)
        if let seconds = output.heardSeconds { print(String(format: "heard in %.1f s", seconds)) }
        if let seconds = output.fitSeconds { print(String(format: "fitted in %.1f s", seconds)) }
        print(output.offset.map { String(format: "the reference would be moved by %+.2f s", $0) } ?? "the reference would stay where it is")
    }
}
