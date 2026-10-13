import Foundation

/// Quick Share's messages are written in Google's "Protocol Buffers" format. The app uses
/// Apple frameworks only, so this file holds just enough of that format to read and write
/// the few messages Quick Share needs: numbered fields that are either a whole number
/// ("varint") or a run of bytes (text, raw data, or another message).
struct ProtoWriter {
    private(set) var data = Data()

    /// A whole number (also used for on/off values and for named choices).
    mutating func number(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        raw(value)
    }

    /// A number that may be negative. Negative numbers are sent as their 64-bit pattern.
    mutating func number(_ field: Int, signed value: Int64) {
        number(field, UInt64(bitPattern: value))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        number(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        raw(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    /// A message inside this one.
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        raw(UInt64(field) << 3 | wireType)
    }

    /// Seven bits at a time, smallest first; the top bit says "more follows".
    private mutating func raw(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }

    /// Builds one message in a single expression.
    static func build(_ build: (inout ProtoWriter) -> Void) -> Data {
        var writer = ProtoWriter()
        build(&writer)
        return writer.data
    }
}

/// A received message, split into its numbered fields. Everything in it came from another
/// device, so reading is strict: anything cut short or malformed is an error.
struct ProtoMessage {

    struct Malformed: Error {}

    private enum Value {
        case number(UInt64)
        case bytes(Data)
    }

    private var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var position = 0

        func readNumber() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard position < bytes.count, shift < 64 else { throw Malformed() }
                let byte = bytes[position]
                position += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        while position < bytes.count {
            let key = try readNumber()
            guard key >> 3 > 0, key >> 3 <= 0x1FFF_FFFF else { throw Malformed() }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                fields[field, default: []].append(.number(try readNumber()))
            case 2:
                let length = try readNumber()
                guard length <= UInt64(bytes.count - position) else { throw Malformed() }
                let end = position + Int(length)
                fields[field, default: []].append(.bytes(Data(bytes[position..<end])))
                position = end
            case 1: // a fixed 8-byte number: not used by Quick Share, skipped
                guard bytes.count - position >= 8 else { throw Malformed() }
                position += 8
            case 5: // a fixed 4-byte number: skipped as well
                guard bytes.count - position >= 4 else { throw Malformed() }
                position += 4
            default:
                throw Malformed()
            }
        }
    }

    func has(_ field: Int) -> Bool {
        fields[field] != nil
    }

    /// The field's value as a whole number (when a field is repeated, the last one counts).
    func number(_ field: Int) -> UInt64? {
        guard case .number(let value)? = fields[field]?.last else { return nil }
        return value
    }

    func int(_ field: Int) -> Int? {
        number(field).map { Int(truncatingIfNeeded: Int32(truncatingIfNeeded: $0)) }
    }

    func int64(_ field: Int) -> Int64? {
        number(field).map { Int64(bitPattern: $0) }
    }

    func bool(_ field: Int) -> Bool {
        number(field).map { $0 != 0 } ?? false
    }

    func bytes(_ field: Int) -> Data? {
        guard case .bytes(let value)? = fields[field]?.last else { return nil }
        return value
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A message inside this one (nil when the field is missing).
    func message(_ field: Int) throws -> ProtoMessage? {
        try bytes(field).map(ProtoMessage.init)
    }

    /// Every value of a field that may appear several times.
    func messages(_ field: Int) throws -> [ProtoMessage] {
        try (fields[field] ?? []).compactMap { value in
            guard case .bytes(let data) = value else { return nil }
            return try ProtoMessage(data)
        }
    }

    func count(of field: Int) -> Int {
        fields[field]?.count ?? 0
    }
}

extension Data {
    /// Base64 with "-" and "_" and no "=" at the end, the way Quick Share writes names.
    var urlSafeBase64: String {
        base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    init?(urlSafeBase64 text: String) {
        var standard = text.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while standard.count % 4 != 0 { standard += "=" }
        self.init(base64Encoded: standard)
    }

    /// Bytes from the system's secure random source.
    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}
