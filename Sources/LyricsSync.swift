import Foundation
import Speech
import os

/// Lyrics added by hand and the words heard in each song, by the id that LyricsFinder gives the song, in
/// `~/Library/Application Support/Muskey/lyrics.json`. Main thread only.
final class LyricsStore {
    /// The store of the app, which Settings reads and clears too.
    static let main = LyricsStore()
    /// Posted after Settings removed every fit and shift.
    static let timingsRemoved = Notification.Name("muskey.lyrics.timingsRemoved")

    struct Entry: Codable {
        /// Lyrics added by hand, plain or LRC, which take the place of the ones from LRCLIB.
        var text: String?
        var heard: [LyricsAligner.Heard]?
        /// Lyrics that Whisper wrote by ear for a song that LRCLIB doesn't have, as LRC.
        var written: String?
        /// The stretches of the song that Whisper has transcribed, as start and end seconds, whether anyone sang in
        /// them or not. Those parts aren't sent to Whisper again.
        var covered: [[Double]]?
        /// What fitting the lyrics onto the vocals found, one for each text and each file or player: the same song
        /// from Spotify and from Muskey Player, or with and without times, is fitted apart.
        var fits: [Fit]?
        /// The seconds that lyrics with times show moved by, from the Fix timing pill, for each text and each file or
        /// player.
        var shifts: [Shift]?
        /// The one fit that a song had before each file and player kept its own. Read once, then moved into `fits`.
        var fit: Fit?
        var date: Date

        var isEmpty: Bool { text == nil && heard == nil && written == nil && covered == nil && fits?.isEmpty != false && shifts?.isEmpty != false }
    }

    /// The seconds that lyrics with times show moved by, set by applying the offset that a fit found or by the arrows
    /// of the Fix timing pill.
    struct Shift: Codable, Equatable {
        /// The text, as `LyricsFit.key` writes it.
        var key: String
        /// The file, as the name of its stems in the cache, or the player, as `app.` and its bundle ID.
        var file: String
        var seconds: Double
    }

    /// The times found by fitting lyrics onto the vocals of a song file, kept so the next play has them from its start.
    struct Fit: Codable, Equatable {
        /// The text that was fitted, as `LyricsFit.key` writes it. Other lyrics for the song are fitted again.
        var key: String
        /// The file whose vocals the text was fitted onto, as the name of its stems in the cache. The same song in
        /// another file, or from another player, can start seconds earlier or later, so the fit isn't used for it.
        var file: String
        /// The second at which the first word of each line is sung, for the lines that were found.
        var starts: [Int: Double]?
        /// Seconds that lyrics with times were off by, as a whole: 0 when they were right, nil when the fit couldn't
        /// tell.
        var offset: Double?
        /// The lines showed moved by the offset, before the shift was kept apart from the fit. Read once, then moved
        /// into `shifts`.
        var applied: Bool?
        /// The parts of the song that were fitted, as start and end seconds, for a song from another app, which is
        /// fitted from what has played. Nil for a file, which is fitted whole.
        var covered: [[Double]]?

        var coveredRanges: [ClosedRange<Double>] { (covered ?? []).compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0] ... $0[1] : nil } }
    }

    private static let limit = 1000
    /// Fits and shifts kept for each song. A song rarely plays from more than two players, with more than two texts.
    private static let perSong = 6
    private let file: StoreFile<[String: Entry]>
    private var entries: [String: Entry]?

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Muskey/lyrics.json")) {
        file = StoreFile(label: "muskey.lyrics", read: {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        }, write: { entries in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            } catch {}
        })
    }

    func text(for id: String) -> String? { load()[id]?.text }
    func heard(for id: String) -> [LyricsAligner.Heard] { load()[id]?.heard ?? [] }
    func written(for id: String) -> String? { load()[id]?.written }
    func fit(for id: String, key: String, file: String) -> Fit? { load()[id]?.fits?.last { $0.key == key && $0.file == file } }
    /// Keeps `fit` in place of the fit of the same text onto the same file or player.
    func setFit(_ fit: Fit, for id: String) {
        update(id) { entry in
            var fits = (entry.fits ?? []).filter { $0.key != fit.key || $0.file != fit.file }
            fits.append(fit)
            entry.fits = Array(fits.suffix(Self.perSong))
        }
    }

    /// The seconds that the lyrics show moved by, 0 when they show at their own times.
    func shift(for id: String, key: String, file: String) -> Double {
        load()[id]?.shifts?.last { $0.key == key && $0.file == file }?.seconds ?? 0
    }

    func setShift(_ seconds: Double, for id: String, key: String, file: String) {
        update(id) { entry in
            var shifts = (entry.shifts ?? []).filter { $0.key != key || $0.file != file }
            if seconds != 0 { shifts.append(Shift(key: key, file: file, seconds: seconds)) }
            entry.shifts = shifts.isEmpty ? nil : Array(shifts.suffix(Self.perSong))
        }
    }

    /// Forgets the fit and the shift of one text on one file or player.
    func removeTiming(for id: String, key: String, file: String) {
        guard load()[id] != nil else { return }
        update(id) { entry in
            entry.fits = entry.fits?.filter { $0.key != key || $0.file != file }
            entry.shifts = entry.shifts?.filter { $0.key != key || $0.file != file }
            if entry.fits?.isEmpty == true { entry.fits = nil }
            if entry.shifts?.isEmpty == true { entry.shifts = nil }
        }
    }

    /// The songs that have a fit or a shift kept (Settings > Lyrics > Saved timings).
    var timedSongs: Int { load().values.count { $0.fits?.isEmpty == false || $0.shifts?.isEmpty == false } }

    /// Forgets every fit and every shift.
    func removeTimings() {
        var entries = load()
        for (id, var entry) in entries {
            entry.fits = nil
            entry.shifts = nil
            entries[id] = entry.isEmpty ? nil : entry
        }
        self.entries = entries
        file.save(entries)
    }

    func covered(for id: String) -> [ClosedRange<Double>] {
        (load()[id]?.covered ?? []).compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0] ... $0[1] : nil }
    }

    func setWritten(_ text: String?, covered: [ClosedRange<Double>], for id: String) {
        update(id) {
            $0.written = text
            // Tenths of a second keep the file small.
            $0.covered = covered.isEmpty ? nil : covered.map { [($0.lowerBound * 10).rounded() / 10, ($0.upperBound * 10).rounded() / 10] }
        }
    }

    func setText(_ text: String?, for id: String) {
        update(id) { $0.text = text }
    }

    func setHeard(_ heard: [LyricsAligner.Heard], for id: String) {
        // Times to the hundredth of a second keep the file small.
        let rounded = heard.map { word -> LyricsAligner.Heard in
            let start: Double = (word.start * 100).rounded() / 100
            let end: Double = (word.end * 100).rounded() / 100
            return LyricsAligner.Heard(start: start, end: end, text: word.text)
        }
        update(id) { $0.heard = rounded.isEmpty ? nil : rounded }
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        var entries = load()
        var entry = entries[id] ?? Entry(date: Date())
        change(&entry)
        entry.date = Date()
        entries[id] = entry.isEmpty ? nil : entry
        if entries.count > Self.limit {
            // The songs heard longest ago go first, but never lyrics added by hand.
            let old = entries.filter { $0.value.text == nil }.sorted { $0.value.date < $1.value.date }.prefix(entries.count - Self.limit)
            for (key, _) in old { entries[key] = nil }
        }
        self.entries = entries
        file.save(entries)
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        var loaded = file.load()
        // A song kept one fit before each file and player kept its own, with the lines moved by its offset after a
        // click. Both move to where they are kept now.
        for (id, var entry) in loaded {
            guard let old = entry.fit else { continue }
            entry.fit = nil
            var fit = old
            fit.applied = nil
            entry.fits = (entry.fits ?? []) + [fit]
            if old.applied == true, let offset = old.offset, offset != 0 {
                entry.shifts = (entry.shifts ?? []) + [Shift(key: old.key, file: old.file, seconds: offset)]
            }
            loaded[id] = entry
        }
        entries = loaded
        return loaded
    }
}

