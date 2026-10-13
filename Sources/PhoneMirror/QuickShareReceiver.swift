import Foundation
import Network
import SystemConfiguration

/// Makes this Mac show up in the Quick Share list of Android phones on the same Wi-Fi,
/// and receives what they send.
///
/// This is the one place where the app listens on the network (the owner's decision of
/// 2026-10-12, an exception to "the app opens no ports"). The limits that come with it:
///  - it only runs while "Receive with Quick Share" is switched on in the menu;
///  - only devices on the same local network are let in, never the internet;
///  - nothing is saved until the person clicks Accept, and nothing is ever replaced.
final class QuickShareReceiver: @unchecked Sendable {

    enum Status: Equatable {
        case off
        case starting
        case on(name: String)
        case failed(String)
    }

    struct Options {
        /// The name phones will see for this Mac.
        var name: String
        var saveFolder: URL
        /// false: listen on this Mac only and don't announce anything (used by the tests).
        var onLocalNetwork = true
    }

    /// Quick Share's Bonjour service type: the start of SHA-256("NearbySharing").
    static let serviceType = "_FC9F5ED42C8A._tcp"
    static let maxConnections = 6

    // All four are called on the main thread.
    var onStatus: ((Status) -> Void)?
    var onRequest: ((IncomingShare) -> Void)?
    var onProgress: ((UUID, Int64) -> Void)?
    var onFinished: ((UUID, ShareResult) -> Void)?

    private let queue = DispatchQueue(label: "phonemirror.quickshare", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: QuickShareInbound] = [:]

    /// The port the listener got (nil until it is ready). Used by the tests.
    var port: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    func start(_ options: Options) {
        queue.async { [self] in
            guard listener == nil else { return }
            report(.starting)

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            if !options.onLocalNetwork { parameters.requiredInterfaceType = .loopback }
            guard let listener = try? NWListener(using: parameters) else {
                return report(.failed("macOS didn’t allow listening on the network"))
            }
            if options.onLocalNetwork {
                listener.service = NWListener.Service(
                    name: Self.serviceName(), type: Self.serviceType, domain: nil,
                    txtRecord: NWTXTRecord(["n": EndpointInfo(name: options.name, kind: .computer).encoded.urlSafeBase64]))
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.report(.on(name: options.name))
                case .waiting:
                    self.report(.failed("waiting for a network connection"))
                case .failed:
                    self.closeEverything()
                    self.report(.failed("macOS stopped the listener (is Local Network allowed for Phone Mirror in System Settings → Privacy & Security?)"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, options: options)
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    /// Stops listening and ends every transfer. Half-received files are removed.
    func stop() {
        queue.async { [self] in
            closeEverything()
            report(.off)
        }
    }

    /// Like `stop()`, but waits until it is done (used when the app quits).
    func stopAndWait() {
        queue.sync { closeEverything() }
    }

    func answer(_ id: UUID, accept: Bool) {
        queue.async { [self] in connections[id]?.answer(accept: accept) }
    }

    func stopTransfer(_ id: UUID) {
        queue.async { [self] in connections[id]?.stop() }
    }

    // MARK: On the queue

    private func accept(_ connection: NWConnection, options: Options) {
        guard connections.count < Self.maxConnections else { return connection.cancel() }
        let ownPrefixes = LocalPeer.ownIPv6Prefixes()
        let events = QuickShareInbound.Events(
            ask: { [weak self] share in
                DispatchQueue.main.async { self?.onRequest?(share) }
            },
            progress: { [weak self] id, bytes in
                DispatchQueue.main.async { self?.onProgress?(id, bytes) }
            },
            finished: { [weak self] id, result in
                guard let self else { return }
                self.connections[id] = nil
                if let result { DispatchQueue.main.async { self.onFinished?(id, result) } }
            })
        let inbound = QuickShareInbound(connection: connection, queue: queue, saveFolder: options.saveFolder,
                                        isAllowedPeer: { LocalPeer.isLocal($0, ownIPv6Prefixes: ownPrefixes) },
                                        events: events)
        connections[inbound.id] = inbound
        inbound.start()
    }

    private func closeEverything() {
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) { connection.stop() }
        connections.removeAll()
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    // MARK: Names

    /// The Bonjour name Quick Share expects: ten bytes in URL-safe base64. Byte 0 is a fixed
    /// marker, then four random letters or digits that identify this Mac until the app is
    /// quit, then the first three bytes of the service ID, then two zero bytes.
    static func serviceName() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = [0x23]
        for _ in 0..<4 { bytes.append(alphabet.randomElement(using: &generator)!) }
        bytes += [0xFC, 0x9F, 0x5E, 0, 0]
        return Data(bytes).urlSafeBase64
    }

    /// The Mac's name from System Settings → General → Sharing, e.g. "Sam’s MacBook Air".
    /// Read locally; this is the same name AirDrop shows to others.
    static func macName() -> String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
        return QuickShareInbound.cleanLabel(name, fallback: "Mac")
    }
}

/// Decides whether a device that connected is on the same local network as this Mac.
enum LocalPeer {

    static func isLocal(_ endpoint: NWEndpoint, ownIPv6Prefixes: Set<Data>) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isLocalIPv4([UInt8](address.rawValue))
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return isLocalIPv4([UInt8](mapped.rawValue)) }
            return isLocalIPv6([UInt8](address.rawValue), ownPrefixes: ownIPv6Prefixes)
        default:
            return false
        }
    }

    /// Home and office ranges (10.x, 172.16–31.x, 192.168.x), self-assigned addresses
    /// (169.254.x) and this Mac itself (127.x).
    static func isLocalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31):                            return true
        default:                                        return false
        }
    }

    /// Link-local (fe80::/10) and private (fc00::/7) addresses, this Mac itself (::1), and
    /// addresses that start with the same 64 bits as one of this Mac's own (same network).
    static func isLocalIPv6(_ bytes: [UInt8], ownPrefixes: Set<Data>) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        return ownPrefixes.contains(Data(bytes[0..<8]))
    }

    /// The first 64 bits of each of this Mac's own IPv6 addresses.
    static func ownIPv6Prefixes() -> Set<Data> {
        var prefixes = Set<Data>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return prefixes }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            if bytes.count == 16 { prefixes.insert(Data(bytes[0..<8])) }
        }
        return prefixes
    }
}
