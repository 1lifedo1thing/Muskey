import AppKit
import Combine
import CryptoKit
import IOKit
import Sentry

/// Sends crashes, hangs of the main thread and uncaught exceptions to Sentry while Settings > General > Send error
/// reports is on, with one event the first time each version launches. A report carries an anonymous machine ID, and
/// the addresses of web requests stay out of it, since lyric and key lookups put song titles and artists in them.
/// `HangWatch` keeps logging the shorter hangs, and nothing restarts Muskey after a crash or a hang.
enum ErrorReports {
    /// Starts Sentry when error reports are on, and from then on starts or closes it whenever the setting changes.
    static func start() {
        #if MUSKEY_DEV
            if TestFlags.has("--test-sentry") { return sendTestEvent() }
        #endif
        let prefs = Preferences.shared
        settingChanges = settingChanges ?? prefs.$errorReports.dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { on in
                if on, !SentrySDK.isEnabled {
                    startSDK()
                } else if !on {
                    SentrySDK.close()
                }
            }
        guard prefs.errorReports else { return }
        startSDK()
    }

    /// A stable, anonymous ID for this Mac, which a person can copy from Settings and quote in a bug report so that
    /// their reports can be found. It is a hash of the serial number, so every app that reports this way gives the
    /// same Mac the same ID, and it is saved so that a new serial after a repair doesn't split one Mac into two.
    static var machineID: String {
        if let saved = UserDefaults.standard.string(forKey: "sentryUserID"), !saved.isEmpty {
            return saved
        }
        let id = serialNumberHash() ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "sentryUserID")
        return id
    }

    private static let dsn = "https://d9c0f0fa73ed3b1ff42578794f219ed4@o84592.ingest.us.sentry.io/4512492050448384"
    private static var settingChanges: AnyCancellable?

    private static func startSDK() {
        // AppKit logs an exception thrown while it handles an event, and then goes on running in a state that nobody
        // tested. With this, the exception crashes Muskey and the crash is reported.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "v\(build)"
            options.dist = build
            options.enableCaptureFailedRequests = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.swiftAsyncStacktraces = true
            // An uncaught exception crashes with SIGTRAP because of NSApplicationCrashOnExceptions. Without this, its
            // report holds only the frames of `_crashOnException`, with no name and no reason for the exception.
            options.enableUncaughtNSExceptionReporting = true
            #if MUSKEY_DEV
                options.environment = "dev"
                // A build for testing never uploads its crashes, and macOS still writes the crash report on the Mac.
                options.enableCrashHandler = false
                // Its hangs would crowd out the hangs of releases, except when `--test-hang` blocks the main thread
                // on purpose to check that a hang reaches Sentry.
                options.enableAppHangTracking = TestFlags.value("--test-hang") != nil
                options.appHangTimeoutInterval = 2
            #else
                options.appHangTimeoutInterval = 30
            #endif
            options.beforeSend = { event in
                guard let exception = event.exceptions?.first, exception.mechanism?.type == "AppHang" else {
                    return event
                }
                // The main thread is waiting for a person to answer an alert or a panel, so Muskey isn't stuck.
                if exception.stacktrace.isWaitingForUser || isWaitingInModalSession || event.isWaitingForSystemDialog {
                    return nil
                }
                // macOS can take longer than the hang threshold to check a code signature on a busy Mac, and
                // Muskey can't make securityd answer faster.
                if event.isCheckingCodeSignature {
                    return nil
                }
                return event
            }
        }

        SentrySDK.configureScope { $0.setUser(User(userId: machineID)) }
        sendLaunchOnce(build: build)
    }

    /// One event the first time each version launches on a Mac, so that the number of Macs running a release shows in
    /// Sentry without an analytics service. A fixed fingerprint keeps every launch in one issue.
    private static func sendLaunchOnce(build: String) {
        guard UserDefaults.standard.string(forKey: "lastLaunchVersion") != build else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard SentrySDK.isEnabled else { return }
            SentrySDK.capture(message: "Launch") { $0.setFingerprint(["launch"]) }
            UserDefaults.standard.set(build, forKey: "lastLaunchVersion")
        }
    }

    #if MUSKEY_DEV
        /// `--test-sentry` sends one event to the dev environment of the project and quits, whatever the setting is.
        private static func sendTestEvent() {
            startSDK()
            let id = SentrySDK.capture(message: "Test event from --test-sentry")
            SentrySDK.flush(timeout: 10)
            print("sentry: sent test event \(id.sentryIdString)")
            exit(0)
        }
    #endif

    /// The main run loop is asleep in its modal panel mode: an alert or a panel shown with `runModal` is waiting for a
    /// click. When the alert was opened from a block on the main queue, as Sparkle does for "You're up to date", the
    /// main queue gets no turn until it closes, so Sentry, which measures the main queue, reports a hang although
    /// Muskey answers. A main thread stuck in code during a modal session is not asleep, so that hang is reported.
    private static var isWaitingInModalSession: Bool {
        let main = CFRunLoopGetMain()
        guard CFRunLoopIsWaiting(main), let mode = CFRunLoopCopyCurrentMode(main) else { return false }
        return mode.rawValue as String == RunLoop.Mode.modalPanel.rawValue
    }

    private static func serialNumberHash() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let serial = IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        else { return nil }
        let hash = SHA256.hash(data: Data(serial.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return Data(hash.prefix(20)).base64EncodedString()
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: "+", with: ".")
    }
}

private extension SentryStacktrace? {
    /// The main thread waits in a modal loop, which macOS keeps running for as long as an alert, a sheet or a panel
    /// stays on screen. The names are there only when the frames were symbolicated in the app, which is rare, so
    /// `isWaitingInModalSession` catches most of these.
    var isWaitingForUser: Bool {
        guard let stack = self else { return false }
        return stack.frames.contains { frame in
            guard let function = frame.function else { return false }
            return ["runModal", "runModalForWindow", "runModalSession", "_doModalLoop", "beginSheet"].contains { function.contains($0) }
        }
    }
}

private extension Event {
    /// The main thread waits for a dialog that a system service shows in Muskey. ViewBridge renames
    /// the main thread for that wait so that hang reports can tell it apart, and the wait can outlast the hang
    /// threshold when the service is slow to show its window.
    var isWaitingForSystemDialog: Bool {
        threads?.first { $0.isMain?.boolValue == true }?.name?.hasPrefix("not a hang but an app-modal session") == true
    }

    /// The main thread is inside the code signing functions of Security, which wait for securityd. Sentry fills only
    /// addresses into the frames that it collects in the app, so `dladdr` names each one. Those functions are
    /// exported by Security, so their names are found even in a stripped build.
    var isCheckingCodeSignature: Bool {
        guard let frames = exceptions?.first?.stacktrace?.frames else { return false }
        return frames.contains { frame in
            guard let hex = frame.instructionAddress,
                  let address = UInt(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16),
                  let pointer = UnsafeRawPointer(bitPattern: address)
            else { return false }
            var info = Dl_info()
            guard dladdr(pointer, &info) != 0, let name = info.dli_sname else { return false }
            let symbol = String(cString: name)
            return symbol.hasPrefix("SecCode") || symbol.hasPrefix("SecStaticCode")
        }
    }
}
