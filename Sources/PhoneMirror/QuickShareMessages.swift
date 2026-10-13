import Foundation

// The Quick Share messages this app reads and writes. The field numbers come from Google's
// published message definitions (the .proto files in Chromium), and the order of the
// conversation from the protocol notes of the open-source NearDrop project.

/// How a device describes itself: its name and what kind of device it is.
struct EndpointInfo: Equatable {
    enum Kind: Int {
        case unknown = 0, phone, tablet, computer, car, foldable, headset
    }

    var name: String
    var kind: Kind

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Layout: one byte of flags, 16 bytes this app has no use for, then the name with its
    /// length in front. A device that hides its name sets the 0x10 flag and leaves it out.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 17 else { return nil }
        kind = Kind(rawValue: Int(bytes[0] >> 1) & 7) ?? .unknown
        guard bytes[0] & 0x10 == 0, bytes.count >= 18 else {
            name = ""
            return
        }
        let length = Int(bytes[17])
        guard bytes.count >= 18 + length,
              let text = String(bytes: bytes[18..<(18 + length)], encoding: .utf8) else { return nil }
        name = text
    }

    var encoded: Data {
        var name = Array(self.name.utf8.prefix(255))
        // Don't cut a character in half.
        while String(bytes: name, encoding: .utf8) == nil, !name.isEmpty { name.removeLast() }
        var data = Data([UInt8(kind.rawValue << 1)])
        data.append(Data.random(16))
        data.append(UInt8(name.count))
        data.append(contentsOf: name)
        return data
    }
}

/// The outer layer: opening, keeping and closing a connection, and moving data in pieces.
enum OfflineFrame {
    case connectionRequest(endpointID: String, info: Data)
    case connectionResponse(accepted: Bool)
    case payload(PayloadPiece)
    /// The other side gave up on one piece of data (an error, or it was cancelled there).
    case payloadStopped(id: Int64)
    case keepAlive(ack: Bool)
    case disconnection
    case other

    /// One piece of a "payload": either a short message (bytes) or part of a file.
    struct PayloadPiece {
        enum Kind: UInt64 { case bytes = 1, file = 2 }
        var id: Int64
        var kind: Kind
        var totalSize: Int64
        var offset: Int64
        var isLast: Bool
        var body: Data
    }

    init(_ data: Data) throws {
        guard let v1 = try ProtoMessage(data).message(2) else {
            self = .other
            return
        }
        switch v1.number(1) {
        case 1:
            guard let request = try v1.message(2), let info = request.bytes(6) else { throw ProtoMessage.Malformed() }
            self = .connectionRequest(endpointID: request.string(1) ?? "", info: info)
        case 2:
            guard let response = try v1.message(3) else { throw ProtoMessage.Malformed() }
            // "response" is 1 for accept and 2 for reject. Older phones leave it out.
            self = .connectionResponse(accepted: response.number(3) != 2)
        case 3:
            guard let transfer = try v1.message(4), let header = try transfer.message(2),
                  let id = header.int64(1) else { throw ProtoMessage.Malformed() }
            if transfer.number(1) == 2 { // a control packet instead of data
                self = .payloadStopped(id: id)
                return
            }
            guard let kind = header.number(2).flatMap(PayloadPiece.Kind.init), let chunk = try transfer.message(3) else {
                self = .other
                return
            }
            self = .payload(PayloadPiece(id: id, kind: kind, totalSize: header.int64(3) ?? 0,
                                         offset: chunk.int64(2) ?? 0, isLast: (chunk.number(1) ?? 0) & 1 == 1,
                                         body: chunk.bytes(3) ?? Data()))
        case 5:
            self = .keepAlive(ack: try v1.message(6)?.bool(1) ?? false)
        case 6:
            self = .disconnection
        default:
            self = .other
        }
    }

