import Foundation

/// Checks for the parts of a song that Whisper transcribed: how they are merged and looked up, and that Whisper
/// skips silence and counts as heard only what it finished.
enum LyricsSelfTest {
    /// A Whisper that hears nothing, and counts the clips it got. It fails on the clips listed.
    final class Recorder: WhisperBackend, @unchecked Sendable {
        let lock = NSLock()
        var clips = 0
        let failing: Set<Int>
        init(failing: Set<Int> = []) { self.failing = failing }

        func words(in samples: [Float], language: String?, prompt: String?) async throws -> [LyricsAligner.Heard] {
            let index = lock.withLock { () -> Int in
                clips += 1
                return clips - 1
            }
            if failing.contains(index) { throw URLError(.cannotConnectToHost) }
            return []
        }
    }

    static func run(report: (Bool, String) -> Void) {
        let merged = LyricsCoverage.merge([50 ... 80, 2 ... 20, 20.1 ... 40, 120 ... 130, 79 ... 90])
        report(merged == [0 ... 40, 50 ... 90, 120 ... 130], "coverage merge   \(merged.map { "\(Int($0.lowerBound))–\(Int($0.upperBound))" })")

        let inside = [1.0, 39.0, 60.0].map { LyricsCoverage.contains(merged, $0, duration: 200) }
        let outside = [45.0, 100.0, 39.8, 49.0].map { LyricsCoverage.contains(merged, $0, duration: 200) }
        report(inside.allSatisfy { $0 } && !outside.contains(true), "coverage lookup  in \(inside), out \(outside)")

        let whole = LyricsCoverage.complete([1.5 ... 100, 100.2 ... 192], duration: 200)
        let gap = LyricsCoverage.complete([0 ... 100, 102 ... 195], duration: 200)
        let unknown = LyricsCoverage.complete([0 ... 195], duration: nil)
        report(whole && !gap && !unknown, "coverage whole   \(whole), with a gap \(gap), no duration \(unknown)")

        // 41 seconds of the whole mix: 16 seconds of silence (a part transcribed earlier), then a tone. Only the
        // three clips with the tone reach Whisper, and the 40 seconds cut into clips count as heard.
        let recorder = Recorder()
        let heard = feed(recorder, silent: 16, seconds: 41)
        let sent = recorder.lock.withLock { recorder.clips }
        report(sent == 3 && abs(heard - 40) < 0.01, String(format: "whisper silence  %d clips sent, %.1f s heard (want 3, 40.0)", sent, heard))

        // Whisper fails on the second clip with sound: nothing from its start on counts as heard.
        let failing = Recorder(failing: [1])
        let stopped = feed(failing, silent: 16, seconds: 41)
        report(abs(stopped - 24) < 0.01, String(format: "whisper failure  %.1f s heard (want 24.0)", stopped))

        sources(report: report)
        fit(report: report)
    }

