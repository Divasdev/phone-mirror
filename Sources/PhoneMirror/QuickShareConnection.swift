import CryptoKit
import Foundation
import Network

/// What a nearby device is offering, as shown in the accept window.
struct IncomingShare: Identifiable, Equatable {
    enum Contents: Equatable {
        case files([File])
        case text(title: String)
        case link(title: String)
    }

    struct File: Equatable {
        var name: String
        var size: Int64
    }

    let id: UUID
    var sender: String
    var senderKind: EndpointInfo.Kind
    /// The 4-digit code for this connection. The phone can show the same one.
    var code: String
    var contents: Contents
    var totalBytes: Int64
}

/// How a share ended.
enum ShareResult: Equatable {
    case saved([URL])
    case text(String)
    case link(String)
    case declined
    case stopped            // stopped on this Mac
    case cancelledByPhone
    case missed             // nobody answered in time
    case failed(String)
}

/// One device that connected to send something. It walks through the Quick Share
/// conversation as the receiving side: connection request, key exchange, the offer
/// ("introduction"), the person's answer, then the files.
///
/// Everything the other device sends is treated as untrusted: sizes are capped, file names
/// are cleaned, nothing is written before the person accepts, and nothing is ever replaced.
/// All of this runs on `queue`; the callbacks in `Events` are called on that queue too.
final class QuickShareInbound: @unchecked Sendable {

    struct Events {
        var ask: (IncomingShare) -> Void
        var progress: (UUID, Int64) -> Void
        /// `nil` means the connection ended before anything was offered (nothing to show).
        var finished: (UUID, ShareResult?) -> Void
    }

    enum Limits {
        static let frame = 5 * 1024 * 1024      // one message on the wire
        static let files = 500                  // files in one share
        static let text = 1024 * 1024           // shared text
        static let setupSeconds = 30.0          // from connecting to the offer
        static let answerSeconds = 120.0        // how long the accept window waits
        static let quietSeconds = 45.0          // no data while receiving
    }

    let id = UUID()

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let saveFolder: URL
    private let isAllowedPeer: (NWEndpoint) -> Bool
    private let events: Events

    private enum Stage { case connectionRequest, clientInit, clientFinish, connectionResponse, secure, closed }
    private var stage = Stage.connectionRequest

    // Key exchange
    private var handshake: QuickShareHandshake?
    private var clientInit = Data()
    private var serverInit = Data()
    private var commitment = Data()
    private var channel: SecureChannel?

    // The offer and the transfer
    private var sender = EndpointInfo(name: "", kind: .unknown)
    private var share: IncomingShare?
    private var offeredFiles: [SharingFrame.FileOffer] = []
    private var offeredText: SharingFrame.TextOffer?
    private var accepted = false
    private var sentPairedResult = false
    private var messages: [Int64: Data] = [:]      // short messages that arrive in pieces
    private var open: [Int64: OpenFile] = [:]      // files being written right now
    private var saved: [URL] = []
    private var receivedBytes: Int64 = 0
    private var lastProgress = Date.distantPast

    // Time limits
    private var watchdog: DispatchSourceTimer?
    private var stageStarted = Date()
    private var lastHeard = Date()
    private var lastKeepAlive = Date()

    private struct OpenFile {
        let url: URL
        let handle: FileHandle
        let size: Int64
        var received: Int64 = 0
    }

    private struct Problem: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    init(connection: NWConnection, queue: DispatchQueue, saveFolder: URL,
         isAllowedPeer: @escaping (NWEndpoint) -> Bool, events: Events) {
        self.connection = connection
        self.queue = queue
        self.saveFolder = saveFolder
        self.isAllowedPeer = isAllowedPeer
        self.events = events
    }

