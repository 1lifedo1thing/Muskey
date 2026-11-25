import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "KeptLogs")

// "Keep debug logs" in Settings > General. The other lowtechguys apps (Cling, Clop, rcmd) offer the same switch in their
// feedback window. Muskey has no feedback window, so the row sits in Settings instead. The daemon, its script and the
// control file work the same way in every app, so a fix in one applies to the others too.

// MARK: - KeptLogs

/// Has macOS keep Muskey's debug lines for a chosen time, for a problem that comes rarely and can't be made to happen
/// while someone streams the log.
///
/// The system log keeps debug lines only for a subsystem whose logging config says so, and only root can change that
/// config: logd ignores a config file that changes under it and reads it through `log config` alone. So turning this
/// on asks for an administrator password once, to install a small LaunchDaemon. The daemon turns the config on, then
/// reads the end time from a file that the app writes in Application Support, when the file changes (`WatchPaths`) and
/// once a minute. When the file says off or the time has passed, the daemon resets the config and removes itself,
/// whether or not the app is running. Turning it off early or picking another time is a write to that file, with no
/// password. `log show --debug` reads the kept lines back.
@MainActor
final class KeptLogs: ObservableObject {
    private init() {
        duration = UserDefaults.standard.string(forKey: Self.durationKey).flatMap(Duration.init(rawValue:)) ?? .week
        until = Self.until()
        scheduleRefresh()
    }

    enum Duration: String, CaseIterable, Identifiable {
        case hour = "1h"
        case day = "1d"
        case threeDays = "3d"
        case week = "7d"
        case twoWeeks = "14d"
        case month = "30d"
        case always

        var id: String {
            rawValue
        }

        var seconds: TimeInterval? {
            switch self {
            case .hour: 3600
            case .day: 86400
            case .threeDays: 3 * 86400
            case .week: 7 * 86400
            case .twoWeeks: 14 * 86400
            case .month: 30 * 86400
            case .always: nil
            }
        }

        var label: String {
            switch self {
            case .hour: "1 hour"
            case .day: "1 day"
            case .threeDays: "3 days"
            case .week: "7 days"
            case .twoWeeks: "14 days"
            case .month: "30 days"
            case .always: "Always"
            }
        }
    }

    static let shared = KeptLogs()

    /// The CLI's argument that makes it run `/bin/sh -c` with the rest of its arguments.
    static let daemonFlag = "--keep-debug-logs-daemon"
    /// The subsystems whose debug lines are kept: Muskey logs everything under one.
    static let subsystems = [LOG_SUBSYSTEM]

    /// `distantFuture` for Always, nil while off.
    @Published private(set) var until: Date?
    @Published private(set) var duration: Duration
    /// The password dialog is up.
    @Published private(set) var installing = false
    @Published private(set) var error: String?

    var isOn: Bool {
        until != nil
    }