/// The stretches of a song that Whisper has transcribed, in seconds of the song.
enum LyricsCoverage {
    /// The first seconds of a song play before the first position comes in, and are rarely sung.
    static let head = 3.0
    /// The last seconds of a song often go unheard when the next song starts, and are rarely sung.
    static let tail = 10.0

    /// Joins the stretches that overlap or are less than a second apart, and counts the start of the song as covered
    /// when the first stretch begins in its first seconds.
    static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            // A pause leaves a hole of a fraction of a second between the stretches before and after it.
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        if let first = merged.first, first.lowerBound > 0, first.lowerBound <= head { merged[0] = 0 ... first.upperBound }
        return merged
    }

    /// The position is in a transcribed stretch, at least half a second before its end, so the audio after it is
    /// heard again a moment early rather than a moment late.
    static func contains(_ ranges: [ClosedRange<Double>], _ position: Double, duration: Double?) -> Bool {
        if let duration, position >= duration - tail, complete(ranges, duration: duration) { return true }
        return ranges.contains { position >= $0.lowerBound && position <= $0.upperBound - 0.5 }
    }

    /// Transcribed from the start to the last seconds of the song.
    static func complete(_ ranges: [ClosedRange<Double>], duration: Double?) -> Bool {
        guard let duration, duration > tail, let first = merge(ranges).first else { return false }
        return first.lowerBound == 0 && first.upperBound >= duration - tail
    }
}

/// Times lyrics that come without times by listening to the song while they show. The heard words are kept for the
/// song, so the next time it plays the lines are timed from its start. Main thread only.
final class LyricsSync {
    /// The timing changed from estimated to heard, or the speech model started or finished downloading.
    var onChange: () -> Void = {}
    var log: (String) -> Void = { _ in }
    /// Whisper, when Settings has it, which times lyrics in place of Apple's speech model and writes lyrics for
    /// songs that LRCLIB doesn't have.
    var whisper: () -> WhisperBackend? = { nil }
    /// The lyrics that Whisper writes, line by line, while it listens.
    var onWritten: (Lyrics) -> Void = { _ in }
    /// Whisper failed three times in a row while writing lyrics, and stopped listening.
    var onWritingFailed: () -> Void = {}

    private(set) var downloading = false
    /// Lines that start at a heard word.
    private(set) var anchored = 0

    private let store: LyricsStore
    private var song: String?
    private var aligner: LyricsAligner?
    private var alignment = LyricsAligner.Alignment()
    /// Words heard in earlier plays of the song, and earlier in this one before a seek.
    private var stored: [LyricsAligner.Heard] = []
    /// Words heard since the last seek, in seconds of the song.
    private var current: [LyricsAligner.Heard] = []

    private var tap: AudioTapping?
    /// The system's audio, or a song file in `--lyrics-replay`.
    var makeTap: () -> AudioTapping = { SystemAudioTap() }
    /// The live separation of the vocals, or a stand-in for it in `--lyrics-live`. It gets the sample rate of the
    /// tap and where to hand the vocals over.
    var makeVocals: (Double, @escaping ([Float]) -> Void) -> VocalsFeeding = { VocalsFeed(inputRate: $0, deliver: $1) }
    private var listener: LyricsHearing?
    private var vocals: VocalsFeeding?
    /// Seconds of audio that the tap heard, which the heard words are timed in, also when the vocals reach the
    /// listener a few seconds later.
    private let tapped = OSAllocatedUnfairLock(initialState: 0.0)
    /// The song plays at its own speed. A song that Muskey Player plays faster or slower isn't heard: its words would
    /// come at other times than the song's.
    var hearsSong: Bool {
        get { hearing.withLock { $0 } }
        set { hearing.withLock { $0 = newValue } }
    }