    // MARK: Start, answer, stop (call these on `queue`)

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Only devices on the same local network may talk to this Mac.
                guard self.isAllowedPeer(self.connection.currentPath?.remoteEndpoint ?? self.connection.endpoint) else {
                    return self.end(nil)
                }
                self.receiveFrame()
            case .failed, .cancelled:
                self.connectionLost()
            default:
                break
            }
        }
        startWatchdog()
        connection.start(queue: queue)
    }

    /// The person's choice in the accept window.
    func answer(accept: Bool) {
        guard stage == .secure, share != nil, !accepted else { return }
        guard accept else {
            try? send(.response(.reject))
            return end(.declined)
        }
        do {
            try createFiles()
        } catch let problem as Problem {
            try? send(.response(problem.reason == Self.noSpace ? .notEnoughSpace : .reject))
            return end(.failed(problem.reason))
        } catch {
            try? send(.response(.reject))
            return end(.failed("the files couldn't be created in your Downloads folder"))
        }
        accepted = true
        lastHeard = Date()
        do {
            try send(.response(.accept))
        } catch {
            end(.failed("the connection to the phone was lost"))
        }
    }

    /// Stop from this Mac (the Stop button, switching Quick Share off, or quitting).
    func stop() {
        guard stage != .closed else { return }
        if stage == .secure { try? send(.cancel) }
        end(share == nil ? nil : (accepted ? .stopped : .declined))
    }

    // MARK: Reading the connection

    /// Every message has its length in front, as four bytes.
    private func receiveFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, self.stage != .closed else { return }
            guard let data, data.count == 4, error == nil else { return self.connectionLost() }
            let length = data.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= Limits.frame else { return self.end(self.failure("it sent something this app doesn’t understand")) }

            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, self.stage != .closed else { return }
                guard let body, body.count == length, error == nil else { return self.connectionLost() }
                self.lastHeard = Date()
                self.handle(body)
                if self.stage != .closed { self.receiveFrame() }
            }
        }
    }

    private func handle(_ frame: Data) {
        do {
            switch stage {
            case .connectionRequest:
                guard case .connectionRequest(_, let info) = try OfflineFrame(frame),
                      let endpoint = EndpointInfo(info) else { throw Problem("unexpected first message") }
                sender = endpoint
                move(to: .clientInit)

            case .clientInit:
                let hello = try Ukey2.open(frame, expecting: .clientInit)
                guard hello.int(1) == 1 else { throw Ukey2.Refused(alert: .badVersion) }
                guard hello.bytes(2)?.count == 32 else { throw Ukey2.Refused(alert: .badRandom) }
                let offered = (try? hello.messages(3)) ?? []
                guard let match = offered.first(where: { $0.number(1) == Ukey2.p256SHA512 })?.bytes(2) else {
                    throw Ukey2.Refused(alert: .badHandshakeCipher)
                }
                guard hello.string(4) == Ukey2.nextProtocol else { throw Ukey2.Refused(alert: .badNextProtocol) }
                commitment = match
                clientInit = frame

                let handshake = QuickShareHandshake()
                self.handshake = handshake
                serverInit = Ukey2.serverInit(random: .random(32), publicKey: handshake.publicKeyMessage)
                sendRaw(serverInit)
                move(to: .clientFinish)

            case .clientFinish:
                let finish = try Ukey2.open(frame, expecting: .clientFinish)
                // The phone promised this exact message (by its SHA-512) before it saw our key.
                guard Data(SHA512.hash(data: frame)) == commitment, let handshake,
                      let peerKey = finish.bytes(1) else { throw Ukey2.Refused(alert: .badMessageData) }
                channel = try handshake.finish(peerKeyMessage: peerKey, clientInit: clientInit,
                                               serverInit: serverInit, asServer: true)
                self.handshake = nil
                move(to: .connectionResponse)

            case .connectionResponse:
                guard case .connectionResponse(let accepted) = try OfflineFrame(frame) else { return }
                guard accepted else { return end(nil) }
                sendRaw(OfflineFrame.connectionResponse(accepted: true).encoded)
                move(to: .secure) // from here on everything is encrypted
                try send(.pairedKeyEncryption)

            case .secure:
                guard var channel else { throw Problem("no keys") }
                let plain = try channel.open(frame)
                self.channel = channel
                try handleSecure(OfflineFrame(plain))

            case .closed:
                break
            }
        } catch let refused as Ukey2.Refused {
            sendRaw(Ukey2.alert(refused.alert))
            end(failure("the secure connection couldn’t be set up"))
        } catch let problem as Problem {
            end(failure(problem.reason))
        } catch is SecureChannel.Failed {
            end(failure("a message failed its security check"))
        } catch {
            end(failure("it sent something this app doesn’t understand"))
        }
    }

    private func handleSecure(_ frame: OfflineFrame) throws {
        switch frame {
        case .payload(let piece):
            switch piece.kind {
            case .bytes: try collect(piece)
            case .file:  try write(piece)
            }
        case .payloadStopped(let id):
            if open[id] != nil || offeredText?.payloadID == id { end(.cancelledByPhone) }
        case .keepAlive(let ack):
            if !ack { try sendFrame(.keepAlive(ack: true)) }
        case .disconnection:
            guard share != nil else { return end(nil) }
            end(accepted ? .failed("the phone ended the transfer early") : .cancelledByPhone)
        case .connectionRequest, .connectionResponse, .other:
            break
        }
    }

    /// Short messages arrive as one or more pieces; the last piece is marked.
    private func collect(_ piece: OfflineFrame.PayloadPiece) throws {
        var buffer = messages[piece.id] ?? Data()
        guard piece.offset == Int64(buffer.count), buffer.count + piece.body.count <= Limits.frame,
              messages.count < 16 || messages[piece.id] != nil else { throw Problem("a message arrived out of order") }
        buffer.append(piece.body)
        guard piece.isLast else {
            messages[piece.id] = buffer
            return
        }
        messages[piece.id] = nil

        if accepted, let text = offeredText, text.payloadID == piece.id {
            guard buffer.count <= Limits.text, let string = String(data: buffer, encoding: .utf8) else {
                throw Problem("the text couldn’t be read")
            }
            return end(text.kind == .link ? .link(string) : .text(string))
        }
        try handleSharing(SharingFrame(buffer))
    }

    private func handleSharing(_ frame: SharingFrame) throws {
        switch frame {
        case .pairedKeyEncryption:
            guard !sentPairedResult else { return }
            sentPairedResult = true
            try send(.pairedKeyResult)
        case .introduction(let introduction):
            guard share == nil else { return }
            guard let offer = describe(introduction) else {
                try? send(.response(.unsupported))
                return end(nil)
            }
            share = offer
            stageStarted = Date()
            events.ask(offer)
        case .cancel:
            end(share == nil ? nil : .cancelledByPhone)
        case .pairedKeyResult, .response, .other:
            break
        }
    }

    /// Turns the phone's offer into what the accept window shows. Returns nil for things
    /// this app doesn't take (Wi-Fi passwords, apps, an empty or oversized offer).
    private func describe(_ introduction: SharingFrame.Introduction) -> IncomingShare? {
        guard !introduction.hasOtherThings, let channel else { return nil }
        let name = Self.cleanLabel(sender.name, fallback: "A nearby device")

        if !introduction.files.isEmpty, introduction.texts.isEmpty {
            let files = introduction.files
            guard files.count <= Limits.files, Set(files.map(\.payloadID)).count == files.count,
                  files.allSatisfy({ $0.size >= 0 }) else { return nil }
            let (total, overflow) = files.reduce((Int64(0), false)) { sum, file in
                let (value, overflow) = sum.0.addingReportingOverflow(file.size)
                return (value, sum.1 || overflow)
            }
            guard !overflow else { return nil }
            offeredFiles = files
            return IncomingShare(id: id, sender: name, senderKind: sender.kind, code: channel.code,
                                 contents: .files(files.map { .init(name: Self.cleanFileName($0.name), size: $0.size) }),
                                 totalBytes: total)
        }
        if introduction.files.isEmpty, introduction.texts.count == 1, let text = introduction.texts.first,
           (0...Int64(Limits.text)).contains(text.size) {
            offeredText = text
            let title = Self.cleanLabel(text.title, fallback: "")
            return IncomingShare(id: id, sender: name, senderKind: sender.kind, code: channel.code,
                                 contents: text.kind == .link ? .link(title: title) : .text(title: title),
                                 totalBytes: text.size)
        }
        return nil
    }

    // MARK: Files

    private static let noSpace = "there isn’t enough free space on this Mac"

    /// Called when the person accepts: makes an empty file for each offered one, under a
    /// name that is free. A file that is already there is never replaced.
    private func createFiles() throws {
        guard !offeredFiles.isEmpty else { return }
        let needed = share?.totalBytes ?? 0
        if let free = try? saveFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < needed + 50_000_000 {
            throw Problem(Self.noSpace)
        }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: saveFolder.path)) ?? []
        var taken = Set(existing.map { $0.lowercased() })

        do {
            for file in offeredFiles {
                var made: (URL, FileHandle)?
                for _ in 0..<20 where made == nil { // another program may take a name first: try the next one
                    let name = FileTransfers.freeName(for: Self.cleanFileName(file.name), taken: &taken)
                    let url = saveFolder.appendingPathComponent(name)
                    // O_EXCL: fail rather than open something that already exists.
                    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                    if descriptor >= 0 {
                        made = (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
                    } else if errno != EEXIST {
                        throw Problem("macOS didn’t allow saving into your Downloads folder")
                    }
                }
                guard let made else { throw Problem("no free file name was found in your Downloads folder") }
                open[file.payloadID] = OpenFile(url: made.0, handle: made.1, size: file.size)
            }
        } catch {
            removeUnfinishedFiles()
            throw error
        }
    }

    private func write(_ piece: OfflineFrame.PayloadPiece) throws {
        guard accepted, var file = open[piece.id] else { throw Problem("it sent a file that wasn’t offered") }
        guard piece.offset == file.received, file.received + Int64(piece.body.count) <= file.size else {
            throw Problem("it sent more data than it announced")
        }
        if !piece.body.isEmpty {
            do {
                try file.handle.write(contentsOf: piece.body)
            } catch {
                throw Problem("the file couldn’t be written (is the disk full?)")
            }
            file.received += Int64(piece.body.count)
            receivedBytes += Int64(piece.body.count)
            open[piece.id] = file
        }
        if piece.isLast {
            guard file.received == file.size else { throw Problem("a file arrived incomplete") }
            try? file.handle.close()
            open[piece.id] = nil
            Self.markAsDownloaded(file.url)
            saved.append(file.url)
        }

        let now = Date()
        if open.isEmpty || now.timeIntervalSince(lastProgress) > 0.1 {
            lastProgress = now
            events.progress(id, receivedBytes)
        }
        if open.isEmpty { end(.saved(saved)) }
    }

    /// A file that didn't arrive completely is of no use: remove it. Only files this
    /// connection created itself are touched.
    private func removeUnfinishedFiles() {
        for file in open.values {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        open.removeAll()
    }

    /// Marks a received file the way browsers mark downloads, so macOS checks it (for
    /// example an app or a script) before it is opened for the first time.
    private static func markAsDownloaded(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload",
                                       "LSQuarantineAgentName": "Phone Mirror"]
        var url = url
        try? url.setResourceValues(values)
    }

    // MARK: Sending

    private func send(_ frame: SharingFrame) throws {
        let data = frame.encoded
        let id = Int64.random(in: Int64.min...Int64.max)
        // The same two steps Android uses: the message, then an empty "that was all".
        try sendFrame(.payload(.init(id: id, kind: .bytes, totalSize: Int64(data.count), offset: 0,
                                     isLast: false, body: data)))
        try sendFrame(.payload(.init(id: id, kind: .bytes, totalSize: Int64(data.count), offset: Int64(data.count),
                                     isLast: true, body: Data())))
    }

    private func sendFrame(_ frame: OfflineFrame) throws {
        guard var channel else { throw Problem("no keys") }
        let sealed = try channel.seal(frame.encoded)
        self.channel = channel
        sendRaw(sealed)
    }

    private func sendRaw(_ frame: Data) {
        guard stage != .closed else { return }
        var data = Data([UInt8(truncatingIfNeeded: frame.count >> 24), UInt8(truncatingIfNeeded: frame.count >> 16),
                         UInt8(truncatingIfNeeded: frame.count >> 8), UInt8(truncatingIfNeeded: frame.count)])
        data.append(frame)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.connectionLost() }
        })
    }

    // MARK: Ending

    private func move(to next: Stage) {
        stage = next
    }

    private func connectionLost() {
        guard stage != .closed else { return }
        guard share != nil else { return end(nil) }
        end(accepted ? .failed("the connection to the phone was lost") : .cancelledByPhone)
    }

    /// A failure is only worth showing once something was offered.
    private func failure(_ reason: String) -> ShareResult? {
        share == nil ? nil : .failed(reason)
    }

    private func end(_ result: ShareResult?) {
        guard stage != .closed else { return }
        var result = result
        if case .failed(let reason)? = result, !saved.isEmpty {
            result = .failed("\(reason). \(saved.count) of \(offeredFiles.count) files arrived before that")
        }
        if stage == .secure {
            // Tell the phone when it didn't work, so it doesn't report a success.
            if case .failed? = result, accepted { try? send(.cancel) }
            try? sendFrame(.disconnection)
        }
        removeUnfinishedFiles()
        stage = .closed
        watchdog?.cancel()
        watchdog = nil

        // Let what was just sent go out, then close. The timer is a backstop.
        let connection = connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        events.finished(id, result)
    }

    /// Looks every few seconds: has a step taken too long, and is a keep-alive due?
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.stage != .closed else { return }
            let now = Date()
            if self.share == nil {
                if now.timeIntervalSince(self.stageStarted) > Limits.setupSeconds { return self.end(nil) }
            } else if !self.accepted {
                if now.timeIntervalSince(self.stageStarted) > Limits.answerSeconds {
                    try? self.send(.response(.timedOut))
                    return self.end(.missed)
                }
            } else if now.timeIntervalSince(self.lastHeard) > Limits.quietSeconds {
                return self.end(.failed("the phone stopped sending"))
            }
            // The phone gives up on a connection that stays silent.
            if self.stage == .secure, now.timeIntervalSince(self.lastKeepAlive) >= 10 {
                self.lastKeepAlive = now
                try? self.sendFrame(.keepAlive(ack: false))
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: Cleaning what the other device sent

    /// A file name that is safe to create in Downloads: only the last part of a path, no
    /// control characters, no ":" or "/", not hidden (no leading dot), and not too long.
    static func cleanFileName(_ raw: String) -> String {
        let lastPart = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in lastPart.unicodeScalars {
            let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            let isHiddenFormatting = (0x200B...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0xFEFF
            if isControl || isHiddenFormatting { continue }
            scalars.append(scalar == ":" ? "-" : scalar)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        while let first = name.first, first == "." || first.isWhitespace { name.removeFirst() }
        if name.isEmpty { return "file" }

        // Keep the ending (".jpg") when shortening.
        var ending = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, name[dot...].utf8.count <= 20 {
            ending = String(name[dot...])
            name = String(name[..<dot])
        }
        while name.utf8.count + ending.utf8.count > 200 { name.removeLast() }
        return name + ending
    }

    /// A device name or a title, made safe to show: one line, no invisible characters, short.
    static func cleanLabel(_ raw: String, fallback: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            let isHiddenFormatting = (0x200B...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0xFEFF
            scalars.append(isControl || isHiddenFormatting ? " " : scalar)
        }
        let text = String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(60))
        return text.isEmpty ? fallback : text
    }
}
