import Foundation
import Network
import os.log
import SystemConfiguration

// A small HTTP/1.1 server on Network.framework for the links that `muskey --link` prints. It listens on the private
// addresses of this Mac (the local network, Tailscale and other VPNs) and never on 0.0.0.0, so nothing outside those
// networks can reach it. Files go out a chunk at a time, with byte ranges, which Safari needs to play audio.

let webLog = Logger(subsystem: "com.lowtechguys.Muskey", category: "Web")

struct WebRequest {
    let method: String
    /// Percent-decoded, without the query.
    let path: String
    let query: [String: String]
    /// Names lowercased.
    let headers: [String: String]
    let body: Data
}

struct WebResponse {
    enum Body {
        case data(Data)
        /// A part of a file, read a chunk at a time.
        case file(String, ClosedRange<UInt64>?)
        case empty
        /// A body with no end, sent through the sink that the closure gets once the headers left, until the phone
        /// closes the connection.
        case stream(@Sendable (WebSink) -> Void)
    }

    var status: Int
    var headers: [(String, String)] = []
    var body: Body = .empty

    static func text(_ text: String, status: Int) -> WebResponse {
        WebResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(text.utf8)))
    }

    static let notFound = text("Not found", status: 404)
}

typealias WebHandler = @Sendable (WebRequest) async -> WebResponse

final class WebServer: @unchecked Sendable {
    init(port: UInt16, handler: @escaping WebHandler) {
        self.port = port
        self.handler = handler
    }

    let port: UInt16

    /// Listens on exactly `addresses`: new ones start and missing ones stop.
    func listen(on addresses: [String]) {
        queue.async { [self] in
            for (address, listener) in listeners where !addresses.contains(address) {
                listener.cancel()
                listeners[address] = nil
            }
            for address in addresses where listeners[address] == nil {
                start(address)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listeners.values.forEach { $0.cancel() }
            listeners.removeAll()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    /// A handful of phones and Macs, with room to spare: a browser opens six connections per address at most.
    private static let maxConnections = 64

    private let handler: WebHandler
    private let queue = DispatchQueue(label: "com.lowtechguys.Muskey.web")
    private var listeners: [String: NWListener] = [:]
    private var connections: [ObjectIdentifier: WebConnection] = [:]

    private func start(_ address: String) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            webLog.error("No listener on \(address, privacy: .public)")
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                webLog.info("Listening on \(address, privacy: .public):\(port.rawValue)")
            case let .failed(error):
                webLog.error("Listener on \(address, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                listener.cancel()
                if listeners[address] === listener { listeners[address] = nil }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            guard connections.count < Self.maxConnections else { return connection.cancel() }
            let client = WebConnection(connection, queue: queue, handler: handler) { [weak self] closed in
                self?.connections[ObjectIdentifier(closed)] = nil
            }
            connections[ObjectIdentifier(client)] = client
            client.start()
        }
        listeners[address] = listener
        listener.start(queue: queue)
    }
}

/// One client connection: requests are read one after another on it, and each answer is sent in full before the next
/// request is read.
private final class WebConnection: @unchecked Sendable {
    init(_ connection: NWConnection, queue: DispatchQueue, handler: @escaping WebHandler, onClose: @escaping (WebConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() { connection.cancel() }

    /// The headers of one request can't be larger than this, and a body sent to the server neither.
    private static let maxHeader = 32 * 1024
    private static let maxBody = 1024 * 1024
    private static let chunk = 256 * 1024
    /// A connection that sends nothing for this long is closed, so a phone that left keeps nothing open.
    private static let idle: TimeInterval = 30

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: WebHandler
    private let onClose: (WebConnection) -> Void
    private var buffer = Data()
    private var closed = false
    private var idleTimer: DispatchWorkItem?

    private func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        connection.cancel()
        onClose(self)
    }

    private func armIdle() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + Self.idle, execute: timer)
    }

    private func receive() {
        guard !closed else { return }
        if let request = parse() { return handle(request) }
        guard !closed else { return }
        armIdle()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            if error != nil || (complete && (data?.isEmpty ?? true)) { return close() }
            if buffer.count > Self.maxHeader + Self.maxBody { return close() }
            receive()
        }
    }

