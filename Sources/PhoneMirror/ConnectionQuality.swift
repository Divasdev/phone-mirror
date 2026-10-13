import Foundation

/// The result of a quick "how good is the link to the phone?" check.
/// It is only measured while the menu is open (never in the background).
struct ConnectionQuality {
    enum Rating: String { case good = "Good", ok = "OK", poor = "Poor" }
    enum Link { case usb, router, hotspot }

    var link: Link
    var phoneBand: WiFiBand?      // the phone's Wi-Fi band (router mode)
    var macBand: WiFiBand?        // the Mac's Wi-Fi band (= the hotspot band in hotspot mode)
    var ping: PingResult?
    var canPing = true            // false for phones connected by name instead of IP
    var measuredAt = Date()

    /// Simple rules based on what we measured on a real phone:
    /// a steady link has a median ping under ~10 ms and small jitter; 2.4 GHz can be OK at
    /// best because it is crowded and every frame crosses it twice via the router.
    var rating: Rating {
        if link == .usb { return .good }
        guard canPing else { return isOn2_4GHz ? .ok : .good }
        guard let ping, let median = ping.medianMs else { return .poor } // no replies
        if median > 30 || ping.jitterMs > 30 || ping.lossPercent >= 10 { return .poor }
        if isOn2_4GHz || median > 10 || ping.jitterMs > 10 || ping.lossPercent > 0 { return .ok }
        return .good
    }

    var isOn2_4GHz: Bool {
        switch link {
        case .usb:     return false
        case .hotspot: return macBand == .ghz2_4
        case .router:  return phoneBand == .ghz2_4 || macBand == .ghz2_4
        }
    }

    /// Show the "Switch to 5 GHz or use Hotspot mode" tip?
    var needsTip: Bool {
        guard link != .usb else { return false }
        return isOn2_4GHz || (ping?.medianMs ?? .infinity) > 15 || (ping?.jitterMs ?? .infinity) > 15
    }

    /// e.g. "Connection: OK · ping 6 ms · jitter 4 ms"
    var summaryLine: String {
        guard link != .usb else { return "Connection: Good · USB cable" }
        var text = "Connection: \(rating.rawValue)"
        if !canPing {
            text += " · ping not available"
        } else if let ping, let median = ping.medianMs {
            text += String(format: " · ping %.0f ms · jitter %.0f ms", median, ping.jitterMs)
            if ping.lossPercent > 0 { text += String(format: " · %.0f%% lost", ping.lossPercent) }
        } else {
            text += " · phone didn't answer ping"
        }
        return text
    }

    /// e.g. "Wi-Fi: phone 2.4 GHz · Mac 2.4 GHz" or "Hotspot link: 5 GHz"
    var bandLine: String? {
        switch link {
        case .usb:
            return nil
        case .hotspot:
            return macBand.map { "Hotspot link: \($0.rawValue) (direct)" }
        case .router:
            let phone = phoneBand?.rawValue ?? "?"
            let mac = macBand?.rawValue ?? "?"
            return "Wi-Fi: phone \(phone) · Mac \(mac) (via router)"
        }
    }
}

/// Ping statistics. Jitter = average change between consecutive round trips.
struct PingResult {
    var times: [Double]           // round-trip times in ms (answered pings only)
    var sent: Int

    var medianMs: Double? {
        guard !times.isEmpty else { return nil }
        let sorted = times.sorted()
        return sorted[sorted.count / 2]
    }

    var jitterMs: Double {
        guard times.count > 1 else { return 0 }
        let diffs = zip(times, times.dropFirst()).map { abs($1 - $0) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    var lossPercent: Double {
        guard sent > 0 else { return 0 }
        return max(0, Double(sent - times.count - PingResult.warmUp)) / Double(sent - PingResult.warmUp) * 100
    }

    /// The first pings wake the phone's Wi-Fi from power saving and are ignored.
    static let warmUp = 2

    /// Parses macOS ping output ("... icmp_seq=3 ttl=64 time=5.123 ms").
    static func parse(_ output: String, sent: Int) -> PingResult {
        var bySequence: [(Int, Double)] = []
        for line in output.split(separator: "\n") {
            guard let seqRange = line.range(of: "icmp_seq="),
                  let timeRange = line.range(of: "time=") else { continue }
            let seq = Int(line[seqRange.upperBound...].prefix { $0.isNumber }) ?? 0
            let time = Double(line[timeRange.upperBound...].prefix { $0.isNumber || $0 == "." }) ?? 0
            bySequence.append((seq, time))
        }
        let kept = bySequence.filter { $0.0 >= warmUp }.map(\.1)
        return PingResult(times: kept, sent: sent)
    }
}

/// Runs macOS's /sbin/ping safely: absolute path, argument array, validated private IP,
/// numeric output only (-n, so no DNS lookups), short and bounded.
enum Pinger {
    static func ping(_ ip: String, count: Int = 12) async -> PingResult? {
        guard Validation.isPrivateLANIPv4(ip), let ping = ToolLocator.findPing() else { return nil }
        let arguments = ["-n", "-c", String(count), "-i", "0.1", "-t", "4", ip]
        let result = await ProcessRunner.run(ping, arguments,
                                             environment: ProcessRunner.safeEnvironment(adbPath: nil),
                                             timeout: 6)
        return PingResult.parse(result.stdout, sent: count)
    }
}
