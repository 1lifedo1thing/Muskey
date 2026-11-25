import CoreML
import CryptoKit
import Foundation

/// Downloads a model that Muskey doesn't come with into Application Support, checks it against its SHA-256, and
/// installs it: the stems, winds and transcription models, which are compiled for this Mac, and the Whisper model, which
/// is used as it is.
@MainActor
final class ModelDownload: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed
    }

    /// The stems model, as a zipped Core ML package of 328 MB.
    static let stems = ModelDownload(
        name: "stems model",
        url: URL(string: "https://files.lowtechguys.com/muskey/models/BSRoformerSW-388.mlpackage.zip")!,
        sha256: "1205d30d46e31e0a332ce926a9b058d293f7530f52974785ccb002d0c8e4eda2", size: 328_096_464,
        installed: { StemModel.isInstalled(.stems) }, remove: {
            StemModel.unload()
            try? FileManager.default.removeItem(at: StemModel.url(.stems))
        }, install: { zip in try ModelDownload.installPackage(.stems, from: zip) }
    )

    /// The woodwind and brass heads of the 53-stem model, which play together as the Winds stem, as a zipped Core ML
    /// package of 83 MB.
    static let winds = ModelDownload(
        name: "winds model",
        url: URL(string: "https://files.lowtechguys.com/muskey/models/BSRoformerWinds-388.mlpackage.zip")!,
        sha256: "eba3fc2088852e84a94512445a22ad2a985799010ef738439fa53bc75bdb0cc3", size: 82_776_494,
        installed: { StemModel.isInstalled(.winds) }, remove: {
            StemModel.unload()
            try? FileManager.default.removeItem(at: StemModel.url(.winds))
        }, install: { zip in try ModelDownload.installPackage(.winds, from: zip) }
    )

    /// Whisper large-v3-turbo for whisper.cpp, the way its authors publish it.
    static let whisper = ModelDownload(
        name: "Whisper model",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", size: 1_624_555_275,
        installed: { WhisperModel.installed }, remove: {
            WhisperModel.unload()
            try? FileManager.default.removeItem(at: WhisperModel.url)
        }, install: { file in try ModelDownload.place(file, at: WhisperModel.url) }
    )

    /// Dettato's transcriber, which turns a stem into notes, as four zipped Core ML packages and the weights of the GRUs
    /// that run between them, 33 MB in all. `make dettato-model` converts it from kobimusic/dettato at the commit in the
    /// file name.
    static let dettato = ModelDownload(
        name: "transcription model",
        url: URL(string: "https://files.lowtechguys.com/muskey/models/Dettato-9b72425.zip")!,
        sha256: "947abc9d1caf6932dcd7ed051745644d79497183ffd95ed6195b122f67276756", size: 33_437_377,
        installed: { Dettato.installed }, remove: {
            Dettato.unload()
            try? FileManager.default.removeItem(at: Dettato.folder)
        }, install: { zip in try ModelDownload.installDettato(from: zip) }
    )

    /// The model that reads sung words for timing lyrics, as a zipped Core ML package and the list of its characters.
    /// `make aligner-model` converts it from facebook/omniASR-CTC-300M.
    static let aligner = ModelDownload(
        name: "lyrics timing model",
        url: URL(string: "https://files.lowtechguys.com/muskey/models/Aligner-omniASR-CTC-300M.zip")!,
        sha256: "ac127fe80626bc4bb4cf8f0bcae3052845b5789d9665c7e53b22443851612ef4", size: 288_929_379,
        installed: { AlignerModel.installed }, remove: {
            AlignerModel.unload()
            try? FileManager.default.removeItem(at: AlignerModel.folder)
        }, install: { zip in try ModelDownload.installAligner(from: zip) }
    )

    @Published private(set) var state = State.idle
    @Published private(set) var installed: Bool

    let name: String
    let url: URL
    let size: Int
    private let sha256: String
    private let isInstalled: () -> Bool
    private let removal: () -> Void
    private let installation: @Sendable (URL) throws -> Void

    private var task: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    var log = EchoLog(category: "ModelDownload")

    private init(name: String, url: URL, sha256: String, size: Int, installed: @escaping () -> Bool, remove: @escaping () -> Void,
                 install: @escaping @Sendable (URL) throws -> Void)
    {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.size = size
        isInstalled = installed
        removal = remove
        installation = install
        self.installed = installed()
    }

    func refresh() { installed = isInstalled() }

    func start() {
        guard task == nil else { return }
        state = .downloading(0)
        // A download that was cancelled, or replaced by a newer one, ends without changing the state.
        var started: URLSessionDownloadTask?
        let task = URLSession.shared.downloadTask(with: url) { [weak self] file, response, error in
            // The file goes away when this returns, so it is moved before going back to the main thread.
            let kept: URL? = file.flatMap { file in
                let url = FileManager.default.temporaryDirectory.appending(path: "muskey-model-\(UUID().uuidString)")
                return (try? FileManager.default.moveItem(at: file, to: url)).map { url }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor [weak self] in
                guard let self, let started, self.task === started else {
                    if let kept { try? FileManager.default.removeItem(at: kept) }
                    return
                }
                self.task = nil
                self.progress = nil
                guard let kept, error == nil, status == 200 else {
                    if let kept { try? FileManager.default.removeItem(at: kept) }
                    return self.fail("download failed: \(error.map { "\($0)" } ?? "HTTP \(status)")")
                }
                self.install(kept)
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in
                if case .downloading = self?.state { self?.state = .downloading(fraction) }
            }
        }
        started = task
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        state = .idle
    }

    func remove() {
        removal()
        refresh()
    }

    private func fail(_ reason: String) {
        log("\(name) \(reason)", .error)
        state = .failed
    }

    /// `--stems-install PATH`, `--winds-install PATH`, `--dettato-install PATH` and `--aligner-install PATH` install the model from a copy of the file, the way a download
    /// does, and quit.
    func installForTesting(_ path: String) {
        let copy = FileManager.default.temporaryDirectory.appending(path: "muskey-model-test")
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        } catch {
            print("can't copy \(path): \(error)")
            exit(1)
        }
        log.echo = { print($0) }
        let started = Date()
        install(copy)
        Task { @MainActor in
            for _ in 0 ..< 1500 where state == .installing { try? await Task.sleep(for: .milliseconds(200)) }
            print(String(format: "%@ in %.1fs", installed ? "installed" : "not installed", Date().timeIntervalSince(started)))
            exit(installed ? 0 : 1)
        }
    }

    /// `--stems-download`, `--winds-download`, `--whisper-download` and `--dettato-download` run a download the way
    /// Settings does, print how it ended, and quit.
    func downloadForTesting() {
        log.echo = { print($0) }
        let started = Date()
        start()
        Task { @MainActor in
            for _ in 0 ..< 9000 where state != .idle && state != .failed { try? await Task.sleep(for: .milliseconds(200)) }
            print(String(format: "%@ in %.1fs", state == .failed ? "failed" : installed ? "installed" : "not installed", Date().timeIntervalSince(started)))
            exit(state == .failed ? 1 : 0)
        }
    }

    /// Checks the file and installs it, off the main thread.
    private func install(_ file: URL) {
        state = .installing
        let sha256 = sha256, installation = installation
        Task.detached(priority: .utility) {
            let result: Result<Void, Error> = Result {
                defer { try? FileManager.default.removeItem(at: file) }
                guard try Self.digest(of: file) == sha256 else { throw StemError.checksum }
                try installation(file)
            }
            await MainActor.run {
                switch result {
                case .success:
                    self.state = .idle
                    self.log("\(self.name) installed", .notice)
                case let .failure(error):
                    self.fail("install failed: \(error)")
                }
                self.refresh()
            }
        }
    }

    /// The SHA-256 of a file, read 8 MB at a time so a large model isn't read into memory whole.
    nonisolated static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        for _ in 0 ..< 100_000 {
            guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips a Core ML package, compiles it for this Mac and puts it where the model loads from.
    nonisolated static func installPackage(_ kind: StemModel.Kind, from zip: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-stems-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw StemError.unpack }
        let compiled = try MLModel.compileModel(at: folder.appending(path: "\(kind.file).mlpackage"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        try place(compiled, at: StemModel.url(kind))
    }

    /// Unzips Dettato, compiles its four packages for this Mac and puts them with the GRU weights where it loads from.
    nonisolated static func installDettato(from zip: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-dettato-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw StemError.unpack }
        let unpacked = folder.appending(path: "Dettato")
        let ready = folder.appending(path: "Ready")
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        for part in 1 ... 4 {
            let compiled = try MLModel.compileModel(at: unpacked.appending(path: "Part\(part).mlpackage"))
            try FileManager.default.moveItem(at: compiled, to: ready.appending(path: "Part\(part).mlmodelc"))
        }
        for file in ["gru.bin", "config.json"] {
            try FileManager.default.moveItem(at: unpacked.appending(path: file), to: ready.appending(path: file))
        }
        try place(ready, at: Dettato.folder)
    }

    /// Unzips the lyrics timing model, compiles it for this Mac and puts it with its list of characters where it loads from.
    nonisolated static func installAligner(from zip: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "muskey-aligner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw StemError.unpack }
        let unpacked = folder.appending(path: "Aligner")
        let ready = folder.appending(path: "Ready")
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        let compiled = try MLModel.compileModel(at: unpacked.appending(path: "Aligner.mlpackage"))
        try FileManager.default.moveItem(at: compiled, to: ready.appending(path: "Aligner.mlmodelc"))
        // The notice of the model's licence stays next to its weights.
        for file in ["labels.json", "NOTICE.txt"] {
            try FileManager.default.moveItem(at: unpacked.appending(path: file), to: ready.appending(path: file))
        }
        try place(ready, at: AlignerModel.folder)
    }

    nonisolated static func place(_ item: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: item)
        } else {
            try FileManager.default.moveItem(at: item, to: destination)
        }
    }
}
