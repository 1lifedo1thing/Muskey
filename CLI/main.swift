import Foundation

// `muskey`: plays songs in Muskey with a change of key, tempo or instruments, transcribes their notes, or writes the
// changed song or its notes to a file. It talks to the running app over its message port (Shared/MuskeyIPC.swift),
// and opens the app when it isn't running. The app does all the work; this tool only reads the arguments, waits and
// moves the file that the app wrote into place, with the permissions of the shell that runs it.

// A root-owned copy of this tool is the program of the daemon behind "Keep debug logs", so that call comes first.
runKeepDebugLogsDaemon()

let help = """
Usage: muskey [INPUT...] [OPTIONS]

Plays songs in Muskey with a change of key, tempo or instruments, transcribes their notes, or writes the
changed song or its notes to a file.

INPUT is a song file, a folder of songs or a link. A Spotify link plays in Spotify, and Muskey listens to it.
Without INPUT, Muskey listens to the song that plays now, as the hotkey does. Over SSH, a Spotify song mutes
the Mac's sound output.

Song:
  -k, --key KEY          Key to play in: Am, F#, Bbm, or semitones like +2 or -3
  -s, --stems LIST       Instruments to play, separated by commas: bass, drums, guitar, piano, vocals, winds, other
  -m, --mute LIST        Instruments to mute
      --speed SPEED      Speed against the song's tempo: 0.9 or 90%
      --from TIME        Start of the part to play, loop or write: 1:12 or 72.5
      --to TIME          End of that part

Notes:
  -n, --notes STEM       Transcribe the notes of an instrument, or auto for the one that plays the most
      --capo FRET        Capo for the tab, from 0 to 11
      --view VIEW        tab, sheet or roll

Output:
  -o, --output PATH      Write a file instead of playing in Muskey. The extension picks what is written:
                           .m4a .mp3 .wav           the changed song
                           .pdf .html               the notes, as pages or as an interactive sheet
                           .musicxml .mid .txt      the notes for other apps
                         A dash (-) writes to standard output.
  -f, --format FORMAT    m4a, mp3, wav, pdf, html, musicxml, mid or txt (for -o - or a path without extension)
  -l, --link             Print a link to the file, for opening it on a phone or another Mac
  -q, --quiet            Print only errors and the path or link
      --json             Print the result as JSON

  -h, --help             Print this help
  -V, --version          Print the version

Debug logs:
  muskey logs persist on|off|status
                         Keep Muskey's debug logs on disk so `log show` can read them later

Examples:
  muskey song.mp3 --key Am
  muskey ~/Music/Album
  muskey "https://youtu.be/…" --stems vocals,piano --key +2
  muskey --key G                                    listen to the song that plays, then move it to G
  muskey spotify:track:4uLU6hMCjMI75M1A2tKUQC --key +2
  muskey song.mp3 --notes guitar
  muskey song.mp3 --key Em --mute vocals -o karaoke.m4a
  muskey song.mp3 --notes bass --from 1:12 --to 1:40 -o bass.pdf
  muskey song.mp3 --notes guitar --capo 2 -o sheet.html --link
"""

let standardError = FileHandle.standardError

func printError(_ text: String) {
    standardError.write(Data("\(text)\n".utf8))
}

func fail(_ text: String, code: Int32 = 1) -> Never {
    printError("Error: \(text)")
    exit(code)
}

// MARK: Arguments

struct Options {
    var inputs: [String] = []
    var request = CLIRequest(command: .play)
    var output: String?
    var quiet = false
    var json = false
}

