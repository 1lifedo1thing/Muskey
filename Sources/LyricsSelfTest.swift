import Foundation
import os

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

        // Made-up lyrics in capitals, with "till" in most lines: as one text the recognizer reads them as Swedish.
        let till = """
        TILL THE MORNING COMES AROUND
        TILL THE RIVER FINDS THE SEA
        I WILL WAIT HERE ON THE GROUND
        TILL YOU COME BACK HOME TO ME
        TILL THE LIGHTS GO DOWN
        TILL THE STARS ARE GONE
        TILL THE LAST TRAIN LEAVES THE TOWN
        I WILL KEEP THE LANTERN ON
        """
        let romanian = "Te aștept în fiecare seară\nLângă fereastra de la drum\nȘi nu mai știu ce să-ți spun"
        let languages = [LyricsListener.language(of: till), LyricsListener.language(of: romanian)]
        report(languages == ["en", "ro"], "lyrics language  \(languages.map { $0 ?? "none" }) (want en, ro)")

        sources(report: report)
        fit(report: report)
        live(report: report)
    }

    /// A reading made up for the test: the letters of each line are likely for two frames each, 100 ms apart, from
    /// the second that the line is sung at, and nothing is sung anywhere else.
    struct MadeUpReading: LyricsReading {
        var sung: [(text: String, start: Double)]
        let space: Int? = nil

        func label(_ character: Character) -> Int? {
            Array("abcdefghijklmnopqrstuvwxyz").firstIndex(of: Character(character.lowercased())).map { $0 + 1 }
        }

        func emissions(_ samples: [Float], columns: [Int], stop _: () -> Bool) throws -> ForcedAligner.Emissions? {
            let width = columns.count + 1, frames = samples.count / AlignerModel.frameSamples
            var values = [Float](repeating: log(1e-4), count: frames * width)
            for frame in 0 ..< frames { values[frame * width] = log(0.98) }
            for line in sung {
                var frame = Int(line.start / ForcedAligner.Emissions.frameSeconds)
                for (_, word) in ForcedAligner.sung(line.text) {
                    for letter in word.compactMap(label) {
                        for spike in frame ..< frame + 2 where spike < frames {
                            values[spike * width] = log(0.1)
                            if let column = columns.firstIndex(of: letter) { values[spike * width + 1 + column] = log(0.8) }
                        }
                        frame += 5
                    }
                }
            }
            return ForcedAligner.Emissions(frames: frames, width: width, values: values)
        }
    }

    /// Hands the tap's audio over as the vocals, at once.
    final class PassedVocals: VocalsFeeding {
        var onFallback: () -> Void = {}
        let deliver: ([Float]) -> Void
        init(deliver: @escaping ([Float]) -> Void) { self.deliver = deliver }
        func push(_ samples: [Float]) { deliver(samples) }
        func stop() {}
    }

    /// The fit of a song from another app, which comes in parts as it plays.
    static func live(report: (Bool, String) -> Void) {
        // Twenty seconds from the middle of a song, from its second 15 on, hold the last three lines of the lyrics.
        // The line that repeats is found where it is expected, not as its first time in the lyrics. The heard words
        // have the three lines near there, and without heard words a part from the middle of a song isn't used.
        let lines = ["Back to the sea", "Over the stones", "", "Nobody sings this line here", "Back to the sea", "Under the bridge", "Into the night"]
        let expected: [Double] = [4, 9, 15, 15, 21, 25, 28]
        let reading = MadeUpReading(sung: [(lines[4], 6), (lines[5], 10), (lines[6], 13)])
        let marks = stride(from: 0.0, through: 20, by: 0.2).map { LiveFit.Mark(audio: $0, song: 15 + $0) }
        let part = LiveFit.Stretch(samples: [Float](repeating: 0, count: Int(20 * AlignerModel.rate)), marks: marks)
        let found = (try? LiveFit.fit(lines, expected: expected, heard: [4: 21.3, 5: 24.6, 6: 28.2], reach: .plain, stretches: [part], reader: reading)) ?? nil
        let unheard = (try? LiveFit.fit(lines, expected: expected, reach: .plain, stretches: [part], reader: reading)) ?? nil
        // The same part with the expected times as the times of the lyrics: the lines are found without heard words.
        let timedPart = (try? LiveFit.fit(lines, expected: expected, reach: .synced, stretches: [part], reader: reading)) ?? nil
        let starts = found?.starts ?? [:]
        let right = starts.count == 3 && [4: 21.0, 5: 25, 6: 28].allSatisfy { line, start in starts[line].map { abs($0 - start) < 0.05 } ?? false }
        report(right && found?.sung == 3 && unheard?.starts.isEmpty == true && unheard?.covered.isEmpty == true && timedPart?.starts.keys.sorted() == [4, 5, 6],
               "live fit part    \(starts.sorted { $0.key < $1.key }.map { String(format: "line %d at %.2f", $0.key, $0.value) }) of \(found?.sung ?? 0) lines sung, \(unheard?.starts.count ?? -1) lines without heard words, \(timedPart?.starts.count ?? -1) as lyrics with times (want lines 4, 5 and 6 at 21, 25 and 28, of 3, then 0, then 3)")

        // The vocals of a play with a seek and a pause come as three parts, each placed in the song by the positions
        // marked while it played.
        let vocals = LiveVocals(rate: AlignerModel.rate)
        vocals.add([Float](repeating: 0, count: Int(60 * AlignerModel.rate)))
        for step in 0 ... 100 { vocals.mark(audio: Double(step) * 0.2, song: 10 + Double(step) * 0.2) }
        for step in 1 ... 100 { vocals.mark(audio: 20 + Double(step) * 0.2, song: 100 + Double(step) * 0.2) }
        for step in 0 ... 75 { vocals.mark(audio: 45 + Double(step) * 0.2, song: 120 + Double(step) * 0.2) }
        let parts = vocals.stretches()
        let lengths = parts.map { ($0.seconds * 10).rounded() / 10 }
        let placed = parts.count == 3 ? [parts[0].song(at: 5), parts[1].song(at: 5), parts[2].song(at: 5)] : []
        let heard = vocals.heard.map { [$0.lowerBound, $0.upperBound] }
        report(lengths == [20, 19.8, 15] && zip(placed, [15.0, 105.2, 125]).allSatisfy { abs($0 - $1) < 0.01 } && heard == [[10, 30], [100.2, 120], [120, 135]],
               "live parts       \(lengths) seconds, their fifth second at \(placed.map { String(format: "%.1f", $0) }) of the song (want 20, 19.8 and 15, at 15.0, 105.2 and 125.0)")
        // The audio after the last position of the song belongs to the next song.
        let cut = vocals.stretches(until: 50).map { ($0.seconds * 10).rounded() / 10 }
        report(cut == [20, 19.8, 5], "live parts end   \(cut) seconds up to the last position (want 20, 19.8 and 5)")

        // Lyrics with times: ten lines found two seconds late are off by two seconds, the same lines found where
        // they are hold, and the lyrics stay when the two halves of the song don't agree or too few lines were found.
        let timed = Lyrics(lines: (0 ..< 10).map { Lyrics.Line(time: 10 + Double($0) * 4, text: "Line \($0)") }, timing: .synced)
        func verdict(_ gaps: [Double], sung: Int = 10) -> LiveFit.Verdict {
            LiveFit.verdict(of: timed, LiveFit.Found(starts: Dictionary(uniqueKeysWithValues: gaps.enumerated().map { ($0.offset, timed.lines[$0.offset].time + $0.element) }), sung: sung))
        }
        let late = verdict([2, 2.05, 1.95, 2, 2.1, 2, 1.9, 2, 2, 2.05]), holds = verdict([0.1, 0, -0.1, 0.2, 0.1, 0, 0.05, 0.1])
        let apart = verdict([2, 2, 2, 2, 2.6, 2.6, 2.6, 2.6]), few = verdict([2, 2, 2, 2])
        let verdicts: [LiveFit.Verdict] = [late, holds, apart, few]
        var wanted = false
        if case let .off(offset) = late { wanted = abs(offset - 2) < 0.06 && holds == .holds && apart == .unsure && few == .unsure }
        report(wanted, "live verdict     \(verdicts) (want off by 2, holds, unsure, unsure)")

        // Two parts of a song that both claim a line, or put a later line first: the most lines in order stay.
        let ordered = LiveFit.inOrder([(0, 10), (1, 14), (2, 90), (3, 22), (4, 26), (3, 60)])
        report(ordered == [0: 10, 1: 14, 3: 22, 4: 26], "live fit order   \(ordered.sorted { $0.key < $1.key }.map { "\($0.key) at \(Int($0.value))" }) (want 0, 1, 3 and 4)")

        // A part from the middle of a song whose lines are found a chorus late: the heard words have most of those
        // lines elsewhere, so nothing of the part is used. One line far from its heard words is left out alone.
        let slid = LiveFit.agreeing([4: 60, 5: 64, 6: 68, 7: 72], heard: [4: 40, 5: 44, 7: 72.5])
        let one = LiveFit.agreeing([4: 60, 5: 64, 6: 68, 7: 72, 8: 76], heard: [4: 60.4, 5: 44, 7: 72.5, 8: 75])
        let thin = LiveFit.agreeing([4: 60, 5: 64, 6: 68, 7: 72], heard: [4: 60.4])
        report(slid == nil && thin == nil && one == [4: 60, 6: 68, 7: 72, 8: 76],
               "live fit heard   \(slid == nil ? "a part that slid is left out" : "a part that slid is used"), \(thin == nil ? "and so is" : "but not") a part with one heard line, lines \((one ?? [:]).keys.sorted()) stay (want 4, 6, 7 and 8)")

        liveSync(report: report)
    }

    /// The lyrics code with a song from another app, with a fit made up for the test: lyrics with times are checked
    /// once enough lines were sung, the offset is kept for that player, and the tap stops. Lyrics without times
    /// keep the lines found for the next play.
    static func liveSync(report: (Bool, String) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-lyrics-live-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LyricsStore(url: folder.appending(path: "lyrics.json"))
        let sync = LyricsSync(store: store)
        let rate = StemModel.sampleRate
        var tap = LyricsReplayTest.FileTap(rate: rate)
        sync.makeTap = { tap }
        sync.makeVocals = { _, deliver in PassedVocals(deliver: deliver) }
        sync.canFit = { true }
        sync.separates = { true }
        sync.hearsWords = { false }
        let calls = OSAllocatedUnfairLock(initialState: [Double]())
        // Line after line is sung every four seconds, from `first` on, and the fit finds the lines sung in the parts
        // that were heard.
        let first = OSAllocatedUnfairLock(initialState: 6.5)
        sync.fitLive = { request in
            let lines = request.lines, stretches = request.stretches
            calls.withLock { $0.append(stretches.reduce(0) { $0 + $1.seconds }) }
            var found = LiveFit.Found()
            for stretch in stretches {
                let from = stretch.song(at: 0), to = stretch.song(at: stretch.seconds)
                found.covered.append(from ... to)
                found.fitted.append(from ... to)
                for line in lines.indices {
                    let sung = first.withLock { $0 } + Double(line) * 4
                    guard sung >= from, sung <= to - 2 else { continue }
                    found.starts[line] = sung
                    found.sung += 1
                }
            }
            return found
        }
        var offsets: [Double] = []
        sync.onOffset = { _, _, offset in offsets.append(offset ?? .nan) }

        /// Plays the song from `from` to `to` seconds, a fifth of a second at a time, and waits for the fits.
        func play(_ from: Double, _ to: Double) {
            let chunk = [Float](repeating: 0, count: Int(rate / 5))
            for step in 0 ..< Int((to - from) * 5) {
                tap.onSamples?(chunk)
                sync.mark(position: from + Double(step + 1) / 5)
                if sync.fitsRunning > 0 { settle() }
            }
        }
        func settle() {
            let deadline = Date().addingTimeInterval(5)
            while sync.fitsRunning > 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }

        let timed = Lyrics(lines: (0 ..< 20).map { Lyrics.Line(time: 5 + Double($0) * 4, text: "Line \($0)") }, timing: .synced)
        sync.check(song: "timed", lyrics: timed, player: "app.one")
        play(0, 25)
        let early = calls.withLock { $0.count }
        play(25, 80)
        settle()
        let kept = store.fit(for: "timed", key: LyricsFit.key(timed), file: "app.one")?.offset
        let other = store.fit(for: "timed", key: LyricsFit.key(timed), file: "app.two")?.offset
        let fits = calls.withLock { $0 }
        let stopped = tap.onSamples == nil
        sync.end()
        report(early == 0 && fits.count == 1 && offsets == [1.5] && kept == 1.5 && other == nil && stopped,
               "live check       \(fits.count) fit after \(fits.first.map { String(format: "%.0f s", $0) } ?? "nothing"), off by \(offsets), kept \(kept.map { "\($0)" } ?? "nothing") for the player and \(other.map { "\($0)" } ?? "nothing") for another, the tap \(stopped ? "stopped" : "still runs") (want 1 fit, 1.5, 1.5, nothing, stopped)")

        // Lyrics without times, in a play that seeks: the lines found in both parts are kept with the parts heard, and
        // the next play times them from its start.
        tap = LyricsReplayTest.FileTap(rate: rate)
        calls.withLock { $0 = [] }
        let plain = Lyrics(lines: (0 ..< 20).map { Lyrics.Line(time: 5 + Double($0) * 4, text: "Words of line \($0)") }, timing: .estimated)
        sync.begin(song: "plain", lyrics: plain, player: "app.one")
        first.withLock { $0 = 6 }
        play(0, 30)
        play(50, 96)
        settle()
        sync.end()
        settle()
        let saved = store.fit(for: "plain", key: LyricsFit.key(plain), file: "app.one")
        let lines = (saved?.starts ?? [:]).keys.sorted()
        let covered = saved?.coveredRanges.map { [$0.lowerBound.rounded(), $0.upperBound.rounded()] } ?? []
        tap = LyricsReplayTest.FileTap(rate: rate)
        sync.begin(song: "plain", lyrics: plain, player: "app.one")
        let again = sync.fitted && sync.anchored == lines.count
        let shown = sync.times(at: 0) ?? []
        sync.end()
        report(lines == [0, 1, 2, 3, 4, 5, 12, 13, 14, 15, 16, 17, 18, 19] && covered == [[0, 30], [50, 96]] && again && shown.count == 20 && abs(shown[0] - 5.5) < 0.05,
               "live fit kept    lines \(lines) over \(covered), \(again ? "timed from the start of the next play" : "not timed in the next play") (want lines 0 to 5 and 12 to 19, over 0 to 30 and 50 to 96)")
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
        // A fit that found four lines of ten times those lines, and is too thin to tell an offset. One that found two
        // lines does neither.
        let thin = LyricsFit.Outcome(starts: [0: 4, 1: 9, 2: 14, 3: 19], words: [], sung: 10)
        let thinner = LyricsFit.Outcome(starts: [0: 4, 1: 9], words: [], sung: 10)
        report(offset.map { abs($0 - 2) < 0.05 } == true && small == nil && outcome.found && thin.usable && !thin.found && !thinner.usable,
               "lyrics offset    \(offset.map { String(format: "%+.2f s", $0) } ?? "none"), and \(small.map { String(format: "%+.2f s", $0) } ?? "none") for lyrics 0.2 s early (want +2.00 s, none)")

        // The Fix timing pill tells right times from a fit that can't tell: lyrics 0.2 s early are right, and a fit
        // whose lines disagree by seconds, or that found too few lines, is unclear.
        let scattered = LyricsFit.Outcome(starts: [0: 4, 1: 12, 4: 18, 5: 25, 6: 33], words: [], sung: 6)
        let checks = [LyricsFit.check(of: early, outcome), LyricsFit.check(of: early.moved(by: 1.8), outcome),
                      LyricsFit.check(of: early.moved(by: 2), scattered), LyricsFit.check(of: early, thin)]
        let two = if case let .off(value) = checks[0] { abs(value - 2) < 0.05 } else { false }
        report(two && Array(checks.dropFirst()) == [.right, .unclear, .unclear], "lyrics check     \(checks) (want off by +2, right, unclear, unclear)")

        // A kept fit times the lines of the same lyrics in the same file from the start of a play, and isn't used
        // for another file or for other lyrics.
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-lyrics-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LyricsStore(url: folder.appending(path: "lyrics.json"))
        // Every line of these lyrics was found, so the play has nothing left to listen for.
        let sungLines = sungAt.keys.sorted().map { lines[$0] }
        let plain = Lyrics.estimate(plain: sungLines.joined(separator: "\n"), duration: 30)!
        let kept = LyricsStore.Fit(key: LyricsFit.key(plain), file: "one.stems", starts: [0: 4, 1: 9, 2: 21, 3: 25, 4: 28], offset: nil)
        store.setFit(kept, for: "song")
        let sync = LyricsSync(store: store)
        sync.begin(song: "song", lyrics: plain, file: "one.stems")
        let shown = sync.times(at: 0) ?? []
        let begun = sync.fitted && sync.anchored == sungLines.count && !sync.listening && shown.count == sungLines.count && abs(shown[2] - 20.5) < 0.05
        sync.end()
        let other = store.fit(for: "song", key: kept.key, file: "two.stems") == nil && store.fit(for: "song", key: LyricsFit.key(early), file: "one.stems") == nil
        let decoded = (try? JSONEncoder().encode(kept)).flatMap { try? JSONDecoder().decode(LyricsStore.Fit.self, from: $0) }
        report(begun && other && !sync.fitted && decoded == kept,
               "lyrics fit kept  \(sync.anchored == 0 ? "ended" : "not ended"), \(begun ? "timed from the start" : "not timed"), \(other ? "only for its file and text" : "used for another file or text"), \(decoded == kept ? "read back the same" : "read back changed")")

        // Heard words time a line that the fit didn't find, when they fall between the fit's lines around it. Words
        // heard in the wrong place, here the unsung line at the end of the song, are left out.
        let both = LyricsAligner(texts: lines, estimate: LyricsAligner.estimate(lines, duration: 30))
        func words(_ text: String, at start: Double) -> [LyricsAligner.Heard] {
            text.split(separator: " ").enumerated().map { LyricsAligner.Heard(start: start + Double($0.offset) * 0.4, end: start + Double($0.offset) * 0.4 + 0.3, text: String($0.element)) }
        }
        let between = both.times(both.alignment(both.align(words(lines[3], at: 17)), fitted: starts))
        let wrong = both.times(both.alignment(both.align(words(lines[3], at: 29)), fitted: starts))
        report(abs(between[3] - 16.5) < 0.05 && abs(between[4] - 20.5) < 0.05 && abs(wrong[3] - 14.5) < 0.05 && abs(wrong[6] - 27.5) < 0.05,
               String(format: "lyrics fit+heard heard line at %.1f, and at %.1f when heard after the last line (want 16.5, and 14.5)", between[3], wrong[3]))

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
