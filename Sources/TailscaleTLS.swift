import Foundation
import Network
import os
import Security

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "TailscaleTLS")

// HTTPS for the web remote on a tailnet. A tailnet with HTTPS certificates turned on gives each Mac a Let's Encrypt
// certificate for its MagicDNS name, which Tailscale hands over (and renews when it runs close to expiry). Served on
// the Tailscale addresses, it makes the page a secure context, which a service worker and installing the page as an
// app on Android or in Chrome both need. The local network stays plain HTTP: no public certificate can name a 192.168
// address.

enum TailscaleTLS {
    struct Certificate: @unchecked Sendable {
        let domain: String
        let identity: sec_identity_t
        /// The leaf's bytes, to tell a renewed certificate from the one already served.
        let leaf: Data
    }

    /// The CLI is the app's own binary (what /usr/local/bin/tailscale runs), or Homebrew's for the open-source build.
    static func cli() -> String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This Mac's MagicDNS name, when the tailnet issues certificates for it.
    static func domain(cli: String) -> String? {
        guard let output = ask(cli, "/localapi/v0/status?peers=false", or: ["status", "--json", "--peers=false"], timeout: 10),
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              var name = me["DNSName"] as? String
        else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        name = name.lowercased()
        return (json["CertDomains"] as? [String] ?? []).map { $0.lowercased() }.contains(name) ? name : nil
    }

    /// The certificate and its key as an identity held in this process only, never added to a keychain (which would
    /// ask for access again after every update, since each build signs differently).
    static func certificate(cli: String, domain: String) -> Certificate? {
        // A first certificate takes Let's Encrypt a minute at most; a cached one comes back at once.
        guard let output = ask(cli, "/localapi/v0/cert/\(domain)?type=pair", or: ["cert", "--cert-file", "-", "--key-file", "-", domain], timeout: 120),
              let pem = String(data: output, encoding: .utf8)
        else {
            log.error("No certificate from Tailscale for \(domain, privacy: .public)")
            return nil
        }
        // The CLI writes the chain and then the key, the local API the key first. The key is EC, or PKCS#8 on other
        // setups.
        let blocks = pemBlocks(pem)
        let chain = blocks.filter { $0.hasPrefix("-----BEGIN CERTIFICATE-----") }.joined(separator: "\n")
        guard !chain.isEmpty, let key = blocks.first(where: { $0.contains("PRIVATE KEY-----") }), let p12 = pkcs12(chain: chain, key: key) else {
            log.error("No certificate and key in what Tailscale sent for \(domain, privacy: .public)")
            return nil
        }

        var items: CFArray?
        let options = [kSecImportExportPassphrase: p12.password, kSecImportToMemoryOnly: true] as CFDictionary
        guard SecPKCS12Import(p12.data as CFData, options, &items) == errSecSuccess,
              let item = (items as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String],
              let certificates = item[kSecImportItemCertChain as String] as? [SecCertificate],
              let leaf = certificates.first
        else {
            log.error("Couldn't load the Tailscale certificate for \(domain, privacy: .public)")
            return nil
        }
        let identity = identityValue as! SecIdentity
        // The leaf comes from the identity; the rest is the chain that browsers need to reach a root they trust (an
        // iPhone fetches no missing intermediates).
        guard let secIdentity = sec_identity_create_with_certificates(identity, Array(certificates.dropFirst()) as CFArray) else { return nil }
        return Certificate(domain: domain, identity: secIdentity, leaf: SecCertificateCopyData(leaf) as Data)
    }

    /// openssl reads the key and the chain from separate files, so they sit for a moment in a folder only this user can
    /// read, and the archive's password is passed through the environment rather than the arguments that `ps` shows.
    private static func pkcs12(chain: String, key: String) -> (data: Data, password: String)? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("muskey-tls-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        let chainFile = folder.appendingPathComponent("chain.pem")
        let keyFile = folder.appendingPathComponent("key.pem")
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              fm.createFile(atPath: chainFile.path, contents: Data(chain.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        else { return nil }

        let password = WebRemote.randomHex()
        guard let data = run(
            "/usr/bin/openssl",
            ["pkcs12", "-export", "-in", chainFile.path, "-inkey", keyFile.path, "-passout", "env:MUSKEY_P12"],
            environment: ["MUSKEY_P12": password],
            timeout: 20
        ), !data.isEmpty else {
            log.error("openssl couldn't package the Tailscale certificate")
            return nil
        }
        return (data, password)
    }

    /// Each `-----BEGIN …-----` to `-----END …-----` block, whole.
    private static func pemBlocks(_ pem: String) -> [String] {
        var blocks: [String] = []
        var rest = pem[...]
        while let begin = rest.range(of: "-----BEGIN "),
              let endMarker = rest.range(of: "-----END ", range: begin.upperBound ..< rest.endIndex),
              let close = rest.range(of: "-----", range: endMarker.upperBound ..< rest.endIndex)
        {
            blocks.append(String(rest[begin.lowerBound ..< close.upperBound]) + "\n")
            rest = rest[close.upperBound...]
        }
        return blocks
    }

    /// Tailscale's local API, the one its CLI talks to, asked first, and the CLI after it.
    private static func ask(_ cli: String, _ path: String, or arguments: [String], timeout: TimeInterval) -> Data? {
        // The App Store app's binary acts as a CLI only when it is told to, or when it finds a terminal's TERM. Started
        // by an app, it tries to reach the Tailscale app instead, prints "The Tailscale GUI failed to start" and still
        // exits with 0.
        localAPI(path, timeout: timeout) ?? run(cli, arguments, environment: ["TAILSCALE_BE_CLI": "1"], timeout: timeout)
    }

    /// The standalone Tailscale app serves its local API on 127.0.0.1, at the port that `/Library/Tailscale/ipnport`
    /// names, to anyone who can read the token next to it (admins). Nil for the App Store app and the open-source
    /// build, which keep it elsewhere, and on any answer but 200. A plain socket rather than URLSession, which App
    /// Transport Security would hold to HTTPS.
    private static func localAPI(_ path: String, timeout: TimeInterval) -> Data? {
        guard let portName = try? FileManager.default.destinationOfSymbolicLink(atPath: "/Library/Tailscale/ipnport"),
              let port = UInt16(portName),
              let token = (try? String(contentsOfFile: "/Library/Tailscale/sameuserproof-\(port)", encoding: .utf8))?
              .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return nil }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }

        let auth = Data(":\(token)".utf8).base64EncodedString()
        let request = Array("GET \(path) HTTP/1.0\r\nHost: local-tailscaled.sock\r\nAuthorization: Basic \(auth)\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == request.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while response.count < 8_000_000 {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { break }
            response.append(buffer, count: count)
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let status = String(data: response[..<split.lowerBound], encoding: .utf8)?.split(separator: " ", maxSplits: 2),
              status.count >= 2, status[1] == "200"
        else { return nil }
        return Data(response[split.upperBound...])
    }

    /// Runs a tool with `environment` added to Muskey's own, and gives its output when it exits with 0 within
    /// `timeout`.
    private static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("Couldn't run \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
