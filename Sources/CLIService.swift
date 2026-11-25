import AVFoundation
import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "CLIService")

// The app's side of the `muskey` command line tool: a message port that only processes of the same user can reach,
// and the jobs that the tool waits for. Playing goes through the app delegate, which shows the song in the HUD.
// Writing a file runs here, away from the HUD: it reads the song, changes it or transcribes it, and writes the result
// into Muskey's cache, from where the tool moves it into place with the permissions of the shell that runs it.
// Nothing here records the sound of the Mac: a file is written only from a song file or a link.

/// A request of the tool that takes a while, which the tool asks about until it is done.
@MainActor final class CLIJob {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    var step: String?
    var progress: Double?
    var message: String?
    var output: String?
    var link: String?
    private(set) var done = false
    private(set) var error: String?
    private(set) var cancelled = false
    private(set) var finishedAt: Date?
    /// Stops the work that runs for the job.
    var onCancel: () -> Void = {}

    func finish(_ message: String? = nil) {
        guard !done else { return }
        self.message = message ?? self.message
        done = true
        finishedAt = Date()
    }

    func fail(_ error: String) {
        guard !done else { return }
        self.error = error
        done = true
        finishedAt = Date()
    }

    func cancel() {
        cancelled = true
        onCancel()
        fail("Stopped")
    }

    var response: CLIResponse {
        CLIResponse(error: error, message: message, job: id, step: step, progress: progress, done: done, output: output, link: link)
    }
}

@MainActor final class CLIService {
    static let shared = CLIService()

    /// Plays the inputs of a request in the HUD with its changes, or listens to the song that plays now.
    var play: (CLIRequest, CLIJob) -> Void = { _, job in job.fail("Muskey is still starting") }
    /// Serves a file at a private link, and gives the link.
    var serve: (String) -> String? = { _ in nil }
    /// The key that the HUD shows for a song (title, artist, album) without listening.
    var knownKey: ([String?]) -> DetectedKey? = { _ in nil }

    private var port: CFMessagePort?
    private var jobs: [String: CLIJob] = [:]
    private let writer = CLIWriter()