    /// The fit of lyrics onto what a speech model reads, on a reading made up for the test: every sung letter is
    /// likely for two frames, 100 ms after the letter before it, and one line of the lyrics isn't sung at all.
    static func fit(report: (Bool, String) -> Void) {
        let lines = ["The river runs", "Over the stones", "", "Nobody sings this line here", "(oh) Back to the sea", "Under the bridge", "Into the night"]
        let sungAt: [Int: Double] = [0: 4, 1: 9, 4: 21, 5: 25, 6: 28]
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        func label(_ character: Character) -> Int? { letters.firstIndex(of: Character(character.lowercased())).map { $0 + 1 } }
        let aligner = ForcedAligner(lines: lines, space: nil, label: label)
        let width = aligner.labels.count + 1, frames = 1500
        var values = [Float](repeating: log(1e-4), count: frames * width)
        for frame in 0 ..< frames { values[frame * width] = log(0.98) }
        for (line, start) in sungAt {
            var frame = Int(start / ForcedAligner.Emissions.frameSeconds)
            for (_, word) in ForcedAligner.sung(lines[line]) {
                for letter in word.compactMap(label) {
                    for spike in frame ..< frame + 2 {
                        values[spike * width] = log(0.1)
                        values[spike * width + 1 + aligner.labels.firstIndex(of: letter)!] = log(0.8)
                    }
                    frame += 5
                }
            }
        }
        let found = aligner.fit(ForcedAligner.Emissions(frames: frames, width: width, values: values))
        let starts = found?.starts ?? [:]
        let right = sungAt.allSatisfy { line, start in starts[line].map { abs($0 - start) < 0.05 } ?? false }
        report(right && starts.count == sungAt.count,
               "lyrics fit       \(starts.sorted { $0.key < $1.key }.map { String(format: "line %d at %.2f", $0.key, $0.value) }) (want lines 0, 1, 4, 5 and 6 at 4, 9, 21, 25 and 28)")

        // The same lyrics with times that are two seconds early: the fit finds the two seconds.
        let early = Lyrics(lines: lines.enumerated().map { Lyrics.Line(time: (sungAt[$0.offset] ?? 15) - 2, text: $0.element) }, timing: .synced)
        let outcome = LyricsFit.Outcome(starts: starts, words: [], sung: 6)
        let offset = LyricsFit.offset(of: early, outcome)
        let small = LyricsFit.offset(of: early.moved(by: 1.8), outcome)
        // A fit that found two lines of six is too thin to time the rest by.
        let thin = LyricsFit.Outcome(starts: [0: 4, 1: 9], words: [], sung: 6)
        report(offset.map { abs($0 - 2) < 0.05 } == true && small == nil && outcome.found && !thin.found,
               "lyrics offset    \(offset.map { String(format: "%+.2f s", $0) } ?? "none"), and \(small.map { String(format: "%+.2f s", $0) } ?? "none") for lyrics 0.2 s early (want +2.00 s, none)")

        // A kept fit times the lines of the same lyrics in the same file from the start of a play, and isn't used
        // for another file or for other lyrics.
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-lyrics-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LyricsStore(url: folder.appending(path: "lyrics.json"))
        let plain = Lyrics.estimate(plain: lines.joined(separator: "\n"), duration: 30)!
        let kept = LyricsStore.Fit(key: LyricsFit.key(plain), file: "one.stems", starts: starts, offset: nil)
        store.setFit(kept, for: "song")
        let sync = LyricsSync(store: store)
        sync.begin(song: "song", lyrics: plain, file: "one.stems")
        let shown = sync.times(at: 0) ?? []
        let begun = sync.fitted && sync.anchored == sungAt.count && !sync.listening && shown.count == lines.count && abs(shown[4] - 20.5) < 0.05
        sync.end()
        let other = store.fit(for: "song", key: kept.key, file: "two.stems") == nil && store.fit(for: "song", key: LyricsFit.key(early), file: "one.stems") == nil
        let decoded = (try? JSONEncoder().encode(kept)).flatMap { try? JSONDecoder().decode(LyricsStore.Fit.self, from: $0) }
        report(begun && other && !sync.fitted && decoded == kept,
               "lyrics fit kept  \(sync.anchored == 0 ? "ended" : "not ended"), \(begun ? "timed from the start" : "not timed"), \(other ? "only for its file and text" : "used for another file or text"), \(decoded == kept ? "read back the same" : "read back changed")")

        // The lines that the fit found take their times, and the line between them is placed between them.
        let timed = LyricsAligner(texts: lines, estimate: LyricsAligner.estimate(lines, duration: 30))
        let times = timed.times(timed.alignment(fitted: starts))
        let placed = times.count == 7 && abs(times[0] - 3.5) < 0.05 && abs(times[4] - 20.5) < 0.05 && times[3] > times[1] && times[3] < times[4]
        report(placed, "lyrics fit times \(times.map { String(format: "%.1f", $0) }) (want 3.5 and 8.5 first, the unsung line between 8.5 and 20.5)")
    }

