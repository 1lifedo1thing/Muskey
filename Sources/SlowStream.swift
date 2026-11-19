import Accelerate
import Foundation

/// Slows down a song that another player plays. The player plays on at its own speed, so the output falls behind
/// it: the pitch change keeps the tap's audio in a backlog and reads it back slower (`ps_slow_*` in pitch.h). This
/// keeps the backlog in bounds and keeps the song as it is heard in step with the player:
/// - When the output falls 30 seconds behind, the player moves back, and once the audio that it plays again is found
///   in the backlog, the output steps over it at the same moment of the song (a splice), so nothing is heard twice.
/// - After a pause the player moves back a little too, since players drop a moment of the song when they play again.
/// - `heard(_:)` makes the song as it is heard out of the player's report: its time moves at the speed, and a song that
///   the player started after it waits until the output reaches it.
/// - Back at 100 %, the player moves to just ahead of the output, which catches up 5 % faster and then plays the tap
///   as it is again.
/// Main thread only.
final class SlowStream {
    /// The speed asked for, from 0.5 to 1. Below 1 the stream is slowed.
    private(set) var speed = 1.0
    /// The output reads through the backlog: while slowed, and while it catches up after going back to 100 %.
    private(set) var active = false
    /// The speed that the backlog is read at, which the correction has to undo.
    private(set) var readSpeed = 1.0

    private let pitch: PitchChanger
    /// The player's own report, apart from what `heard` makes of it.
    var player: () -> NowPlaying.Track? = { nil }
    /// Moves the player's song to a time, through the way that worked in that player before.
    var move: (NowPlaying.Track, Double) -> Void = { _, _ in }
    /// Whether moves are known to work in a player, by bundle ID.
    var movesKnown: (String) -> Bool = { _ in false }
    /// The song as it is heard changed: Now Playing makes `track` again and tells the app.
    var refresh: () -> Void = {}
    /// The speed that the backlog is read at changed, so the correction changes with it.
    var onReadSpeed: () -> Void = {}
    /// Slowing had to stop because the player didn't take the moves back. Gets the speed that was asked for.
    var onFailed: (Double) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    init(pitch: PitchChanger) {
        self.pitch = pitch
    }

    private var rate: Double { pitch.sampleRate }

    // MARK: The song as it is heard

    /// The song that plays out of the backlog, and the moment of it that the clock was at.
    private struct Heard {
        var track: NowPlaying.Track
        var song: Double
        var clock: Double
    }

    private var current: Heard?
    /// A song that the player started after the one that is heard, and the backlog frame where it starts.
    private var next: (track: NowPlaying.Track, frame: UInt64)?
    /// The player's last report, for telling a song that ended from one that was skipped, and a seek in the player
    /// from the moves that Muskey asked for.
    private var lastPlayer: NowPlaying.Track?
    /// The written frames of the backlog when the player paused, for moving it back once it plays again.
    private var pausedWritten: (frame: UInt64, song: Double)?
    /// A pause that ended while a move was under way: the move after it waits for that one to be done.
    private var pendingResume: (frame: UInt64, song: Double)?

    /// The song as it is heard, made from the player's report: while slowed, its time is the output's, and it moves at
    /// the speed that the backlog is read at.
    func heard(_ report: NowPlaying.Track) -> NowPlaying.Track {
        guard active, let current, let state = pitch.slowState else { return report }
        var track = report.song == current.track.song ? report : current.track
        let position = current.song + (state.clock - current.clock) / rate
        track.elapsed = max(0, min(position, track.duration ?? .greatestFiniteMagnitude))
        track.timestamp = Date().timeIntervalSince1970
        track.rate = report.playing ? readSpeed : 0
        return track
    }