    /// Opens the message port on the main run loop. The requests are answered at once: the work of a job goes on
    /// after the answer, and the tool asks how it goes.
    func start() {
        guard port == nil else { return }
        writer.serve = { [weak self] in self?.serve($0) }
        writer.knownKey = { [weak self] in self?.knownKey($0) }
        CLIWriter.removeOldFiles()
        guard let port = CFMessagePortCreateLocal(nil, muskeyPortName, { _, _, data, _ in
            let request = (data as Data?).flatMap { try? JSONDecoder().decode(CLIRequest.self, from: $0) }
            let response = request.map { request in MainActor.assumeIsolated { CLIService.shared.answer(request) } }
                ?? CLIResponse(error: "Muskey couldn't read the request. Is the muskey tool from another version of Muskey?")
            let data = (try? JSONEncoder().encode(response)) ?? Data()
            return Unmanaged.passRetained(data as CFData)
        }, nil, nil) else {
            return log.error("cli: the message port couldn't be opened, another Muskey may have it")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
        self.port = port
        log.info("cli: listening")
    }

    /// A request from the web remote, answered as the tool's are.
    func handle(_ request: CLIRequest) -> CLIResponse { answer(request) }

    /// The file that a write job made, which stays in its folder of the cache for a week, after the job is forgotten.
    func output(of id: String) -> String? {
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        if let job = jobs[id] { return job.done && job.error == nil ? job.output : nil }
        let folder = CLIWriter.folder.appending(path: id)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { !$0.hasPrefix(".") }.map { folder.appending(path: $0).path }
    }

    private func answer(_ request: CLIRequest) -> CLIResponse {
        // A job that ended a while ago has been read by its tool.
        jobs = jobs.filter { $0.value.finishedAt.map { Date().timeIntervalSince($0) < 600 } ?? true }
        switch request.command {
        case .version:
            return CLIResponse(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        case .job:
            guard let id = request.job, let job = jobs[id] else { return CLIResponse(error: "Muskey has no such job", done: true) }
            return job.response
        case .cancel:
            if let id = request.job, let job = jobs[id] {
                job.cancel()
                log.info("cli: job \(id, privacy: .public) stopped")
            }
            return CLIResponse(done: true)
        case .play:
            let job = CLIJob()
            jobs[job.id] = job
            log.info("cli: play \(self.describe(request), privacy: .public)")
            play(request, job)
            return job.response
        case .write:
            let job = CLIJob()
            jobs[job.id] = job
            log.info("cli: write \(request.format?.rawValue ?? "?", privacy: .public) from \(self.describe(request), privacy: .public)")
            writer.write(request, job: job)
            return job.response
        }
    }

    /// The request in the log, without the paths of the files.
    private func describe(_ request: CLIRequest) -> String {
        var parts = [request.inputs.isEmpty ? "the song that plays" : "\(request.inputs.count) input\(request.inputs.count == 1 ? "" : "s")"]
        if let key = request.key { parts.append("key \(key)") }
        if let stems = request.stems { parts.append("stems \(stems.joined(separator: ","))") }
        if let mute = request.mute { parts.append("mute \(mute.joined(separator: ","))") }
        if let speed = request.speed { parts.append(String(format: "speed %.2f", speed)) }
        if request.from != nil || request.to != nil { parts.append("a part") }
        if let notes = request.notes { parts.append("notes \(notes)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Keys

extension DetectedKey {
    /// A key as the tool takes it: `Am`, `F#`, `Bbm`, `A minor`, `Amin`, `Ebmaj`.
    init?(cli text: String) {
        var name = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard let first = name.first else { return nil }
        name = first.uppercased() + name.dropFirst()
        for (suffix, short) in [("minor", "m"), ("min", "m"), ("major", ""), ("maj", "")] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)) + short
            break
        }
        self.init(name: name)
    }

    /// The semitones that move this key to `text`, a key or a number of semitones, and whether the key is named in the
    /// other mode then. Nil for text that is neither.
    func cliShift(to text: String) -> (semitones: Int, relative: Bool?)? {
        if let semitones = Int(text.trimmingCharacters(in: .whitespaces)) { return (semitones, nil) }
        guard let target = DetectedKey(cli: text) else { return nil }
        return (shift(to: target), target.minor != minor)
    }
}

// MARK: Writing files

/// Writes a song with its changes, or its notes, for the tool. One job runs at a time, with a stems separation of
/// its own, so a job never takes over the separation of the song in the HUD.
@MainActor final class CLIWriter {
    var serve: (String) -> String? = { _ in nil }
    /// The key that the HUD shows for a song (title, artist, album) without listening: a remembered one or Noiseblend's.
    var knownKey: ([String?]) -> DetectedKey? = { _ in nil }
    private var last: Task<Void, Never>?
    private let builder = StemsCacheBuilder()
    private let links = LinkCache()

    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/CLI")

    /// Files of jobs from more than a week ago, which the tool moved away or which a link served long enough.
    static func removeOldFiles() {
        let fm = FileManager.default
        guard let jobs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for job in jobs {
            let date = (try? job.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 7 * 24 * 3600 { try? fm.removeItem(at: job) }
        }
    }

    func write(_ request: CLIRequest, job: CLIJob) {
        let previous = last
        if previous != nil { job.step = "Waiting for the job before it" }
        last = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !job.cancelled else { return }
            do {
                try await run(request, job)
            } catch is CancellationError {
                job.fail("Stopped")
            } catch {
                job.fail(error.localizedDescription)
            }
            if let error = job.response.error { log.error("cli: job \(job.id, privacy: .public) failed: \(error, privacy: .public)") }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func run(_ request: CLIRequest, _ job: CLIJob) async throws {
        guard let format = request.format, let input = request.inputs.first, let url = FilePlayer.url(from: input) else {
            throw Failure("no song file or link to write")
        }
        var song = url.isFileURL ? FilePlayer.Song(path: url.path) : try await download(url, job)
        let file = URL(fileURLWithPath: song.path)
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw Failure("Muskey can't read \(file.lastPathComponent)") }
        try Task.checkCancellation()
        let tags = await Self.tags(of: file, song: song)
        song.title = tags.title
        let folder = Self.folder.appending(path: job.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (tags.title ?? file.deletingPathExtension().lastPathComponent).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if let from = request.from, let to = request.to, to <= from { throw Failure("the part ends before it starts") }
        if (request.from ?? 0) < 0 || (request.to ?? 1) <= 0 { throw Failure("the part starts before the song") }
        let range = request.from.map { $0 ... (request.to ?? .infinity) } ?? request.to.map { 0 ... $0 }
        let known = knownKey([tags.title, tags.artist, tags.album])

        let out: URL
        if format.isAudio {
            out = folder.appending(path: "\(name).\(format.rawValue)")
            try await writeSong(file, request: request, range: range, tags: tags, key: known, to: out, format: format, job: job)
        } else {
            out = try await writeNotes(file, request: request, range: range, title: name, artist: tags.artist, key: known, folder: folder, format: format,
                                       job: job)
        }
        job.output = out.path
        if request.link {
            guard let link = serve(out.path) else { throw Failure("the link couldn't be made: the web server didn't start") }
            job.link = link
        }
        job.step = nil
        job.progress = nil
        log.info("cli: job \(job.id, privacy: .public) wrote a \(format.rawValue, privacy: .public) file")
        job.finish("Wrote \(out.lastPathComponent)")
    }

    // MARK: Links

    /// A link's song from the cache, or downloaded into it as when it plays.
    private func download(_ url: URL, _ job: CLIJob) async throws -> FilePlayer.Song {
        if let song = links.song(for: url) { return song }
        let direct = LinkDownload.directExtensions.contains(url.pathExtension.lowercased())
        guard direct || Downloader.find() != nil else { throw Failure("a link to a page needs yt-dlp. Install it from the HUD with Open URL") }
        job.step = "Downloading"
        let download = LinkDownload(url: url, folder: links.folder, direct: direct)
        download.onProgress = { step, _, progress in
            job.step = step == .converting ? "Converting" : "Downloading"
            job.progress = progress
        }
        job.onCancel = { download.cancel() }
        let song: FilePlayer.Song? = await withCheckedContinuation { continuation in
            download.start { continuation.resume(returning: $0) }
        }
        job.onCancel = {}
        try Task.checkCancellation()
        guard var song else { throw Failure("the link couldn't be downloaded") }
        song.name = SongName.link(url)
        links.keep(song, for: url)
        job.progress = nil
        return song
    }

    /// The title, artist, album and cover of a song file, or of the page that a link's song came from.
    private static func tags(of file: URL, song: FilePlayer.Song) async -> SongTags {
        var tags = SongTags(title: song.title, artist: song.artist, album: song.album)
        let asset = AVURLAsset(url: file)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                switch item.commonKey {
                case .commonKeyTitle: if tags.title == nil { tags.title = try? await item.load(.stringValue) }
                case .commonKeyArtist: if tags.artist == nil { tags.artist = try? await item.load(.stringValue) }
                case .commonKeyAlbumName: if tags.album == nil { tags.album = try? await item.load(.stringValue) }
                case .commonKeyArtwork:
                    if tags.cover == nil, let data = try? await item.load(.dataValue) { tags.cover = SongTags.jpeg(NSImage(data: data)) }
                default: break
                }
            }
        }
        if tags.title?.isEmpty != false { tags.title = song.name ?? file.deletingPathExtension().lastPathComponent }
        return tags
    }

    // MARK: Songs

    private func writeSong(_ file: URL, request: CLIRequest, range: ClosedRange<Double>?, tags: SongTags, key songKey: DetectedKey?, to out: URL,
                           format: CLIFormat, job: CLIJob) async throws {
        job.step = "Reading"
        let audio = try await Task.detached(priority: .userInitiated) { try SongRender.read(file) }.value
        try Task.checkCancellation()
        if let range, range.lowerBound >= audio.seconds - 0.25 { throw Failure("the part starts after the end of the song") }
        var changes = SongChanges(speed: request.speed ?? 1, range: range.map { max(0, $0.lowerBound) ... min(audio.seconds, $0.upperBound) })
        if let key = request.key {
            changes.semitones = try await semitones(for: key, file: file, duration: audio.seconds, job: job, songKey: songKey).semitones
        }
        if let playing = request.stems ?? request.mute.map({ muted in muskeyStemNames.filter { !muted.contains($0) } }) {
            guard StemModel.installed else { throw Failure("the separation model is not installed. Install it in Settings > Instruments and vocals") }
            changes.stemGains = Stem.allCases.map { playing.contains($0.name.lowercased()) ? 1 : 0 }
        }
        guard !changes.isEmpty || changes.range != nil else { throw Failure("nothing to change. Give --key, --stems, --mute, --speed or a part with --from and --to") }
        let separating = changes.stemGains != nil
        job.step = separating ? "Separating instruments" : "Changing the song"
        let state = RenderState()
        job.onCancel = { state.cancel() }
        let path = file.path
        let rendered = try await Task.detached(priority: .userInitiated) {
            try SongRender.render(audio, changes: changes, path: path) { part in
                Task { @MainActor in
                    // The stems take the first four fifths of a render that mixes them.
                    job.step = separating && part < 0.8 ? "Separating instruments" : "Changing the song"
                    job.progress = separating && part < 0.8 ? part / 0.8 : separating ? (part - 0.8) / 0.2 : part
                }
                return !state.cancelled
            }
        }.value
        job.onCancel = {}
        try Task.checkCancellation()
        job.step = "Writing"
        job.progress = nil
        let saveFormat = SaveFormat(rawValue: format.rawValue) ?? .m4a
        try await Task.detached(priority: .userInitiated) {
            try SongRender.write(rendered, as: saveFormat, to: out, tags: tags)
        }.value
    }

    private final class RenderState: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var cancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }

    /// The semitones for `--key`: a number as it is, a key from the key of the song, which is read from the file.
    private func semitones(for key: String, file: URL, duration: Double, job: CLIJob, songKey: DetectedKey? = nil) async throws
        -> (semitones: Int, relative: Bool?, key: DetectedKey?) {
        if let semitones = Int(key.trimmingCharacters(in: .whitespaces)) { return (semitones, nil, songKey) }
        var found = songKey
        if found == nil {
            job.step = "Finding the key"
            found = await QueueItem.analyse(file, duration: duration).key
        }
        guard let found else { throw Failure("the key of the song wasn't found. Give semitones instead, like +2") }
        guard let shift = found.cliShift(to: key) else { throw Failure("unknown key \"\(key)\"") }
        return (shift.semitones, shift.relative, found)
    }

    // MARK: Notes

    private func writeNotes(_ file: URL, request: CLIRequest, range: ClosedRange<Double>?, title: String, artist: String?, key songKey: DetectedKey?,
                            folder: URL, format: CLIFormat, job: CLIJob) async throws -> URL {
        let path = file.path
        job.step = "Finding the beats"
        let duration = await ChordDetector.duration(file)
        if let range, duration > 0, range.lowerBound >= duration - 0.25 { throw Failure("the part starts after the end of the song") }
        let grid = await Task.detached(priority: .utility) { await ChordDetector.analyse(file, duration: duration) }.value
        try Task.checkCancellation()

        var named: Stem?
        if let name = request.notes, name != "auto" {
            guard let stem = Stem.allCases.first(where: { $0.name.lowercased() == name }) else { throw Failure("unknown instrument \"\(name)\"") }
            named = stem
        }
        // Notes of the whole song that the notes window or an earlier job kept need no stems and no models, and a part
        // of the song is cut from them.
        var kept = named.flatMap { NotesStore.load(path: path, stem: $0) }

        var cache: StemsCache?
        if kept == nil {
            guard ModelDownload.dettato.installed, StemModel.installed else {
                throw Failure("the notes need the models of Transcribe notes. Install them with T over the HUD")
            }
            cache = StemsCache.open(for: path)
            if cache == nil {
                job.step = "Separating instruments"
                job.progress = 0
                builder.progress = { job.progress = $0 }
                job.onCancel = { [builder] in builder.cancel() }
                cache = await NotesPipeline.stems(for: path, builder: builder)
                job.onCancel = {}
                builder.progress = { _ in }
            }
            try Task.checkCancellation()
            guard cache != nil else { throw Failure("the instruments couldn't be separated") }
        }

        let stem: Stem
        if let named {
            stem = named
        } else if let cache {
            // The instrument that plays the most, as T's picker picks it first. Dettato doesn't hear drums.
            let activity = await Task.detached(priority: .userInitiated) { NotesPipeline.activity(cache, range: range) }.value
            guard let richest = activity.shares.filter({ $0.key != .drums }).max(by: { $0.value < $1.value })?.key else {
                throw Failure("no instrument plays in the song")
            }
            stem = richest
            log.info("cli: the \(stem.name.lowercased(), privacy: .public) plays the most")
            kept = NotesStore.load(path: path, stem: stem)
        } else {
            throw Failure("no instrument to transcribe")
        }

        var notes: [TranscribedNote]
        if let kept {
            notes = range.map { NotesPipeline.notes(kept.notes, in: $0) } ?? kept.notes
        } else {
            guard let cache else { throw Failure("the instruments couldn't be separated") }
            job.step = "Transcribing the \(stem.name.lowercased())"
            job.progress = 0
            let heard = range.map { max(0, $0.lowerBound - NotesPipeline.regionContext) ... min(duration > 0 ? duration : .infinity, $0.upperBound + NotesPipeline.regionContext) }
            let stop = StopFlag()
            job.onCancel = { stop.set() }
            let found = try await Task.detached(priority: .userInitiated) { () throws -> [TranscribedNote] in
                let audio = Dettato.resample(NotesPipeline.stemSamples(cache, stem: stem, range: heard), from: StemsCache.rate)
                return try Dettato.transcribe(audio, program: stem.program, progress: { fraction in
                    Task { @MainActor in job.progress = fraction }
                }, stop: { stop.isSet })
            }.value
            job.onCancel = {}
            try Task.checkCancellation()
            if let range, let heard {
                let shifted = found.map { TranscribedNote(start: $0.start + heard.lowerBound, end: $0.end + heard.lowerBound, pitch: $0.pitch, program: $0.program, drum: $0.drum) }
                notes = NotesPipeline.notes(shifted, in: range)
            } else {
                notes = found
            }
        }
        // The key that the HUD shows, or the one that the notes were kept with, or one read from the file now.
        var key = songKey ?? kept?.keyValue
        var bpm = grid?.bpm ?? kept?.bpm
        if key == nil || bpm == nil {
            job.step = "Finding the key"
            let analysis = await QueueItem.analyse(file, duration: duration)
            key = key ?? analysis.key
            bpm = bpm ?? analysis.bpm
        }
        let fixture = NotesFixture(title: title, stem: stem.name, key: key?.code, bpm: bpm ?? 120, duration: duration,
                                   beats: grid?.beats ?? kept?.beats ?? [], notes: notes)
        if range == nil, kept == nil { NotesStore.save(fixture, path: path, stem: stem) }

        // The notes moved to `--key`, with the key named in its mode, as the notes window shows them.
        var shift = 0, relative = false
        if let key = request.key {
            let moved = try await semitones(for: key, file: file, duration: duration, job: job, songKey: fixture.keyValue)
            shift = moved.semitones
            relative = moved.relative ?? false
        }
        job.step = "Writing"
        job.progress = nil
        let capo = request.capo ?? 0
        let view = request.view.flatMap(NotesView.init(rawValue:))
        let stemName = stem.name.lowercased()
        let base = folder.appending(path: "\(title) \(stem.name)")
        let score = Self.score(fixture, shift: shift, relative: relative, capo: capo)
        switch format {
        case .musicxml:
            let out = base.appendingPathExtension("musicxml")
            try score.musicXML(title: title).write(to: out, atomically: true, encoding: .utf8)
            return out
        case .mid:
            let out = base.appendingPathExtension("mid")
            try score.midi.write(to: out)
            return out
        case .txt:
            guard stem == .bass || stem == .guitar else { throw Failure("text tab is for guitar and bass; the \(stemName) can go to .pdf, .html, .musicxml or .mid") }
            let out = base.appendingPathExtension("txt")
            try score.textTab.write(to: out, atomically: true, encoding: .utf8)
            return out
        case .pdf:
            let out = base.appendingPathExtension("pdf")
            let shown = view.flatMap { $0 == .tab && !(stem == .bass || stem == .guitar) ? nil : $0 } ?? .preferred(for: stem)
            try NotesPDF.write(score.collapsingRests(), title: title, artist: artist, view: shown, to: out)
            return out
        case .html:
            let out = base.appendingPathExtension("html")
            let page = NotesSheet.html(fixture, artist: artist, view: view, shift: shift, relative: relative, capo: capo)
            guard !page.isEmpty else { throw Failure("the interactive sheet is missing from the app's resources") }
            try page.write(to: out, atomically: true, encoding: .utf8)
            return out
        case .json:
            // The notes as the web remote's sheet reads them, unmoved: the page moves them with the song.
            let out = base.appendingPathExtension("json")
            try JSONEncoder().encode(WebNotes(fixture: fixture, artist: artist)).write(to: out)
            return out
        case .m4a, .mp3, .wav:
            throw Failure("a song format can't hold notes")
        }
    }

    /// The score of a transcription moved by `shift`, named in the other mode with `relative`, as `NotesModel` builds it.
    static func score(_ fixture: NotesFixture, shift: Int, relative: Bool, capo: Int) -> Score {
        let moved = fixture.notes.map { TranscribedNote(start: $0.start, end: $0.end, pitch: $0.pitch + shift, program: $0.program, drum: $0.drum) }
        let key = fixture.keyValue.map { relative ? $0.transposed(by: shift).relative : $0.transposed(by: shift) }
        let stem = fixture.stemValue
        return Score(notes: moved, stem: stem, beats: fixture.beats, bpm: fixture.bpm, key: key, duration: fixture.duration,
                     capo: stem == .bass || stem == .guitar ? capo : 0)
    }
}
