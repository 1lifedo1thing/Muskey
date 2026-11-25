import Foundation
import Network
import os

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "WebLinks")

/// The private links that `muskey --link` prints. Each file is copied into a folder named after a random token of 128
/// bits, so a link keeps working after Muskey restarts, and the folder's date ends it after three days. A request
/// names only a token, so no path from the network ever reaches the disk.
///
/// With HTTPS on Tailscale turned on, the Tailscale addresses listen with TLS once Tailscale hands over its certificate
/// for the Mac's MagicDNS name, and the links and the pairing link for Tailscale carry `https://` and that name.
@MainActor final class WebLinks: ObservableObject {
    static let shared = WebLinks()

    /// A fixed port, so that a link stays the same across restarts.
    nonisolated static let port: UInt16 = 25471
    nonisolated static let lifetime: TimeInterval = 3 * 24 * 3600
    /// Kept apart from `Muskey/Links`, where Muskey Player keeps the songs that it downloads from links.
    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Shared")

    /// Settings > Remote > HTTPS on Tailscale. Off until asked for: getting the certificate puts the Mac's Tailscale name
    /// in Let's Encrypt's public certificate logs.
    nonisolated static let httpsKey = "webRemoteHTTPS"
    nonisolated static var https: Bool { UserDefaults.standard.bool(forKey: httpsKey) }

    /// The MagicDNS name that the Tailscale addresses serve HTTPS for, while they do.
    @Published private(set) var secureHost: String? {
        didSet { WebAddresses.secureHost = secureHost }
    }

    /// The name that Tailscale would issue this Mac a certificate for, asked without getting one. Settings offers HTTPS
    /// only while there is one.
    @Published private(set) var certificateDomain: String?

    /// Serves the links from before a restart while any of them is still valid.
    func startIfNeeded() {
        moveOldLinks()
        removeExpired()
        let links = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        if links.contains(where: Self.isToken) { start() }
    }

