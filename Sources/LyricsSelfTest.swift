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
