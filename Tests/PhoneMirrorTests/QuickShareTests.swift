import CryptoKit
import Foundation
import Network
import Testing

@testable @preconcurrency import PhoneMirror

// "Receive with Quick Share" is tested with two pretend phones, never a real one:
//  - `PretendPhone` below, written in Swift with the app's own building blocks;
//  - Tools/quickshare_fake_phone.py, written separately in Python with Google's own message
//    definitions and a different encryption library. Those tests run only after the one-time
//    setup described at the top of that file (otherwise they pass without doing anything).
// Both connect to a receiver that listens on this Mac only and announces nothing.

// MARK: The message format

@Test func numbersAndTextAreWrittenTheWayProtocolBuffersDefinesThem() throws {
    // The two examples from Google's own documentation of the format.
    #expect(ProtoWriter.build { $0.number(1, 150) } == Data([0x08, 0x96, 0x01]))
    #expect(ProtoWriter.build { $0.string(2, "testing") } == Data([0x12, 0x07] + Array("testing".utf8)))
    // A negative number takes ten bytes.
    #expect(ProtoWriter.build { $0.number(1, signed: -1) } == Data([0x08] + Array(repeating: 0xFF, count: 9) + [0x01]))

    let message = try ProtoMessage(ProtoWriter.build {
        $0.number(1, signed: -5_000_000_000)
        $0.string(2, "héllo")
        $0.message(3) { $0.bool(1, true) }
        $0.bytes(4, Data([1, 2, 3]))
        $0.bytes(4, Data([4]))
    })
    #expect(message.int64(1) == -5_000_000_000)
    #expect(message.string(2) == "héllo")
    #expect(try message.message(3)?.bool(1) == true)
    #expect(message.bytes(4) == Data([4]))
    #expect(message.count(of: 4) == 2)
    #expect(message.number(9) == nil)
}

@Test func brokenMessagesAreRefused() {
    let broken: [[UInt8]] = [
        [0x08],                                  // a number that never comes
        [0x12, 0x05, 0x01],                      // says 5 bytes, has 1
        [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], // a number that never ends
        [0x0B],                                  // a kind of field this format no longer uses
        [0x00, 0x01],                            // field number 0
        [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F],    // says 4 GB follow
    ]
    for bytes in broken {
        #expect(throws: ProtoMessage.Malformed.self) { try ProtoMessage(Data(bytes)) }
    }
}

@Test func theFixedValuesMatchThePublishedProtocol() {
    func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }
    // The service type phones look for is the start of SHA-256("NearbySharing").
    #expect(QuickShareReceiver.serviceType == "_" + sha256("NearbySharing").prefix(12) + "._tcp")
    // The two salts used when deriving keys, as given in the protocol notes.
    #expect(sha256("D2D") == "82AA55A0D397F88346CA1CEE8D3909B95F13FA7DEB1D4AB38376B8256DA85510")
    #expect(sha256("SecureMessage") == "BF9D2A53C63616D75DB0A7165B91C1EF73E537F2427405FA23610A4BE657642E")

    // The Bonjour name: a marker, four letters or digits, the service ID, two zero bytes.
    let name = [UInt8](Data(urlSafeBase64: QuickShareReceiver.serviceName()) ?? Data())
    #expect(name.count == 10)
    #expect(name.first == 0x23)
    #expect(name[1...4].allSatisfy { Character(UnicodeScalar($0)).isLetter || Character(UnicodeScalar($0)).isNumber })
    #expect(Array(name[5...]) == [0xFC, 0x9F, 0x5E, 0, 0])
}

@Test func deviceDescriptionsAreReadAndWritten() throws {
    let mac = EndpointInfo(name: "Sam’s MacBook Air", kind: .computer)
    let bytes = mac.encoded
    #expect(bytes.first == 3 << 1)
    #expect(bytes.count == 1 + 16 + 1 + mac.name.utf8.count)
    #expect(EndpointInfo(bytes) == mac)

    // A phone that hides its name sets a flag and leaves the name out.
    let hidden = EndpointInfo(Data([0x10 | (1 << 1)] + Array(repeating: UInt8(7), count: 16)))
    #expect(hidden == EndpointInfo(name: "", kind: .phone))
    // Cut short, or a name that is longer than what is there.
    #expect(EndpointInfo(Data([2, 1, 2, 3])) == nil)
    #expect(EndpointInfo(Data([2] + Array(repeating: UInt8(0), count: 16) + [9, 65])) == nil)
    // A very long name is cut without splitting a character.
    let long = EndpointInfo(name: String(repeating: "é", count: 200), kind: .computer)
    #expect(EndpointInfo(long.encoded)?.name == String(repeating: "é", count: 127))
}

