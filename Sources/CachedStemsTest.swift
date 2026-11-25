import Accelerate
import Foundation

/// Self-tests of the stems from the cache, for `--selftest`. The song is made of functions of time, so that a stand-in
/// for Muskey Player can play it from any place and at any speed, exactly, and its stems go in a cache file as the
/// separation would write them. The real writer of cached stems runs between two calls of the IOProc, as the
/// separation thread runs between them.
enum CachedStemsTest {
    static let rate = 48000.0

    /// Drums on a bar of 2 seconds that repeats exactly, a sweep from 200 Hz up by 14 Hz each second as the piano, and a
    /// tone of 1700 Hz that wobbles 4 times a second as the vocals. Nothing else plays at 1700 Hz, so vocals that leak
    /// through show up there.
    struct Song {
        var length: Double
        var drumsOnly = false

        private static let hats: [(hz: Double, phase: Double)] = (0 ..< 10).map { (k: Int) -> (hz: Double, phase: Double) in
            let hz: Double = 3000 + 560 * Double(k) + 97 * Double(k % 3)
            return (hz, Double(k) * 1.7)
        }

        func drums(_ t: Double) -> Double {
            guard t >= 0, t < length else { return 0 }
            let beat = (t / 0.5).rounded(.down), sinceBeat = t - beat * 0.5
            let kickHz = [55.0, 62, 50, 68][Int(beat) % 4]
            let kick = 0.5 * (1 - exp(-sinceBeat / 0.002)) * exp(-14 * sinceBeat)
                * sin(2 * .pi * (kickHz * sinceBeat + 80 * (1 - exp(-30 * sinceBeat)) / 30))
            let eighth = (t / 0.25).rounded(.down), sinceEighth = t - eighth * 0.25
            var hat = 0.0
            for (hz, phase) in Self.hats { hat += sin(2 * .pi * hz * sinceEighth + phase) }
            hat *= (0.03 + 0.015 * Double(Int(eighth) % 8 % 3)) * (1 - exp(-sinceEighth / 0.002)) * exp(-60 * sinceEighth)
            return kick + hat
        }

        func piano(_ t: Double) -> Double {
            guard !drumsOnly, t >= 0, t < length else { return 0 }
            return 0.25 * sin(2 * .pi * (200 * t + 7 * t * t))
        }

        func vocals(_ t: Double) -> Double {
            guard !drumsOnly, t >= 0, t < length else { return 0 }
            return 0.25 * (0.75 + 0.25 * sin(2 * .pi * 4 * t)) * sin(2 * .pi * 1700 * t)
        }
    }

    /// Writes the stems of `song` into a cache file, as the separation of a whole song does.
    static func makeCache(_ song: Song, at url: URL) throws -> StemsCache {
        let frames = Int(song.length * StemsCache.rate)
        let file = try StemsCacheFile(url: url, frames: frames)
        let block = 65536
        for at in stride(from: 0, to: frames, by: block) {
            let n = min(block, frames - at)
            var drums = [Float](repeating: 0, count: n), piano = drums, vocals = drums
            for i in 0 ..< n {
                let t = Double(at + i) / StemsCache.rate
                drums[i] = Float(song.drums(t))
                piano[i] = Float(song.piano(t))
                vocals[i] = Float(song.vocals(t))
            }
            let silence = [Float](repeating: 0, count: n)
            try file.write(Stem.allCases.map { stem in
                let plane = stem == .drums ? drums : stem == .piano ? piano : stem == .vocals ? vocals : silence
                return [plane, plane]
            }, at: at)
        }
        try file.finish()
        return try StemsCache(url: url)
    }

    /// The time of a run, in seconds of the song that the tap played, for the player's reports.
    final class Clock {
        var now = 0.0
    }

    /// The stand-in for Muskey Player, the shifter, and the separation thread's part, for one run.
    final class Harness {
        let shifter: OpaquePointer
        let feed: StemsFeed
        let song: Song
        /// The player: where it is in the song, at what speed, and the tap's silence until a moment of the run.
        var position: Double
        var speed: Double
        var playing = true
        var silentUntil = -1.0
        var now = 0.0
        /// Seconds of the song for each frame of the tap, nil while it was silent.
        var times: [Double?] = []
        /// Captured frames, from `captured` on, came from the tap's frames from `tap` on.
        var captures: [(captured: UInt64, tap: Int, count: Int)] = []
        var writer: CachedStemsWriter?
        var generation: UInt64 = 0
        /// The whole song is in the cache: a generation that starts at the moment that plays takes its stems from there.
        /// Until then, and once the cache didn't line up, the stand-in for the separation writes them as the song plays.
        var cacheReady = true
        /// Where the stand-in for the separation writes next, and the callbacks since its generation began.
        var separated: UInt64 = 0
        var separating = 0
        /// A song file in place of the song made of functions, for `--stems-cache`.
        var file: FileTap?
        /// How far the writer's place in the cache was from the song's, in frames of the cache, at each check.
        var errors: [Double] = []
        var delays: [Double] = []