    var encoded: Data {
        ProtoWriter.build { frame in
            frame.number(1, 1) // version 1
            frame.message(2) { v1 in
                switch self {
                case .connectionRequest(let endpointID, let info):
                    v1.number(1, 1)
                    v1.message(2) { request in
                        request.string(1, endpointID)
                        request.string(2, EndpointInfo(info)?.name ?? "")
                        request.number(5, 5) // can talk over the local network
                        request.bytes(6, info)
                    }
                case .connectionResponse(let accepted):
                    v1.number(1, 2)
                    v1.message(3) { response in
                        response.number(1, 0)
                        response.number(3, accepted ? 1 : 2)
                        response.message(4) { $0.number(1, 4) } // this is an Apple device
                    }
                case .payload(let piece):
                    v1.number(1, 3)
                    v1.message(4) { transfer in
                        transfer.number(1, 1) // data
                        transfer.message(2) { header in
                            header.number(1, signed: piece.id)
                            header.number(2, piece.kind.rawValue)
                            header.number(3, signed: piece.totalSize)
                            header.bool(4, false)
                        }
                        transfer.message(3) { chunk in
                            chunk.number(1, piece.isLast ? 1 : 0)
                            chunk.number(2, signed: piece.offset)
                            if !piece.body.isEmpty { chunk.bytes(3, piece.body) }
                        }
                    }
                case .payloadStopped(let id):
                    v1.number(1, 3)
                    v1.message(4) { transfer in
                        transfer.number(1, 2) // control
                        transfer.message(2) { $0.number(1, signed: id) }
                        transfer.message(4) { $0.number(1, 2) } // cancelled
                    }
                case .keepAlive(let ack):
                    v1.number(1, 5)
                    v1.message(6) { $0.bool(1, ack) }
                case .disconnection:
                    v1.number(1, 6)
                    v1.message(7) { _ in }
                case .other:
                    v1.number(1, 0)
                }
            }
        }
    }
}

/// The inner layer, sent as short "bytes" payloads: what is on offer, and the answer.
enum SharingFrame {
    case introduction(Introduction)
    case response(Answer)
    case pairedKeyEncryption
    case pairedKeyResult
    case cancel
    case other

    enum Answer: UInt64 {
        case accept = 1, reject, notEnoughSpace, unsupported, timedOut
    }

    struct FileOffer: Equatable {
        var name: String
        var payloadID: Int64
        var size: Int64
        var mimeType = "application/octet-stream"
    }

    struct TextOffer: Equatable {
        enum Kind: UInt64 { case unknown = 0, text, link, address, phoneNumber }
        var title: String
        var kind: Kind
        var payloadID: Int64
        var size: Int64
    }

    struct Introduction: Equatable {
        var files: [FileOffer] = []
        var texts: [TextOffer] = []
        /// Wi-Fi passwords, apps or streams were offered too. This app takes none of those.
        var hasOtherThings = false
    }

    init(_ data: Data) throws {
        guard let v1 = try ProtoMessage(data).message(2) else {
            self = .other
            return
        }
        switch v1.number(1) {
        case 1:
            guard let intro = try v1.message(2) else { throw ProtoMessage.Malformed() }
            var introduction = Introduction()
            for file in try intro.messages(1) {
                guard let id = file.int64(3) else { throw ProtoMessage.Malformed() }
                introduction.files.append(FileOffer(name: file.string(1) ?? "", payloadID: id, size: file.int64(4) ?? 0,
                                                    mimeType: file.string(5) ?? "application/octet-stream"))
            }
            for text in try intro.messages(2) {
                guard let id = text.int64(4) else { throw ProtoMessage.Malformed() }
                introduction.texts.append(TextOffer(title: text.string(2) ?? "",
                                                    kind: text.number(3).flatMap(TextOffer.Kind.init) ?? .unknown,
                                                    payloadID: id, size: text.int64(5) ?? 0))
            }
            introduction.hasOtherThings = intro.has(4) || intro.has(5) || intro.has(7)
            self = .introduction(introduction)
        case 2:
            self = .response(try v1.message(3)?.number(1).flatMap(Answer.init) ?? .reject)
        case 3: self = .pairedKeyEncryption
        case 4: self = .pairedKeyResult
        case 6: self = .cancel
        default: self = .other
        }
    }

