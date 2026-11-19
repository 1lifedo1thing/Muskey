import Foundation
import NaturalLanguage
import Speech
import os

/// Lyrics added by hand and the words heard in each song, by the id that LyricsFinder gives the song, in
/// `~/Library/Application Support/Muskey/lyrics.json`. Main thread only.
final class LyricsStore {
    struct Entry: Codable {
        /// Lyrics added by hand, plain or LRC, which take the place of the ones from LRCLIB.
        var text: String?
        var heard: [LyricsAligner.Heard]?
        /// Lyrics that Whisper wrote by ear for a song that LRCLIB doesn't have, as LRC.
        var written: String?
        /// The stretches of the song that Whisper has transcribed, as start and end seconds, whether anyone sang in
        /// them or not. Those parts aren't sent to Whisper again.
        var covered: [[Double]]?
        var date: Date
    }

    private static let limit = 1000
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
        entries[id] = entry.text == nil && entry.heard == nil && entry.written == nil && entry.covered == nil ? nil : entry
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
        let loaded = file.load()
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
    private var listener: LyricsHearing?
    private var vocals: VocalsFeed?
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

    init(store: LyricsStore) {
        self.store = store
    }

    var listening: Bool { listener != nil }

    /// Starts timing the lyrics of `song`, which come with estimated times, and listens to the song unless the
    /// words heard in earlier plays already time most lines.
    func begin(song: String, lyrics: Lyrics) {
        guard song != self.song else { return }
        end()
        self.song = song
        let texts = lyrics.lines.map(\.text)
        let aligner = LyricsAligner(texts: texts, estimate: lyrics.lines.map(\.time), keepsSpacing: lyrics.otherVersion)
        self.aligner = aligner
        stored = store.heard(for: song)
        realign(now: true)
        let lines = texts.filter { !$0.isEmpty }.count
        guard anchored < lines * 9 / 10 else { return log("lyrics: \(anchored) of \(lines) lines timed from an earlier play") }
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
        whisperFailures = 0
        started += 1
        closeSegment()
        if let song, !stored.isEmpty { store.setHeard(stored, for: song) }
        heardSaved = .distantPast
        song = nil
        aligner = nil
        // An alignment still being worked out belongs to this song, and is dropped.
        alignments.withLock { $0 += 1 }
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
        guard listener != nil, let position else { return }
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
            guard backend != nil || locale != nil else { return log("lyrics: no speech model for their language") }
            guard attempt == started else { return }
            let tap = makeTap()
            do {
                try tap.prepare()
                let separate = StemModel.installed
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
                let vocals = separate ? VocalsFeed(inputRate: tap.sampleRate) { listener.feed($0) } : nil
                self.tap = tap
                self.listener = listener
                self.vocals = vocals
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
            }
            if downloading {
                downloading = false
                onChange()
            }
        }
    }

    /// The two-letter language of the lyrics, for Whisper.
    private static func language(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
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
    /// Counts the alignments asked for, so that only the latest one is worked out and applied.
    private let alignments = OSAllocatedUnfairLock(initialState: 0)

    /// Matches the heard words to the lyrics again. `now` does it before returning, for the start of a song, which
    /// needs to know how many lines the earlier plays timed.
    private func realign(now: Bool = false) {
        guard let aligner else { return }
        let heard = Self.merge(stored, current)
        let number = alignments.withLock {
            $0 += 1
            return $0
        }
        if now { return apply(aligner.align(heard)) }
        let alignments = alignments
        Self.aligning.async { [weak self] in
            guard alignments.withLock({ $0 }) == number else { return }
            let alignment = aligner.align(heard)
            DispatchQueue.main.async {
                guard let self, alignments.withLock({ $0 }) == number else { return }
                self.apply(alignment)
            }
        }
    }

    private func apply(_ alignment: LyricsAligner.Alignment) {
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
    let vocals: VocalsFeed?
    let closed: [LyricsSync.Span]
    /// The sample rate of the audio that the vocals or Whisper are fed.
    let feedRate: Double
    let earlier: [Lyrics.Line]
    var written: [Lyrics.Line]
    var covered: [ClosedRange<Double>]
    var failed = false
    let log: (String) -> Void

    init(song: String, store: LyricsStore, whisper: WhisperTranscriber, vocals: VocalsFeed?, feedRate: Double, closed: [LyricsSync.Span],
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