    /// Follows the player's report: a pause, a song that started after the one that is heard, a song skipped to, and
    /// a seek in the player.
    func playerReported(_ report: NowPlaying.Track) {
        defer { lastPlayer = report }
        guard active, let current, let state = pitch.slowState else { return }
        let last = lastPlayer
        if let last, last.playing, !report.playing, let at = last.position(at: Date()) { pausedWritten = (state.written, at) }
        if let last, !last.playing, report.playing, report.song == last.song, let paused = pausedWritten {
            pausedWritten = nil
            if drain != nil || awaitingSplice != nil {
                pendingResume = paused
            } else {
                resumed(paused, report: report, state: state)
            }
        }

        if report.song != current.track.song, report.title?.isEmpty == false {
            if let pending = next, pending.track.title == report.title {
                // The rest of the song's details, which some players send a moment after its title.
                next?.track = report
                return
            }
            let lastEnded = last.flatMap { last -> Bool? in
                guard last.song == current.track.song, let duration = last.duration, let at = last.position(at: Date()) else { return nil }
                return at >= duration - 5
            } ?? false
            if lastEnded, next == nil {
                // The song that the player started plays once the output reaches it, where the backlog started it.
                let at = report.position(at: Date()) ?? 0
                let frame = state.written - min(state.written, UInt64(max(0, at) * rate))
                next = (report, frame)
                log(String(format: "slow: %@ starts once the output reaches it, %.1f s from now", report.label, Double(frame - min(frame, state.reading)) / rate / max(readSpeed, 0.1)))
            } else {
                log("slow: the player skipped to \(report.label), the output jumps to it")
                jump(to: report, at: report.position(at: Date()) ?? 0, state: state)
            }
            return
        }

        // A seek in the player that Muskey didn't ask for is heard at once.
        if report.song == current.track.song, let last, last.song == report.song, report.playing, last.playing,
           let before = last.position(at: Date()), let now = report.position(at: Date()), abs(now - before) > 2, !ownMove(near: now) {
            log(String(format: "slow: the player moved the song to %.1f s, the output jumps to it", now))
            jump(to: report, at: now, state: state)
        }
    }

    /// Jumps the output to the newest audio, which plays `track` at `seconds` into it.
    private func jump(to track: NowPlaying.Track, at seconds: Double, state: PSSlowState) {
        cancelDrain()
        next = nil
        pendingResume = nil
        pitch.slowFlush()
        current = Heard(track: track, song: seconds, clock: state.clock)
        refresh()
    }

    /// The song moved to `seconds` at Muskey's request (the seek keys, karaoke's start): the player moves, and the
    /// output jumps to the newest audio, which is that moment.
    func moved(_ track: NowPlaying.Track, to seconds: Double) {
        let report = player() ?? track
        guard active, let state = pitch.slowState else { return move(report, seconds) }
        log(String(format: "slow: the song moves to %.1f s, the output jumps to it", seconds))
        expectMove(to: seconds)
        move(report, seconds)
        jump(to: report, at: seconds, state: state)
    }

    // MARK: Speed

    /// Slows the song that `track` is down to `target`, or goes back to 100 % with 1.
    func setSpeed(_ target: Double, track: NowPlaying.Track) {
        let target = min(max(target, 0.5), 1)
        guard target != speed else { return }
        speed = target
        if target < 1 {
            if !active {
                active = true
                pitch.slowing = true
                current = Heard(track: track, song: track.position(at: Date()) ?? 0, clock: pitch.slowState?.clock ?? 0)
                lastPlayer = player()
                startTimer()
                log("slow: the output reads the song from the backlog")
            }
            setReadSpeed(target)
        } else {
            // The song plays at its speed again at once, and the output catches up with the player from there.
            log("slow: back at 100 %, the output catches up with the player")
            setReadSpeed(1)
        }
        refresh()
    }

    /// Stops slowing at once: the output plays the tap as it is again, which jumps ahead to the player. `failed` tells
    /// the app, which shows the speed that was asked for as a failure.
    func stop(_ reason: String, failed: Bool = false) {
        guard active else { return }
        log("slow: stopped, \(reason)")
        let wanted = speed
        cancelDrain()
        speed = 1
        finish()
        if failed { onFailed(wanted) }
    }

    private func finish() {
        active = false
        next = nil
        current = nil
        pausedWritten = nil
        pendingResume = nil
        timer?.invalidate()
        timer = nil
        pitch.slowing = false
        setReadSpeed(1)
        refresh()
    }