    private let hearing = OSAllocatedUnfairLock(initialState: true)
    /// A test leaves the speech model out.
    var hearsWords: () -> Bool = { true }
    /// The listener hears the vocals alone, when the model that separates them is on the Mac.
    var separates: () -> Bool = { StemModel.installed }
    /// Whisper writes the lyrics of this song, as it hears them.
    private(set) var writing = false
    /// Whisper writes the lyrics of a part of the song that it hasn't transcribed before, so the song has to play
    /// behind for the lines to come before they are sung. Called once per song.
    var onNeedsLead: () -> Void = {}
    private var leadAsked = false
    /// The parts of the song that Whisper has transcribed, in this play and the ones before it.
    private var covered: [ClosedRange<Double>] = []
    /// How far the coverage reached when it was last saved.
    private var savedCoverage = 0.0
    private var duration: Double?
    /// While the song plays a part that Whisper has transcribed, the transcriber gets silence: nothing is sent to
    /// Whisper, and the audio keeps its timing. Set on the main thread, read on the tap's thread.
    private let skipping = OSAllocatedUnfairLock(initialState: false)
    /// The last time the words heard for timing were saved.
    private var heardSaved = Date.distantPast
    /// Whether the song was in a transcribed part at the last position, for the log.
    private var inCovered: Bool?
    /// Whisper finishing the phrases of songs that stopped playing.
    private var finishing: [Finisher] = []
    private var tapRate = 48000.0
    var finishingCount: Int { finishing.count }
    /// The song plays a part that Whisper transcribed in an earlier play.
    var inTranscribedPart: Bool { writing && inCovered == true }
    /// The audio heard since the last seek: where it starts in the listener's audio and in the song.
    private var segment: (audio: Double, song: Double)?
    /// The stretches heard before the last seek while Whisper writes, for placing what Whisper finishes after it:
    /// where each starts and ends in the listener's audio and in the song.
    private var closed: [Span] = []
    fileprivate struct Span {
        var audio: ClosedRange<Double>
        var song: ClosedRange<Double>

        func song(at audio: Double) -> Double {
            let length = self.audio.upperBound - self.audio.lowerBound
            guard length > 0 else { return song.lowerBound }
            return song.lowerBound + (audio - self.audio.lowerBound) / length * (song.upperBound - song.lowerBound)
        }
    }
    /// The song's position at moments of the listener's audio, to place the heard words in the song.
    private var marks: [(audio: Double, song: Double)] = []
    private var started = 0

    /// The first word of each line that the fit of the text onto the vocals of the whole song found, in seconds. Those
    /// lines keep these times, and the heard words time the rest.
    private var fittedStarts: [Int: Double] = [:]
    var fitted: Bool { !fittedStarts.isEmpty }

    init(store: LyricsStore) {
        self.store = store
    }

    /// Times the lines whose first words the fit of the text onto the vocals found. The heard words keep timing the
    /// other lines, and the listening stops when the fit left almost none.
    func apply(fitted starts: [Int: Double]) {
        guard aligner != nil, !writing, !starts.isEmpty else { return }
        fittedStarts = starts
        realign(now: true)
        if anchored >= sungLines * 9 / 10, listener != nil {
            stopListening()
            if downloading {
                downloading = false
                onChange()
            }
        }
    }

    /// Lines of the lyrics with words to sing.
    private var sungLines = 0

    var listening: Bool { listener != nil }

    // MARK: Songs from other apps

    /// The check of lyrics with times has its answer for the song that plays: its id, the key of the lyrics and the
    /// seconds that every line is off by, 0 when the times hold and nil when the check can't tell. The answer is
    /// kept with the song, and nothing moves the lines here.
    var onOffset: (String, String, Double?) -> Void = { _, _, _ in }
    /// A fit of the song from another app has started or ended, for tests.
    private(set) var fitsRunning = 0
    /// The lyrics timing model and the model that separates the vocals are on the Mac. A test fits without them.
    var canFit: () -> Bool = { AlignerModel.installed && StemModel.installed }
    /// Fits the lyrics onto the parts of the song heard. A test counts the fits, or gives their result.
    var fitLive: @Sendable (LiveFit.Request) throws -> LiveFit.Found? = { request in
        try AlignerModel.use { reader in
            try LiveFit.fit(request.lines, expected: request.expected, heard: request.heard, reach: request.reach, stretches: request.stretches,
                            duration: request.duration, reader: reader)
        }
    }

    /// The vocals of the song from another app, kept for the fit.
    private var live: LiveVocals?
    /// What the fit is of: the lyrics, the player that the song comes from, the length of the song, and whether the
    /// lyrics come with times and are only checked.
    private var fitting: (lyrics: Lyrics, player: String, duration: Double?, checking: Bool)?
    /// What earlier plays found, and what this one adds to it.
    private var kept: LyricsStore.Fit?
    /// Seconds of vocals that the last fit had, and the fits made in this play.
    private var fittedAt = 0.0
    private var fits = 0
    /// The last position of the song that was marked, and the tap's audio at that moment.
    private var lastMark: (audio: Double, song: Double)?

    /// Lyrics with times are checked after this many seconds of vocals, once this many of their lines were sung.
    static let checkAfter = (seconds: 30.0, lines: 8)
    /// A check that can't tell is made again when this many more seconds and lines were heard, up to this many checks in all.
    static let checkAgain = (seconds: 25.0, lines: 6, times: 4)
    /// Lyrics without times are fitted at the end of a play that heard at least this many seconds of the song that
    /// no earlier play had fitted. A shorter part has few lines, and the model isn't loaded for them.
    static let fitAfter = 45.0
    /// The vocals come a few seconds behind the song, and a line takes a few seconds to sing.
    static let behind = 8.0

    /// Checks lyrics with times against the vocals of a song that another app plays: after the first lines, a fit
    /// says whether the lyrics are off as a whole, and `onOffset` gets the offset. The answer is kept for the song
    /// and the player, so a song is checked in one play only. Nothing is heard once the answer is known. The lines
    /// stay where they are: moving them by the offset is up to whoever reads it.
    func check(song: String, lyrics: Lyrics, player: String, duration: Double? = nil) {
        guard song != self.song else { return }
        end()
        guard canFit() else { return }
        self.song = song
        fitting = (lyrics, player, duration, true)
        if collect() { log("lyrics: hearing the vocals to check their times") }
    }

    /// Hears the vocals of the song for the fit alone, without a listener for its words.
    private func collect() -> Bool {
        started += 1
        let tap = makeTap()
        do {
            try tap.prepare()
            startCollecting(tapRate: tap.sampleRate)
            let vocals = vocals
            self.tap = tap
            tapped.withLock { $0 = 0 }
            let tapRate = tap.sampleRate
            let hearing = hearing
            try tap.start { [tapped] samples in
                guard hearing.withLock({ $0 }) else { return }
                tapped.withLock { $0 += Double(samples.count) / tapRate }
                vocals?.push(samples)
            }
            return true
        } catch {
            log("lyrics: hearing the vocals failed: \(error)")
            tap.stop()
            stopCollecting()
            return false
        }
    }

