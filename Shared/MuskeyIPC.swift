import Foundation

// The requests that the `muskey` command line tool sends to the running app, and the answers. This file is compiled
// into both, so they always agree on the format.

/// The name of the app's message port. Only processes of the same user on this Mac can reach it.
let muskeyPortName = "com.lowtechguys.Muskey.cli" as CFString

/// The instruments that the stems model separates, by the names that the tool takes.
let muskeyStemNames = ["bass", "drums", "guitar", "piano", "vocals", "winds", "other"]

/// What the tool can write, by file extension.
enum CLIFormat: String, Codable, CaseIterable {
    case m4a, mp3, wav, pdf, html, musicxml, mid, txt

    /// The changed song, as opposed to its notes.
    var isAudio: Bool { [.m4a, .mp3, .wav].contains(self) }

    init?(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        self.init(rawValue: ext == "xml" ? "musicxml" : ext == "midi" ? "mid" : ext)
    }
}

struct CLIRequest: Codable {
    enum Command: String, Codable {
        /// Plays the input in Muskey with the changes, or listens to the song that plays now.
        case play
        /// Writes the input with the changes, or its notes, to a file in Muskey's cache.
        case write
        /// How a job goes.
        case job
        /// Stops a job.
        case cancel
        /// The app's version, which also tells that it answers.
        case version
    }

    var command: Command
    /// Absolute paths of files and folders, or links.
    var inputs: [String] = []
    /// A key like `Am` or `F#`, or semitones like `+2`.
    var key: String?
    /// The instruments to play, the others muted.
    var stems: [String]?
    /// The instruments to mute.
    var mute: [String]?
    var speed: Double?
    /// A part of the song in seconds.
    var from: Double?
    var to: Double?
    /// The instrument to transcribe, or `auto` for the one that plays the most.
    var notes: String?
    var capo: Int?
    /// tab, sheet or roll.
    var view: String?
    var format: CLIFormat?
    /// Serve the written file at a link too.
    var link = false
    var job: String?
}

struct CLIResponse: Codable {
    var error: String?
    /// What the app did, for the tool to print.
    var message: String?
    var job: String?
    /// The step that a job is on, and how much of it is done, from 0 to 1.
    var step: String?
    var progress: Double?
    var done = false
    /// The file that a write job made, in Muskey's cache.
    var output: String?
    var link: String?
    var version: String?
}

/// Sends a request to the running app and waits for its answer. Nil when the app isn't running.
func sendToMuskey(_ request: CLIRequest, timeout: TimeInterval = 10) throws -> CLIResponse? {
    guard let port = CFMessagePortCreateRemote(nil, muskeyPortName) else { return nil }
    let data = try JSONEncoder().encode(request)
    var reply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(port, 1, data as CFData, 2, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
    guard status == kCFMessagePortSuccess else {
        throw NSError(domain: "muskey", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Muskey didn't answer (message port status \(status))"])
    }
    guard let reply = reply?.takeRetainedValue() as Data? else { return CLIResponse(error: "Muskey sent an empty answer") }
    return try JSONDecoder().decode(CLIResponse.self, from: reply)
}
