import AVFoundation
import Foundation

/// `--lyrics-live SONG --lyrics-ref LYRICS` plays a song file through the lyrics code as a song from another app,
/// faster than real time, and prints how far the lines land from the times in LYRICS (TTML or LRC): as each line lit
/// up while the song played, and as the lines are timed at the start of the next play. The lyrics are the text of
/// LYRICS without its times.
///
/// - `--plays 0-end,0-end` sets each play in seconds of the song, as for `--lyrics-replay`: `0-40+90-130` seeks, and
///   `0-40+p5+40-90` pauses for 5 seconds.
/// - `--lyrics-synced FILE` shows the lyrics of FILE with their times instead (LYRICS itself for `--lyrics-synced ref`),
///   moved by `--lyrics-shift` seconds, and prints what the check of their times says and when.
/// - `--lyrics-vocals FILE` takes the vocals from a file that the live separation wrote earlier, and hands them over
///   late and in pieces as the separation does. Without it the song is separated while it plays.
/// - `--live-fit off` leaves the lyrics timing model out, and `--live-listener off` the speech model.
/// - `--live-speed N` plays N times faster than real time (10 by default). The speech model hears words about as late
///   in real time at any speed, so the lines light up later at a high speed than they would in a real play.
/// - `--live-jitter B,J` reports the song's position B seconds off, with up to J seconds more that change every 5
///   seconds, as a player does.
/// - `--lyrics-align-out FILE` writes every time as JSON.
enum LyricsLiveTest {
    /// Stands in for the live separation: the vocals of the part of the song that the tap just heard come out in
    /// blocks, a few seconds late, with one sample out for each sample in.
    final class RecordedVocals: VocalsFeeding, @unchecked Sendable {
        var onFallback: () -> Void = {}
        private let vocals: [Float]
        private let tapRate: Double
        private let deliver: ([Float]) -> Void
        private let queue = DispatchQueue(label: "muskey.test.vocals")
        private var pending: [Float] = []
        private var owed = 0.0
        /// The second of the song that the next samples pushed are from, or nil in a pause. Set by the test before
        /// each push.
        var position: Double?

        init(vocals: [Float], tapRate: Double, deliver: @escaping ([Float]) -> Void) {
            self.vocals = vocals
            self.tapRate = tapRate
            self.deliver = deliver
        }

        func push(_ samples: [Float]) {
            owed += Double(samples.count) * StemModel.sampleRate / tapRate
            let count = Int(owed)
            owed -= Double(count)
            let start = position.map { Int($0 * StemModel.sampleRate) }
            queue.async { [self] in
                if let start {
                    for index in start ..< start + count { pending.append(index >= 0 && index < vocals.count ? vocals[index] : 0) }
                } else {
                    pending += [Float](repeating: 0, count: count)
                }
                while pending.count >= StemModel.chunk {
                    deliver(Array(pending.prefix(StemStream.step)))
                    pending.removeFirst(StemStream.step)
                }
            }
        }

        func stop() {}

        /// Waits until everything pushed so far was handed over.
        func drain() { queue.sync {} }
    }

    struct Output: Encodable {
        struct Play: Encodable {
            var plan: String
            /// For each line of the reference, the first word's time as the lines were timed when the play began.
            var start: [Double?] = []
            /// The position of the song at which each line lit up, moved to the time of its first word.
            var lit: [Double?] = []
            /// The same as the lines were timed when the play ended.
            var end: [Double?] = []
            /// What the check of lyrics with times said: the position of the song, and the seconds they are off by.
            var offsetAt: Double?
            var offset: Double?
            /// The position of the song at which the check stopped hearing it, with its answer or after its last try.
            var stoppedAt: Double?
            /// Seconds of the song that the play heard.
            var heardSeconds = 0.0
            var log: [String] = []
            /// Fits made in the play, and the seconds they took in all.
            var fits = 0
            var fitSeconds = 0.0
        }

        var reference: [Double] = []
        var texts: [String] = []
        var plays: [Play] = []
        /// The offset kept for the song after the last play, for lyrics with times. 0 when they hold, nil when no
        /// check could tell.
        var keptOffset: Double?
    }