    /// Keeps the vocals for the fit, from the separation that `deliver` also gets the vocals of.
    private func startCollecting(tapRate: Double, deliver: @escaping ([Float]) -> Void = { _ in }) {
        let live = LiveVocals(rate: StemModel.sampleRate)
        let vocals = makeVocals(tapRate) {
            live.add($0)
            deliver($0)
        }
        // Without the vocals alone, the fit finds half as many lines, so the song as a whole isn't fitted.
        vocals.onFallback = { live.close() }
        self.live = live
        self.vocals = vocals
        fittedAt = 0
        fits = 0
        lastMark = nil
    }

    /// Stops hearing the song for the fit. A listener that hears the words goes on.
    private func stopCollecting() {
        live = nil
        guard listener == nil else { return }
        tap?.stop()
        tap = nil
        vocals?.stop()
        vocals = nil
    }

    /// Checks lyrics with times when enough of the song has played since the last check. Lyrics without times are
    /// fitted once, when the play ends: the lines light up by the heard words, which come seconds before a fit of
    /// the same part of the song could, so a fit while the song plays wouldn't change what shows.
    private func considerFit(position: Double) {
        guard let live, let fitting, fitting.checking, fitsRunning == 0 else { return }
        let have = live.seconds
        // After the last line, no more lines come to check: one last fit of what was heard, or none when the last
        // fit already had it, and the song isn't heard any longer.
        if let end = fitting.lyrics.lines.last(where: { !$0.text.isEmpty })?.time, position > end + 2 * Self.behind {
            return have - fittedAt >= LiveFit.shortest ? fit(final: true) : stopCollecting()
        }
        let seconds = fits == 0 ? Self.checkAfter.seconds : Self.checkAgain.seconds
        let lines = Self.checkAfter.lines + Self.checkAgain.lines * fits
        guard have - fittedAt >= seconds else { return }
        let heard = live.heard
        let sung = fitting.lyrics.lines.count { line in
            !line.text.isEmpty && line.time <= position - Self.behind && heard.contains { $0.contains(line.time) }
        }
        guard sung >= lines else { return }
        fit(final: false)
    }

    /// Seconds of the song heard in this play that no earlier play had fitted.
    private func newlyHeard(_ live: LiveVocals) -> Double {
        live.heard.reduce(0.0) { sum, range in
            var length = range.upperBound - range.lowerBound
            for old in earlierCovered { length -= max(0, min(old.upperBound, range.upperBound) - max(old.lowerBound, range.lowerBound)) }
            return sum + max(0, length)
        }
    }

    /// The parts of the song that earlier plays fitted.
    private var earlierCovered: [ClosedRange<Double>] = []

    /// Fits the lyrics onto the parts of the song heard so far, off the main thread. The model is loaded for the fit
    /// and unloaded after it. A fit that ends after the song has changed still keeps what it found, for that song.
    private func fit(final: Bool) {
        guard let live, let fitting, let song else { return }
        // The tap hears the next song before the player reports it, so the audio after the last position is left out.
        let stretches = live.stretches(until: lastMark?.audio)
        guard stretches.contains(where: { $0.seconds >= LiveFit.shortest }) else { return }
        let lyrics = fitting.lyrics, player = fitting.player, checking = fitting.checking, duration = fitting.duration
        let texts = lyrics.lines.map(\.text)
        // Lines without times are expected where the heard words and the estimate have them. The lines of an earlier
        // fit are left out of that: a fit that slid by a chorus would hold the next one to the same mistake.
        let aligner = checking ? nil : aligner, heard = Self.merge(stored, current)
        fittedAt = live.seconds
        fits += 1
        let last = final || fits >= Self.checkAgain.times
        let number = started, kept = kept, fitLive = fitLive
        fitsRunning += 1
        let began = Date()
        Self.fitQueue.async { [weak self] in
            let words = aligner.map { $0.align(heard) }
            let expected = words.flatMap { words in aligner.map { $0.times(words).map { $0 + LyricsAligner.lead } } } ?? lyrics.lines.map(\.time)
            let request = LiveFit.Request(lines: texts, expected: expected, heard: words?.firstWords ?? [:], reach: checking ? .synced : .plain,
                                          stretches: stretches, duration: duration)
            let result = Result { try fitLive(request) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fitsRunning -= 1
                switch result {
                case let .failure(error): self.log("lyrics: the fit failed: \(error.localizedDescription)")
                case .success(nil): break
                case let .success(found?):
                    let took = String(format: "%.1f s", Date().timeIntervalSince(began))
                    let current = number == self.started
                    if checking {
                        self.checked(found, song: song, lyrics: lyrics, player: player, last: last, current: current, took: took)
                    } else {
                        self.timed(found, song: song, lyrics: lyrics, player: player, kept: kept, took: took)
                    }
                }
            }
        }
    }

    private static let fitQueue = DispatchQueue(label: "muskey.lyrics.fit", qos: .utility)

    /// What a fit says about lyrics with times. `current` is false when the song has changed since the fit started.
    private func checked(_ found: LiveFit.Found, song: String, lyrics: Lyrics, player: String, last: Bool, current: Bool, took: String) {
        let key = LyricsFit.key(lyrics)
        let verdict = LiveFit.verdict(of: lyrics, found)
        let lines = "\(found.starts.count) of \(found.sung) lines"
        if verdict == .unsure {
            guard last else { return log("lyrics: the fit of \(lines) in \(took) can't tell yet whether their times hold") }
            // A song whose singing the model can't make out isn't heard again on every play, as long as enough of
            // its lines were sung to tell. A play that ended sooner leaves the check to the next one.
            guard found.sung >= Self.checkAfter.lines * 2 else {
                if current { stopCollecting() }
                return
            }
            log("lyrics: the offset of their times is unclear, by the fit of \(lines)")
        }
        let offset: Double? = switch verdict {
        case let .off(offset): offset
        case .holds: 0
        case .unsure: nil
        }
        store.setFit(LyricsStore.Fit(key: key, file: player, starts: nil, offset: offset, covered: nil), for: song)
        if let offset, offset != 0 {
            log(String(format: "lyrics: their times are off by %+.2f s, by the fit of %@ in %@", offset, lines, took))
        } else if offset != nil {
            log("lyrics: their times hold, by the fit of \(lines) in \(took)")
        }
        guard current else { return }
        stopCollecting()
        onOffset(song, key, offset)
    }

