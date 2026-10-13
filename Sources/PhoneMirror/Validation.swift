import Foundation

/// Input checks. Every IP address, port and device serial is checked here
/// before it is ever handed to adb or scrcpy.
enum Validation {

    /// Parses "a.b.c.d" into four numbers, or returns nil if it's not a
    /// strictly-formatted IPv4 address. We reject leading zeros ("010")
    /// because some tools read those as octal numbers.
    static func parseIPv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// True only for private home/office LAN addresses:
    /// 10.x.x.x, 172.16–31.x.x and 192.168.x.x.
    /// Network (.0) and broadcast (.255) addresses are rejected too.
    static func isPrivateLANIPv4(_ text: String) -> Bool {
        guard let o = parseIPv4(text) else { return false }
        guard o[3] != 0 && o[3] != 255 else { return false }

        switch (o[0], o[1]) {
        case (10, _):         return true
        case (172, 16...31):  return true
        case (192, 168):      return true
        default:              return false
        }
    }

    /// Port must be 5555 (the adb default) or a normal, non-system port.
    static func isValidPort(_ port: Int) -> Bool {
        port == 5555 || (1024...65535).contains(port)
    }

    /// Splits "192.168.0.10:5555" into ("192.168.0.10", 5555) if both parts are valid.
    static func privateHostPort(_ text: String) -> (ip: String, port: Int)? {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let port = Int(pieces[1]),
              isValidPort(port),
              isPrivateLANIPv4(String(pieces[0])) else { return nil }
        return (String(pieces[0]), port)
    }

    /// Device serials come from `adb devices`. Even though we never use a
    /// shell, we still only accept plain characters, and never a leading "-"
    /// (which a program could mistake for an option).
    static func isSafeSerial(_ serial: String) -> Bool {
        guard !serial.isEmpty, serial.count <= 128, !serial.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return serial.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The phone's shared storage (photos, downloads, …). The Files window never leaves it.
    static let phoneStorageRoot = "/sdcard"

    /// One file or folder name, from the phone or about to be created on it: no "/",
    /// no control characters (such as a line break), and not "." or "..".
    static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A phone path we are willing to hand to adb: inside the shared storage and made
    /// only of safe names, so "../" can't be used to climb out of it.
    static func isSafePhonePath(_ path: String) -> Bool {
        guard path.utf8.count <= 1024 else { return false }
        if path == phoneStorageRoot { return true }
        guard path.hasPrefix(phoneStorageRoot + "/") else { return false }
        let names = path.dropFirst(phoneStorageRoot.count + 1)
            .split(separator: "/", omittingEmptySubsequences: false)
        return names.allSatisfy { isSafeFileName(String($0)) }
    }

    /// Video encoder names come from `scrcpy --list-encoders`, e.g. "c2.qti.avc.encoder".
    static func isSafeEncoderName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, !name.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