    /// Holds the end time: digits for a Unix time, `always`, or `off`. Written in place, never replaced, so
    /// `WatchPaths` keeps watching the same file.
    nonisolated static var controlFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Muskey/keep-debug-logs")
    }

    nonisolated static var label: String {
        "\(Bundle.main.bundleIdentifier ?? LOG_SUBSYSTEM).keep-debug-logs"
    }

    nonisolated static var daemonPlist: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    }

    /// The root-owned copy of the `muskey` tool. It is a copy so that the user can't swap the program of a root job,
    /// and so that moving or updating the app doesn't break the daemon.
    nonisolated static var daemonProgram: URL {
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(label)")
    }

    /// What the control file asks for, when the daemon is there to do it.
    nonisolated static func until() -> Date? {
        guard FileManager.default.fileExists(atPath: daemonPlist.path),
              let text = try? String(contentsOf: controlFile, encoding: .utf8)
        else { return nil }
        let state = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "always" {
            return .distantFuture
        }
        guard let seconds = TimeInterval(state), seconds > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The administrator step: writes the daemon's plist from a here-document, so no file the user can change goes
    /// into a root job, and loads it.
    static func installScript() -> String {
        let source = bundledProgram
        let program = daemonProgram.path
        let shellArguments = ["-c", daemonScript, "keep-debug-logs", controlFile.path, label, daemonPlist.path] + subsystems
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": source == nil ? ["/bin/sh"] + shellArguments : [program, daemonFlag] + shellArguments,
            "WatchPaths": [controlFile.path],
            "StartInterval": 60,
            "RunAtLoad": true,
            // Groups the daemon under the app in System Settings > General > Login Items. macOS honours it only for a
            // program signed by the app's team.
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier].compactMap { $0 },
        ]
        let xml = (try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let copyProgram = source.map { source in
            """
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /bin/rm -f '\(program)'
            /bin/cp \(shellQuoted(source.path)) '\(program)'
            /usr/sbin/chown root:wheel '\(program)'
            /bin/chmod 755 '\(program)'
            """
        } ?? ""
        let shell = """
        set -e
        \(copyProgram)
        /bin/cat > '\(daemonPlist.path)' <<'KEPT_LOGS_PLIST'
        \(xml)
        KEPT_LOGS_PLIST
        /usr/sbin/chown root:wheel '\(daemonPlist.path)'
        /bin/chmod 644 '\(daemonPlist.path)'
        /bin/launchctl bootout 'system/\(label)' 2>/dev/null || true
        /bin/launchctl bootstrap system '\(daemonPlist.path)'
        """
        let prompt = "Muskey wants to keep its debug logs."
        return "do shell script \"\(appleScriptEscaped(shell))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges without altering line endings"
    }

    func setOn(_ on: Bool) {
        error = nil
        if on {
            turnOn()
        } else {
            write(nil)
            until = nil
            log.info("Keep debug logs turned off")
        }
    }

    /// Picking a time while it is on starts that time from now.
    func choose(_ duration: Duration) {
        self.duration = duration
        UserDefaults.standard.set(duration.rawValue, forKey: Self.durationKey)
        guard isOn else { return }
        let until = end(of: duration)
        write(until)
        self.until = until
        scheduleRefresh()
    }

    /// "2 d 4 h left", or "Until turned off" for Always.
    func detail(at now: Date = Date()) -> String {
        guard let until, until != .distantFuture else {
            return "Until turned off"
        }
        let minutes = max(1, Int(until.timeIntervalSince(now) / 60))
        return switch minutes {
        case 1440...: "\(minutes / 1440) d \(minutes % 1440 / 60) h left"
        case 60...: "\(minutes / 60) h \(minutes % 60) min left"
        default: "\(minutes) min left"
        }
    }

    /// Reads the state back from the control file and the daemon.
    func refresh() {
        until = Self.until()
        scheduleRefresh()
    }

    /// Run by launchd as root, with the control file, the label, the plist path and the subsystems. Only digits,
    /// `always` and `off` mean anything in the control file: the app's user can write it, so nothing read from it
    /// reaches a command.
    private static let daemonScript = """
    file="$1"; label="$2"; daemon="$3"; shift 3
    state=$(/usr/bin/head -c 32 "$file" 2>/dev/null | /usr/bin/tr -cd 'a-z0-9')
    now=$(/bin/date +%s)
    case "$state" in
        always) on=1 ;;
        "" | off | *[!0-9]*) on=0 ;;
        *) if [ "$state" -gt "$now" ]; then on=1; else on=0; fi ;;
    esac
    if [ "$on" = 1 ]; then
        for subsystem in "$@"; do
            [ -f "/Library/Preferences/Logging/Subsystems/$subsystem.plist" ] || /usr/bin/log config --subsystem "$subsystem" --mode "level:debug,persist:debug"
        done
        exit 0
    fi
    for subsystem in "$@"; do /usr/bin/log config --subsystem "$subsystem" --reset; done
    /bin/rm -f "$daemon" "/Library/PrivilegedHelperTools/$label"
    /bin/launchctl bootout "system/$label"
    """

    private static let durationKey = "keptLogsDuration"

    private var refreshTimer: Timer?

    /// The `muskey` tool in Contents/Helpers, which the daemon runs as its program. System Settings lists a daemon by
    /// the signature of its program, so a program signed with the app's team is listed under Muskey, where `/bin/sh`
    /// is listed as "sh" from an unknown developer.
    private static var bundledProgram: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/muskey")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func appleScriptEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs a command and kills it after `timeout`. The output goes through files rather than pipes, so a command that
    /// prints megabytes can't block on a full pipe.
    private nonisolated static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (success: Bool, error: String) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("kept-logs-run-\(UUID().uuidString)", isDirectory: true)
        let outURL = dir.appendingPathComponent("out")
        let errURL = dir.appendingPathComponent("err")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: outURL.path, contents: nil)
            fm.createFile(atPath: errURL.path, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = try FileHandle(forWritingTo: outURL)
            process.standardError = try FileHandle(forWritingTo: errURL)
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
            }
            process.waitUntilExit()
            let error = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            return (process.terminationReason == .exit && process.terminationStatus == 0, error)
        } catch {
            return (false, "\(error)")
        }
    }

    private func end(of duration: Duration) -> Date {
        duration.seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
    }

    private func write(_ until: Date?) {
        let file = Self.controlFile
        let state = switch until {
        case nil: "off"
        case .distantFuture?: "always"
        case let until?: "\(Int(until.timeIntervalSince1970))"
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try state.write(to: file, atomically: false, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
            log.error("Could not write \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func turnOn() {
        let until = end(of: duration)
        // The daemon reads this as it loads, so it goes first.
        write(until)
        // A daemon that runs `/bin/sh` shows as "sh" in System Settings, so it is installed again with the app's CLI.
        let outdated = Self.bundledProgram != nil && !FileManager.default.fileExists(atPath: Self.daemonProgram.path)
        guard outdated || !FileManager.default.fileExists(atPath: Self.daemonPlist.path) else {
            self.until = until
            scheduleRefresh()
            return
        }

        installing = true
        let script = Self.installScript()
        Task {
            let result = await Task.detached { Self.run("/usr/bin/osascript", ["-e", script], timeout: 300) }.value
            installing = false
            guard result.success else {
                write(nil)
                // -128 is the Cancel button of the password dialog.
                if !result.error.contains("-128") {
                    error = result.error.isEmpty ? "the administrator step failed" : result.error
                    log.error("Could not install the debug log daemon: \(result.error, privacy: .public)")
                }
                refresh()
                return
            }
            log.notice("Keeping debug logs until \(until == .distantFuture ? "turned off" : until.ISO8601Format(), privacy: .public)")
            refresh()
        }
    }

    /// Puts the row in step when the time is up. The daemon does the real work on its own.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let until, until != .distantFuture else { return }
        let timer = Timer(fire: until.addingTimeInterval(1), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}

// MARK: - KeptLogsRow

/// The row of Settings > General: a switch for keeping the debug logs, and how long to keep them for.
struct KeptLogsRow: View {
    @ObservedObject var logs: KeptLogs

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker("Keep for", selection: Binding(get: { logs.duration }, set: { logs.choose($0) })) {
                    ForEach(KeptLogs.Duration.allCases) { duration in
                        Text(duration.label).tag(duration)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Keep debug logs", isOn: Binding(get: { logs.isOn }, set: { logs.setOn($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(logs.installing)
            }
        } label: {
            Text("Keep debug logs")
            if logs.installing {
                Text("Waiting for the administrator password")
            } else if let error = logs.error {
                Text("Couldn't keep logs: \(error)")
            } else if logs.isOn {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(verbatim: logs.detail(at: context.date))
                }
            }
        }
        .help(logs.isOn ? "" : "Asks for an administrator password")
        // The daemon may have ended the time while Settings was closed.
        .onAppear { logs.refresh() }
    }
}