@Test func keyNumbersAreWrittenLikeAndroidWritesThem() {
    let high = Data([0x80] + Array(repeating: UInt8(1), count: 31))
    #expect(QuickShareHandshake.javaNumber(high) == Data([0]) + high)          // top bit set: a zero in front
    let low = Data([0x00, 0x00, 0x7F] + Array(repeating: UInt8(1), count: 29))
    #expect(QuickShareHandshake.javaNumber(low) == Data(low.dropFirst(2)))      // leading zeros dropped
    #expect(QuickShareHandshake.fieldBytes(Data([0]) + high) == high)
    #expect(QuickShareHandshake.fieldBytes(Data(low.dropFirst(2))) == low)
    #expect(QuickShareHandshake.fieldBytes(Data(repeating: 1, count: 33)) == nil)
}

@Test func bothEndsOfAKeyExchangeAgree() throws {
    let phone = QuickShareHandshake(), mac = QuickShareHandshake()
    let hello = Data("client init".utf8), reply = Data("server init".utf8)
    var phoneSide = try phone.finish(peerKeyMessage: mac.publicKeyMessage, clientInit: hello, serverInit: reply, asServer: false)
    var macSide = try mac.finish(peerKeyMessage: phone.publicKeyMessage, clientInit: hello, serverInit: reply, asServer: true)
    #expect(phoneSide.code == macSide.code)
    #expect(phoneSide.code.count == 4)

    let first = try phoneSide.seal(Data("one".utf8))
    let second = try phoneSide.seal(Data("two".utf8))
    #expect(try macSide.open(first) == Data("one".utf8))
    // The same message again is refused (it has an old number), and so is a changed one.
    #expect(throws: SecureChannel.Failed.self) { try macSide.open(first) }
    var changed = second
    changed[changed.count - 1] ^= 1
    #expect(throws: SecureChannel.Failed.self) { try macSide.open(changed) }
    // A message this side wrote itself can't be passed back to it either.
    let own = try macSide.seal(Data("mine".utf8))
    #expect(throws: SecureChannel.Failed.self) { try macSide.open(own) }

    // Someone who saw different opening messages ends up with different keys.
    var other = try mac.finish(peerKeyMessage: phone.publicKeyMessage, clientInit: Data("changed".utf8), serverInit: reply, asServer: true)
    #expect(throws: SecureChannel.Failed.self) { try other.open(first) }
    // A key that isn't a point on the curve is refused.
    let bad = ProtoWriter.build { key in
        key.number(1, 1)
        key.message(2) {
            $0.bytes(1, Data(repeating: 1, count: 32))
            $0.bytes(2, Data(repeating: 2, count: 32))
        }
    }
    #expect(throws: Ukey2.Refused.self) {
        try mac.finish(peerKeyMessage: bad, clientInit: hello, serverInit: reply, asServer: true)
    }
}

// MARK: What a phone sends is cleaned first

@Test func fileNamesFromAPhoneAreMadeSafe() {
    let clean = QuickShareInbound.cleanFileName
    #expect(clean("photo.jpg") == "photo.jpg")
    #expect(clean("../../.zshrc") == "zshrc")
    #expect(clean("/etc/passwd") == "passwd")
    #expect(clean("C:\\Users\\me\\report.pdf") == "report.pdf")
    #expect(clean("..") == "file")
    #expect(clean("") == "file")
    #expect(clean(" . .hidden ") == "hidden")
    #expect(clean("re:port.pdf") == "re-port.pdf")
    #expect(clean("two\nlines\u{0}.txt") == "twolines.txt")
    #expect(clean("photo\u{202E}gpj.exe") == "photogpj.exe") // no text-direction tricks
    let long = clean(String(repeating: "a", count: 400) + ".jpeg")
    #expect(long.utf8.count == 200)
    #expect(long.hasSuffix(".jpeg"))
    #expect(Validation.isSafeFileName(clean("a/b/../c\u{7F}d.txt")))

    #expect(QuickShareInbound.cleanLabel("  Pixel\n8\u{202E} ", fallback: "x") == "Pixel 8")
    #expect(QuickShareInbound.cleanLabel("\u{200B}", fallback: "A nearby device") == "A nearby device")
    #expect(QuickShareInbound.cleanLabel(String(repeating: "n", count: 300), fallback: "x").count == 60)
}