    private func setReadSpeed(_ value: Double) {
        guard value != readSpeed else { return }
        readSpeed = value
        pitch.slowSpeed = value
        onReadSpeed()
        refresh()
    }

    // MARK: Keeping the backlog in bounds

    /// The output moves the player back once it is this many seconds behind it, to a moment just ahead of the output.
    /// `--slow-behind S` lowers it, so a test sees the moves sooner.
    private static let mostBehind = TestFlags.value("--slow-behind").flatMap(Double.init) ?? 30.0
    /// `--log-slow` logs the backlog and the time heard every 2 seconds.
    private static let logState = TestFlags.has("--log-slow")
    private var loggedAt = Date.distantPast

    /// A move of the player that waits for the audio it plays again: where the old audio stops (`seam`), where the
    /// audio after the move starts (`searchFrom`), the stretch of old audio to find in it, and the time it was sent.
    private struct Drain {
        var seam: UInt64
        var searchFrom: UInt64
        var reference: Range<UInt64>
        var target: Double
        var sent: Date
        var searching = false
        var why: String
    }

    private var drain: Drain?
    /// A splice handed to the output, which holds one at a time: no move starts until the output has stepped through it.
    /// The count is the splices that the output stepped through or missed when it was handed over.
    private var awaitingSplice: UInt32?
    private var timer: Timer?
    /// Moves that Muskey sent, so the report of each isn't taken for a seek in the player.
    private var expected: [(seconds: Double, until: Date)] = []
    /// Moves back in a row that the player didn't take.
    private var failedDrains = 0

    private func expectMove(to seconds: Double) {
        expected.removeAll { $0.until < Date() }
        expected.append((seconds, Date().addingTimeInterval(6)))
    }

