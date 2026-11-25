import Accelerate
import Foundation
import os

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "SlowStream")

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
    /// How far the return to 100 % has come, 0 to 1, or nil once the output plays the tap as it is.
    var onReturn: (Double?) -> Void = { _ in }
    /// The output plays the tap as it is again, so the pitch change can stop if nothing else needs it.
    var onEnd: () -> Void = {}
    /// The backlog when the song went back to 100 %, which the return counts down from.
    private var returnFrom: Double?
    /// The speed that the output catches up with the player at, once the song plays at 100 % again. The pitch change
    /// keeps the key, so the song plays a quarter faster for a few seconds instead of a twentieth for a minute.
    static let catchUp = 1.25
    /// Slowing had to stop because the player didn't take the moves back. Gets the speed that was asked for.
    var onFailed: (Double) -> Void = { _ in }

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
    /// When that pause was reported, and whether it came right after a move that Muskey sent.
    private var pausedWhen = Date.distantPast
    private var pausedNearMove = false
    /// The song that was paused: a play report of another song is a song change, not the end of the pause.
    private var pausedSong: [String?] = []
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
        if let last, last.playing, !report.playing, let at = last.position(at: Date()) {
            pausedWritten = (state.written, at)
            pausedSong = last.song
            pausedWhen = Date()
            pausedNearMove = Date().timeIntervalSince(moveSent) < 1.5
        }
        // Some players (Safari) report a pause and a play within a fraction of a second around a move, which isn't a
        // pause that the person made.
        let bounce = pausedNearMove && Date().timeIntervalSince(pausedWhen) < 0.6
        if let last, !last.playing, report.playing, report.song == last.song, report.song == pausedSong, let paused = pausedWritten {
            pausedWritten = nil
            if bounce {
                log.debug("slow: the pause around the move was the player's own")
            } else if drain != nil || awaitingSplice != nil {
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
                let line = String(format: "slow: %@ starts once the output reaches it, %.1f s from now", report.label, Double(frame - min(frame, state.reading)) / rate / max(readSpeed, 0.1))
                log.info("\(line, privacy: .public)")
            } else {
                log.info("slow: the player skipped to \(report.label, privacy: .public), the output jumps to it")
                jump(to: report, at: report.position(at: Date()) ?? 0, state: state)
            }
            return
        }

        // A seek in the player that Muskey didn't ask for is heard at once.
        if report.song == current.track.song, let last, last.song == report.song, report.playing, last.playing,
           let before = last.position(at: Date()), let now = report.position(at: Date()), abs(now - before) > 2, !ownMove(near: now) {
            log.info("\(String(format: "slow: the player moved the song to %.1f s, the output jumps to it", now), privacy: .public)")
            jump(to: report, at: now, state: state)
        }
    }

    /// Jumps the output to the newest audio, which plays `track` at `seconds` into it.
    private func jump(to track: NowPlaying.Track, at seconds: Double, state: PSSlowState) {
        cancelDrain()
        next = nil
        pendingResume = nil
        pausedWritten = nil
        pitch.slowFlush()
        current = Heard(track: track, song: seconds, clock: state.clock)
        refresh()
    }

    /// The song moved to `seconds` at Muskey's request (the seek keys, karaoke's start): the player moves, and the
    /// output jumps to the newest audio, which is that moment.
    func moved(_ track: NowPlaying.Track, to seconds: Double) {
        let report = player() ?? track
        guard active, let state = pitch.slowState else { return move(report, seconds) }
        log.info("\(String(format: "slow: the song moves to %.1f s, the output jumps to it", seconds), privacy: .public)")
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
                log.notice("slow: the output reads the song from the backlog")
            }
            setReadSpeed(target)
        } else {
            // The song plays at its speed again at once, and the output catches up with the player from there.
            log.info("slow: back at 100 %, the output catches up with the player")
            setReadSpeed(1)
        }
        refresh()
    }

    /// Stops slowing at once: the output plays the tap as it is again, which jumps ahead to the player. `failed` tells
    /// the app, which shows the speed that was asked for as a failure.
    func stop(_ reason: String, failed: Bool = false) {
        guard active else { return }
        log.log(level: failed ? .error : .notice, "slow: stopped, \(reason, privacy: .public)")
        let wanted = speed
        cancelDrain()
        speed = 1
        finish()
        if failed { onFailed(wanted) }
    }

    private func finish() {
        if returnFrom != nil {
            returnFrom = nil
            onReturn(nil)
        }
        active = false
        next = nil
        current = nil
        pausedWritten = nil
        pendingResume = nil
        timer?.invalidate()
        timer = nil
        pitch.slowing = false
        missingSince = nil
        setReadSpeed(1)
        refresh()
        onEnd()
    }

    /// When the pitch change was first found gone while slowing. It starts over for another output device in a moment,
    /// but one that stays gone took the backlog with it, and there is nothing left to read or catch up with.
    private var missingSince: Date?

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
    /// `--slow-dump DIR` saves the backlog around each search that failed, from 3 seconds before the old audio to the
    /// newest audio, as raw 32-bit floats at the backlog's rate, one channel.
    private static let dumpFolder = TestFlags.value("--slow-dump")
    private var dumps = 0
    private var loggedAt = Date.distantPast

    /// A move of the player that waits for the audio it plays again: where the old audio stops (`seam`), where the
    /// audio after the move starts (`searchFrom`), the stretch of old audio to find in it, and the time it was sent.
    private struct Drain {
        var seam: UInt64
        var searchFrom: UInt64
        var reference: Range<UInt64>
        var target: Double
        /// Seconds that the player plays after the move before it is past the old audio.
        var toReference: Double
        var sent: Date
        var searching = false
        var why: String
        /// The best match of the searches so far, for the log when the audio isn't found.
        var best: Float = 0
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
        moveSent = Date()
    }

    /// When Muskey last sent a move. Some players (Safari) report a pause and a play around a move, which isn't a pause
    /// that the person made.
    private var moveSent = Date.distantPast
    /// Muskey sent a move less than 1.5 seconds ago.
    var movedRecently: Bool { active && Date().timeIntervalSince(moveSent) < 1.5 }

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
        guard active else { return }
        guard let state = pitch.slowState else {
            let since = missingSince ?? Date()
            missingSince = since
            if Date().timeIntervalSince(since) > 3 {
                log.info("slow: the pitch change stopped, the output plays the tap as it is")
                finish()
            }
            return
        }
        missingSince = nil
        // Until the output engages, the reader's frame is still 0, and the backlog would read as days long.
        guard state.engaged != 0 else { return }
        defer { lastWritten = state.written }
        if state.written < lastWritten, let report = player() {
            log.info("slow: the output started over with an empty backlog")
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
            log.info("slow: the output reached \(pending.track.label, privacy: .public)")
            refresh()
        }
        let backlog = Double(state.written - min(state.written, state.reading)) / rate
        if speed == 1 {
            let from = max(returnFrom ?? backlog, backlog)
            returnFrom = from
            onReturn(from > 0.05 ? min(1, max(0, 1 - backlog / from)) : 1)
        }
        if Self.logState, Date().timeIntervalSince(loggedAt) >= 2, let current {
            loggedAt = Date()
            let line = String(format: "slow: backlog %.2f s, heard %.2f s, player %.2f s, read at %.2f, %d splices, %d missed",
                              backlog, current.song + (state.clock - current.clock) / rate, player()?.position(at: Date()) ?? -1, readSpeed,
                              state.splices, state.missed)
            log.debug("\(line, privacy: .public)")
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
        else {
            // Back at 100 %, a player that plays another song than the one heard, and that the output isn't on its way
            // to, leaves no moment to catch up with.
            if speed == 1, let report = player(), report.playing, report.song != current?.track.song, next == nil {
                log.info("slow: the player plays another song, the output plays the tap as it is")
                finish()
            }
            return
        }
        if speed == 1, backlog <= 4 {
            if backlog > 0.05 { return setReadSpeed(Self.catchUp) }
            log.info("slow: caught up with the player, the output plays the tap as it is")
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
        let ahead = readSpeed >= 1 ? 3.5 : 6
        let reference = state.reading + UInt64((ahead + 0.5) * rate) ..< state.reading + UInt64((ahead + 1.5) * rate)
        guard reference.upperBound + UInt64(rate) < state.written, duration - at > 4 else { return }
        // Two estimates of the old audio's moment in the song: from the time heard, which can be off by a moment after a
        // song change, and from the player's position (the newest audio in the backlog is where the player is), which
        // is off when a player reports its position loosely (Safari). The player moves to half a second before the
        // earlier one and plays past the later one, so the old audio is played again either way.
        let heardAt = current.song + (state.clock - current.clock) / rate
        let fromHeard = heardAt + ahead + 0.5, fromPlayer = at - Double(state.written - reference.lowerBound) / rate
        let early = min(fromHeard, fromPlayer), late = max(fromHeard, fromPlayer)
        // The player has until the output reaches the old audio to play past it, less a second or two for the move.
        let spare = (ahead + 0.5) / max(readSpeed, 0.1) - 2 - 1.5
        let target = max(early, late - max(spare, 0)) - 0.5
        guard at - target > 1 else { return }
        startDrain(Drain(seam: state.written, searchFrom: state.written, reference: reference, target: target,
                         toReference: late + 1 - target, sent: Date(),
                         why: String(format: "%@, heard %.1f s, player %.1f s", speed == 1 ? "catching up" : String(format: "%.0f s behind", backlog),
                                     fromHeard, fromPlayer)), report: report)
    }

    /// The player played on after a pause, from a moment later than where it stopped, as most players do: it moves
    /// back a little, and the output steps over the audio played again at the moment it stopped.
    private func resumed(_ pause: (frame: UInt64, song: Double), report: NowPlaying.Track, state: PSSlowState) {
        guard drain == nil, pause.song > 3 else { return }
        // Some of the audio after the pause may be written already, so the old audio to find ends a little earlier.
        let seam = pause.frame
        let reference = seam - UInt64(1.8 * rate) ..< seam - UInt64(0.8 * rate)
        guard state.reading + UInt64(0.5 * rate) < reference.lowerBound else { return }
        // The player moves to 3.2 seconds before the pause, 1.4 seconds before the old audio: a player that reported the
        // pause late, or that plays a moment of silence after a move, still plays all of it again.
        startDrain(Drain(seam: seam, searchFrom: state.written, reference: reference, target: pause.song - 3.2, toReference: 2.4, sent: Date(),
                         why: "played after a pause"), report: report)
    }

    private func startDrain(_ new: Drain, report: NowPlaying.Track) {
        drain = new
        expectMove(to: new.target)
        log.info("\(String(format: "slow: the player moves back to %.1f s (%@)", new.target, new.why), privacy: .public)")
        move(report, new.target)
    }

    private var searchID = 0

    /// The old audio is looked for in three windows of 0.4 seconds across its second, the earliest first. A moment
    /// that the tap or the player dropped in one window leaves the others.
    private func windows(of reference: Range<UInt64>) -> [Range<UInt64>] { Self.windows(of: reference, rate: rate) }

    private static func windows(of reference: Range<UInt64>, rate: Double) -> [Range<UInt64>] {
        let length = UInt64(0.4 * rate), room = reference.count > Int(length) ? reference.upperBound - length - reference.lowerBound : 0
        return [0, room / 2, room].map { reference.lowerBound + $0 ..< reference.lowerBound + $0 + length }
    }

    /// `--splice-dump FILE OLD MOVE` runs the search on a file saved by `--slow-dump`, with the old audio's second at
    /// OLD seconds into it and the move at MOVE, and prints what each window found.
    static func searchDump(_ path: String, old: Double, move: Double, rate: Double = 48000) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("can't read \(path)")
            return 1
        }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let reference = UInt64(old * rate) ..< UInt64((old + 1) * rate)
        let region = Array(samples[Int(move * rate)...])
        for window in windows(of: reference, rate: rate) {
            let part = Array(samples[Int(window.lowerBound) ..< Int(window.upperBound)])
            let search = Splice.search(part, in: region, rate: rate)
            let place = search.match.map { String(format: "found at %.3f s, %.4f", move + Double($0.offset) / rate, $0.score) } ?? "not found"
            print(String(format: "window at %.2f s: %@, best %.4f", Double(window.lowerBound) / rate, place, search.best))
        }
        return 0
    }

    /// Waits for the audio after the move to reach the old audio's moment, then looks for it, and hands the splice to
    /// the output. The output mustn't reach the old audio before that, or the move would be heard.
    private func follow(_ current: Drain, state: PSSlowState) {
        let last = windows(of: current.reference).last!.lowerBound
        let deadline = last - min(last, UInt64(0.25 * rate))
        if state.reading >= deadline {
            drain = nil
            searchID += 1
            failedDrains += 1
            log.error("\(String(format: "slow: the audio after the move wasn't found before the output reached it (best match %.2f)", current.best), privacy: .public)")
            if let folder = Self.dumpFolder { dump(current, state: state, to: folder) }
            if failedDrains >= 2 { stop("the player didn't play the song again after moving it back", failed: true) }
            return
        }
        guard !current.searching, Date().timeIntervalSince(lastSearch) > 0.4 else { return }
        // The player gets to the old audio's moment this long after the move, and then some, for a player that takes a
        // moment to play again.
        let needed = current.toReference + 0.5
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
        // A window that the output is about to reach is too late for a splice.
        let windows = windows(of: current.reference).filter { $0.lowerBound >= state.reading + UInt64(0.25 * rate) }
        let rate = self.rate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The same audio played again matches at 0.99 and more. A window with a dropout in it matches a little less
            // and can line up a few dozen milliseconds off, so a weaker match is taken only when no window is clean.
            var best: Float = 0
            var found: (window: Range<UInt64>, offset: Int, score: Float)?
            for window in windows {
                let part = Array(old.samples[Int(window.lowerBound - old.start) ..< Int(window.upperBound - old.start)])
                let search = Splice.search(part, in: region.samples, rate: rate)
                best = max(best, search.best)
                guard let match = search.match, match.score > found?.score ?? 0 else { continue }
                found = (window, match.offset, match.score)
                if match.score > 0.99 { break }
            }
            DispatchQueue.main.async {
                guard let self, self.searchID == id, let drain = self.drain else { return }
                // Not there yet: the player may still be getting to it, so the search runs again with more audio.
                guard let found else {
                    self.drain?.searching = false
                    self.drain?.best = max(drain.best, best)
                    return
                }
                let to = region.start + UInt64(found.offset)
                let handed = self.pitch.slowState.map { $0.splices + $0.missed } ?? 0
                self.pitch.slowSplice(from: found.window.lowerBound, to: to, before: drain.seam)
                self.awaitingSplice = handed
                self.drain = nil
                self.failedDrains = 0
                let line = String(format: "slow: found the audio after the move (%.4f match, window %d), the output steps over %.1f s of it",
                                  found.score, Int((found.window.lowerBound - drain.reference.lowerBound) * 10 / UInt64(rate)),
                                  Double(to - found.window.lowerBound) / rate)
                log.info("\(line, privacy: .public)")
            }
        }
    }

    private var lastSearch = Date.distantPast

    private func dump(_ drain: Drain, state: PSSlowState, to folder: String) {
        dumps += 1
        let start = drain.reference.lowerBound - min(drain.reference.lowerBound, UInt64(3 * rate))
        let span = pitch.slowRead(from: start, count: Int(state.written - start))
        let file = URL(fileURLWithPath: folder).appendingPathComponent("fail-\(dumps).f32")
        try? span.samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file)
        let line = String(format: "slow: saved %@ (%.2f s): old audio at %.2f s for %.2f s, the move at %.2f s", file.path,
                          Double(span.samples.count) / rate, Double(drain.reference.lowerBound - span.start) / rate,
                          Double(drain.reference.upperBound - drain.reference.lowerBound) / rate, Double(drain.searchFrom - span.start) / rate)
        log.debug("\(line, privacy: .public)")
    }
}