@Test func onlyDevicesOnTheLocalNetworkAreLetIn() {
    func v4(_ text: String) -> Bool {
        LocalPeer.isLocal(.hostPort(host: .ipv4(IPv4Address(text)!), port: 1234), ownIPv6Prefixes: [])
    }
    #expect(v4("192.168.1.20"))
    #expect(v4("10.0.0.7"))
    #expect(v4("172.20.10.2"))
    #expect(v4("169.254.3.4"))
    #expect(v4("127.0.0.1"))
    #expect(!v4("172.32.0.1"))
    #expect(!v4("8.8.8.8"))
    #expect(!v4("100.64.0.1"))

    let own: Set<Data> = [Data([0x20, 0x01, 0x0D, 0xB8, 0, 1, 0, 2])]
    func v6(_ text: String) -> Bool {
        LocalPeer.isLocal(.hostPort(host: .ipv6(IPv6Address(text)!), port: 1234), ownIPv6Prefixes: own)
    }
    #expect(v6("fe80::1"))
    #expect(v6("fd12:3456::9"))
    #expect(v6("::1"))
    #expect(v6("2001:db8:1:2::55"))            // same first 64 bits as this Mac
    #expect(!v6("2001:db8:1:3::55"))           // a different network
    #expect(!v6("2606:4700::1111"))
    #expect(v6("::ffff:192.168.1.5"))          // an IPv4 address written the IPv6 way
    #expect(!v6("::ffff:8.8.8.8"))
    #expect(!LocalPeer.isLocal(.hostPort(host: .name("example.com", nil), port: 80), ownIPv6Prefixes: own))
}

// MARK: A whole share, against a pretend phone

/// The receiving side, as the app sets it up, with a temporary folder instead of Downloads.
@MainActor
private final class TestMac {
    let receiver = QuickShareReceiver()
    let folder: URL
    var asked: [IncomingShare] = []
    var results: [ShareResult] = []
    var progress: [Int64] = []
    var status = QuickShareReceiver.Status.off
    /// What to answer when a phone offers something (nil: leave the question open).
    var answer: Bool? = true