        init(shifter: OpaquePointer, feed: StemsFeed, song: Song, position: Double, speed: Double) {
            self.shifter = shifter
            self.feed = feed
            self.song = song
            self.position = position
            self.speed = speed
        }

        /// The app moves the song: the shifter waits for the stems of the new place.
        func announce(_ target: Double) {
            feed.seekTarget = target
            _ = ps_stems_seek(shifter)
        }

        /// The player takes the move, with the tap silent for a moment.
        func jump(to target: Double, silence: Double) {
            position = target
            silentUntil = now + silence
        }

        /// Seconds of the song that captured frame `frame` came from, nil while the tap was silent.
        func time(ofCaptured frame: UInt64) -> Double? {
            var low = 0, high = captures.count
            while low < high {
                let middle = (low + high) / 2
                if captures[middle].captured + UInt64(captures[middle].count) <= frame { low = middle + 1 } else { high = middle }
            }
            guard low < captures.count, captures[low].captured <= frame else { return nil }
            return times[captures[low].tap + Int(frame - captures[low].captured)]
        }

        func checkMapping() {
            let frame = ps_captured_written(shifter) - UInt64(CachedStemsTest.rate * 0.05)
            guard let capture = captures.last(where: { $0.captured <= frame && frame < $0.captured + UInt64($0.count) }),
                  let time = times[capture.tap + Int(frame - capture.captured)], let found = writer?.position(of: frame)
            else { return errors.append(.infinity) }
            errors.append(found - time * StemsCache.rate)
        }
    }

    struct Run {
        /// The shifter's input, and the song as the tap played it with every stem and without the vocals.
        var input: [Float]
        var full: [Float]
        var muted: [Float]
        var takeover: Double?
        var spins: UInt32
        var countdown: Bool
        /// The last moment that a countdown showed.
        var counted: Double?
        var lost: Bool
        var errors: [Double]
        var delays: [Double]
    }

    /// Plays the song through the shifter in callbacks of `chunk` frames, with the writer stepped after every `every`
    /// callbacks, as the separation thread may run less often than the IOProc.
    static func render(_ song: Song, cache: StemsCache, start: Double, speed: Double, seconds: Double, hintError: Double? = 0.4,
                       file: FileTap? = nil, chunk: Int = 512, every: Int = 1, events: [(at: Double, run: (Harness) -> Void)]) -> Run {
        let events = events.sorted { $0.at < $1.at }
        let shifter = ps_create(rate, 0, seconds)!
        defer { ps_destroy(shifter) }
        let clock = Clock()
        let feed = StemsFeed(cache: cache, path: "self-test", speed: speed) { clock.now }
        let harness = Harness(shifter: shifter, feed: feed, song: song, position: start, speed: speed)
        harness.file = file
        // Without an error to put in the hint, the player's reports are what the app gets: one at the start, and any
        // that the events give.
        if let hintError { feed.hint = { [unowned harness] in harness.position + hintError } } else { feed.report(elapsed: start, timestamp: 0, rate: speed) }

        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { free(input.unsafeMutablePointer); free(output.unsafeMutablePointer); inData.deallocate(); outData.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: inData)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: outData)