    /// What the fit at the end of a play found for lyrics without times: the lines found are kept for the song and
    /// the player together with the lines of earlier plays, and the next play starts with them.
    private func timed(_ found: LiveFit.Found, song: String, lyrics: Lyrics, player: String, kept: LyricsStore.Fit?, took: String) {
        let key = LyricsFit.key(lyrics)
        let usable = LyricsFit.Outcome(starts: found.starts, words: [], sung: found.sung).usable
        // The lines of this play take the place of the lines that earlier plays found in the same parts of the song,
        // and the rest stay as long as their times still go up with the lines. A fit that found too few lines adds
        // none, and its parts still count as fitted, so the same audio isn't fitted again on every play.
        let new = usable ? found.starts : [:]
        let replaced = usable ? found.covered : []
        let earlier = (kept?.starts ?? [:]).filter { line, start in new[line] == nil && !replaced.contains { $0.contains(start) } }
        let starts = LiveFit.inOrder(new.map { ($0.key, $0.value) } + earlier.map { ($0.key, $0.value) })
        let covered = LyricsCoverage.merge((kept?.coveredRanges ?? []) + found.fitted)
        let fit = LyricsStore.Fit(key: key, file: player, starts: starts, offset: nil,
                                  covered: covered.map { [($0.lowerBound * 10).rounded() / 10, ($0.upperBound * 10).rounded() / 10] })
        store.setFit(fit, for: song)
        log(usable ? "lyrics: \(found.starts.count) of the \(found.sung) lines sung timed by the fit in \(took), for the next play"
            : "lyrics: the fit found \(found.starts.count) of \(found.sung) lines in \(took), too few to time them by")
    }

    /// Starts timing the lyrics of `song`, which come with estimated times, and listens to the song unless the
    /// words heard in earlier plays already time most lines. `file` names the file that Muskey Player plays, whose
    /// lines are timed at once when an earlier play fitted these lyrics onto its vocals.
    ///
    /// `player` names the app that plays a song from another app. With the lyrics timing model on the Mac, the lines
    /// found by fitting the lyrics onto the vocals in earlier plays are timed at once, and the fit goes on with what
    /// this play adds.
    func begin(song: String, lyrics: Lyrics, file: String? = nil, player: String? = nil, duration: Double? = nil) {
        guard song != self.song else { return }
        end()
        self.song = song
        if file == nil, let player, canFit() {
            fitting = (lyrics, player, duration, false)
            kept = store.fit(for: song, key: LyricsFit.key(lyrics), file: player)
            earlierCovered = kept?.coveredRanges ?? []
        }
        let texts = lyrics.lines.map(\.text)
        let aligner = LyricsAligner(texts: texts, estimate: lyrics.lines.map(\.time), keepsSpacing: lyrics.otherVersion)
        self.aligner = aligner
        let lines = texts.filter { !$0.isEmpty }.count
        sungLines = lines
        if let source = file ?? fitting?.player, let starts = store.fit(for: song, key: LyricsFit.key(lyrics), file: source)?.starts, !starts.isEmpty {
            fittedStarts = starts
            log("lyrics: \(starts.count) lines timed by the fit of an earlier play")
        }
        stored = store.heard(for: song)
        realign(now: true)
        guard anchored < lines * 9 / 10 else { return log("lyrics: \(anchored) of \(lines) lines timed from an earlier play") }
        guard hearsWords() else {
            if fitting != nil, separates(), collect() { log("lyrics: hearing the vocals to time them by the fit") }
            return
        }
        text = texts.joined(separator: "\n")
        listen(to: text)
    }

    /// Listens to a song that has no lyrics, and writes them from what Whisper hears, a line for each phrase. The
    /// lines written in earlier plays stay, and the parts of the song that they cover aren't sent to Whisper again.
    /// Returns false when Settings has no Whisper.
    func transcribe(song: String, written lines: [Lyrics.Line] = [], covered: [ClosedRange<Double>] = [], duration: Double? = nil) -> Bool {
        guard song != self.song || !writing else { return true }
        guard whisper() != nil else { return false }
        end()
        self.song = song
        writing = true
        earlier = lines
        written = lines
        self.covered = LyricsCoverage.merge(covered)
        savedCoverage = self.covered.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        self.duration = duration
        leadAsked = false
        listen(to: nil)
        return true
    }

    /// Stops listening and keeps the words heard for the next play.
    func end() {
        // The part of the song that played since the last fit is fitted for the next play.
        if let live, let fitting, fitting.checking ? live.seconds - fittedAt >= Self.checkAgain.seconds : newlyHeard(live) >= Self.fitAfter {
            fit(final: true)
        }
        live = nil
        fitting = nil
        kept = nil
        earlierCovered = []
        fittedAt = 0
        fits = 0
        lastMark = nil
        tap?.stop()
        tap = nil
        if writing {
            extendCoverage()
            saveWritten(force: true)
            // Whisper finishes the phrases that it has yet to hear, and they are saved for this song.
            if let whisper = listener as? WhisperTranscriber, let song, whisperFailures < 3 {
                // The phrase being sung when the play ended is cut short, like at a seek, so the next play hears it
                // whole.
                if let segment, let last = marks.last, last.audio > segment.audio, last.song >= segment.song {
                    closed.append(Span(audio: segment.audio ... last.audio, song: segment.song ... last.song))
                    whisper.seek(at: last.audio)
                }
                let finisher = Finisher(song: song, store: store, whisper: whisper, vocals: vocals,
                                        feedRate: vocals == nil ? whisper.inputRate : tapRate, closed: closed,
                                        earlier: earlier, written: written, covered: covered, log: log)
                finishing.append(finisher)
                finisher.run { [weak self, weak finisher] in self?.finishing.removeAll { $0 === finisher } }
                listener = nil
                vocals = nil
            }
        }
        listener?.stop()
        listener = nil
        vocals?.stop()
        vocals = nil
        writing = false
        written = []
        earlier = []
        covered = []
        closed = []
        inCovered = nil
        savedCoverage = 0
        duration = nil
        skipping.withLock { $0 = false }
        text = nil
        fittedStarts = [:]
        whisperFailures = 0
        started += 1
        closeSegment()
        if let song, !stored.isEmpty { store.setHeard(stored, for: song) }
        heardSaved = .distantPast
        song = nil
        aligner = nil
        // An alignment still being worked out belongs to this song, and is dropped.
        appliedAlignment = alignments.withLock { $0 }
        alignment = LyricsAligner.Alignment()
        stored = []
        marks = []
        anchored = 0
        if downloading {
            downloading = false
            onChange()
        }
    }