    /// The formats of the services after LRCLIB: word-timed LRC, TTML with and without times, and NetEase's credits.
    static func sources(report: (Bool, String) -> Void) {
        let words = Lyrics.parse(lrc: "[00:31.41]<00:31.41>Like <00:31.70>the <00:31.93>legend <00:33.73>\n[00:35.94]<00:35.94>All ends")
        let wordTexts = words?.lines.map(\.text) ?? []
        report(wordTexts == ["Like the legend", "All ends"], "lrc word stamps  \(wordTexts)")

        let timed = Data("""
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p begin="00:08.390" end="00:10.000"><span begin="00:08.390" end="00:09.000">I'm</span> <span begin="00:09.000" end="00:10.000">hurtin'</span><span ttm:role="x-bg"><span>(baby)</span></span><span ttm:role="x-translation">我受伤了</span></p>
        <p begin="1:02.5" end="1:05.0">Second line</p>
        <p begin="70.25s" end="72s">Third</p>
        </div></body></tt>
        """.utf8)
        let ttml = TTML.lyrics(timed, duration: 200)
        let lines = ttml?.lines.map { String(format: "%.2f %@", $0.time, $0.text) } ?? []
        // A break comes after a line where the singing pauses for four seconds or more, and after the last line.
        let wanted = ["8.39 I'm hurtin'", "10.00 ", "62.50 Second line", "65.00 ", "70.25 Third", "72.00 "]
        report(ttml?.timing == .synced && lines == wanted, "ttml timed       \(lines)")

        let untimed = Data("""
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div><p>One</p><p>Two</p></div><div><p>Three</p></div></body></tt>
        """.utf8)
        let plain = TTML.lyrics(untimed, duration: 120)
        let plainTexts = plain?.lines.map(\.text) ?? []
        report(plain?.timing == .estimated && plainTexts == ["One", "Two", "", "Three"], "ttml plain       \(plainTexts)")

        // Lyrics of a version without the 20-second intro of the one that plays: one heard line moves every line by
        // the intro, and the lines after it keep their spacing of 4 seconds.
        let texts = ["Drifting slow across the tide", "Every light a little promise", "Burning low on the other side", "Hold the line until the morning",
                     "Count the boats along the shore"]
        let aligner = LyricsAligner(texts: texts, estimate: [10, 14, 18, 22, 26], keepsSpacing: true)
        let heardWords = "Burning low on the other side".split(separator: " ").enumerated().map { index, word in
            LyricsAligner.Heard(start: 38 + Double(index) * 0.5, end: 38.4 + Double(index) * 0.5, text: String(word))
        }
        let shifted = aligner.times(aligner.align(heardWords))
        let spaced = shifted.count == 5 && abs(shifted[4] - shifted[3] - 4) < 0.01 && abs(shifted[3] - 41.5) < 1.5 && abs(shifted[0] - 29.5) < 1.5
        report(spaced, "other version    \(shifted.map { String(format: "%.1f", $0) }) (want about 29.5 33.5 37.5 41.5 45.5)")

        let credited = Lyrics.parse(lrc: "[00:00.000] 作曲 : Pharrell Williams\n[00:01.000] Lyrics by: Someone\n[00:09.000]吉他：Nile Rodgers\n[00:30.90]Like the legend: of the Phoenix")
        let kept = credited.map(LyricsFinder.withoutCredits)?.lines.map(\.text) ?? []
        report(kept == ["Like the legend: of the Phoenix"], "netease credits  \(kept)")
    }

    /// Feeds a transcriber of the whole mix at 48 kHz, waits up to 5 seconds for Whisper to get the three clips with
    /// sound, and returns the seconds that count as heard.
    private static func feed(_ backend: Recorder, silent: Double, seconds: Double) -> Double {
        let rate = 48000.0
        let whisper = WhisperTranscriber(backend: backend, inputRate: rate, vocals: false)
        let started = DispatchSemaphore(value: 0)
        Task.detached {
            try? await whisper.start()
            started.signal()
        }
        started.wait()
        let chunk = 4800
        var index = 0
        while Double(index) < seconds * rate {
            let samples = (0 ..< chunk).map { i -> Float in
                let t = Double(index + i) / rate
                return t < silent ? 0 : Float(0.3 * sin(2 * .pi * 440 * t))
            }
            whisper.feed(samples)
            index += chunk
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, backend.lock.withLock({ backend.clips }) < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // The last clip's answer reaches the transcriber a moment after Whisper got it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let heard = whisper.handled
        whisper.stop()
        return heard
    }
}