    /// A whole request from the start of the buffer, which is removed from it, or nil while more bytes are needed.
    private func parse() -> WebRequest? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeader { close() }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex ..< end.lowerBound], encoding: .utf8) else {
            close()
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3 else {
            close()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard (0 ... Self.maxBody).contains(length) else {
            close()
            return nil
        }
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyStart = end.upperBound
        let body = Data(buffer[bodyStart ..< buffer.index(bodyStart, offsetBy: length)])
        buffer = Data(buffer[buffer.index(bodyStart, offsetBy: length)...])

        let target = String(parts[1])
        let pathPart = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        var query: [String: String] = [:]
        if let queryPart = target.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in queryPart.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
                guard let name = kv.first, !name.isEmpty else { continue }
                query[name] = kv.count > 1 ? kv[1] : ""
            }
        }
        return WebRequest(method: String(parts[0]), path: pathPart.removingPercentEncoding ?? pathPart, query: query, headers: headers, body: body)
    }

    private func handle(_ request: WebRequest) {
        idleTimer?.cancel()
        let keepAlive = request.headers["connection"]?.lowercased() != "close"
        let handler = handler
        Task {
            let response = await handler(request)
            queue.async { [weak self] in self?.send(response, head: request.method == "HEAD", keepAlive: keepAlive) }
        }
    }

    private func send(_ response: WebResponse, head: Bool, keepAlive: Bool) {
        guard !closed else { return }
        var headers = response.headers
        var length: UInt64 = 0
        var file: (FileHandle, UInt64)?
        switch response.body {
        case let .data(data):
            length = UInt64(data.count)
        case let .file(path, range):
            guard let handle = FileHandle(forReadingAtPath: path) else { return send(.notFound, head: head, keepAlive: keepAlive) }
            let size = (try? handle.seekToEnd()) ?? 0
            let part = range ?? 0 ... max(size, 1) - 1
            length = size == 0 ? 0 : part.upperBound - part.lowerBound + 1
            try? handle.seek(toOffset: part.lowerBound)
            file = (handle, length)
        case .empty:
            break
        case let .stream(start):
            return sendStream(response, start: start)
        }
        headers.append(("Content-Length", String(length)))
        headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        var text = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if !head, case let .data(body) = response.body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? file?.0.close()
                return close()
            }
            if let file, !head {
                pump(file.0, remaining: file.1, keepAlive: keepAlive)
            } else {
                try? file?.0.close()
                finish(keepAlive: keepAlive)
            }
        })
    }

    /// The headers of a body with no length, then the sink, which sends until the phone closes the connection. A read
    /// that ends tells that the phone closed it.
    private func sendStream(_ response: WebResponse, start: @escaping @Sendable (WebSink) -> Void) {
        var text = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers + [("Connection", "close")] { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        let sink = WebSink(connection: connection, queue: queue) { [weak self] in self?.close() }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return sink.close() }
            watchForEnd(sink)
            start(sink)
        })
    }

    private func watchForEnd(_ sink: WebSink) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            if error != nil || complete || data == nil { return sink.close() }
            self?.watchForEnd(sink)
        }
    }

    /// Sends the next chunk of a file once the one before it left, so a slow phone never makes the Mac read ahead.
    private func pump(_ handle: FileHandle, remaining: UInt64, keepAlive: Bool) {
        guard remaining > 0 else {
            try? handle.close()
            return finish(keepAlive: keepAlive)
        }
        let data = (try? handle.read(upToCount: Int(min(UInt64(Self.chunk), remaining)))) ?? Data()
        guard !data.isEmpty else {
            try? handle.close()
            return close()
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                return close()
            }
            pump(handle, remaining: remaining - UInt64(data.count), keepAlive: keepAlive)
        })
    }

    private func finish(keepAlive: Bool) {
        keepAlive ? receive() : close()
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 303: "See Other"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        default: "Error"
        }
    }
}

/// Where a body with no end is sent: the audio stream of the web remote. Any thread.
final class WebSink: @unchecked Sendable {
    init(connection: NWConnection, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.onClose = onClose
    }

    /// Called once, on the connection's queue, when the phone closed the connection or fell behind.
    var ended: (() -> Void)? {
        get { lock.withLock { endedHandler } }
        set { lock.withLock { endedHandler = newValue } }
    }

    var closed: Bool { lock.withLock { isClosed } }