    /// The start of each line, with the song at `position`.
    func times(at position: Double) -> [Double]? {
        guard let aligner else { return nil }
        let heard = segment.map { $0.song ... max($0.song, position) }
        return aligner.times(alignment, listening: listener == nil ? nil : heard)
    }

    /// Notes where the song is in the listener's audio, a few times a second. A position that jumps is a seek, which
    /// starts a new stretch of heard audio.
    func mark(position: Double?) {
        guard listener != nil || live != nil, let position else { return }
        let audio = tapped.withLock { $0 }
        guard audio > 0 else { return }
        if let last = marks.last {
            let drift = (position - last.song) - (audio - last.audio)
            if abs(drift) > 1.5 {
                // A pause leaves the song where it was while the audio goes on, and the singing ends there anyway.
                let paused = abs(position - last.song) < 1.5
                if writing, let segment, last.audio > segment.audio, last.song >= segment.song {
                    closed.append(Span(audio: segment.audio ... last.audio, song: segment.song ... last.song))
                    if !paused { (listener as? WhisperTranscriber)?.seek(at: last.audio) }
                }
                extendCoverage()
                closeSegment()
                log(String(format: paused ? "lyrics: resumed at %.1fs" : "lyrics: seek to %.1fs", position))
            }
        }
        if segment == nil { segment = (audio, position) }
        marks.append((audio, position))
        // While the song isn't heard, the tap's audio stands still. Marks of the same audio at later positions would
        // hide the jump of the position against the audio, which is what starts a new part once the song is heard again.
        if let live, audio > lastMark?.audio ?? 0 {
            lastMark = (audio, position)
            live.mark(audio: audio, song: position)
            considerFit(position: position)
        }
        if marks.count > 4000 { marks.removeFirst(2000) }
        guard writing else { return }
        extendCoverage()
        let known = LyricsCoverage.contains(covered, position, duration: duration)
        skipping.withLock { $0 = known }
        if known != inCovered {
            inCovered = known
            if known, let range = covered.first(where: { $0.contains(position) }) {
                log(String(format: "lyrics: %.0fs to %.0fs were transcribed before, Whisper skips them", range.lowerBound, range.upperBound))
            } else if !known {
                log(String(format: "lyrics: Whisper writes from %.0fs", position))
            }
        }
        // The song plays behind only for a part long enough to wait for, and with enough of the song left for the
        // wait to end before it does.
        if !known, !leadAsked {
            let next = covered.first { $0.lowerBound > position }?.lowerBound ?? duration ?? .infinity
            let left = (duration ?? .infinity) - position
            if next - position >= 8, left >= 45 {
                leadAsked = true
                log(String(format: "lyrics: the song plays behind from %.0fs, for Whisper", position))
                onNeedsLead()
            }
        }
    }

    /// Adds the audio that Whisper is done with to the parts of the song it has transcribed, and saves them every
    /// few seconds of new coverage.
    private func extendCoverage() {
        guard writing, let whisper = listener as? WhisperTranscriber else { return }
        let done = whisper.handled
        var added = Self.coverage(of: closed, done: done, cutShort: whisper.cutShortStarts)
        if let segment, done > segment.audio, let mark = marks.last(where: { $0.audio <= done }) {
            let end = mark.song + (done - mark.audio)
            if end > segment.song + 1 { added.append(segment.song ... end) }
        }
        guard !added.isEmpty else { return }
        covered = LyricsCoverage.merge(covered + added)
        saveWritten(force: false)
    }

    /// Saves the lines written so far and the parts of the song transcribed, after each phrase and every 5 seconds
    /// of new coverage, so a play that ends early keeps all of it.
    private func saveWritten(force: Bool) {
        guard writing, let song else { return }
        let total = covered.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        guard force || total >= savedCoverage + 5 else { return }
        savedCoverage = total
        let lines = written.filter { !$0.text.isEmpty }
        store.setWritten(lines.isEmpty ? nil : Lyrics(lines: written, timing: .written).lrc, covered: covered, for: song)
    }

    /// Lines written by ear so far, in seconds of the song, and the ones from earlier plays.
    private var written: [Lyrics.Line] = []
    private var earlier: [Lyrics.Line] = []
    /// The lyrics being timed, for listening again with Apple's speech model when Whisper fails.
    private var text: String?
    private var whisperFailures = 0

    /// Stops the tap and the listener, and keeps everything heard so far.
    private func stopListening() {
        started += 1
        live = nil
        listener?.stop()
        listener = nil
        tap?.stop()
        tap = nil
        vocals?.stop()
        vocals = nil
    }

    /// Three failures in a row: lyrics being written stop with a failure, and lyrics being timed are heard by Apple's
    /// speech model instead, for this song.
    private func whisperFailed(_ error: Error) {
        log("lyrics: Whisper failed: \(error)")
        whisperFailures += 1
        guard whisperFailures == 3 else { return }
        if writing {
            log("lyrics: stopped writing them, Whisper keeps failing")
            // Keeps what was written, and lets Retry start over.
            end()
            onWritingFailed()
        } else if let text {
            stopListening()
            log("lyrics: listening with Apple speech, Whisper keeps failing")
            listen(to: text, apple: true)
        }
    }