    init() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phonemirror-quickshare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        receiver.onStatus = { status in MainActor.assumeIsolated { self.status = status } }
        receiver.onRequest = { share in
            MainActor.assumeIsolated {
                self.asked.append(share)
                if let answer = self.answer { self.receiver.answer(share.id, accept: answer) }
            }
        }
        receiver.onProgress = { _, bytes in MainActor.assumeIsolated { self.progress.append(bytes) } }
        receiver.onFinished = { _, result in MainActor.assumeIsolated { self.results.append(result) } }
        receiver.start(.init(name: "Test Mac", saveFolder: folder, onLocalNetwork: false))
        try await waitUntil { self.status == .on(name: "Test Mac") }
        try #require(status == .on(name: "Test Mac"))
    }

    var port: UInt16 { receiver.port ?? 0 }

    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func data(_ name: String) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(name))
    }

    func close() {
        receiver.stopAndWait()
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let start = Date()
    while !condition(), Date().timeIntervalSince(start) < 15 {
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A pretend phone made from the app's own building blocks, talking over a plain socket.
private final class PretendPhone: @unchecked Sendable {
    struct Closed: Error {}

    private let socket: Int32
    private var channel: SecureChannel?
    private var files: [(id: Int64, data: Data)] = []
    private var textID: Int64?
    var code: String { channel?.code ?? "" }

    init(port: UInt16, name: String = "Pixel 8") throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Writing to a connection the Mac has already closed must fail quietly, not stop the whole test run.
        var quiet: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Closed() }
        try handshake(name: name)
    }

    deinit { Darwin.close(socket) }

    func hangUp() { shutdown(socket, SHUT_RDWR) }

    // The wire: four bytes of length, then the message.

    func sendRaw(_ data: Data) throws {
        var packet = Data([UInt8(truncatingIfNeeded: data.count >> 24), UInt8(truncatingIfNeeded: data.count >> 16),
                           UInt8(truncatingIfNeeded: data.count >> 8), UInt8(truncatingIfNeeded: data.count)])
        packet.append(data)
        var sent = 0
        while sent < packet.count {
            let count = packet.withUnsafeBytes { Darwin.send(socket, $0.baseAddress! + sent, packet.count - sent, 0) }
            guard count > 0 else { throw Closed() }
            sent += count
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let piece = data.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress! + got, count - got, 0) }
            guard piece > 0 else { throw Closed() }
            got += piece
        }
        return data
    }

    func readRaw() throws -> Data {
        let length = try read(4).reduce(0) { $0 << 8 | Int($1) }
        return try read(length)
    }

    private func handshake(name: String) throws {
        try sendRaw(OfflineFrame.connectionRequest(endpointID: "TEST", info: EndpointInfo(name: name, kind: .phone).encoded).encoded)
        let handshake = QuickShareHandshake()
        let finish = Ukey2.clientFinish(publicKey: handshake.publicKeyMessage)
        let hello = Ukey2.clientInit(random: .random(32), commitment: Data(SHA512.hash(data: finish)))
        try sendRaw(hello)
        let reply = try readRaw()
        let serverInit = try Ukey2.open(reply, expecting: .serverInit)
        try sendRaw(finish)
        channel = try handshake.finish(peerKeyMessage: serverInit.bytes(4) ?? Data(), clientInit: hello,
                                       serverInit: reply, asServer: false)
        try sendRaw(OfflineFrame.connectionResponse(accepted: true).encoded)
        guard case .connectionResponse(accepted: true) = try OfflineFrame(readRaw()) else { throw Closed() }
    }

    // The encrypted layer.

    func send(_ frame: OfflineFrame) throws {
        try sendRaw(channel!.seal(frame.encoded))
    }

    func readFrame() throws -> OfflineFrame {
        try OfflineFrame(channel!.open(readRaw()))
    }

    func send(_ frame: SharingFrame) throws {
        let data = frame.encoded
        let id = Int64.random(in: .min ... .max)
        try send(.payload(.init(id: id, kind: .bytes, totalSize: Int64(data.count), offset: 0, isLast: false, body: data)))
        try send(.payload(.init(id: id, kind: .bytes, totalSize: Int64(data.count), offset: Int64(data.count), isLast: true, body: Data())))
    }

    /// The next sharing message from the Mac (keep-alives are answered and skipped).
    func readSharing() throws -> SharingFrame {
        var buffer = Data()
        while true {
            switch try readFrame() {
            case .payload(let piece):
                buffer.append(piece.body)
                if piece.isLast { return try SharingFrame(buffer) }
            case .keepAlive(let ack):
                if !ack { try send(.keepAlive(ack: true)) }
            case .disconnection:
                throw Closed()
            default:
                break
            }
        }
    }

    /// Everything up to the Mac's answer.
    func offer(files offered: [(name: String, data: Data)] = [], text: (String, SharingFrame.TextOffer.Kind)? = nil,
               announcing sizes: [Int64]? = nil) throws -> SharingFrame.Answer {
        try send(SharingFrame.pairedKeyEncryption)
        guard case .pairedKeyEncryption = try readSharing() else { throw Closed() }
        try send(SharingFrame.pairedKeyResult)
        guard case .pairedKeyResult = try readSharing() else { throw Closed() }

        var introduction = SharingFrame.Introduction()
        for (index, file) in offered.enumerated() {
            let id = Int64.random(in: .min ... .max)
            files.append((id, file.data))
            introduction.files.append(.init(name: file.name, payloadID: id, size: sizes?[index] ?? Int64(file.data.count)))
        }
        if let text {
            let id = Int64.random(in: .min ... .max)
            textID = id
            introduction.texts.append(.init(title: String(text.0.prefix(20)), kind: text.1, payloadID: id,
                                            size: Int64(text.0.utf8.count)))
        }
        try send(SharingFrame.introduction(introduction))
        guard case .response(let answer) = try readSharing() else { throw Closed() }
        return answer
    }

    func sendFiles(pieceSize: Int = 64 * 1024, stopAfterPieces: Int? = nil) throws {
        var pieces = 0
        for file in files {
            var offset = 0
            while offset < file.data.count {
                if let stopAfterPieces, pieces >= stopAfterPieces { return }
                let body = Data(file.data[offset..<min(offset + pieceSize, file.data.count)])
                try send(.payload(.init(id: file.id, kind: .file, totalSize: Int64(file.data.count), offset: Int64(offset),
                                        isLast: false, body: body)))
                offset += body.count
                pieces += 1
            }
            try send(.payload(.init(id: file.id, kind: .file, totalSize: Int64(file.data.count), offset: Int64(offset),
                                    isLast: true, body: Data())))
        }
    }

    func sendText(_ text: String) throws {
        let data = Data(text.utf8)
        guard let textID else { throw Closed() }
        try send(.payload(.init(id: textID, kind: .bytes, totalSize: Int64(data.count), offset: 0, isLast: false, body: data)))
        try send(.payload(.init(id: textID, kind: .bytes, totalSize: Int64(data.count), offset: Int64(data.count), isLast: true, body: Data())))
    }

    /// The Mac says goodbye once everything has arrived.
    func waitForGoodbye() throws {
        while true {
            if case .disconnection = try readFrame() { return }
        }
    }
}

