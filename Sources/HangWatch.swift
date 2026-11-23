import AppKit
import Foundation

/// Watches the main thread from a background queue and logs every time it stops answering, the way the hang detection
/// of Lowtech does in Clop and rcmd. A block is sent to the main thread four times a second, and the time it waited
/// is the length of the hang. Past `sampleAfter` seconds, `sample(1)` reads the main thread's stack while the hang
/// still lasts, so a hang that never ends is in the log too. Nothing restarts the app.
final class HangWatch: @unchecked Sendable {
    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// A wait shorter than this is not logged.
    static let threshold = 0.5
    /// A hang this long gets its main thread stack sampled, once per hang and at most once a minute.
    static let sampleAfter = 2.0

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()

        // Timers stop while the Mac sleeps, and the first wait after a wake would read as a hang.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.sleeping = true; self?.pending = nil }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.sleeping = false; self?.pending = nil }
        }
    }

    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "muskey.hang-watch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    /// The block sent to the main thread that hasn't run yet: its number and when it was sent.
    private var pending: (id: Int, sent: Double)?
    private var sent = 0
    private var sleeping = false
    private var sampled: Int?
    private var lastSample = -Double.infinity

    private func tick() {
        guard !sleeping else { return }
        let now = CACurrentMediaTime()
        if let pending {
            let waited = now - pending.sent
            if waited >= Self.sampleAfter, sampled != pending.id, now - lastSample > 60 {
                sampled = pending.id
                lastSample = now
                let stack = Self.mainThreadStack() ?? "(sample read nothing)"
                log(String(format: "hang: the main thread hasn't answered for %.1f s\n%@", waited, stack))
            }
            return
        }
        sent += 1
        let id = sent
        pending = (id, now)
        let answer: @Sendable () -> Void = { [weak self] in
            let answered = CACurrentMediaTime()
            self?.queue.async { self?.answered(id, at: answered) }
        }
        DispatchQueue.main.async(execute: answer)
        // A modal panel, an open menu and a drag run the main run loop in modes that leave the main queue waiting,
        // so the block is also performed in those modes. Whichever runs first answers.
        RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking, .common], block: answer)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func answered(_ id: Int, at time: Double) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        let waited = time - pending.sent
        guard waited >= Self.threshold else { return }
        if sampled == id {
            log(String(format: "hang: the main thread answered again after %.1f s", waited))
        } else {
            log(String(format: "hang: the main thread didn't answer for %.2f s", waited))
        }
    }

    /// The main thread's part of a `sample(1)` of Muskey, which takes about 0.2 s and needs no permission.
    private static func mainThreadStack() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "0.001"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read before waiting, since a full pipe would keep `sample` from exiting.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var lines: [Substring] = []
        var inMain = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("Thread_") {
                if inMain { break }
                inMain = line.contains("com.apple.main-thread")
            }
            if inMain {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