    /// Lyrics are timed by Apple's speech model, which needs them to know their language, and which times each word
    /// better than Whisper's phrases. Whisper, when Settings has it, writes lyrics, and times the ones in languages
    /// that only Apple's older dictation model knows. With the stems model on the Mac, the listener hears the vocals.
    private func listen(to text: String?, apple: Bool = false) {
        started += 1
        let attempt = started
        Task { @MainActor [self] in
            var locale: Locale?
            if let text { locale = await LyricsListener.locale(for: text) }
            let transcribed = if let locale { await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil } else { false }
            let backend = apple || (transcribed && !writing) ? nil : whisper()
            guard attempt == started else { return }
            guard backend != nil || locale != nil else {
                log("lyrics: no speech model for their language")
                // The lyrics timing model needs no language, so the fit still times the lines for the next play.
                if fitting != nil, separates(), collect() { log("lyrics: hearing the vocals to time them by the fit") }
                return
            }
            let tap = makeTap()
            do {
                try tap.prepare()
                let separate = separates()
                let rate = separate ? StemModel.sampleRate : tap.sampleRate
                let listener: LyricsHearing
                if let backend {
                    let whisper = WhisperTranscriber(backend: backend, inputRate: rate, vocals: separate)
                    whisper.language = text.flatMap(Self.language)
                    whisper.onPhrases = { [weak self] phrases in
                        guard let self, attempt == started else { return }
                        whisperFailures = 0
                        if writing { write(phrases) }
                    }
                    whisper.onError = { [weak self] error in
                        guard let self, attempt == started else { return }
                        whisperFailed(error)
                    }
                    listener = whisper
                } else {
                    listener = LyricsListener(locale: locale!, inputRate: rate)
                }
                listener.onWords = { [weak self] words in
                    guard let self, attempt == started, !writing else { return }
                    heard(words)
                }
                listener.onDownload = { [weak self] in
                    guard let self, attempt == started else { return }
                    downloading = true
                    log("lyrics: downloading the speech model for \(locale?.identifier ?? "")")
                    onChange()
                }
                live = nil
                if separate, fitting != nil, !writing {
                    // The vocals that the listener hears are also kept for the fit.
                    startCollecting(tapRate: tap.sampleRate) { listener.feed($0) }
                } else {
                    vocals = separate ? makeVocals(tap.sampleRate) { listener.feed($0) } : nil
                }
                let vocals = vocals
                self.tap = tap
                self.listener = listener
                tapped.withLock { $0 = 0 }
                let tapRate = tap.sampleRate
                self.tapRate = tapRate
                let skipping = skipping
                let hearing = hearing
                try tap.start { [tapped] samples in
                    // The heard audio stops with the song still going, which the marks take as a seek.
                    guard hearing.withLock({ $0 }) else { return }
                    tapped.withLock { $0 += Double(samples.count) / tapRate }
                    // Silence over the parts that Whisper has transcribed, which keeps the timing of what follows.
                    let heard = skipping.withLock { $0 } ? [Float](repeating: 0, count: samples.count) : samples
                    if let vocals { vocals.push(heard) } else { listener.feed(heard) }
                }
                try await listener.start()
                // Lyrics hidden while the model got ready.
                guard attempt == started else { return listener.stop() }
                log("lyrics: listening with \(backend == nil ? locale!.identifier : "Whisper")\(separate ? " to the vocals" : "")")
            } catch {
                guard attempt == started else { return }
                log("lyrics: listening failed: \(error)")
                tap.stop()
                listener?.stop()
                vocals?.stop()
                self.tap = nil
                self.listener = nil
                self.vocals = nil
                live = nil
            }
            if downloading {
                downloading = false
                onChange()
            }
        }
    }

    /// The two-letter language of the lyrics, for Whisper.
    private static func language(_ text: String) -> String? {
        LyricsListener.language(of: text)
    }

    private func write(_ phrases: [[LyricsAligner.Heard]]) {
        written = Self.compose(phrases, earlier: earlier) { Self.place($0, in: closed) + song($0) }
        extendCoverage()
        saveWritten(force: true)
        onWritten(Lyrics(lines: written, timing: .written))
    }

    /// The lines that Whisper heard, at the time they were sung, with a break before a phrase that comes after a long
    /// pause. Whisper starts each sung line with a capital, so a phrase of several lines is split there. `place`
    /// moves the words into seconds of the song.
    fileprivate static func compose(_ phrases: [[LyricsAligner.Heard]], earlier: [Lyrics.Line],
                                    place: ([LyricsAligner.Heard]) -> [LyricsAligner.Heard]) -> [Lyrics.Line]
    {
        // Each phrase as lines, in seconds of the song. A phrase heard again after a seek back takes the place of
        // the one heard before it.
        var blocks: [(span: ClosedRange<Double>, lines: [Lyrics.Line])] = []
        for phrase in phrases {
            let words = place(phrase).filter { !$0.text.isEmpty }
            guard let first = words.first?.start, let end = words.last?.end, end >= first else { continue }
            var lines: [Lyrics.Line] = []
            var line: [LyricsAligner.Heard] = []
            for word in words {
                if line.count >= 3, startsLine(word.text) {
                    lines.append(Lyrics.Line(time: line[0].start, text: line.map(\.text).joined(separator: " ")))
                    line = []
                }
                line.append(word)
            }
            if !line.isEmpty { lines.append(Lyrics.Line(time: line[0].start, text: line.map(\.text).joined(separator: " "))) }
            let span = first ... end
            blocks.removeAll { block in
                let overlap = min(block.span.upperBound, span.upperBound) - max(block.span.lowerBound, span.lowerBound)
                return overlap > 0.5 * min(block.span.upperBound - block.span.lowerBound, end - first)
            }
            blocks.append((span, lines))
        }
        blocks.sort { $0.span.lowerBound < $1.span.lowerBound }
        var lines: [Lyrics.Line] = []
        var last: Double?
        for block in blocks {
            if let last, block.span.lowerBound - last > 6 { lines.append(Lyrics.Line(time: last + 1, text: "")) }
            lines += block.lines
            last = block.span.upperBound
        }
        // The lines of earlier plays stay, apart from the ones heard again now. Lines next to a phrase stay, since
        // the parts of the song around it may have been skipped as already transcribed.
        let kept = earlier.filter { line in !blocks.contains { line.time >= $0.span.lowerBound - 0.3 && line.time <= $0.span.upperBound } }
        return (kept + lines).sorted { $0.time < $1.time }
    }

    /// Words of the listener's audio in seconds of the song, from the stretches before a seek.
    fileprivate static func place(_ words: [LyricsAligner.Heard], in spans: [Span]) -> [LyricsAligner.Heard] {
        words.compactMap { word -> LyricsAligner.Heard? in
            guard let span = spans.last(where: { $0.audio.contains(word.start) }) else { return nil }
            let shift = span.song(at: word.start) - word.start
            return LyricsAligner.Heard(start: word.start + shift, end: word.end + shift, text: word.text)
        }
    }

    /// The parts of the stretches before a seek that Whisper is done with, without a phrase that a seek cut short.
    fileprivate static func coverage(of spans: [Span], done: Double, cutShort: [Double]) -> [ClosedRange<Double>] {
        spans.compactMap { span -> ClosedRange<Double>? in
            let cut = cutShort.filter { span.audio.contains($0) }.min() ?? span.audio.upperBound
            let end = min(done, cut)
            guard end > span.audio.lowerBound + 1 else { return nil }
            return span.song.lowerBound ... span.song(at: end)
        }
    }