    /// Sends the bytes, or ends the response when more than `limit` bytes still wait to leave, since the phone then
    /// fell too far behind to catch up.
    func send(_ data: Data, limit: Int = 2_000_000) {
        let fresh = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            pending += data.count
            return pending <= limit
        }
        guard fresh else { return close() }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            lock.withLock { self.pending -= data.count }
            if error != nil { close() }
        })
    }

    func close() {
        let handler = lock.withLock { () -> (() -> Void)? in
            guard !isClosed else { return nil }
            isClosed = true
            defer { endedHandler = nil }
            return endedHandler
        }
        guard !closedOnce() else { return }
        queue.async { [onClose] in
            handler?()
            onClose()
        }
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClose: () -> Void
    private let lock = NSLock()
    private var isClosed = false
    private var finished = false
    private var pending = 0
    private var endedHandler: (() -> Void)?

    /// The close runs once, though the read that ends and a failed send can both call it.
    private func closedOnce() -> Bool {
        lock.withLock {
            defer { finished = true }
            return finished
        }
    }
}

// MARK: Addresses

enum WebAddresses {
    struct Address: Equatable {
        let address: String
        let interface: String
        /// Tailscale's, which reaches this Mac from anywhere its devices are.
        let tailscale: Bool

        var host: String { address.contains(":") ? "[\(address)]" : address }
    }

    /// The defaults key of the host that Settings > Remote > Address picked, as it goes in a URL. Absent means Automatic.
    static let choiceKey = "remoteAddress"
    static var choice: String? { UserDefaults.standard.string(forKey: choiceKey)?.lowercased() }

    /// The names that a request's Host may carry: the Mac's addresses, localhost, and the DNS name picked in Settings,
    /// exactly that one. Any other name is refused, so that a web page elsewhere can't reach the remote through a DNS
    /// name that resolves to the Mac.
    static func allowedHosts() -> [String] {
        var hosts = current().map(\.address) + ["localhost"]
        if let choice, isName(choice) { hosts.append(choice) }
        return hosts
    }

    /// The host that the pairing link and the links of `muskey --link` carry: the one picked in Settings while it reaches
    /// this Mac, or else Tailscale's address, then the local network's. A picked address that went away is kept for
    /// when it comes back.
    static func linkHost() -> String? {
        let addresses = current()
        if let choice {
            if isName(choice) {
                // A Tailscale name leads here only while Tailscale is up.
                if !choice.hasSuffix(".ts.net") || addresses.contains(where: \.tailscale) { return choice }
            } else if addresses.contains(where: { $0.host.lowercased() == choice }) {
                return choice
            }
        }
        return (addresses.first(where: { !$0.interface.hasPrefix("lo") }) ?? addresses.first)?.host
    }