        var full: [Float] = [], muted: [Float] = []
        var takeover: Double?, countdown = false, counted: Double?, lost = false
        var frame = 0, next = 0
        // The separation as the song plays: 2 seconds before its first stems, as the first window takes, then each
        // captured frame's stems from the song itself, as a perfect separation would give them.
        let most = 4096, firstWindow = Int(rate * 2) / chunk
        let planes = UnsafeMutablePointer<Float>.allocate(capacity: Int(PS_STEMS) * 2 * most)
        planes.initialize(repeating: 0, count: Int(PS_STEMS) * 2 * most)
        defer { planes.deallocate() }
        let pointers: [UnsafePointer<Float>?] = (0 ..< Int(PS_STEMS) * 2).map { UnsafePointer(planes + $0 * most) }
        for call in 0 ..< Int(rate * seconds) / chunk {
            // What the app sees after each callback and the separation's round that may follow it.
            defer {
                if takeover == nil, ps_stems_started(shifter) != 0, ps_stems_cached(shifter) != 0 { takeover = Double(frame) / rate }
                if ps_stems_waiting(shifter) >= 0 {
                    countdown = true
                    counted = Double(frame) / rate
                }
            }
            harness.now = Double(frame) / rate
            clock.now = harness.now
            while next < events.count, events[next].at <= harness.now {
                events[next].run(harness)
                next += 1
            }
            for i in 0 ..< chunk {
                let t = harness.position
                let silent = !harness.playing || Double(frame + i) / rate < harness.silentUntil
                if let file = harness.file {
                    let sample = silent ? 0 : file.next(at: t, speed: harness.speed)
                    if !silent { harness.position += harness.speed / rate }
                    harness.times.append(silent ? nil : t)
                    inData[i * 2] = sample
                    inData[i * 2 + 1] = sample
                    continue
                }
                let drums = silent ? 0 : song.drums(t), piano = silent ? 0 : song.piano(t), vocals = silent ? 0 : song.vocals(t)
                if !silent { harness.position += harness.speed / rate }
                harness.times.append(silent ? nil : t)
                full.append(Float(drums + piano + vocals))
                muted.append(Float(drums + piano))
                inData[i * 2] = Float(drums + piano + vocals)
                inData[i * 2 + 1] = inData[i * 2]
            }
            let before = ps_captured_written(shifter)
            ps_process(shifter, input.unsafePointer, output.unsafeMutablePointer)
            let after = ps_captured_written(shifter)
            if after > before { harness.captures.append((before, frame, Int(after - before))) }
            frame += chunk

            // The separation thread: cached stems for each generation.
            guard call % every == every - 1 else { continue }
            var start: UInt64 = 0
            let current = ps_stems_generation(shifter, &start)
            if current != harness.generation, current != 0 {
                harness.generation = current
                if harness.cacheReady, !feed.lost, start + UInt64(rate) > ps_captured_written(shifter) {
                    harness.writer = CachedStemsWriter(shifter: shifter, rate: rate, feed: feed, generation: current, start: start)
                    if ProcessInfo.processInfo.environment["MUSKEY_TEST_LOG"] != nil {
                        harness.writer?.log.echo = { [unowned harness] in print(String(format: "      %.3f s  ", harness.now) + $0) }
                    }
                    ps_stems_begin_cached(shifter, current, start)
                } else {
                    harness.writer = nil
                    harness.separated = start
                    harness.separating = 0
                    ps_stems_begin(shifter, current, start)
                }
            }
            if let writer = harness.writer {
                if writer.step() == .lost {
                    lost = true
                    feed.markLost()
                    harness.writer = nil
                    ps_stems_restart(shifter)
                }
            } else if harness.generation != 0 {
                // A move asked for while the song is separated as it plays has nothing to wait for.
                var answered: UInt32 = 0
                let asked = ps_stems_seeks(shifter, &answered)
                if asked != answered { ps_stems_seek_answer(shifter, asked, 0) }
                harness.separating += every
                let written = ps_captured_written(shifter)
                let room = harness.separating > firstWindow && written > harness.separated
                    ? min(ps_stems_room(shifter, harness.separated), Int(written - harness.separated)) : 0
                for at in stride(from: 0, to: room, by: most) {
                    let n = min(most, room - at)
                    for i in 0 ..< n {
                        let t = harness.time(ofCaptured: harness.separated + UInt64(at + i))
                        for (stem, value) in [(Stem.drums, t.map(song.drums)), (.piano, t.map(song.piano)), (.vocals, t.map(song.vocals))] {
                            planes[stem.rawValue * 2 * most + i] = Float(value ?? 0)
                            planes[(stem.rawValue * 2 + 1) * most + i] = Float(value ?? 0)
                        }
                    }
                    pointers.withUnsafeBufferPointer { ps_stems_write(shifter, $0.baseAddress!, n) }
                }
                harness.separated += UInt64(room)
            }
        }
        var pairs: UnsafePointer<Float>?
        let count = ps_recording(shifter, &pairs)
        let recorded = pairs.map { Array(UnsafeBufferPointer(start: $0, count: count * 2)) } ?? []
        return Run(input: stride(from: 0, to: recorded.count, by: 2).map { recorded[$0] }, full: full, muted: muted, takeover: takeover,
                   spins: ps_spins(shifter), countdown: countdown, counted: counted, lost: lost, errors: harness.errors, delays: harness.delays)
    }

    /// The lag of the shifter's input behind `expected` that matches best in the window, and how far the input is from
    /// it there, in dB under the signal.
    static func match(_ input: [Float], _ expected: [Float], from: Double, to: Double, lags: ClosedRange<Int> = 0 ... 2048) -> (lag: Int, residual: Double) {
        let lower = Int(from * rate), upper = min(input.count, Int(to * rate))
        guard upper > lower, lower - lags.upperBound >= 0 else { return (0, .infinity) }
        func residual(_ lag: Int, _ count: Int) -> Double {
            var error: Float = 0, energy: Float = 0
            input.withUnsafeBufferPointer { i in
                expected.withUnsafeBufferPointer { e in
                    vDSP_distancesq(i.baseAddress! + lower, 1, e.baseAddress! + lower - lag, 1, &error, vDSP_Length(count))
                    vDSP_svesq(e.baseAddress! + lower - lag, 1, &energy, vDSP_Length(count))
                }
            }
            return 10 * log10(max(Double(error), 1e-20) / max(Double(energy), 1e-20))
        }
        // The lag from the first 0.2 s of the window, then how far off the whole window is at that lag.
        let short = min(upper - lower, Int(rate * 0.2))
        let lag = lags.min { residual($0, short) < residual($1, short) } ?? 0
        return (lag, residual(lag, upper - lower))
    }

    /// The lowest level of the input in 10 ms windows between two moments.
    static func quietest(_ input: [Float], from: Double, to: Double) -> Double {
        let window = Int(rate * 0.01)
        return stride(from: Int(from * rate), to: min(input.count, Int(to * rate)) - window, by: window).map { start in
            (input[start ..< start + window].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)).squareRoot()
        }.min() ?? 0
    }

    /// The highest amplitude of the vocals' tone, 1700 Hz at the song's speed, in 40 ms windows of the input between two
    /// moments.
    static func vocals(_ input: [Float], speed: Double = 1, from: Double, to: Double) -> Double {
        stride(from: from, to: to - 0.04, by: 0.02).map { amplitude(input, hz: 1700 * speed, from: $0) }.max() ?? 0
    }

    /// Through a Hann window, so the sweep a few hundred hertz away doesn't leak into it.
    static func amplitude(_ input: [Float], hz: Double, from: Double) -> Double {
        let start = Int(from * rate), count = Int(rate * 0.04)
        guard start >= 0, start + count <= input.count else { return 0 }
        var re = 0.0, im = 0.0
        for i in 0 ..< count {
            let angle = 2 * .pi * hz * Double(i) / rate
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(count))
            re += Double(input[start + i]) * window * cos(angle)
            im += Double(input[start + i]) * window * sin(angle)
        }
        return 4 * (re * re + im * im).squareRoot() / Double(count)
    }

    /// The lowest level of the input in 10 ms windows between two moments, against the level of `expected` there.
    static func lowest(_ input: [Float], _ expected: [Float], lag: Int, from: Double, to: Double) -> Double {
        func level(_ samples: ArraySlice<Float>) -> Double { (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))).squareRoot() }
        let window = Int(rate * 0.01)
        return stride(from: Int(from * rate), to: Int(to * rate) - window, by: window).map { start -> Double in
            let wanted = level(expected[(start - lag) ..< (start - lag + window)])
            return wanted > 0.01 ? level(input[start ..< start + window]) / wanted : 1
        }.min() ?? 0
    }

    /// A song file played the way Muskey Player plays it: at a speed, with the pitch, through Core Audio's sample rate
    /// converter, which is not the reader that the stems from the cache are read with. A move starts it over at the place.
    final class FileTap {
        private let audio: StereoAudio
        private var converter: Resampler?
        private var pending: [Float] = []
        private var taken = 0
        private var read = 0
        private var expected = -1.0, speed = 0.0

        init(_ audio: StereoAudio) { self.audio = audio }

        /// The next frame of the tap, which plays the song at `seconds` at `speed`.
        func next(at seconds: Double, speed: Double) -> Float {
            if abs(seconds - expected) > 0.001 || speed != self.speed {
                // A move, or a new speed: the converter starts over there.
                converter = Resampler(from: audio.rate * speed, to: CachedStemsTest.rate)
                read = max(0, Int(seconds * audio.rate))
                pending = []
                taken = 0
                self.speed = speed
            }
            expected = seconds + speed / CachedStemsTest.rate
            while taken >= pending.count, let converter {
                let end = min(audio.frames, read + 4096)
                guard end > read else { return 0 }
                let mono = zip(audio.left[read ..< end], audio.right[read ..< end]).map { ($0 + $1) / 2 }
                pending = converter.convert(mono[...], mono[...])[0]
                taken = 0
                read = end
            }
            guard taken < pending.count else { return 0 }
            taken += 1
            return pending[taken - 1]
        }
    }

    /// `--stems-cache FILE` separates a song file whole into the cache, as Muskey Player's songs are (`--stems-cache-dir
    /// DIR` keeps it elsewhere), then plays it through the shifter as Muskey Player would, at `--speed S`, from a fifth of
    /// the song, with the vocals muted, a move to half of the song and back to a fifth, and a pause. It prints how far the
    /// stems from the cache were from the song, and quits.
    static func runFile(_ path: String, speed: Double) -> Int32 {
        do {
            guard let url = StemsCache.url(for: path) else { throw SaveError(message: "No file at \(path)") }
            if StemsCache.open(for: path) == nil {
                let began = Date()
                try StemsCacheBuilder.build(path, to: url, live: { false }) { true }
                print(String(format: "separated whole in %.1f s into %@", Date().timeIntervalSince(began), url.path))
            }
            guard let cache = StemsCache.open(for: path) else { throw SaveError(message: "The cache didn't open") }
            let audio = try SongRender.read(URL(fileURLWithPath: path))
            let length = audio.seconds, start = length / 5, middle = length / 2
            print(String(format: "%.1f s of song, %d frames in the cache, at %.0f%% speed", length, cache.frames, speed * 100))
            var failures = 0
            let run = render(Song(length: length), cache: cache, start: start, speed: speed, seconds: 14, hintError: 0.3, file: FileTap(audio), events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (2.5, { $0.checkMapping() }),
                (4, { $0.announce(middle) }), (4.03, { $0.jump(to: middle, silence: 0.02) }), (6, { $0.checkMapping() }),
                (7, { $0.playing = false; ps_set_paused($0.shifter, 1) }), (8.5, { ps_set_paused($0.shifter, 0); $0.playing = true }),
                (10, { $0.checkMapping() }),
                (11, { $0.announce(start) }), (11.03, { $0.jump(to: start, silence: 0.02) }), (13.5, { $0.checkMapping() }),
            ])
            let errors = run.errors.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            if !run.errors.allSatisfy({ abs($0) < 2 }) { failures += 1 }
            if run.lost || run.takeover == nil || run.spins != 0 { failures += 1 }
            print(String(format: "%@  took over %.0f ms after the mute, %d spins, %@, frames off at four checks: %@",
                         failures == 0 ? "PASS" : "FAIL", ((run.takeover ?? 15) - 1) * 1000, run.spins, run.lost ? "lost the song" : "kept the song", errors))
            return failures == 0 ? 0 : 1
        } catch {
            print("stems cache failed: \(error)")
            return 1
        }
    }

    static func run(_ report: (Bool, String) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-stems-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let song = Song(length: 70), loop = Song(length: 40, drumsOnly: true)
        guard let cache = try? makeCache(song, at: folder.appending(path: "song.stems")),
              let loopCache = try? makeCache(loop, at: folder.appending(path: "loop.stems"))
        else { return report(false, "cache file      the stems couldn't be written") }

        // The file: what was written is read back within a step of 16 bits, and the reader that the writer uses gives
        // the sweep back at the tap's rate.
        do {
            var back = [Float](repeating: 0, count: 4096)
            back.withUnsafeMutableBufferPointer { cache.copy([Stem.piano.rawValue * 2], from: 441_000, count: 4096, into: $0.baseAddress!) }
            let worst = (0 ..< 4096).map { abs(Double(back[$0]) - song.piano(Double(441_000 + $0) / StemsCache.rate)) }.max() ?? 1
            let reader = SincReader(step: StemsCache.rate / rate)
            let from = 20.0 * StemsCache.rate + 0.37, count = 4800
            let span = reader.span(from: from, count: count)
            var source = [Float](repeating: 0, count: span.length), read = [Float](repeating: 0, count: count)
            source.withUnsafeMutableBufferPointer { cache.copy([Stem.piano.rawValue * 2], from: span.first, count: span.length, into: $0.baseAddress!) }
            source.withUnsafeBufferPointer { s in
                read.withUnsafeMutableBufferPointer { r in
                    reader.read([s.baseAddress!], origin: span.first, length: span.length, from: from, count: count, into: [r.baseAddress!])
                }
            }
            var error = 0.0, energy = 0.0
            for j in 0 ..< count {
                let want = song.piano((from + Double(j) * reader.step) / StemsCache.rate)
                error += (Double(read[j]) - want) * (Double(read[j]) - want)
                energy += want * want
            }
            let residual = 10 * log10(error / energy)
            report(worst <= Double(StemsCache.scale) && cache.frames == Int(70 * StemsCache.rate) && residual < -60,
                   String(format: "cache file      %d frames, off by %.6f at most (a step is %.6f), sweep read back at %.0f dB", cache.frames, worst,
                          StemsCache.scale, residual))
        }

        // The vocals muted at 1 s, with the player 30 s into the song and its report 0.4 s off: the stems from the cache
        // take over within a moment, with no backspin and no countdown, at the moment that plays, and in place of the
        // vocals. The lag of the input behind the tap stays what it was, so nothing is heard twice or skipped.
        for speed in [1.0, 0.8, 1.3] {
            let run = render(song, cache: cache, start: 30, speed: speed, seconds: 4, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (2, { $0.checkMapping() }), (3.5, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let stems = match(run.input, run.muted, from: (run.takeover ?? 4) + 0.1, to: 3.9)
            let error = run.errors.map(abs).max() ?? .infinity
            let leak = vocals(run.input, speed: speed, from: (run.takeover ?? 4) + 0.05, to: 3.9), before = vocals(run.input, speed: speed, from: 0.3, to: 0.9)
            let low = lowest(run.input, run.muted, lag: live.lag, from: 1, to: 3.9)
            let name = speed == 1 ? "cached stems   " : String(format: "cached %.0f%%     ", speed * 100)
            report(run.takeover.map { $0 - 1 < 0.35 } == true && run.spins == 0 && !run.countdown && !run.lost && error < 1
                   && stems.lag == live.lag && stems.residual < -30 && leak < 0.01 * before && low > 0.7,
                   String(format: "%@ took over %.0f ms after the mute, %d spins, %@, %.2f frames off, lag %d then %d, %.0f dB off the song, vocals at %.1f%%, lowest %.0f%%",
                          name, ((run.takeover ?? 5) - 1) * 1000, run.spins, run.countdown ? "a countdown" : "no countdown", error, live.lag, stems.lag,
                          stems.residual, leak / before * 100, low * 100))
        }

        // Moves while the stems from the cache play: from about 32 s to 60 s, the player taking the move 30 ms later with
        // 20 ms of silence, then back to 10 s. The output goes quiet at once and comes back with the stems of the new
        // place, and the vocals never play. The same with callbacks of 128 and 2048 frames, and the writer stepped after
        // every third one.
        for (chunk, every) in [(512, 1), (128, 3), (2048, 3)] {
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 8, chunk: chunk, every: every, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (3, { $0.announce(60) }), (3.03, { $0.jump(to: 60, silence: 0.02) }), (4.5, { $0.checkMapping() }),
                (5, { $0.announce(10) }), (5.03, { $0.jump(to: 10, silence: 0.02) }), (7.5, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let first = match(run.input, run.muted, from: 3.5, to: 4.9), second = match(run.input, run.muted, from: 5.5, to: 7.9)
            let leak = vocals(run.input, from: 1.4, to: 7.9), before = vocals(run.input, from: 0.3, to: 0.9)
            // When the level is back after each move, against the song at the place it moved to.
            let back = [3.0, 5.0].map { at in (stride(from: at + 0.01, to: at + 1, by: 0.01).first { t in lowest(run.input, run.muted, lag: live.lag, from: t, to: t + 0.03) > 0.8 } ?? at + 9) - at }
            let error = run.errors.map(abs).max() ?? .infinity
            report(run.spins == 0 && !run.lost && first.lag == live.lag && second.lag == live.lag && first.residual < -30 && second.residual < -30
                   && leak < 0.01 * before && back.allSatisfy { $0 < 0.4 } && error < 1,
                   String(format: "%@ the stems of 60 s back %.0f ms after the move, of 10 s %.0f ms after, lag %d and %d, %.0f and %.0f dB off, vocals at %.1f%%, %.2f frames off, %d spins",
                          chunk == 512 ? "cached seek    " : String(format: "cached seek %-4d", chunk), back[0] * 1000, back[1] * 1000, first.lag, second.lag, first.residual, second.residual, leak / before * 100, error, run.spins))
        }

        // A pause while the stems from the cache play, reported as the song goes silent, then the way players report it:
        // a tenth of a second late, or a quarter, and the resume as early. The output is quiet while paused, and carries
        // on from where the song stopped, at the lag it had.
        // The same with callbacks of 128 and 2048 frames, and the writer stepped after every third one.
        let pauses = [("cached pause", 3.0, 3.0, 5.0, 5.0), ("cached 0.1 s", 3.0, 3.1, 4.9, 5.0), ("cached late", 3.0, 3.25, 4.75, 5.0)]
        for (pause, (chunk, every)) in pauses.flatMap({ pause in [(512, 1), (128, 3), (2048, 3)].map { (pause, $0) } }) {
            let (base, silence, flag, clear, sound) = pause
            let name = chunk == 512 ? base.padding(toLength: 15, withPad: " ", startingAt: 0)
                : base.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: "%-4d", chunk)
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 8, chunk: chunk, every: every, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (silence, { $0.playing = false }), (flag, { ps_set_paused($0.shifter, 1) }),
                (clear, { ps_set_paused($0.shifter, 0) }), (sound, { $0.playing = true }), (7, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let steady = match(run.input, run.muted, from: 2, to: 2.9)
            let quiet = (run.input[Int(rate * (flag + 0.15)) ..< Int(rate * (sound - 0.05))].map { Double($0 * $0) }.reduce(0, +)
                / (rate * (sound - flag - 0.2))).squareRoot()
            let after = match(run.input, run.muted, from: sound + 0.2, to: 7.9)
            let low = lowest(run.input, run.muted, lag: after.lag, from: sound + 0.15, to: 7.9)
            let leak = vocals(run.input, from: 1.4, to: 7.9), before = vocals(run.input, from: 0.3, to: 0.9)
            let error = run.errors.map(abs).max() ?? .infinity
            report(quiet < 0.005 && after.lag <= live.lag && steady.lag == live.lag && after.residual < -30 && low > 0.7 && leak < 0.01 * before && error < 1,
                   String(format: "%@ %.4f level while paused, lag %d then %d, %.0f dB off after it, lowest %.0f%%, vocals at %.1f%%, %.2f frames off",
                          name, quiet, steady.lag, after.lag, after.residual, low * 100, leak / before * 100, error))
        }

        // Four pauses in a row, each reported as the song goes silent: the stems stay in line with the song after each.
        do {
            var events: [(at: Double, run: (Harness) -> Void)] = [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
            ]
            for at in [2.0, 2.8, 3.6, 4.4] {
                events += [(at, { $0.playing = false; ps_set_paused($0.shifter, 1) }), (at + 0.3, { ps_set_paused($0.shifter, 0); $0.playing = true })]
            }
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 7, events: events)
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let after = match(run.input, run.muted, from: 5, to: 6.9)
            let low = lowest(run.input, run.muted, lag: after.lag, from: 4.85, to: 6.9)
            report(after.lag <= live.lag && after.residual < -30 && low > 0.7,
                   String(format: "cached pauses   lag %d then %d after four, %.0f dB off, lowest %.0f%%", live.lag, after.lag, after.residual, low * 100))
        }

        // The player moves the song without the app asking, as Control Center's scrubber does: within the next check,
        // the stems go quiet and come back at the place that the player reports, with the vocals still muted.
        do {
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 6, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (3, { $0.jump(to: 50, silence: 0.02) }), (4.5, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let after = match(run.input, run.muted, from: 4, to: 5.9)
            let leak = vocals(run.input, from: 1.4, to: 5.9), before = vocals(run.input, from: 0.3, to: 0.9)
            let error = run.errors.map(abs).max() ?? .infinity
            report(after.lag == live.lag && after.residual < -30 && leak < 0.01 * before && error < 1 && !run.lost && run.spins == 0,
                   String(format: "cached scrub    lag %d then %d, %.0f dB off the new place, vocals at %.1f%%, %.2f frames off", live.lag, after.lag,
                          after.residual, leak / before * 100, error))
        }

        // Moves that Now Playing reports seconds late, as the helper that reads it can: the app moves the song to 55 s and
        // the player says so, which the app knows it asked for, then Control Center's scrubber moves it to 15 s and the
        // player says so, which the app passes on. Reports from before each move come in after it, and are older than
        // it. The stems follow each move, and the song isn't lost.
        do {
            var repeated = false, passed = false
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 8, hintError: nil, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (2.5, { $0.announce(55) }),
                (2.53, { $0.jump(to: 55, silence: 0.02); $0.feed.moved(to: 55); repeated = $0.feed.asked(55) }),
                (3, { $0.feed.report(elapsed: 31, timestamp: 1, rate: 1) }),
                (4.5, { $0.jump(to: 15, silence: 0.02); $0.feed.moved(to: 15); passed = !$0.feed.asked(15); if passed { $0.announce(15) } }),
                (5, { $0.feed.report(elapsed: 57, timestamp: 4.5 - 0.001, rate: 1) }), (6, { $0.checkMapping() }),
                (7.5, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let first = match(run.input, run.muted, from: 3.2, to: 4.4), second = match(run.input, run.muted, from: 5.2, to: 7.9)
            let leak = vocals(run.input, from: 1.4, to: 7.9), before = vocals(run.input, from: 0.3, to: 0.9)
            let error = run.errors.map(abs).max() ?? .infinity
            report(repeated && passed && !run.lost && first.lag == live.lag && second.lag == live.lag && first.residual < -30 && second.residual < -30
                   && leak < 0.01 * before && error < 1 && run.spins == 0,
                   String(format: "cached late tap lag %d then %d and %d, %.0f and %.0f dB off, vocals at %.1f%%, %.2f frames off, the app's move %@, the scrubber's %@",
                          live.lag, first.lag, second.lag, first.residual, second.residual, leak / before * 100, error,
                          repeated ? "known" : "taken twice", passed ? "passed on" : "missed"))
        }

        // The first move after the whole song is in the cache, while the stems are separated as the song plays: the stems
        // start over from the cache at the new place, with no backspin and no countdown, and the vocals never play.
        do {
            var spinsBefore: UInt32 = 0
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 9, events: [
                (0, { $0.cacheReady = false }),
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (5, { $0.cacheReady = true }),
                (6, { spinsBefore = ps_spins($0.shifter); ps_stems_restart($0.shifter); $0.announce(50) }),
                (6.03, { $0.jump(to: 50, silence: 0.02) }), (8, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let separated = vocals(run.input, from: 5, to: 5.9), before = vocals(run.input, from: 0.3, to: 0.9)
            let after = match(run.input, run.muted, from: 6.6, to: 8.9)
            let leak = vocals(run.input, from: 6, to: 8.9)
            let error = run.errors.map(abs).max() ?? .infinity
            report(separated < 0.01 * before && run.takeover.map { $0 - 6 < 0.4 } == true && run.spins == spinsBefore && (run.counted ?? 0) < 6
                   && after.lag <= live.lag && after.residual < -30 && leak < 0.01 * before && error < 1 && !run.lost,
                   String(format: "cached first    vocals at %.1f%% as separated, from the cache %.0f ms after the move, %d spins after it, %@, lag %d then %d, %.0f dB off, vocals at %.1f%%, %.2f frames off",
                          separated / before * 100, ((run.takeover ?? 9) - 6) * 1000, run.spins - spinsBefore,
                          (run.counted ?? 0) < 6 ? "no countdown" : "a countdown", live.lag, after.lag, after.residual, leak / before * 100, error))
        }

        // A cache that isn't the song, after a move: the move doesn't wait for it, the song is separated as it plays once
        // the cache counts as lost, and the vocals go once its first stems are in.
        do {
            let run = render(song, cache: loopCache, start: 10, speed: 1, seconds: 10, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (2, { $0.announce(25) }), (2.03, { $0.jump(to: 25, silence: 0.02) }),
            ])
            let level = { (from: Double, to: Double) in
                (run.input[Int(rate * from) ..< Int(rate * to)].map { Double($0 * $0) }.reduce(0, +) / (rate * (to - from))).squareRoot()
            }
            let song = level(0.3, 0.9), heard = level(5.5, 9.9)
            let leak = vocals(run.input, from: 9, to: 9.9), before = vocals(run.input, from: 0.3, to: 0.9)
            report(run.lost && heard > 0.5 * song && leak < 0.01 * before,
                   String(format: "cached wrong    %@, level %.0f%% of the song's after it, vocals at %.1f%% once separated", run.lost ? "lost" : "not lost",
                          heard / song * 100, leak / before * 100))
        }

        // The vocals play again and the stems turn off together: the song comes back with no dip, at the same moment.
        do {
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 5, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (3, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 1); ps_stems_enable($0.shifter, 0) }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let low = lowest(run.input, run.full, lag: live.lag, from: 3.05, to: 4.9)
            let after = match(run.input, run.full, from: 3.5, to: 4.9)
            report(low > 0.85 && after.lag == live.lag && after.residual < -30,
                   String(format: "cached off      lowest %.0f%% as the song comes back, lag %d then %d, %.0f dB off it", low * 100, live.lag, after.lag, after.residual))
        }

        // A song that repeats a bar exactly: the first lock, a move, and a move that the player takes 2.2 seconds later
        // each find the bar that the player is in, where the next bar matches as well.
        do {
            let run = render(loop, cache: loopCache, start: 12.3, speed: 1, seconds: 9, events: [
                (1, { ps_stems_enable($0.shifter, 1) }), (2, { $0.checkMapping() }),
                (3, { $0.announce(21) }), (3.04, { $0.jump(to: 21, silence: 0.01) }), (4, { $0.checkMapping() }),
                (5, { $0.announce(31) }), (5.04, { $0.jump(to: 31, silence: 2.2) }), (8.5, { $0.checkMapping() }),
            ])
            let errors = run.errors.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            report(run.errors.count == 3 && run.errors.allSatisfy { abs($0) < 1 } && !run.lost,
                   "cached loop     frames off after the first lock and two moves: \(errors) (a bar is \(Int(2 * StemsCache.rate)))")
        }

        // The tap drops 30 ms of the song once: the check finds the song that much further on, and the stems cross over
        // to it with no gap.
        do {
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 6, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (3, { $0.position += 0.03 }), (4.5, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let after = match(run.input, run.muted, from: 4, to: 5.9)
            let low = quietest(run.input, from: 2, to: 5.9)
            let error = run.errors.map(abs).max() ?? .infinity
            report(after.lag == live.lag && after.residual < -30 && low > 0.1 && error < 1 && !run.lost,
                   String(format: "cached drop     lag %d then %d, %.0f dB off after it, lowest level %.2f, %.2f frames off", live.lag, after.lag,
                          after.residual, low, error))
        }

        // The lyrics delay of 6 seconds, and of 30, raised while the stems from the cache play: they step back with the
        // song, with the vocals still muted, and when the delay ends they play at the moment that plays again.
        for (delay, start) in [(6.0, 30.0), (30, 10)] {
            let run = render(song, cache: cache, start: start, speed: 1, seconds: delay + 9, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (2, { ps_set_delay($0.shifter, delay) }), (delay + 5, { $0.delays.append(ps_stems_delay($0.shifter)) }),
                (delay + 6, { ps_set_delay($0.shifter, 0) }), (delay + 8, { $0.delays.append(ps_stems_delay($0.shifter)); $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let behind = Int(delay * rate) + live.lag
            let delayed = match(run.input, run.muted, from: delay + 3.5, to: delay + 5.9, lags: behind - 600 ... behind + 600)
            let after = match(run.input, run.muted, from: delay + 6.6, to: delay + 8.9)
            let leak = max(vocals(run.input, from: 1.4, to: delay + 1.9), vocals(run.input, from: delay + 3.2, to: delay + 8.9))
            let before = vocals(run.input, from: 0.3, to: 0.9)
            let delays = run.delays.map { String(format: "%.2f", $0) }.joined(separator: " then ")
            report(run.delays.count == 2 && abs(run.delays[0] - delay) < 0.05 && run.delays[1] < 0.05 && abs(delayed.lag - behind) < 600
                   && delayed.residual < -30 && after.lag == live.lag && after.residual < -30 && leak < 0.01 * before && !run.lost,
                   String(format: "cached delay %2.0f %@ s behind, %.0f dB off %.0f s back, lag %d after it, %.0f dB off, vocals at %.1f%%",
                          delay, delays, delayed.residual, delay, after.lag, after.residual, leak / before * 100))
        }

        // The speed changes from 100% to 115% while the stems from the cache play: they follow it.
        do {
            let run = render(song, cache: cache, start: 30, speed: 1, seconds: 6, events: [
                (1, { ps_stems_set_gain($0.shifter, Int32(Stem.vocals.rawValue), 0); ps_stems_enable($0.shifter, 1) }),
                (3, { $0.feed.speed = 1.15 }), (3.02, { $0.speed = 1.15 }), (5, { $0.checkMapping() }),
            ])
            let live = match(run.input, run.full, from: 0.3, to: 0.95)
            let after = match(run.input, run.muted, from: 4, to: 5.9)
            let error = run.errors.map(abs).max() ?? .infinity
            report(after.lag == live.lag && after.residual < -30 && error < 1 && !run.lost,
                   String(format: "cached speed    lag %d then %d at 115%%, %.0f dB off, %.2f frames off", live.lag, after.lag, after.residual, error))
        }
    }
}