    /// A capital that isn't the word I.
    fileprivate static func startsLine(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return !["i", "i'm", "i'll", "i've", "i'd", "i’m", "i’ll", "i’ve", "i’d"].contains(bare)
    }

    /// Every word that the listener heard so far, in seconds of its audio.
    private func heard(_ words: [LyricsAligner.Heard]) {
        current = song(words)
        realign()
        // Kept every 10 seconds, so a play that ends early still times the next one.
        if let song, Date().timeIntervalSince(heardSaved) >= 10 {
            heardSaved = Date()
            store.setHeard(Self.merge(stored, current), for: song)
        }
    }

    /// Words heard since the last seek, moved from seconds of the audio into seconds of the song.
    private func song(_ words: [LyricsAligner.Heard]) -> [LyricsAligner.Heard] {
        guard let segment, !marks.isEmpty else { return [] }
        let first = marks.firstIndex { $0.audio >= segment.audio } ?? marks.count - 1
        return words.filter { $0.start >= segment.audio }.map { word in
            // The last mark before the word, or the first one after the seek.
            var index = first
            while index + 1 < marks.count, marks[index + 1].audio <= word.start { index += 1 }
            let shift = marks[index].song - marks[index].audio
            return LyricsAligner.Heard(start: word.start + shift, end: word.end + shift, text: word.text)
        }
    }

    /// Matching the heard words to the lyrics fills a table as large as both, and a guess of the listener comes about
    /// once a second, so it is worked out off the main thread.
    private static let aligning = DispatchQueue(label: "muskey.lyrics.align", qos: .userInitiated)
    /// Counts the alignments asked for. One with a newer one queued behind it is skipped.
    private let alignments = OSAllocatedUnfairLock(initialState: 0)
    /// The number of the last alignment applied, or of the last one asked for before `end()`. Older ones are dropped.
    private var appliedAlignment = 0

    /// Matches the heard words to the lyrics again. `now` does it before returning, for the start of a song, which
    /// needs to know how many lines the earlier plays timed.
    private func realign(now: Bool = false) {
        guard let aligner else { return }
        let heard = Self.merge(stored, current)
        let number = alignments.withLock {
            $0 += 1
            return $0
        }
        let fitted = fittedStarts
        if now { return apply(aligner.alignment(aligner.align(heard), fitted: fitted), number: number) }
        let alignments = alignments
        Self.aligning.async { [weak self] in
            guard alignments.withLock({ $0 }) == number else { return }
            let alignment = aligner.alignment(aligner.align(heard), fitted: fitted)
            DispatchQueue.main.async { self?.apply(alignment, number: number) }
        }
    }

    private func apply(_ alignment: LyricsAligner.Alignment, number: Int) {
        guard number > appliedAlignment else { return }
        appliedAlignment = number
        self.alignment = alignment
        if (anchored == 0) != (alignment.anchored == 0) {
            anchored = alignment.anchored
            onChange()
        }
        anchored = alignment.anchored
    }

    private func closeSegment() {
        stored = Self.merge(stored, current)
        current = []
        segment = nil
        marks = []
    }

    /// Words heard now replace the words heard before over the same part of the song.
    private static func merge(_ old: [LyricsAligner.Heard], _ new: [LyricsAligner.Heard]) -> [LyricsAligner.Heard] {
        guard let first = new.first, let last = new.last else { return old }
        let kept = old.filter { $0.end < first.start - 0.5 || $0.start > last.end + 0.5 }
        return (kept + new).sorted { $0.start < $1.start }
    }
}

/// Whisper finishing the phrases of a song that stopped playing, or whose lyrics were hidden: the lines and the parts
/// of the song that it hears are saved for that song, so the next play doesn't send them again.
private final class Finisher {
    let song: String
    let store: LyricsStore
    let whisper: WhisperTranscriber
    let vocals: VocalsFeeding?
    let closed: [LyricsSync.Span]
    /// The sample rate of the audio that the vocals or Whisper are fed.
    let feedRate: Double
    let earlier: [Lyrics.Line]
    var written: [Lyrics.Line]
    var covered: [ClosedRange<Double>]
    var failed = false
    let log: (String) -> Void

    init(song: String, store: LyricsStore, whisper: WhisperTranscriber, vocals: VocalsFeeding?, feedRate: Double, closed: [LyricsSync.Span],
         earlier: [Lyrics.Line], written: [Lyrics.Line], covered: [ClosedRange<Double>], log: @escaping (String) -> Void)
    {
        self.song = song
        self.store = store
        self.whisper = whisper
        self.vocals = vocals
        self.feedRate = feedRate
        self.closed = closed
        self.earlier = earlier
        self.written = written
        self.covered = covered
        self.log = log
    }

    /// Ends the audio with silence, which ends the phrase being sung and pushes the last vocals out, waits up to 30
    /// seconds for Whisper to hear the rest, and saves.
    func run(done: @escaping () -> Void) {
        guard let end = closed.map(\.audio.upperBound).max() else {
            stop()
            return done()
        }
        whisper.onWords = { _ in }
        whisper.onPhrases = { [self] phrases in
            written = LyricsSync.compose(phrases, earlier: earlier) { LyricsSync.place($0, in: closed) }
            save()
        }
        whisper.onError = { [self] _ in failed = true }
        let silence = [Float](repeating: 0, count: Int(feedRate * 9))
        if let vocals { vocals.push(silence) } else { whisper.feed(silence) }
        Task { @MainActor [self] in
            let started = Date()
            while Date().timeIntervalSince(started) < 30, !failed, whisper.handled < end {
                try? await Task.sleep(for: .milliseconds(250))
            }
            save()
            stop()
            log(String(format: "lyrics: Whisper finished the last phrases in %.1fs", Date().timeIntervalSince(started)))
            done()
        }
    }

    private func save() {
        covered = LyricsCoverage.merge(covered + LyricsSync.coverage(of: closed, done: whisper.handled, cutShort: whisper.cutShortStarts))
        let lines = written.filter { !$0.text.isEmpty }
        store.setWritten(lines.isEmpty ? nil : Lyrics(lines: written, timing: .written).lrc, covered: covered, for: song)
    }

    private func stop() {
        whisper.stop()
        vocals?.stop()
    }
}
