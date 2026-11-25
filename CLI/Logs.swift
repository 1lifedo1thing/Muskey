import Foundation

// `muskey logs persist on|off|status`, the same command that Cling, Clop and rcmd have. Builds made with `make` keep
// debug logs through their Info.plist; a release build needs the system's logging config changed, which only root can
// do, so this runs `log config` under sudo and lets it ask for the password in the terminal.

enum LogsPersist {
    enum Action: String, CaseIterable {
        case on
        case off
        case status

        /// nil for status, whose answer is what `log config` printed.
        var doneMessage: String? {
            switch self {
            case .on: """
                Debug logs for Muskey are kept now. Read them with:
                    log show --debug --info --last 1h --predicate 'subsystem == "\(LOG_SUBSYSTEM)"'
                """
            case .off: "Debug logs for Muskey are back to the macOS default"
            case .status: nil
            }
        }

        func logConfigArguments(subsystem: String) -> [String] {
            switch self {
            case .on: ["config", "--subsystem", subsystem, "--mode", "level:debug,persist:debug"]
            case .off: ["config", "--subsystem", subsystem, "--reset"]
            case .status: ["config", "--status", "--subsystem", subsystem]
            }
        }
    }

    static let help = """
    Usage: muskey logs persist on|off|status

    Keep Muskey's debug logs on disk so `log show` can read them later.

    macOS keeps debug and info messages only in memory, so they are gone before anyone looks. Changing this needs an
    administrator password.
    """

    /// Everything Muskey logs goes under one subsystem; this tool itself doesn't log.
    static let subsystems = [LOG_SUBSYSTEM]

    static func run(_ arguments: [String]) -> Never {
        if arguments.contains("-h") || arguments.contains("--help") {
            print(help)
            exit(0)
        }
        guard arguments.count == 1, let action = Action(rawValue: arguments[0].lowercased()) else {
            printError(help)
            exit(2)
        }
        for subsystem in subsystems {
            let status: Int32
            do {
                status = try runInForeground(["/usr/bin/sudo", "/usr/bin/log"] + action.logConfigArguments(subsystem: subsystem))
            } catch {
                printError("Could not change the log settings: \(error)")
                exit(1)
            }
            guard status == 0 else {
                printError("Could not change the log settings: sudo exited with status \(status)")
                exit(status)
            }
        }
        if let message = action.doneMessage {
            print(message)
        }
        exit(0)
    }
}

// MARK: - SpawnError

/// Why spawning failed, worded for the end of "Could not change the log settings: ".
struct SpawnError: Error, CustomStringConvertible {
    let description: String
}

/// Runs `argv` on the terminal's own stdin, stdout and stderr and returns its exit status.
///
/// posix_spawn rather than Process: Process starts the child in a process group of its own, which the terminal
/// treats as a background job. sudo turns echo off before asking for the password, the kernel stops a background
/// group that changes the terminal's settings with SIGTTOU, and the command hangs before the prompt shows whenever
/// sudo has no cached password. Spawned in our group the child stays in the foreground, and Ctrl-C reaches it too.
func runInForeground(_ argv: [String]) throws -> Int32 {
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) } }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, argv[0], nil, nil, &cArgs, environ)
    guard spawned == 0 else {
        throw SpawnError(description: "could not run \(argv[0]): \(String(cString: strerror(spawned)))")
    }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        guard errno == EINTR else {
            throw SpawnError(description: "lost track of \(argv[0]): \(String(cString: strerror(errno)))")
        }
    }
    // WIFEXITED and friends are C macros Swift can't see. The low 7 bits are the signal that ended the process,
    // 0 when it exited on its own; reported the way a shell does, as 128 + the signal.
    let signal = status & 0x7F
    return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
}

/// "Keep debug logs" in Settings installs a LaunchDaemon whose program is a root-owned copy of this tool, called with
/// `--keep-debug-logs-daemon` and then the arguments for `/bin/sh`. The daemon could run `/bin/sh` directly, but
/// System Settings > General > Login Items lists a daemon by the signature of its program, and `/bin/sh` shows there
/// as "sh" from an unknown developer. This tool is signed by the app's team, so the daemon is listed under Muskey.
func runKeepDebugLogsDaemon() {
    let arguments = CommandLine.arguments
    guard arguments.count > 2, arguments[1] == "--keep-debug-logs-daemon" else { return }
    var argv: [UnsafeMutablePointer<CChar>?] = (["/bin/sh"] + arguments.dropFirst(2)).map { strdup($0) }
    argv.append(nil)
    execv("/bin/sh", argv)
    perror("execv /bin/sh")
    exit(127)
}