    /// A DNS name, as opposed to an IPv4 or IPv6 address.
    static func isName(_ host: String) -> Bool {
        guard !host.contains(":"), !host.hasPrefix("[") else { return false }
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) != 1
    }

    /// One way that another device reaches this Mac, for Settings > Remote > Address: an address, or a DNS name that
    /// leads back to one.
    struct Choice: Hashable, Identifiable {
        /// As it goes in a URL: a name, an IPv4 address, or an IPv6 one in brackets.
        let host: String
        /// The network and the host, like `Wi-Fi · 192.168.1.5`.
        let title: String
        var id: String { host }
    }

    /// Each address with the name of its network, after the DNS name that leads back to it, then the Mac's local
    /// hostname. With `lookUp`, it waits on the network's DNS for the names, so it runs off the main thread then.
    static func choices(lookUp: Bool) -> [Choice] {
        let addresses = current().filter { !$0.interface.hasPrefix("lo") }
        let interfaces = interfaceNames()
        let vpns = vpnNames()
        let ours = Set(addresses.map(\.address))
        var choices: [Choice] = []
        for address in addresses {
            let label: String = if address.tailscale {
                "Tailscale"
            } else if ["utun", "ipsec", "ppp"].contains(where: { address.interface.hasPrefix($0) }) {
                vpns[address.interface] ?? "VPN"
            } else {
                interfaces[address.interface] ?? address.interface
            }
            // A name counts only when it leads back to one of these addresses, since DNS can keep a name for an
            // address that moved, and only with a dot, since a bare name may resolve on this Mac alone.
            if lookUp, let name = reverseLookup(address.address), name.contains("."), !name.hasSuffix(".arpa"),
               !forwardLookup(name).isDisjoint(with: ours), !choices.contains(where: { $0.host == name })
            {
                choices.append(Choice(host: name, title: "\(label) · \(name)"))
            }
            choices.append(Choice(host: address.host.lowercased(), title: "\(label) · \(address.address)"))
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty {
            let name = "\(local).local".lowercased()
            if !choices.contains(where: { $0.host == name }) { choices.append(Choice(host: name, title: "Local hostname · \(name)")) }
        }
        return choices
    }

    /// The names that System Settings > Network gives the interfaces, like Wi-Fi and Ethernet, by BSD name.
    private static func interfaceNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = name
            }
        }
        return names
    }

    /// The name of each connected VPN as System Settings > VPN shows it, by tunnel interface.
    private static func vpnNames() -> [String: String] {
        let patterns = ["State:/Network/Service/[^/]+/IPv[46]", "Setup:/Network/Service/[^/]+", "Setup:/Network/Service/[^/]+/Interface"]
        guard let store = SCDynamicStoreCreate(nil, "Muskey" as CFString, nil, nil),
              let values = SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray) as? [String: Any]
        else { return [:] }
        var names: [String: String] = [:]
        for (key, value) in values where key.hasPrefix("State:") {
            let parts = key.split(separator: "/")
            guard parts.count == 5, let interface = (value as? [String: Any])?["InterfaceName"] as? String else { continue }
            let setup = "Setup:/Network/Service/\(parts[3])"
            let provider = (values[setup + "/Interface"] as? [String: Any])?["SubType"] as? String ?? ""
            if provider.hasPrefix("io.tailscale.") {
                names[interface] = "Tailscale"
            } else if let name = (values[setup] as? [String: Any])?["UserDefinedName"] as? String, !name.isEmpty {
                names[interface] = name
            }
        }
        return names
    }

    private static func reverseLookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = String(cString: host).lowercased()
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    private static func forwardLookup(_ name: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(info) }
        var found = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.insert(String(cString: host))
            }
        }
        return found
    }

    /// The private addresses that a browser on the same network or VPN can reach: RFC 1918, link-local IPv4, the
    /// 100.64/10 range on a tunnel (Tailscale and other VPNs), IPv6 unique-local, and 127.0.0.1. The most useful first:
    /// Tailscale, then Wi-Fi or Ethernet, then other VPNs, then this Mac.

    static func current() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(address: String, interface: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let sa = entry.ifa_addr else { continue }
            let interface = String(cString: entry.ifa_name)
            // AirDrop's and iPhone Mirroring's links, which no browser reaches.
            guard !["awdl", "llw", "anpi", "ap"].contains(where: { interface.hasPrefix($0) }) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let v = UInt32(bigEndian: addr.s_addr)
                let tunnelRange = v >> 22 == 0x191
                let isPrivate = v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8 || v >> 16 == 0xA9FE || v == 0x7F00_0001 || tunnelRange
                // 100.64/10 is a VPN's on a tunnel, but a carrier's shared space on Wi-Fi or Ethernet, with strangers in it.
                guard isPrivate, !tunnelRange || interface.hasPrefix("utun") else { continue }
                inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
            case AF_INET6:
                var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                // Unique-local only (fc00::/7): link-local needs a zone that no link can carry, and a global address may be
                // reachable from anywhere.
                guard addr.__u6_addr.__u6_addr8.0 & 0xFE == 0xFC else { continue }
                inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count))
            default:
                continue
            }
            let address = String(cString: text)
            if !found.contains(where: { $0.address == address }) { found.append((address, interface)) }
        }
        // A tunnel that carries a Tailscale IPv6 address is Tailscale's, and so is its 100.x address.
        let tailscale = Set(found.filter { $0.address.hasPrefix("fd7a:115c:a1e0:") }.map(\.interface))
        return found
            .map { Address(address: $0.address, interface: $0.interface, tailscale: tailscale.contains($0.interface)) }
            .sorted { rank($0) < rank($1) }
    }

    private static func rank(_ address: Address) -> Int {
        let v6 = address.address.contains(":") ? 1 : 0
        if address.tailscale { return 0 + v6 }
        if address.interface.hasPrefix("en") { return 2 + v6 }
        if address.interface.hasPrefix("lo") { return 6 }
        return 4 + v6
    }
}
