import CommonCrypto
import CryptoKit
import Foundation

/// One side's half of the Quick Share key exchange. Each connection gets a fresh key pair,
/// both sides swap public keys, and from the shared secret they derive the keys that
/// encrypt and sign everything that follows. Nothing here is this app's own invention:
/// it is Google's published "UKEY2" handshake, done with Apple's CryptoKit.
struct QuickShareHandshake {

    struct Failed: Error {}

    private let privateKey = P256.KeyAgreement.PrivateKey()

    /// This side's public key, wrapped the way the handshake messages carry it.
    var publicKeyMessage: Data {
        let raw = privateKey.publicKey.rawRepresentation // x and y, 32 bytes each
        return ProtoWriter.build { key in
            key.number(1, 1) // a P-256 key
            key.message(2) { point in
                point.bytes(1, Self.javaNumber(raw.prefix(32)))
                point.bytes(2, Self.javaNumber(raw.suffix(32)))
            }
        }
    }

    /// Finishes the exchange with the other side's public key and the two opening messages
    /// exactly as they were sent (they are mixed into the keys, so nobody can swap them).
    func finish(peerKeyMessage: Data, clientInit: Data, serverInit: Data, asServer: Bool) throws -> SecureChannel {
        guard let key = try? ProtoMessage(peerKeyMessage), key.number(1) == 1,
              let point = try? key.message(2),
              let x = point.bytes(1).flatMap(Self.fieldBytes), let y = point.bytes(2).flatMap(Self.fieldBytes),
              let peer = try? P256.KeyAgreement.PublicKey(rawRepresentation: x + y), // also checks it is on the curve
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
            throw Ukey2.Refused(alert: .badPublicKey)
        }
        let secret = SymmetricKey(data: Data(SHA256.hash(data: shared.withUnsafeBytes { Data($0) })))
        let transcript = clientInit + serverInit

        let auth = Self.derive(secret, salt: Data("UKEY2 v1 auth".utf8), info: transcript)
        let next = Self.derive(secret, salt: Data("UKEY2 v1 next".utf8), info: transcript)

        let d2dSalt = Data(SHA256.hash(data: Data("D2D".utf8)))
        let clientKey = Self.derive(next, salt: d2dSalt, info: Data("client".utf8))
        let serverKey = Self.derive(next, salt: d2dSalt, info: Data("server".utf8))

        let messageSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))
        func keys(_ from: SymmetricKey) -> (encryption: Data, signing: SymmetricKey) {
            (Self.derive(from, salt: messageSalt, info: Data("ENC:2".utf8)).withUnsafeBytes { Data($0) },
             Self.derive(from, salt: messageSalt, info: Data("SIG:1".utf8)))
        }
        let mine = keys(asServer ? serverKey : clientKey)
        let theirs = keys(asServer ? clientKey : serverKey)
        return SecureChannel(code: Self.code(from: auth.withUnsafeBytes { Data($0) }),
                             encryptKey: mine.encryption, sendSigningKey: mine.signing,
                             decryptKey: theirs.encryption, receiveSigningKey: theirs.signing)
    }

    private static func derive(_ key: SymmetricKey, salt: Data, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: info, outputByteCount: 32)
    }

    /// The 4-digit code both devices can show, so a person can check that the two ends of
    /// the connection really are their phone and their Mac. Same sum as Android's.
    static func code(from auth: Data) -> String {
        var hash = 0
        var multiplier = 1
        for byte in auth {
            hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }

    /// Android writes key numbers the way Java does: no leading zero bytes, except one when
    /// the first byte's top bit is set (so the number can't be read as negative).
    static func javaNumber(_ bytes: Data) -> Data {
        var trimmed = Data(bytes.drop { $0 == 0 })
        if trimmed.isEmpty { return Data([0]) }
        if trimmed[trimmed.startIndex] & 0x80 != 0 { trimmed.insert(0, at: trimmed.startIndex) }
        return trimmed
    }

    /// The reverse: exactly 32 bytes, or nil if the number can't be a P-256 coordinate.
    static func fieldBytes(_ number: Data) -> Data? {
        let trimmed = Data(number.drop { $0 == 0 })
        guard trimmed.count <= 32 else { return nil }
        return Data(repeating: 0, count: 32 - trimmed.count) + trimmed
    }
}

/// The encrypted connection after the handshake. Every message is encrypted with
/// AES-256-CBC, signed with HMAC-SHA256, and numbered so none can be replayed or dropped.
struct SecureChannel {

    struct Failed: Error {}

    /// The 4-digit code for this connection (see `QuickShareHandshake.code`).
    let code: String

    private let encryptKey: Data
    private let sendSigningKey: SymmetricKey
    private let decryptKey: Data
    private let receiveSigningKey: SymmetricKey
    private var sent: Int32 = 0
    private var received: Int32 = 0

    fileprivate init(code: String, encryptKey: Data, sendSigningKey: SymmetricKey,
                     decryptKey: Data, receiveSigningKey: SymmetricKey) {
        self.code = code
        self.encryptKey = encryptKey
        self.sendSigningKey = sendSigningKey
        self.decryptKey = decryptKey
        self.receiveSigningKey = receiveSigningKey
    }

    /// Wraps one frame for sending.
    mutating func seal(_ frame: Data) throws -> Data {
        sent += 1
        let number = sent
        let inner = ProtoWriter.build {
            $0.bytes(1, frame)
            $0.number(2, signed: Int64(number))
        }
        let iv = Data.random(kCCBlockSizeAES128)
        let body = try Self.aes(CCOperation(kCCEncrypt), key: encryptKey, iv: iv, input: inner)
        let headerAndBody = ProtoWriter.build { message in
            message.message(1) { header in
                header.number(1, 1) // signed with HMAC-SHA256
                header.number(2, 2) // encrypted with AES-256-CBC
                header.bytes(5, iv)
                header.bytes(6, ProtoWriter.build {
                    $0.number(1, 13) // a device-to-device message
                    $0.number(2, 1)
                })
            }
            message.bytes(2, body)
        }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: headerAndBody, using: sendSigningKey))
        return ProtoWriter.build {
            $0.bytes(1, headerAndBody)
            $0.bytes(2, signature)
        }
    }

    /// Checks and unwraps one received message. Throws if it was tampered with, wasn't made
    /// with this connection's keys, or arrives out of order.
    mutating func open(_ message: Data) throws -> Data {
        guard let outer = try? ProtoMessage(message),
              let headerAndBody = outer.bytes(1), let signature = outer.bytes(2),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: headerAndBody, using: receiveSigningKey),
              let parts = try? ProtoMessage(headerAndBody),
              let header = try? parts.message(1), let body = parts.bytes(2),
              header.number(1) == 1, header.number(2) == 2, let iv = header.bytes(5) else {
            throw Failed()
        }
        let inner = try ProtoMessage(Self.aes(CCOperation(kCCDecrypt), key: decryptKey, iv: iv, input: body))
        received += 1
        guard let frame = inner.bytes(1), inner.int(2) == Int(received) else { throw Failed() }
        return frame
    }

    private static func aes(_ operation: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw Failed() }
        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { data in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, kCCKeySizeAES256, iv.baseAddress,
                                data.baseAddress, input.count, out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failed() }
        return Data(output.prefix(length))
    }
}