    private func ownMove(near seconds: Double) -> Bool {
        expected.contains { $0.until > Date() && abs($0.seconds - seconds) < 2.5 }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func cancelDrain() {
        drain = nil
        awaitingSplice = nil
        searchID += 1
    }

    /// The backlog's written frames at the last tick: fewer means that the pitch change started over, for another
    /// output device, with an empty backlog.
    private var lastWritten: UInt64 = 0

    private func tick() {
        guard active, let state = pitch.slowState else { return }
        guard state.engaged != 0 || pitch.slowing else { return }
        defer { lastWritten = state.written }
        if state.written < lastWritten, let report = player() {
            log("slow: the output started over with an empty backlog")
            cancelDrain()
            next = nil
            current = Heard(track: report, song: report.position(at: Date()) ?? 0, clock: state.clock)
            return refresh()
        }
        if let pending = next, state.reading >= pending.frame {
            // The output reached the song that the player started after the one heard.
            let song = Double(state.reading - pending.frame) / rate
            current = Heard(track: pending.track, song: song, clock: state.clock)
            next = nil
            log("slow: the output reached \(pending.track.label)")
            refresh()
        }
        let backlog = Double(state.written - min(state.written, state.reading)) / rate
        if Self.logState, Date().timeIntervalSince(loggedAt) >= 2, let current {
            loggedAt = Date()
            log(String(format: "slow: backlog %.2f s, heard %.2f s, player %.2f s, read at %.2f, %d splices, %d missed",
                       backlog, current.song + (state.clock - current.clock) / rate, player()?.position(at: Date()) ?? -1, readSpeed,
                       state.splices, state.missed))
        }
        if let drain {
            return follow(drain, state: state)
        }
        if let posted = awaitingSplice {
            guard state.splices + state.missed > posted else { return }
            awaitingSplice = nil
        }
        if let pause = pendingResume, let report = player() {
            pendingResume = nil
            if report.playing, report.song == current?.track.song { return resumed(pause, report: report, state: state) }
        }
        guard let report = player(), report.playing, let at = report.position(at: Date()), let duration = report.duration,
              report.song == current?.track.song, next == nil
        else { return }
        if speed == 1, backlog <= 4 {
            if backlog > 0.05 { return setReadSpeed(1.05) }
            log("slow: caught up with the player, the output plays the tap as it is")
            return finish()
        }
        // In a player that hasn't moved a song for Muskey yet, the first move comes early: one that the player ignores
        // then costs little, and the slowing stops before the output falls far behind.
        let known = report.bundleID.map(movesKnown) ?? false
        guard (speed < 1 && (backlog >= Self.mostBehind || (!known && backlog >= 8))) || speed == 1, let current else { return }
        // The player moves to a moment ahead of the output, and once the audio it plays again reaches the output's
        // moment, the output steps over to it: everything in between was waiting to be heard, so it goes. While
        // slowed, the moment is 6 seconds ahead, which leaves time for a player that takes a few seconds to play
        // again after a move, such as one that streams; while catching up, 3.5 seconds, so less is left to catch up.
        let heardAt = current.song + (state.clock - current.clock) / rate
        let ahead = readSpeed >= 1 ? 3.5 : 6
        let reference = state.reading + UInt64((ahead + 0.5) * rate) ..< state.reading + UInt64((ahead + 1) * rate)
        guard reference.upperBound + UInt64(rate) < state.written, at - (heardAt + ahead) > 1, duration - at > 4 else { return }
        startDrain(Drain(seam: state.written, searchFrom: state.written, reference: reference, target: heardAt + ahead, sent: Date(),
                         why: speed == 1 ? "catching up" : String(format: "%.0f s behind", backlog)), report: report)
    }

    /// The player played on after a pause, from a moment later than where it stopped, as most players do: it moves
    /// back a little, and the output steps over the audio played again at the moment it stopped.
    private func resumed(_ pause: (frame: UInt64, song: Double), report: NowPlaying.Track, state: PSSlowState) {
        guard drain == nil, pause.song > 3 else { return }
        // Some of the audio after the pause may be written already, so the old audio to find ends a little earlier.
        let seam = pause.frame
        let reference = seam - UInt64(1.8 * rate) ..< seam - UInt64(0.8 * rate)
        guard state.reading + UInt64(0.5 * rate) < reference.lowerBound else { return }
        startDrain(Drain(seam: seam, searchFrom: state.written, reference: reference, target: pause.song - 2.2, sent: Date(),
                         why: "played after a pause"), report: report)
    }

    private func startDrain(_ new: Drain, report: NowPlaying.Track) {
        drain = new
        expectMove(to: new.target)
        log(String(format: "slow: the player moves back to %.1f s (%@)", new.target, new.why))
        move(report, new.target)
    }

    private var searchID = 0

    /// Waits for the audio after the move to reach the old audio's moment, then looks for it, and hands the splice to
    /// the output. The output mustn't reach the old audio before that, or the move would be heard.
    private func follow(_ current: Drain, state: PSSlowState) {
        let deadline = current.reference.lowerBound - min(current.reference.lowerBound, UInt64(0.25 * rate))
        if state.reading >= deadline {
            drain = nil
            searchID += 1
            failedDrains += 1
            log("slow: the audio after the move wasn't found before the output reached it")
            if failedDrains >= 2 { stop("the player didn't play the song again after moving it back", failed: true) }
            return
        }
        guard !current.searching, Date().timeIntervalSince(lastSearch) > 0.4 else { return }
        // The player gets to the old audio's moment this long after the move, and then some, for a player that takes a
        // moment to play again.
        let needed = (playerSecondsToReference(current) ?? 2) + 0.5
        guard Double(state.written - current.searchFrom) / rate >= needed else { return }
        drain?.searching = true
        lastSearch = Date()
        let id = searchID
        let old = pitch.slowRead(from: current.reference.lowerBound, count: Int(current.reference.upperBound - current.reference.lowerBound))
        let region = pitch.slowRead(from: current.searchFrom, count: Int(state.written - current.searchFrom))
        guard old.start == current.reference.lowerBound, !old.samples.isEmpty, region.samples.count > old.samples.count else {
            drain?.searching = false
            return
        }
        let rate = self.rate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Splice.find(old.samples, in: region.samples, rate: rate)
            DispatchQueue.main.async {
                guard let self, self.searchID == id, let drain = self.drain else { return }
                // Not there yet: the player may still be getting to it, so the search runs again with more audio.
                guard let found else {
                    self.drain?.searching = false
                    return
                }
                let to = region.start + UInt64(found.offset)
                let handed = self.pitch.slowState.map { $0.splices + $0.missed } ?? 0
                self.pitch.slowSplice(from: drain.reference.lowerBound, to: to, before: drain.seam)
                self.awaitingSplice = handed
                self.drain = nil
                self.failedDrains = 0
                self.log(String(format: "slow: found the audio after the move (%.4f match), the output steps over %.1f s of it",
                                found.score, Double(to - drain.reference.lowerBound) / rate))
            }
        }
    }