private func sampleData(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
}

@MainActor
@Test(.timeLimit(.minutes(1))) func sharedFilesArriveAndNothingIsReplaced() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    try Data("already here".utf8).write(to: mac.folder.appendingPathComponent("photo.jpg"))
    let photo = sampleData(700_000)
    let port = mac.port

    let phone = Task.detached { () -> (code: String, answer: SharingFrame.Answer) in
        let phone = try PretendPhone(port: port)
        let answer = try phone.offer(files: [("photo.jpg", photo), ("../../notes.txt", Data("hi".utf8)), ("empty.bin", Data())])
        try phone.sendFiles()
        try phone.waitForGoodbye()
        return (phone.code, answer)
    }
    let outcome = try await phone.value
    try await waitUntil { !mac.results.isEmpty }

    #expect(outcome.answer == .accept)
    let share = try #require(mac.asked.first)
    #expect(share.sender == "Pixel 8")
    #expect(share.senderKind == .phone)
    #expect(share.code == outcome.code)
    #expect(share.contents == .files([.init(name: "photo.jpg", size: 700_000), .init(name: "notes.txt", size: 2),
                                      .init(name: "empty.bin", size: 0)]))
    #expect(share.totalBytes == 700_002)

    // The file that was already there is untouched; the new one got a free name. The name
    // with "../" in it stayed inside the folder.
    #expect(mac.files == ["empty.bin", "notes.txt", "photo (2).jpg", "photo.jpg"])
    #expect(mac.data("photo.jpg") == Data("already here".utf8))
    #expect(mac.data("photo (2).jpg") == photo)
    #expect(mac.data("notes.txt") == Data("hi".utf8))
    #expect(mac.data("empty.bin") == Data())
    guard case .saved(let urls)? = mac.results.first else {
        Issue.record("expected the files to be saved, got \(mac.results)")
        return
    }
    #expect(Set(urls.map(\.lastPathComponent)) == ["photo (2).jpg", "notes.txt", "empty.bin"])
    #expect(mac.progress.last == 700_002)
    // Received files are marked like downloads, so macOS checks them before first use.
    let marks = try urls[0].resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    #expect(marks?["LSQuarantineAgentName"] as? String == "Phone Mirror")
}