/// Reads the arguments the way most command line tools do: `-k Am`, `-kAm`, `--key Am` and `--key=Am`, flags
/// combined as `-lq`, and `--` before inputs that start with a dash. An option that takes a value always takes the
/// next argument, so `--key -3` works.
func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    let valued: [String: String] = [
        "-k": "key", "--key": "key", "-s": "stems", "--stems": "stems", "-m": "mute", "--mute": "mute", "--speed": "speed",
        "--from": "from", "--to": "to", "-n": "notes", "--notes": "notes", "--capo": "capo", "--view": "view",
        "-o": "output", "--output": "output", "-f": "format", "--format": "format",
    ]
    let flags: [String: String] = [
        "-l": "link", "--link": "link", "-q": "quiet", "--quiet": "quiet", "--json": "json", "-h": "help", "--help": "help",
        "-V": "version", "--version": "version",
    ]

    func value(for name: String, attached: String?) -> String {
        if let attached { return attached }
        index += 1
        guard index < arguments.count else { fail("\(name) needs a value. Run muskey --help for the options", code: 2) }
        return arguments[index]
    }

    func set(_ option: String, _ raw: String, as name: String) {
        switch option {
        case "key": options.request.key = checkedKey(raw)
        case "stems": options.request.stems = checkedStems(raw, option: name)
        case "mute": options.request.mute = checkedStems(raw, option: name)
        case "speed": options.request.speed = checkedSpeed(raw)
        case "from": options.request.from = checkedTime(raw, option: name)
        case "to": options.request.to = checkedTime(raw, option: name)
        case "notes": options.request.notes = checkedNotes(raw)
        case "capo":
            guard let capo = Int(raw), (0 ... 11).contains(capo) else { fail("\(name) takes a fret from 0 to 11", code: 2) }
            options.request.capo = capo
        case "view":
            guard ["tab", "sheet", "roll"].contains(raw.lowercased()) else { fail("\(name) takes tab, sheet or roll", code: 2) }
            options.request.view = raw.lowercased()
        case "output": options.output = raw
        case "format":
            guard let format = CLIFormat(rawValue: raw.lowercased()) else {
                fail("unknown format \"\(raw)\". Use \(CLIFormat.allCases.map(\.rawValue).joined(separator: ", "))", code: 2)
            }
            options.request.format = format
        default: break
        }
    }

    func setFlag(_ flag: String) {
        switch flag {
        case "link": options.request.link = true
        case "quiet": options.quiet = true
        case "json": options.json = true
        case "help":
            print(help)
            exit(0)
        case "version":
            print("muskey \(appVersion ?? "unknown version")")
            exit(0)
        default: break
        }
    }

    var onlyInputs = false
    while index < arguments.count {
        let argument = arguments[index]
        if onlyInputs || !argument.hasPrefix("-") {
            options.inputs.append(argument)
        } else if argument == "--" {
            onlyInputs = true
        } else if argument.hasPrefix("--") {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if let option = valued[parts[0]] {
                set(option, value(for: parts[0], attached: parts.count > 1 ? parts[1] : nil), as: parts[0])
            } else if let flag = flags[parts[0]], parts.count == 1 {
                setFlag(flag)
            } else {
                fail("unknown option \(parts[0]). Run muskey --help for the options", code: 2)
            }
        } else {
            // Short options: flags may share a dash, and the first one that takes a value takes the rest of the
            // argument or the next one.
            let letters = Array(argument.dropFirst())
            for (position, letter) in letters.enumerated() {
                let name = "-\(letter)"
                if let option = valued[name] {
                    let rest = String(letters[(position + 1)...])
                    set(option, value(for: name, attached: rest.isEmpty ? nil : rest), as: name)
                    break
                } else if let flag = flags[name] {
                    setFlag(flag)
                } else {
                    fail("unknown option \(name). Run muskey --help for the options", code: 2)
                }
            }
        }
        index += 1
    }
    return options
}

func checkedKey(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if let semitones = Int(text), (-12 ... 12).contains(semitones) { return text }
    let pattern = #"^[A-Ga-g](#|♯|b|♭)?(m|min|minor|maj|major)?$"#
    guard text.range(of: pattern, options: .regularExpression) != nil else {
        fail("unknown key \"\(raw)\". Use a key like Am, F#, Bbm, or semitones like +2", code: 2)
    }
    return text
}