    @MainActor static func run(file: String, reference: String, plays spec: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reference)) else {
            print("can't read \(reference)")
            exit(1)
        }
        Task { @MainActor in
            // The vocals of a file stand in for the tap's audio too: only their length is used.
            let recorded = TestFlags.value("--lyrics-vocals").flatMap { try? SongRender.read(URL(fileURLWithPath: $0)) }
            guard let song = recorded ?? (try? SongRender.read(URL(fileURLWithPath: file))) else {
                print("can't read \(file)")
                exit(1)
            }
            let mono = zip(song.left, song.right).map { ($0 + $1) * 0.5 }
            let rate = song.rate, duration = song.seconds
            let vocals = recorded.map { _ in rate == StemModel.sampleRate ? mono : Resampler(from: rate, to: StemModel.sampleRate).convert(mono[...], mono[...])[0] }

            func parse(_ data: Data, _ path: String) -> Lyrics? {
                path.hasSuffix(".ttml") ? TTML.lyrics(data, duration: duration) : String(data: data, encoding: .utf8).flatMap { Lyrics.parse(lrc: $0) }
            }
            guard let truth = parse(data, reference), truth.timing == .synced,
                  let plain = Lyrics.estimate(plain: truth.lines.map(\.text).joined(separator: "\n"), duration: duration)
            else {
                print("no times in \(reference)")
                exit(1)
            }
            var synced: Lyrics?
            if let path = TestFlags.value("--lyrics-synced") {
                let lyrics = path == "ref" ? truth : (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { parse($0, path) }
                guard let lyrics, lyrics.timing == .synced else {
                    print("no times in \(path)")
                    exit(1)
                }
                synced = lyrics.moved(by: TestFlags.value("--lyrics-shift").flatMap(Double.init) ?? 0)
            }
            // Each line of the lyrics without times is the next line of the reference with its text.
            var place: [Int: Int] = [:]
            var next = 0
            for (index, line) in plain.lines.enumerated() where !line.text.isEmpty {
                guard let at = truth.lines[next...].firstIndex(where: { $0.text == line.text }) else { continue }
                next = at + 1
                place[index] = at
            }

            let url = FileManager.default.temporaryDirectory.appending(path: "muskey-lyrics-live-\(getpid()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = LyricsStore(url: url)
            let sync = LyricsSync(store: store)
            let id = "live", player = "app.test"
            let fits = TestFlags.value("--live-fit") != "off"
            let speed = TestFlags.value("--live-speed").flatMap(Double.init) ?? 10
            let jitter = (TestFlags.value("--live-jitter") ?? "0,0").split(separator: ",").compactMap { Double($0) }
            var output = Output(reference: truth.lines.map(\.time), texts: truth.lines.map(\.text))
            var play = Output.Play(plan: "")
            sync.log = {
                print("    " + $0)
                play.log.append($0)
            }
            sync.canFit = { fits && AlignerModel.installed }
            sync.separates = { true }
            if TestFlags.value("--live-listener") == "off" { sync.hearsWords = { false } }
            let fit = sync.fitLive
            let took = FitTimer()
            sync.fitLive = { request in
                let began = Date()
                defer { took.add(Date().timeIntervalSince(began)) }
                return try fit(request)
            }
            var position = 0.0
            sync.onOffset = { _, _, offset in
                play.offsetAt = position
                play.offset = offset
            }

            func times() -> [Double?] {
                var result = [Double?](repeating: nil, count: truth.lines.count)
                guard let shown = sync.times(at: position) else { return result }
                for (index, at) in place where index < shown.count { result[at] = shown[index] + LyricsAligner.lead }
                return result
            }

            let plans = spec.split(separator: ",").map(String.init)
            for (number, plan) in plans.enumerated() {
                let parts = plan.split(separator: "+").compactMap { part -> (Double, Double)? in
                    if part.hasPrefix("p"), let length = Double(part.dropFirst()) { return (-length, -length) }
                    let ends = part.split(separator: "-").map { $0 == "end" ? duration : Double($0) }
                    guard ends.count == 2, let from = ends[0], let to = ends[1], from < to else { return nil }
                    return (from, min(to, duration))
                }
                print("play \(number + 1): \(plan)")
                play = Output.Play(plan: plan)
                position = parts.first { $0.0 >= 0 }?.0 ?? 0
                let tap = LyricsReplayTest.FileTap(rate: rate)
                var feed: RecordedVocals?
                sync.makeTap = { tap }
                if let vocals {
                    sync.makeVocals = { tapRate, deliver in
                        let recorded = RecordedVocals(vocals: vocals, tapRate: tapRate, deliver: deliver)
                        feed = recorded
                        return recorded
                    }
                }
                if let synced {
                    sync.check(song: id, lyrics: synced, player: player, duration: duration)
                } else {
                    sync.begin(song: id, lyrics: plain, player: player, duration: duration)
                }
                play.start = times()
                // The speech model takes a moment to get ready, and the audio before that would be dropped. A play that
                // has nothing left to hear never says that it listens.
                for _ in 0 ..< 120 where !play.log.contains(where: { $0.contains("listening with") || $0.contains("hearing the vocals") || $0.contains("timed from an earlier play") }) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                var lit = [Double?](repeating: nil, count: plain.lines.count)
                let step = Int(rate / 10)
                var bias = jitter.first ?? 0, biasAt = 0.0
                for part in parts {
                    if part.0 < 0 {
                        for _ in 0 ..< Int(-part.0 * 10) {
                            feed?.position = nil
                            tap.onSamples?([Float](repeating: 0, count: step))
                            sync.mark(position: nil)
                            try? await Task.sleep(for: .milliseconds(Int(100 / speed)))
                        }
                        continue
                    }
                    for start in stride(from: Int(part.0 * rate), to: Int(part.1 * rate), by: step) {
                        feed?.position = Double(start) / rate
                        tap.onSamples?(Array(mono[start ..< min(mono.count, start + step)]))
                        position = Double(min(mono.count, start + step)) / rate
                        if jitter.count == 2, position - biasAt >= 5 {
                            biasAt = position
                            bias = jitter[0] + Double.random(in: -jitter[1] ... jitter[1])
                        }
                        sync.mark(position: position + bias)
                        if tap.onSamples != nil { play.heardSeconds += 0.1 } else if play.stoppedAt == nil, synced != nil { play.stoppedAt = position }
                        // A line lights up a quarter of a second before its time, as in the lyrics panel.
                        if synced == nil, let shown = sync.times(at: position + bias), let current = shown.lastIndex(where: { $0 <= position + bias + 0.25 }) {
                            for line in 0 ... current where lit[line] == nil { lit[line] = position + bias + 0.25 + LyricsAligner.lead }
                        }
                        try? await Task.sleep(for: .milliseconds(Int(100 / speed)))
                        // A fit takes a few seconds, which is less of the song in a real play than at this speed, so
                        // the song waits for it.
                        while sync.fitsRunning > 0 { try? await Task.sleep(for: .milliseconds(20)) }
                    }
                }
                play.end = times()
                play.lit = [Double?](repeating: nil, count: truth.lines.count)
                for (index, at) in place { play.lit[at] = lit[index] }
                feed?.drain()
                sync.end()
                for _ in 0 ..< 3000 where sync.fitsRunning > 0 { try? await Task.sleep(for: .milliseconds(20)) }
                (play.fits, play.fitSeconds) = took.take()
                print(String(format: "    %d fits, %.1f s", play.fits, play.fitSeconds))
                output.plays.append(play)
            }
            // The lines as the next play would start with them.
            if synced == nil {
                position = 0
                play = Output.Play(plan: "next")
                sync.makeTap = { LyricsReplayTest.FileTap(rate: rate) }
                sync.hearsWords = { false }
                sync.canFit = { fits }
                sync.begin(song: id, lyrics: plain, player: player)
                play.start = times()
                sync.end()
                output.plays.append(play)
                report(output)
            } else if let synced {
                output.keptOffset = store.fit(for: id, key: LyricsFit.key(synced), file: player)?.offset
                print(output.keptOffset.map { $0 == 0 ? "kept: their times hold" : String(format: "kept: off by %+.2f s", $0) } ?? "kept: nothing")
            }
            if let path = TestFlags.value("--lyrics-align-out") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try? encoder.encode(output).write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// Counts the fits and their seconds, from the queue that they run on.
    final class FitTimer: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var seconds = 0.0

        func add(_ value: Double) {
            lock.withLock {
                count += 1
                seconds += value
            }
        }

        func take() -> (Int, Double) {
            lock.withLock {
                defer { (count, seconds) = (0, 0) }
                return (count, seconds)
            }
        }
    }

    private static func report(_ output: Output) {
        func stats(_ name: String, _ times: [Double?], from: Double = 0) {
            let errors = zip(times, zip(output.reference, output.texts)).compactMap { time, line in
                line.1.isEmpty || line.0 < from ? nil : time.map { $0 - line.0 }
            }
            guard !errors.isEmpty else { return print("\(name): no lines") }
            // The reference can be off as a whole, so the errors are counted around their median.
            let median = errors.sorted()[errors.count / 2]
            let around = errors.map { abs($0 - median) }.sorted()
            func share(_ limit: Double) -> Double { 100 * Double(around.count { $0 < limit }) / Double(around.count) }
            print(String(format: "%@: %d lines, median %+.0f ms from the reference, and around that median: median %.0f ms, within 200 ms %.0f%%, 500 ms %.0f%%, over 1 s %.0f%%",
                         name, errors.count, median * 1000, around[around.count / 2] * 1000, share(0.2), share(0.5), 100 - share(1)))
        }
        for (number, play) in output.plays.enumerated() where play.plan != "next" {
            stats("play \(number + 1), as the lines lit up", play.lit)
            stats("play \(number + 1), at its end", play.end)
        }
        if let next = output.plays.last { stats("the next play, from its start", next.start) }
    }
}