    /// Copies the file into a new link's folder and gives the link.
    func serve(_ path: String) -> String? {
        removeExpired()
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent
        let folder = Self.folder.appending(path: token)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: folder.appending(path: name))
        } catch {
            log.error("No link for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        start()
        guard let base = Self.base else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? name
        return "\(base)/l/\(token)/\(encoded)"
    }

    /// The start of a link, at the host picked in Settings > Remote > Address, or else at the address that reaches the
    /// furthest: Tailscale's, then the local network's.
    nonisolated static var base: String? {
        guard let host = WebAddresses.linkHost() else { return nil }
        return "\(host == WebAddresses.secureHost ? "https" : "http")://\(host):\(port)"
    }

    private var server: WebServer?
    private var monitor: NWPathMonitor?
    private var relisten: DispatchWorkItem?
    private var addresses: [WebAddresses.Address] = []

    private var certificate: TailscaleTLS.Certificate?
    private var certificateFetch: Task<Void, Never>?
    private var certificateChecked: Date?
    private var certificateTimer: Timer?
    /// The next try after a fetch that got no certificate, while none is served: the Tailscale addresses stay plain HTTP
    /// until one comes.
    private var certificateRetry: DispatchWorkItem?
    private var certificateFailures = 0
    private var tailscaleCheck: Task<Void, Never>?

    /// Starts the server, for the links or for the web remote.
    func start() {
        if server == nil {
            server = WebServer(port: Self.port, handler: Self.handle)
            // Wi-Fi changes and VPNs coming up change the addresses, so the listeners follow them.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { _ in
                Task { @MainActor in WebLinks.shared.scheduleListen() }
            }
            monitor.start(queue: .main)
            self.monitor = monitor
            // `tailscale cert` renews a certificate only when asked, so it is asked a few times a day.
            certificateTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in
                MainActor.assumeIsolated { WebLinks.shared.refreshCertificate() }
            }
        }
        listen()
        checkTailscale()
        refreshCertificate()
    }

    /// Stops listening when no link is valid and the web remote is off.
    func stopIfIdle() {
        removeExpired()
        let links = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        guard server != nil, !WebRemote.enabled, !links.contains(where: Self.isToken) else { return }
        server?.stop()
        server = nil
        monitor?.cancel()
        monitor = nil
        relisten?.cancel()
        addresses = []
        certificateTimer?.invalidate()
        certificateTimer = nil
        certificateRetry?.cancel()
        certificateRetry = nil
        certificateFailures = 0
        certificate = nil
        certificateChecked = nil
        secureHost = nil
        certificateDomain = nil
    }

    /// Settings > Remote > HTTPS on Tailscale changed.
    func httpsChanged() {
        guard server != nil else { return }
        if Self.https {
            refreshCertificate()
        } else {
            certificateRetry?.cancel()
            certificateRetry = nil
            certificateFailures = 0
            certificate = nil
            certificateChecked = nil
            secureHost = nil
            listen()
        }
    }

    /// Fetches Tailscale's certificate for this Mac when HTTPS is on and a Tailscale address is up, then starts those
    /// listeners again with TLS, or with the renewed certificate. Off the main thread: a first certificate can take a
    /// minute.
    func refreshCertificate() {
        guard Self.https, server != nil, certificateFetch == nil, addresses.contains(where: \.tailscale) else { return }
        if let certificateChecked, certificate != nil, Date().timeIntervalSince(certificateChecked) < 3 * 3600 { return }
        certificateRetry?.cancel()
        certificateRetry = nil
        certificateFetch = Task.detached(priority: .utility) {
            let certificate = Self.fetchCertificate()
            await MainActor.run { WebLinks.shared.certificateArrived(certificate) }
        }
    }

    nonisolated private static func fetchCertificate() -> TailscaleTLS.Certificate? {
        guard let cli = TailscaleTLS.cli() else {
            log.error("No Tailscale app or CLI to get a certificate from")
            return nil
        }
        guard let domain = TailscaleTLS.domain(cli: cli) else {
            log.error("Tailscale didn't say which name this Mac has a certificate for")
            return nil
        }
        return TailscaleTLS.certificate(cli: cli, domain: domain)
    }

    /// A failed refresh keeps the certificate already served: it stays valid for weeks.
    private func certificateArrived(_ new: TailscaleTLS.Certificate?) {
        certificateFetch = nil
        certificateChecked = Date()
        if new == nil, certificate == nil, server != nil, Self.https {
            // After a minute, then less often, up to every 10 minutes.
            certificateFailures += 1
            let retry = DispatchWorkItem { MainActor.assumeIsolated { WebLinks.shared.refreshCertificate() } }
            certificateRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + min(600, 60 * pow(2, Double(certificateFailures - 1))), execute: retry)
        } else if new != nil {
            certificateFailures = 0
        }
        guard server != nil, Self.https, let new, new.leaf != certificate?.leaf || new.domain != certificate?.domain else { return }
        log.notice("Serving HTTPS for \(new.domain, privacy: .public)")
        certificate = new
        secureHost = new.domain
        listen()
    }

    /// Asks Tailscale for this Mac's name and whether the tailnet issues certificates, which gets none.
    private func checkTailscale() {
        guard server != nil, tailscaleCheck == nil else { return }
        guard addresses.contains(where: \.tailscale) else {
            certificateDomain = nil
            return
        }
        tailscaleCheck = Task.detached(priority: .utility) {
            let domain = TailscaleTLS.cli().flatMap { TailscaleTLS.domain(cli: $0) }
            await MainActor.run {
                WebLinks.shared.tailscaleCheck = nil
                WebLinks.shared.certificateDomain = domain
            }
        }
    }

    private func listen() {
        guard let server else { return }
        addresses = WebAddresses.current()
        var tls: [String: sec_identity_t] = [:]
        if let certificate {
            for address in addresses where address.tailscale {
                tls[address.address] = certificate.identity
            }
        }
        server.listen(on: addresses.map(\.address), tls: tls)
    }

    /// Settles for a second first, since joining a network changes the path several times in a row. Tailscale is asked
    /// again only when the addresses changed.
    private func scheduleListen() {
        relisten?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, server != nil else { return }
            let before = addresses
            listen()
            guard addresses != before else { return }
            checkTailscale()
            refreshCertificate()
        }
        relisten = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Removes the folders of links that ended, and nothing that isn't a link's folder.
    private func removeExpired() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Self.folder.path)) ?? [] where Self.isToken(name) {
            let folder = Self.folder.appending(path: name)
            if Self.expired(folder) { try? fm.removeItem(at: folder) }
        }
    }

    /// The first builds kept the links in `Muskey/Links`, among the downloaded songs. Only the links' folders move.
    private func moveOldLinks() {
        let fm = FileManager.default
        let old = Self.folder.deletingLastPathComponent().appending(path: "Links")
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where Self.isToken(name) {
            try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? fm.moveItem(at: old.appending(path: name), to: Self.folder.appending(path: name))
        }
    }

    nonisolated private static func isToken(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    nonisolated private static func expired(_ folder: URL) -> Bool {
        let created = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date ?? .distantPast
        return Date().timeIntervalSince(created) > lifetime
    }

    // MARK: Requests

    nonisolated private static func handle(_ request: WebRequest) async -> WebResponse {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.first == "l" else { return await WebRemote.handle(request) }
        guard request.method == "GET" || request.method == "HEAD" else { return .text("Method not allowed", status: 405) }
        guard parts.count >= 2, isToken(String(parts[1])) else { return .notFound }
        let folder = Self.folder.appending(path: String(parts[1]))
        guard !expired(folder), let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path).first(where: { !$0.hasPrefix(".") })
        else { return .notFound }
        return file(folder.appending(path: name).path, request: request)
    }

    /// A file with its type, an ETag and byte ranges, named for a download by its file name.
    nonisolated static func file(_ path: String, request: WebRequest, extra: [(String, String)] = []) -> WebResponse {
        let name = (path as NSString).lastPathComponent
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return .notFound }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let etag = "\"\(String(size, radix: 16))-\(String(Int(modified), radix: 16))\""

        let ext = (name as NSString).pathExtension.lowercased()
        var headers: [(String, String)] = [
            ("Content-Type", contentType(ext)),
            ("Accept-Ranges", "bytes"),
            ("ETag", etag),
            ("Cache-Control", "private, max-age=3600"),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "no-referrer"),
            ("Content-Disposition", "\(["musicxml", "mid", "xml"].contains(ext) ? "attachment" : "inline"); filename*=UTF-8''\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file")"),
        ] + extra
        if ext == "html" {
            // The sheet carries its scripts and styles inline and asks for nothing from the network.
            headers.append(("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:"))
        }
        if request.headers["range"] == nil, request.headers["if-none-match"] == etag {
            return WebResponse(status: 304, headers: headers.filter { $0.0 != "Content-Type" })
        }
        guard let range = request.headers["range"], request.headers["if-range"].map({ $0 == etag }) ?? true else {
            return WebResponse(status: 200, headers: headers, body: .file(path, nil))
        }
        guard let part = byteRange(range, size: size) else {
            return WebResponse(status: 416, headers: headers + [("Content-Range", "bytes */\(size)")])
        }
        return WebResponse(status: 206, headers: headers + [("Content-Range", "bytes \(part.lowerBound)-\(part.upperBound)/\(size)")],
                           body: .file(path, part))
    }

    /// One range of `bytes=a-b`, `bytes=a-` or `bytes=-n`. Browsers ask for one; a list of them gets the first.
    nonisolated static func byteRange(_ header: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let ends = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard ends.count == 2 else { return nil }
        if ends[0].isEmpty {
            guard let suffix = UInt64(ends[1]), suffix > 0 else { return nil }
            return (size - min(suffix, size)) ... size - 1
        }
        guard let start = UInt64(ends[0]), start < size else { return nil }
        let end = ends[1].isEmpty ? size - 1 : min(UInt64(ends[1]) ?? .max, size - 1)
        return end >= start ? start ... end : nil
    }

    nonisolated static func contentType(_ ext: String) -> String {
        switch ext {
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "pdf": "application/pdf"
        case "html": "text/html; charset=utf-8"
        case "musicxml", "xml": "application/vnd.recordare.musicxml+xml"
        case "mid": "audio/midi"
        case "txt": "text/plain; charset=utf-8"
        case "json": "application/json"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}
