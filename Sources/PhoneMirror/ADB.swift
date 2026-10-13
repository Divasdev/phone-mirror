import Foundation

/// One phone as reported by `adb devices -l`.
struct Device: Equatable {
    enum Connection { case usb, wifi }

    let serial: String       // e.g. "abc123" (USB) or "192.168.1.50:5555" (Wi-Fi)
    let state: String        // "device" = ready, or "unauthorized", "offline", ...
    let model: String?       // e.g. "2201116PI"
    let connection: Connection

    var isReady: Bool { state == "device" }
}

/// Small, safe wrapper around the adb program.
/// Every call uses an arguments array — never a shell string.
struct ADB {
    let executable: URL

    var environment: [String: String] {
        ProcessRunner.safeEnvironment(adbPath: executable.path)
    }

    /// Run `adb <arguments>`.
    func run(_ arguments: [String], timeout: TimeInterval = 10) async -> ProcessResult {
        await ProcessRunner.run(executable, arguments, environment: environment, timeout: timeout)
    }

    /// Same, but blocking — only used while the app is quitting.
    func runBlocking(_ arguments: [String], timeout: TimeInterval = 4) -> ProcessResult {
        ProcessRunner.runBlocking(executable, arguments, environment: environment, timeout: timeout)
    }

    /// Start the adb background server once, with its output sent nowhere.
    func startServer() async {
        _ = await run(["start-server"], timeout: 10)
    }

    // MARK: Devices

    func devices() async -> [Device] {
        ADB.parseDevices(await run(["devices", "-l"], timeout: 5).stdout)
    }

    func devicesBlocking() -> [Device] {
        ADB.parseDevices(runBlocking(["devices", "-l"], timeout: 3).stdout)
    }

    /// Turns the text output of `adb devices -l` into Device values.
    static func parseDevices(_ text: String) -> [Device] {
        var result: [Device] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Skip the header and adb's "* daemon started *" messages.
            guard fields.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { continue }

            let serial = fields[0]
            guard Validation.isSafeSerial(serial) else { continue }

            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) }
            result.append(Device(serial: serial, state: fields[1], model: model,
                                 connection: connectionType(for: serial)))
        }
        return result
    }

    /// The IP part of a Wi-Fi serial like "192.168.0.10:5555" (nil for USB / mDNS names).
    static func ipAddress(ofSerial serial: String) -> String? {
        Validation.privateHostPort(serial)?.ip
    }

    /// Wi-Fi devices show up as "ip:port" or as an mDNS name (Android 11+ wireless debugging).
    static func connectionType(for serial: String) -> Device.Connection {
        if serial.contains("._adb-tls-connect._tcp") { return .wifi }
        let pieces = serial.split(separator: ":")
        if pieces.count == 2, Validation.parseIPv4(String(pieces[0])) != nil { return .wifi }
        return .usb
    }

    // MARK: Wireless

    /// `adb connect ip:port` — only after the IP and port pass validation.
    func connect(ip: String, port: Int) async -> (ok: Bool, output: String) {
        guard Validation.isPrivateLANIPv4(ip), Validation.isValidPort(port) else {
            return (false, "Refused: \(ip):\(port) is not a private home-network address.")
        }
        let result = await run(["connect", "\(ip):\(port)"], timeout: 8)
        let text = result.combinedOutput.lowercased()
        let ok = text.contains("connected to") && !text.contains("failed") && !text.contains("unable")
            && !text.contains("cannot")
        return (ok, result.combinedOutput)
    }

    /// The phone's Wi-Fi band and signal (read-only: `cmd wifi status`).
    func wifiBand(serial: String) async -> WiFiBand? {
        let status = await run(["-s", serial, "shell", "cmd", "wifi", "status"], timeout: 5).stdout
        return ADB.parseWifiFrequency(status).flatMap(WiFiBand.init(frequencyMHz:))
    }

    /// Picks "Frequency: 2412MHz" out of `cmd wifi status`. Only this number is read;
    /// the rest of the output (which includes the network name) is ignored and not kept.
    static func parseWifiFrequency(_ text: String) -> Int? {
        guard text.contains("Wifi is connected") else { return nil }
        for field in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Frequency:") {
                let digits = trimmed.dropFirst("Frequency:".count).drop { $0 == " " }.prefix { $0.isNumber }
                return Int(digits)
            }
        }
        return nil
    }

    /// Reads the phone's Wi-Fi IP address over USB.
    /// Tries `ip route` first, then `ip addr show wlan0`.
    func wifiIP(serial: String) async -> String? {
        let route = await run(["-s", serial, "shell", "ip", "route"], timeout: 5).stdout
        if let ip = ADB.parseIPFromRoute(route) { return ip }

        let addr = await run(["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"], timeout: 5).stdout
        return ADB.parseIPFromAddr(addr)
    }

    /// Example line: "192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.50"
    static func parseIPFromRoute(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("wlan") {
            let words = line.split(separator: " ").map(String.init)
            if let i = words.firstIndex(of: "src"), i + 1 < words.count,
               Validation.parseIPv4(words[i + 1]) != nil {
                return words[i + 1]
            }
        }
        return nil
    }

    /// Example line: "inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0"
    static func parseIPFromAddr(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            if let i = words.firstIndex(of: "inet"), i + 1 < words.count {
                let ip = String(words[i + 1].split(separator: "/")[0])
                if Validation.parseIPv4(ip) != nil { return ip }
            }
        }
        return nil
    }
}