/// Finds a stretch of old audio in the audio that a player played again: first at an eighth of the rate across the
/// whole region, then at the full rate around the best match.
enum Splice {
    /// The match, when there is one, and the best score that the search reached either way.
    static func search(_ reference: [Float], in region: [Float], rate: Double) -> (match: (offset: Int, score: Float)?, best: Float) {
        guard reference.count > 64, region.count > reference.count else { return (nil, 0) }
        let energy = vDSP.sumOfSquares(reference)
        // Silence can't be told apart from silence: no splice is found in it.
        guard energy / Float(reference.count) > 1e-7 else { return (nil, 0) }
        let step = 8
        let small = decimate(reference, by: step), wide = decimate(region, by: step)
        guard wide.count > small.count else { return (nil, 0) }
        let coarse = best(small, in: wide, near: nil)
        guard let coarse, coarse.score > 0.6 else { return (nil, coarse?.score ?? 0) }
        // At an eighth of the rate, a beat or a bass note a few periods away can match about as well, so the full rate
        // searches 50 ms around it. The same audio played again matches almost exactly; another moment doesn't.
        let around = Int(rate * 0.05), center = coarse.offset * step
        let fine = best(reference, in: region, near: center - around ..< center + around + 1)
        guard let fine, fine.score > 0.97 else { return (nil, fine?.score ?? coarse.score) }
        return (fine, fine.score)
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
        let referenceEnergy = Double(vDSP.sumOfSquares(reference))
        // The running sum is kept in doubles: in floats, the near silence after a loud stretch (a player's silence
        // after a seek) came out as almost nothing, and the score there far above 1. A window 40 dB quieter than the
        // old audio can't be it, so it isn't scored.
        let quietest = referenceEnergy * 1e-4
        var window = squares[0 ..< n].reduce(0.0) { $0 + Double($1) }
        var bestIndex = -1
        var bestScore: Float = -1
        for i in 0 ..< count {
            if i > 0 { window += Double(squares[i + n - 1]) - Double(squares[i - 1]) }
            guard window > quietest else { continue }
            let score = Float(Double(correlation[i]) / (window * referenceEnergy).squareRoot())
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex < 0 ? nil : (lower + bestIndex, bestScore)
    }
}