    private var lastSearch = Date.distantPast

    /// Seconds that the player plays after the move before it gets past the old audio's moment.
    private func playerSecondsToReference(_ drain: Drain) -> Double? {
        guard let state = pitch.slowState, let current else { return nil }
        let heardAt = current.song + (state.clock - current.clock) / rate
        let reference = heardAt + Double(drain.reference.upperBound - min(drain.reference.upperBound, state.reading)) / rate
        return reference - drain.target
    }
}

/// Finds a stretch of old audio in the audio that a player played again: first at an eighth of the rate across the
/// whole region, then at the full rate around the best match.
enum Splice {
    static func find(_ reference: [Float], in region: [Float], rate: Double) -> (offset: Int, score: Float)? {
        guard reference.count > 64, region.count > reference.count else { return nil }
        let energy = vDSP.sumOfSquares(reference)
        // Silence can't be told apart from silence: no splice is found in it.
        guard energy / Float(reference.count) > 1e-7 else { return nil }
        let step = 8
        let small = decimate(reference, by: step), wide = decimate(region, by: step)
        guard wide.count > small.count else { return nil }
        let coarse = best(small, in: wide, near: nil)
        guard let coarse, coarse.score > 0.6 else { return nil }
        // At an eighth of the rate, a beat or a bass note a few periods away can match about as well, so the full rate
        // searches 50 ms around it. The same audio played again matches almost exactly; another moment doesn't.
        let around = Int(rate * 0.05), center = coarse.offset * step
        let fine = best(reference, in: region, near: center - around ..< center + around + 1)
        guard let fine, fine.score > 0.97 else { return nil }
        return fine
    }

    private static func decimate(_ samples: [Float], by step: Int) -> [Float] {
        let count = samples.count / step
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { s in
            for i in 0 ..< count {
                var sum: Float = 0
                vDSP_sve(s.baseAddress! + i * step, 1, &sum, vDSP_Length(step))
                out[i] = sum / Float(step)
            }
        }
        return out
    }

    /// The offset in `region` where `reference` matches best, by normalized correlation, within `near` when given.
    private static func best(_ reference: [Float], in region: [Float], near: Range<Int>?) -> (offset: Int, score: Float)? {
        let n = reference.count
        let lower = max(0, near?.lowerBound ?? 0), upper = min(region.count - n + 1, near?.upperBound ?? region.count - n + 1)
        guard upper > lower else { return nil }
        let count = upper - lower
        var correlation = [Float](repeating: 0, count: count)
        region.withUnsafeBufferPointer { r in
            vDSP_conv(r.baseAddress! + lower, 1, reference, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(n))
        }
        // The energy of each window of the region, from a running sum of squares.
        var squares = [Float](repeating: 0, count: count + n - 1)
        region.withUnsafeBufferPointer { r in vDSP_vsq(r.baseAddress! + lower, 1, &squares, 1, vDSP_Length(count + n - 1)) }
        let referenceEnergy = vDSP.sumOfSquares(reference)
        var window = squares[0 ..< n].reduce(0, +)
        var bestIndex = -1
        var bestScore: Float = -1
        for i in 0 ..< count {
            if i > 0 { window += squares[i + n - 1] - squares[i - 1] }
            let score = correlation[i] / (max(window, 1e-12) * referenceEnergy).squareRoot()
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex < 0 ? nil : (lower + bestIndex, bestScore)
    }
}
