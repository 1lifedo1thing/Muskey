import Foundation
import os

// Muskey logs through the unified log, the way the other lowtechguys apps do. Each file declares its own logger with
// a category named after the file:
//
//     private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "FilePlayer")
//
// The levels decide what macOS keeps. Debug and info lines live only in memory, so `log stream` sees them while they
// happen and they are gone soon after. Notice, error and fault lines are written to disk. So a line that comes often
// (a report every second, every request, every window of the stems) is debug, a routine event is info, a change of
// state that a bug report needs is notice, and a failure is error. "Keep debug logs" in Settings > General, and
// `muskey logs persist on`, have macOS write the debug and info lines to disk as well, and so does the Info.plist of
// a build made with `make`.
//
// The values in a line are marked public, since the unified log hides strings as <private> by default, which would
// leave most lines empty. A line names songs, files and the hosts of links, never a password or the pairing key of
// the web remote.
//
// os.Logger interpolation uses escaping autoclosures, so a property of `self` inside a message needs an explicit
// `self.`.

/// The subsystem of every line that Muskey logs: the app's bundle identifier. It is written out rather than read from
/// the bundle, because the `muskey` tool, which changes the logging setting of this subsystem, has no bundle of its
/// own.
let LOG_SUBSYSTEM = "com.lowtechguys.Muskey"

extension OSLogType {
    /// The level that `Logger.notice` writes at, by the same name, for the calls that pass a level.
    static var notice: OSLogType { .default }
}

/// The log of a type whose lines a test run also prints to the terminal. Each line goes to the unified log under the
/// file's category, at the level that the call gives, and to `echo` when a test sets it.
struct EchoLog {
    init(category: String) {
        logger = Logger(subsystem: LOG_SUBSYSTEM, category: category)
    }

    let logger: Logger
    var echo: ((String) -> Void)?

    func callAsFunction(_ line: String, _ level: OSLogType = .info) {
        logger.log(level: level, "\(line, privacy: .public)")
        echo?(line)
    }
}