@MainActor
@Test(.timeLimit(.minutes(1))) func decliningSavesNothing() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    mac.answer = false
    let port = mac.port

    let answer = try await Task.detached {
        try PretendPhone(port: port).offer(files: [("photo.jpg", sampleData(1000))])
    }.value
    try await waitUntil { !mac.results.isEmpty }
    #expect(answer == .reject)
    #expect(mac.results == [.declined])
    #expect(mac.files.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func nothingIsWrittenBeforeTheAnswer() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    mac.answer = nil // the question stays open
    let port = mac.port

    // A phone that doesn't wait for the answer and sends the file straight away.
    let phone = Task.detached {
        let phone = try PretendPhone(port: port)
        try phone.send(SharingFrame.pairedKeyEncryption)
        try phone.send(SharingFrame.pairedKeyResult)
        let id = Int64(77)
        try phone.send(SharingFrame.introduction(.init(files: [.init(name: "pushy.txt", payloadID: id, size: 5)])))
        try phone.send(.payload(.init(id: id, kind: .file, totalSize: 5, offset: 0, isLast: true, body: Data("hello".utf8))))
        _ = try? phone.waitForGoodbye()
    }
    _ = try? await phone.value
    try await waitUntil { !mac.results.isEmpty }
    #expect(mac.asked.count == 1)
    #expect(mac.files.isEmpty)
    guard case .failed? = mac.results.first else {
        Issue.record("expected a failure, got \(mac.results)")
        return
    }
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aTransferThatBreaksOffLeavesNoHalfFile() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    let port = mac.port

    try await Task.detached {
        let phone = try PretendPhone(port: port)
        _ = try phone.offer(files: [("small.txt", Data("done".utf8)), ("video.mp4", sampleData(400_000))])
        try phone.sendFiles(stopAfterPieces: 3) // the small file and part of the video
        phone.hangUp()
    }.value
    try await waitUntil { !mac.results.isEmpty }
    // The file that arrived whole is kept; the half one is gone.
    #expect(mac.files == ["small.txt"])
    #expect(mac.results == [.failed("the connection to the phone was lost. 1 of 2 files arrived before that")])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func moreDataThanAnnouncedIsRefused() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    let port = mac.port

    try await Task.detached {
        let phone = try PretendPhone(port: port)
        _ = try phone.offer(files: [("big.bin", sampleData(200_000))], announcing: [1000])
        try? phone.sendFiles()
    }.value
    try await waitUntil { !mac.results.isEmpty }
    #expect(mac.asked.first?.totalBytes == 1000)
    #expect(mac.files.isEmpty)
    #expect(mac.results == [.failed("it sent more data than it announced")])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func stoppingOnTheMacRemovesWhatArrivedSoFar() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    let port = mac.port

    let phone = Task.detached {
        let phone = try PretendPhone(port: port)
        _ = try phone.offer(files: [("video.mp4", sampleData(400_000))])
        try phone.sendFiles(stopAfterPieces: 2)
        // Then the phone just waits; the Mac stops the transfer.
        guard case .cancel? = try? phone.readSharing() else { return false }
        return true
    }
    try await waitUntil { (mac.progress.last ?? 0) > 0 }
    let share = try #require(mac.asked.first)
    #expect(mac.files == ["video.mp4"])
    mac.receiver.stopTransfer(share.id)
    #expect(try await phone.value) // the phone was told
    try await waitUntil { !mac.results.isEmpty }
    #expect(mac.results == [.stopped])
    #expect(mac.files.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func textAndLinksArriveAsText() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    let port = mac.port

    for (text, kind) in [("Milk, eggs, bread 🥖", SharingFrame.TextOffer.Kind.text), ("https://example.com/a?b=c", .link)] {
        try await Task.detached {
            let phone = try PretendPhone(port: port)
            guard try phone.offer(text: (text, kind)) == .accept else { throw PretendPhone.Closed() }
            try phone.sendText(text)
            try phone.waitForGoodbye()
        }.value
    }
    try await waitUntil { mac.results.count == 2 }
    #expect(mac.results == [.text("Milk, eggs, bread 🥖"), .link("https://example.com/a?b=c")])
    #expect(mac.asked.map(\.contents) == [.text(title: "Milk, eggs, bread 🥖"), .link(title: "https://example.com/")])
    #expect(mac.files.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aPhoneThatDoesNotFollowTheRulesIsDropped() async throws {
    let mac = try await TestMac()
    defer { mac.close() }
    let port = mac.port

    try await Task.detached {
        // 1. Garbage instead of a first message.
        let first = try? PretendPhone.rawConnection(port: port) { socket in
            let junk = Data([0, 0, 0, 3, 0xFF, 0xFF, 0xFF])
            _ = junk.withUnsafeBytes { Darwin.send(socket, $0.baseAddress!, junk.count, 0) }
        }
        _ = first
        // 2. A message that claims to be 4 GB long.
        _ = try? PretendPhone.rawConnection(port: port) { socket in
            let huge = Data([0xFF, 0xFF, 0xFF, 0xFF])
            _ = huge.withUnsafeBytes { Darwin.send(socket, $0.baseAddress!, huge.count, 0) }
        }
        // 3. A proper handshake, then a message with a wrong signature.
        let phone = try PretendPhone(port: port)
        var sealed = try phone.sealForTest(SharingFrame.pairedKeyEncryption.encoded)
        sealed[sealed.count - 1] ^= 1
        try phone.sendRaw(sealed)
        _ = try? phone.readSharing()
        _ = try? phone.readSharing()
        _ = try? phone.readSharing()
    }.value

    // None of them got as far as offering anything, so nothing was shown or saved; and the
    // receiver still works afterwards.
    #expect(mac.asked.isEmpty)
    #expect(mac.results.isEmpty)
    #expect(mac.files.isEmpty)
    let answer = try await Task.detached {
        let phone = try PretendPhone(port: port)
        let answer = try phone.offer(files: [("ok.txt", Data("fine".utf8))])
        try phone.sendFiles()
        try phone.waitForGoodbye()
        return answer
    }.value
    #expect(answer == .accept)
    try await waitUntil { !mac.results.isEmpty }
    #expect(mac.files == ["ok.txt"])
}

