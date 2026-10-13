import Foundation

/// The "Connection quality" line in the menu. It is measured only while the menu is open
/// (at most every 20 seconds) or right before Auto mode starts mirroring. Nothing runs in
/// the background.
extension AppState {

    /// Called when the menu opens and every few seconds while it stays open.
    func checkQualityIfNeeded() {
        guard let target = pickDevice(from: devices) else {
            quality = nil // no phone connected, nothing to measure
            return
        }
        guard !isCheckingQuality else { return }
        if let quality, quality.link == linkKind(for: target),
           Date().timeIntervalSince(quality.measuredAt) < 20 {
            return // still fresh
        }
        isCheckingQuality = true
        let check = Task { await measureQuality(for: target, pingCount: 12) }
        qualityCheck = (linkKind(for: target), check)
        Task {
            quality = await check.value
            isCheckingQuality = false
            qualityCheck = nil
        }
    }

    /// A recent measurement (< 60 s old) for this phone, or a quick new one.
    func recentQuality(for target: Device) async -> ConnectionQuality? {
        if let quality, quality.link == linkKind(for: target),
           Date().timeIntervalSince(quality.measuredAt) < 60 {
            return quality
        }
        // Opening the menu already started a check: wait for that one instead of pinging
        // the phone a second time (saves about a second before mirroring starts).
        if let running = qualityCheck, running.link == linkKind(for: target) {
            return await running.task.value
        }
        let fresh = await measureQuality(for: target, pingCount: 8)
        quality = fresh
        return fresh
    }

    private func linkKind(for target: Device) -> ConnectionQuality.Link {
        if target.connection == .usb { return .usb }
        return isHotspot(target) ? .hotspot : .router
    }

    /// Measures: the phone's Wi-Fi band (read-only adb query), the Mac's band (read from
    /// macOS), and ping round-trip + jitter to the phone (macOS /sbin/ping).
    private func measureQuality(for target: Device, pingCount: Int) async -> ConnectionQuality {
        let link = linkKind(for: target)
        guard link != .usb else { return ConnectionQuality(link: .usb) }

        let macBand = MacNetwork.wifiLink()?.band
        var phoneBand: WiFiBand?
        if link == .router, let adb {
            phoneBand = await adb.wifiBand(serial: target.serial)
        }
        // Phones connected by name (Android 11+ pairing) have no IP to ping.
        guard let ip = ADB.ipAddress(ofSerial: target.serial) else {
            return ConnectionQuality(link: link, phoneBand: phoneBand, macBand: macBand, canPing: false)
        }
        let ping = await Pinger.ping(ip, count: pingCount)
        return ConnectionQuality(link: link, phoneBand: phoneBand, macBand: macBand, ping: ping)
    }
}