    var encoded: Data {
        ProtoWriter.build { frame in
            frame.number(1, 1) // version 1
            frame.message(2) { v1 in
                switch self {
                case .introduction(let introduction):
                    v1.number(1, 1)
                    v1.message(2) { intro in
                        for file in introduction.files {
                            intro.message(1) { meta in
                                meta.string(1, file.name)
                                meta.number(3, signed: file.payloadID)
                                meta.number(4, signed: file.size)
                                meta.string(5, file.mimeType)
                            }
                        }
                        for text in introduction.texts {
                            intro.message(2) { meta in
                                meta.string(2, text.title)
                                meta.number(3, text.kind.rawValue)
                                meta.number(4, signed: text.payloadID)
                                meta.number(5, signed: text.size)
                            }
                        }
                    }
                case .response(let answer):
                    v1.number(1, 2)
                    v1.message(3) { $0.number(1, answer.rawValue) }
                case .pairedKeyEncryption:
                    // Used by Google for "contacts only" sharing, which needs Google's servers.
                    // Random filler is what other devices without an account send too.
                    v1.number(1, 3)
                    v1.message(4) { keys in
                        keys.bytes(1, Data.random(72))
                        keys.bytes(2, Data.random(6))
                    }
                case .pairedKeyResult:
                    v1.number(1, 4)
                    v1.message(5) { $0.number(1, 3) } // "unable": no shared account
                case .cancel:
                    v1.number(1, 6)
                case .other:
                    v1.number(1, 0)
                }
            }
        }
    }
}

/// The key exchange messages ("UKEY2", Google's published handshake).
enum Ukey2 {
    enum Kind: UInt64 { case alert = 1, clientInit, serverInit, clientFinish }

    /// Reasons a handshake is refused, as the other side expects to be told.
    enum Alert: UInt64 {
        case badMessage = 1, badMessageType = 2, badMessageData = 4
        case badVersion = 100, badRandom, badHandshakeCipher, badNextProtocol, badPublicKey
    }

    struct Refused: Error { let alert: Alert }

    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"
    /// The one key-exchange method this app speaks: curve P-256 with SHA-512.
    static let p256SHA512: UInt64 = 100

    static func message(_ kind: Kind, _ body: Data) -> Data {
        ProtoWriter.build {
            $0.number(1, kind.rawValue)
            $0.bytes(2, body)
        }
    }

    /// Splits a handshake message into its kind and its contents.
    static func open(_ data: Data, expecting kind: Kind) throws -> ProtoMessage {
        guard let message = try? ProtoMessage(data) else { throw Refused(alert: .badMessage) }
        guard message.number(1) == kind.rawValue else { throw Refused(alert: .badMessageType) }
        guard let body = message.bytes(2), let contents = try? ProtoMessage(body) else {
            throw Refused(alert: .badMessageData)
        }
        return contents
    }

    static func alert(_ alert: Alert) -> Data {
        message(.alert, ProtoWriter.build { $0.number(1, alert.rawValue) })
    }

    static func clientInit(random: Data, commitment: Data) -> Data {
        message(.clientInit, ProtoWriter.build { initMessage in
            initMessage.number(1, 1)
            initMessage.bytes(2, random)
            initMessage.message(3) {
                $0.number(1, p256SHA512)
                $0.bytes(2, commitment)
            }
            initMessage.string(4, nextProtocol)
        })
    }

    static func serverInit(random: Data, publicKey: Data) -> Data {
        message(.serverInit, ProtoWriter.build {
            $0.number(1, 1)
            $0.bytes(2, random)
            $0.number(3, p256SHA512)
            $0.bytes(4, publicKey)
        })
    }

    static func clientFinish(publicKey: Data) -> Data {
        message(.clientFinish, ProtoWriter.build { $0.bytes(1, publicKey) })
    }
}