func checkedStems(_ raw: String, option: String) -> [String] {
    let names = raw.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    guard !names.isEmpty else { fail("\(option) needs instruments, like vocals,guitar", code: 2) }
    for name in names where !muskeyStemNames.contains(name) {
        fail("unknown instrument \"\(name)\". Use \(muskeyStemNames.joined(separator: ", "))", code: 2)
    }
    return names
}

func checkedNotes(_ raw: String) -> String {
    let name = raw.lowercased()
    guard name == "auto" || muskeyStemNames.contains(name), name != "drums" else {
        fail("--notes takes an instrument (bass, guitar, piano, vocals, winds, other) or auto", code: 2)
    }
    return name
}

func checkedSpeed(_ raw: String) -> Double {
    let text = raw.trimmingCharacters(in: .whitespaces)
    let speed = text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
    guard let speed, (0.5 ... 1.5).contains(speed) else { fail("--speed takes a speed from 0.5 to 1.5, or 50% to 150%", code: 2) }
    return speed
}

/// Seconds from `72.5`, `1:12` or `1:02:03`.
func checkedTime(_ raw: String, option: String) -> Double {
    let parts = raw.split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil || $0! < 0 }) else {
        fail("\(option) takes a time like 1:12 or 72.5", code: 2)
    }
    return parts.reduce(0) { $0 * 60 + $1! }
}

// MARK: The app

/// The app that this tool belongs to: Muskey.app/Contents/Helpers/muskey, also through a link in ~/.local/bin.
let appBundle: URL? = {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}()

let appVersion: String? = appBundle.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }

/// Sends a request, opening Muskey first when it isn't running and waiting up to 20 seconds for its port.
func send(_ request: CLIRequest) -> CLIResponse {
    do {
        if let response = try sendToMuskey(request) { return response }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = appBundle.map { ["-g", $0.path] } ?? ["-g", "-b", "com.lowtechguys.Muskey"]
        try open.run()
        open.waitUntilExit()
        for _ in 0 ..< 80 {
            Thread.sleep(forTimeInterval: 0.25)
            if let response = try sendToMuskey(request) { return response }
        }
        fail("Muskey is not running, and it could not be opened")
    } catch {
        fail(error.localizedDescription)
    }
}

// MARK: Run

// `muskey logs persist` is a command of its own, so it is read before the arguments are taken as songs. A folder named
// logs still plays with `muskey logs`.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "logs", CommandLine.arguments[2] == "persist" {
    LogsPersist.run(Array(CommandLine.arguments.dropFirst(3)))
}

var options = parse(Array(CommandLine.arguments.dropFirst()))
var request = options.request

// Paths are made absolute here, since the app runs in another folder.
let currentFolder = FileManager.default.currentDirectoryPath
request.inputs = options.inputs.map { input in
    let expanded = (input as NSString).expandingTildeInPath
    let path = expanded.hasPrefix("/") ? expanded : (currentFolder as NSString).appendingPathComponent(expanded)
    if FileManager.default.fileExists(atPath: path) { return (path as NSString).standardizingPath }
    if input.contains("://") || input.lowercased().hasPrefix("spotify:") || input.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil { return input }
    fail("no file or folder at \(input)", code: 2)
}
if let from = request.from, let to = request.to, to <= from { fail("--to must come after --from", code: 2) }
// A command sent over SSH comes from away from the Mac.
request.remote = ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil
if request.stems != nil, request.mute != nil { fail("use either --stems or --mute", code: 2) }