extension PretendPhone {
    /// Opens a plain connection, lets `talk` send whatever it wants, and waits for the Mac
    /// to close it.
    static func rawConnection(port: UInt16, _ talk: (Int32) -> Void) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socket) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Writing to a connection the Mac has already closed must fail quietly, not stop the whole test run.
        var quiet: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Closed() }
        talk(socket)
        var byte: UInt8 = 0
        while Darwin.recv(socket, &byte, 1, 0) > 0 {}
    }

    func sealForTest(_ sharing: Data) throws -> Data {
        try channel!.seal(OfflineFrame.payload(.init(id: 1, kind: .bytes, totalSize: Int64(sharing.count), offset: 0,
                                                     isLast: true, body: sharing)).encoded)
    }
}

// MARK: The same, against the separately written Python phone

/// Tools/quickshare_fake_phone.py, if its one-time setup has been done.
private struct PythonPhone {
    let python: URL
    let script: URL
    let definitions: URL

    init?() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        python = root.appendingPathComponent("build/reference/venv/bin/python3")
        script = root.appendingPathComponent("Tools/quickshare_fake_phone.py")
        definitions = root.appendingPathComponent("build/reference/pb")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: python.path), files.fileExists(atPath: script.path),
              files.fileExists(atPath: definitions.appendingPathComponent("wire_format_pb2.py").path) else { return nil }
    }

    func send(to port: UInt16, _ arguments: [String]) async -> ProcessResult {
        await ProcessRunner.run(python, ["-I", script.path, "--pb", definitions.path, "--port", String(port)] + arguments,
                                environment: ["PATH": "/usr/bin:/bin"], timeout: 45)
    }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func theSeparatelyWrittenPhoneCanSendFiles() async throws {
    guard let python = PythonPhone() else { return }
    let mac = try await TestMac()
    defer { mac.close() }

    // A file bigger than one piece, random so nothing can match by accident, and a small one.
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("phonemirror-python-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: source) }
    let big = Data.random(1_300_000), small = Data("hello from python".utf8)
    try big.write(to: source.appendingPathComponent("holiday video.mp4"))
    try small.write(to: source.appendingPathComponent("note.txt"))

    let result = await python.send(to: mac.port, ["--name", "Pixel 9 Pro", "--chunk", "500000",
                                                  source.appendingPathComponent("holiday video.mp4").path,
                                                  source.appendingPathComponent("note.txt").path])
    try await waitUntil { !mac.results.isEmpty }
    #expect(result.exitCode == 0, "\(result.combinedOutput)")
    #expect(result.stdout.contains("ANSWER ACCEPT"))
    #expect(result.stdout.contains("DONE"))

    let share = try #require(mac.asked.first)
    #expect(share.sender == "Pixel 9 Pro")
    #expect(share.senderKind == .phone)
    // Both ends worked out the same 4-digit code, each with its own code and its own library.
    #expect(result.stdout.contains("CODE \(share.code)"))
    #expect(share.contents == .files([.init(name: "holiday video.mp4", size: 1_300_000), .init(name: "note.txt", size: Int64(small.count))]))
    #expect(mac.data("holiday video.mp4") == big)
    #expect(mac.data("note.txt") == small)
    #expect(mac.files.count == 2)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func theSeparatelyWrittenPhoneIsToldWhenTheMacDeclines() async throws {
    guard let python = PythonPhone() else { return }
    let mac = try await TestMac()
    defer { mac.close() }
    mac.answer = false
    let file = mac.folder.deletingLastPathComponent().appendingPathComponent("phonemirror-decline-\(UUID().uuidString).txt")
    try Data("secret".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = await python.send(to: mac.port, [file.path])
    #expect(result.exitCode == 3, "\(result.combinedOutput)")
    #expect(result.stdout.contains("ANSWER REJECT"))
    try await waitUntil { !mac.results.isEmpty }
    #expect(mac.results == [.declined])
    #expect(mac.files.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func theSeparatelyWrittenPhoneCanSendTextAndOddlyCutFiles() async throws {
    guard let python = PythonPhone() else { return }
    let mac = try await TestMac()
    defer { mac.close() }

    let text = await python.send(to: mac.port, ["--text", "नमस्ते, Mac!"])
    #expect(text.exitCode == 0, "\(text.combinedOutput)")
    let link = await python.send(to: mac.port, ["--link", "https://phonemirror.in/setup"])
    #expect(link.exitCode == 0, "\(link.combinedOutput)")
    try await waitUntil { mac.results.count == 2 }
    #expect(mac.results == [.text("नमस्ते, Mac!"), .link("https://phonemirror.in/setup")])

    // A phone that marks the last piece of data itself as the last one, a name that tries to
    // leave the folder, and tiny pieces.
    let file = mac.folder.deletingLastPathComponent().appendingPathComponent("phonemirror-odd-\(UUID().uuidString).bin")
    let contents = Data.random(10_000)
    try contents.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let odd = await python.send(to: mac.port, ["--last-piece-carries-data", "--chunk", "999",
                                               "--send-as", "../../../escape.bin", file.path])
    #expect(odd.exitCode == 0, "\(odd.combinedOutput)")
    try await waitUntil { mac.results.count == 3 }
    #expect(mac.files == ["escape.bin"])
    #expect(mac.data("escape.bin") == contents)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func theSeparatelyWrittenPhoneCannotCheat() async throws {
    guard let python = PythonPhone() else { return }
    let mac = try await TestMac()
    defer { mac.close() }
    let file = mac.folder.deletingLastPathComponent().appendingPathComponent("phonemirror-cheat-\(UUID().uuidString).bin")
    try Data.random(5000).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    // A message changed after it was signed: the connection is dropped before any offer.
    let tampered = await python.send(to: mac.port, ["--tamper", file.path])
    #expect(tampered.exitCode == 1)
    #expect(mac.asked.isEmpty)

    // More bytes than announced: refused, and the part that arrived is removed.
    let greedy = await python.send(to: mac.port, ["--too-much", file.path])
    #expect(greedy.exitCode == 1)
    try await waitUntil { !mac.results.isEmpty }
    #expect(mac.results == [.failed("it sent more data than it announced")])

    // Gone right after offering: the question is withdrawn.
    mac.answer = nil
    _ = await python.send(to: mac.port, ["--quit-after-offer", file.path])
    try await waitUntil { mac.results.count == 2 }
    #expect(mac.results.last == .cancelledByPhone)
    #expect(mac.files.isEmpty)
}

// MARK: The words on the card

@MainActor
@Test func theCardSaysWhatIsHappening() {
    let files = IncomingShare(id: UUID(), sender: "Pixel 8", senderKind: .phone, code: "0420",
                              contents: .files([.init(name: "a.jpg", size: 1), .init(name: "b.jpg", size: 1), .init(name: "c.jpg", size: 1)]),
                              totalBytes: 4_200_000)
    let card = ShareCard(share: files)
    #expect(card.title == "“Pixel 8” wants to send you 3 files")
    #expect(card.detail == "a.jpg, b.jpg and 1 more · 4.2 MB")
    card.phase = .receiving
    card.receivedBytes = 2_100_000
    #expect(card.title == "Receiving 3 files from “Pixel 8”…")
    #expect(card.fraction == 0.5)
    #expect(card.progressLine == "2.1 MB of 4.2 MB")
    card.phase = .done(.saved([URL(fileURLWithPath: "/tmp/a.jpg")]))
    #expect(card.title == "Saved to Downloads")
    #expect(card.savedFiles.count == 1)
    card.phase = .done(.failed("the connection to the phone was lost"))
    #expect(card.detail == "What happened: the connection to the phone was lost. Anything that arrived only in part was removed.")

    let one = ShareCard(share: IncomingShare(id: UUID(), sender: "Tab", senderKind: .tablet, code: "1234",
                                             contents: .files([.init(name: "a.pdf", size: 10)]), totalBytes: 10))
    #expect(one.title == "“Tab” wants to send you a file")

    // Only web links get an "Open Link" button.
    let link = ShareCard(share: IncomingShare(id: UUID(), sender: "Pixel 8", senderKind: .phone, code: "1234",
                                              contents: .link(title: "example.com"), totalBytes: 20))
    #expect(link.title == "“Pixel 8” wants to send you a link")
    link.phase = .done(.link("https://example.com/page"))
    #expect(link.openableLink?.absoluteString == "https://example.com/page")
    for unsafe in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "not a link", "https://"] {
        link.phase = .done(.link(unsafe))
        #expect(link.openableLink == nil)
    }
}