if let output = options.output {
    request.command = .write
    guard request.format != nil || output != "-" else { fail("-o - needs --format to know what to write", code: 2) }
    request.format = request.format ?? CLIFormat(path: output)
    guard let format = request.format else {
        fail("the extension of \(output) names no format. Use --format, or one of .\(CLIFormat.allCases.map(\.rawValue).joined(separator: " ."))", code: 2)
    }
    guard request.inputs.count == 1 else {
        fail(request.inputs.isEmpty ? "no input to write. Give a song file or a link" : "--output writes one song; give one input", code: 2)
    }
    var isFolder: ObjCBool = false
    if FileManager.default.fileExists(atPath: request.inputs[0], isDirectory: &isFolder), isFolder.boolValue {
        fail("--output writes one song, not a folder", code: 2)
    }
    let input = request.inputs[0].lowercased()
    if input.hasPrefix("spotify:") || input.contains("open.spotify.com") { fail("a Spotify song can't be written to a file, only played", code: 2) }
    if format.isAudio, request.notes != nil { fail("--notes writes the notes: use .pdf, .html, .musicxml, .mid or .txt", code: 2) }
    if !format.isAudio { request.notes = request.notes ?? "auto" }
} else if request.link {
    fail("--link needs --output", code: 2)
}

/// Prints how a job goes on standard error: one line rewritten in place in a terminal, a line per step otherwise.
final class Progress {
    private var lastLine = ""
    private var lastStep = ""
    private var lastTenth = -1
    private let terminal = isatty(STDERR_FILENO) != 0
    var quiet = false

    func show(_ step: String?, _ progress: Double?) {
        guard !quiet, let step else { return }
        let percent = progress.map { Int(($0 * 100).rounded()) }
        let line = percent.map { "\(step) \($0)%" } ?? step
        if terminal {
            guard line != lastLine else { return }
            standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
        } else {
            // A log gets a line for each step, and one for each tenth of it.
            let tenth = percent.map { $0 / 10 } ?? -1
            guard step != lastStep || tenth != lastTenth else { return }
            standardError.write(Data("\(line)\n".utf8))
            lastTenth = tenth
        }
        lastLine = line
        lastStep = step
    }

    func end() {
        if terminal, !lastLine.isEmpty { standardError.write(Data("\r\u{1B}[2K".utf8)) }
    }
}

let progress = Progress()
progress.quiet = options.quiet || options.json

let started = send(request)
if let error = started.error { fail(error) }
guard let job = started.job else {
    if options.json { print(String(data: try! JSONEncoder().encode(started), encoding: .utf8)!) } else if let message = started.message, !options.quiet { print(message) }
    exit(0)
}

// Ctrl-C stops the job in the app too.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    progress.end()
    _ = try? sendToMuskey(CLIRequest(command: .cancel, job: job))
    printError("Stopped")
    exit(130)
}
interrupt.resume()

DispatchQueue.global().async {
    var state = started
    while !state.done {
        Thread.sleep(forTimeInterval: 0.25)
        do {
            guard let next = try sendToMuskey(CLIRequest(command: .job, job: job)) else { fail("Muskey quit before the job was done") }
            state = next
        } catch {
            fail(error.localizedDescription)
        }
        DispatchQueue.main.sync { progress.show(state.step, state.progress) }
    }
    DispatchQueue.main.sync {
        progress.end()
        if let error = state.error { fail(error) }
        if let output = options.output, let written = state.output {
            if output == "-" {
                guard let data = FileManager.default.contents(atPath: written) else { fail("the file that Muskey wrote can't be read") }
                FileHandle.standardOutput.write(data)
                exit(0)
            }
            let destination = ((output as NSString).expandingTildeInPath as NSString).isAbsolutePath
                ? (output as NSString).expandingTildeInPath : (currentFolder as NSString).appendingPathComponent(output)
            let target = URL(fileURLWithPath: destination)
            do {
                try? FileManager.default.removeItem(at: target)
                // The app keeps a file that it serves at a link, and lets go of the others.
                if request.link {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: written), to: target)
                } else {
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: written), to: target)
                }
            } catch {
                fail("the file can't be written to \(destination): \(error.localizedDescription)")
            }
            state.output = target.path
        }
        if options.json {
            print(String(data: try! JSONEncoder().encode(state), encoding: .utf8)!)
        } else {
            if let message = state.message, !options.quiet, options.output == nil { print(message) }
            if options.output != nil, let output = state.output { print(output) }
            if let link = state.link { print(link) }
        }
        exit(0)
    }
}

dispatchMain()
