import Foundation

/// Wireless actions: Go Wireless (via the home router), Hotspot mode (direct link to the
/// phone), and Disconnect Wireless.
extension AppState {

    // MARK: Go Wireless (home router)

    func goWireless() {
        guard !isBusy else { return }
        Task { await goWirelessNow() }
    }

    private func goWirelessNow() async {
        guard let adb else { return show(.toolsMissing) }
        busyMessage = "Checking the USB connection…"
        defer { busyMessage = nil }

        devices = await adb.devices()
        guard let usb = devices.first(where: { $0.connection == .usb && $0.isReady }) else {
            return show(FriendlyError(title: "Plug in your phone first.",
                                      advice: "“Go Wireless” needs the USB cable connected once. Plug it in, unlock the phone, then try again."))
        }

        busyMessage = "Finding your phone’s Wi-Fi address…"
        guard let ip = await adb.wifiIP(serial: usb.serial) else {
            return show(FriendlyError(title: "Couldn’t find your phone’s Wi-Fi address.",
                                      advice: "Make sure Wi-Fi is turned ON on the phone and it’s connected to your home network. (Using the phone’s hotspot instead? Use “Hotspot Mode” in the menu.)"))
        }
        guard Validation.isPrivateLANIPv4(ip) else {
            return show(FriendlyError(title: "That network doesn’t look like a home network.",
                                      advice: "Your phone’s address (\(ip)) isn’t a private home-network address, so Phone Mirror refused to turn on wireless debugging for safety."))
        }

        busyMessage = "Turning on wireless debugging…"
        let tcpip = await adb.run(["-s", usb.serial, "tcpip", String(wirelessPort)])
        guard tcpip.succeeded else {
            return show(FriendlyError(title: "The phone didn’t switch to wireless mode.",
                                      advice: "Unplug and replug the cable, tap Allow if asked, and try again.",
                                      details: tcpip.combinedOutput))
        }
        try? await Task.sleep(for: .seconds(2)) // the phone restarts its adb service

        busyMessage = "Connecting to \(ip)…"
        var failure = await connectOverWiFi(adb, ip: ip, tries: 5)

        // macOS only lets Phone Mirror's own adb reach devices on the Wi-Fi. If another program
        // (Android Studio, a Terminal window) started adb before this app did, the app has been
        // using that one, and macOS answers every connection with "No route to host". Start our
        // own adb and try once more.
        if let output = failure, FriendlyError.looksBlockedByMacOS(output) {
            busyMessage = "Restarting the connection…"
            _ = await adb.run(["kill-server"])
            await adb.startServer()
            try? await Task.sleep(for: .seconds(2))
            busyMessage = "Connecting to \(ip)…"
            failure = await connectOverWiFi(adb, ip: ip, tries: 3)
        }

        guard let failure else {
            savedIP = ip
            lastWasHotspot = false
            await refresh()
            quality = nil // measure the new link next time the menu opens
            busyMessage = nil
            FriendlyError.info("Wireless is ready! 🎉",
                               "Connected to your phone at \(ip).\nYou can unplug the USB cable now, then click “Mirror Phone”.\n\nWhen you're done, use “Disconnect Wireless” to switch it off.")
            return
        }
        // Didn't work: switch the phone back to USB-only instead of leaving it listening.
        _ = await adb.run(["-s", usb.serial, "usb"])
        if FriendlyError.looksBlockedByMacOS(failure) {
            show(.localNetworkBlocked(details: failure))
        } else {
            show(FriendlyError(title: "Couldn’t connect over Wi-Fi.",
                               advice: "Make sure the Mac and phone are on the same Wi-Fi network (not a guest network), then try again.",
                               details: failure))
        }
    }

    /// Tries `adb connect` a few times, a second apart. Returns nil when it worked, otherwise
    /// what adb said last.
    private func connectOverWiFi(_ adb: ADB, ip: String, tries: Int) async -> String? {
        var lastOutput = ""
        for _ in 1...tries {
            let attempt = await adb.connect(ip: ip, port: wirelessPort)
            if attempt.ok { return nil }
            lastOutput = attempt.output
            try? await Task.sleep(for: .seconds(1))
        }
        return lastOutput
    }

    // MARK: Hotspot mode (direct phone → Mac link)

    /// When the Mac is joined to the phone's hotspot, the phone is the Mac's Wi-Fi router.
    /// So we read the router address from macOS, check it's a private address, and connect
    /// adb to it. Video then travels one wireless hop instead of two (phone → router → Mac).
    func connectHotspot() {
        guard !isBusy else { return }
        Task { await connectHotspotNow() }
    }

    private func connectHotspotNow() async {
        guard let adb else { return show(.toolsMissing) }
        busyMessage = "Looking for your phone’s hotspot…"
        defer { busyMessage = nil }

        guard let phoneIP = MacNetwork.wifiRouterIP() else {
            return show(FriendlyError(title: "Your Mac isn’t connected to a Wi-Fi hotspot.",
                                      advice: """
                                      1. On your phone, turn on Hotspot (Settings → Connection & sharing → Portable hotspot).
                                      2. On your Mac, click the Wi-Fi icon and join the phone’s hotspot.
                                      3. Click “Connect via Hotspot” again.
                                      """))
        }
        macRouterIP = phoneIP

        // 1. Try right away: works if the phone's wireless debugging is already on.
        busyMessage = "Connecting to your phone at \(phoneIP)…"
        var attempt = await adb.connect(ip: phoneIP, port: wirelessPort)

        // 2. Otherwise, if the cable is plugged in, switch wireless debugging on and retry.
        let current = await adb.devices()
        let usb = current.first(where: { $0.connection == .usb && $0.isReady })
        if !attempt.ok, let usb {
            busyMessage = "Turning on wireless debugging…"
            _ = await adb.run(["-s", usb.serial, "tcpip", String(wirelessPort)])
            try? await Task.sleep(for: .seconds(2))
            busyMessage = "Connecting to your phone at \(phoneIP)…"
            for _ in 1...2 where !attempt.ok {
                attempt = await adb.connect(ip: phoneIP, port: wirelessPort)
                if !attempt.ok { try? await Task.sleep(for: .seconds(1)) }
            }
            // Still no luck: don't leave wireless debugging switched on for nothing.
            if !attempt.ok {
                _ = await adb.run(["-s", usb.serial, "usb"])
            }
        }

        if attempt.ok {
            lastWasHotspot = true
            await refresh()
            quality = nil
            busyMessage = nil
            FriendlyError.info("Connected directly to your phone 🎉",
                               """
                               Phone Mirror is now talking to your phone through its hotspot, with no router in between.
                               You can unplug the cable and click “Mirror Phone”.

                               Note: while your Mac is on the phone’s hotspot, it uses the phone’s mobile data for internet.
                               """)
            return
        }

        // A router in the same network as the phone's home address = still on home Wi-Fi.
        let homeNetwork = savedIP.map { $0.split(separator: ".").prefix(3) == phoneIP.split(separator: ".").prefix(3) } ?? false
        show(FriendlyError(title: homeNetwork ? "Your Mac seems to be on your home Wi-Fi, not the phone’s hotspot."
                                              : "Couldn’t connect through the hotspot.",
                           advice: """
                           Check:
                           • This Mac is joined to your phone’s hotspot (click the Wi-Fi icon in the menu bar).
                           • Wireless debugging is on: plug in the USB cable, then click “Connect via Hotspot” again.
                             (It turns off whenever the phone restarts or after “Disconnect Wireless”.)
                           """,
                           details: attempt.output))
    }

    // MARK: Disconnect Wireless

    func disconnectWireless() {
        guard !isBusy else { return }
        Task { await disconnectWirelessNow() }
    }

    private func disconnectWirelessNow() async {
        guard let adb else { return show(.toolsMissing) }
        busyMessage = "Turning off wireless debugging…"
        defer { busyMessage = nil }

        // Stop mirroring first if it's running over Wi-Fi.
        if let serial = mirroredSerial, ADB.connectionType(for: serial) == .wifi {
            scrcpy.stop()
        }

        let current = await adb.devices()
        let ok = await Self.switchOffWireless(current, savedIP: savedIP, port: wirelessPort) { args in
            await adb.run(args)
        }
        await refresh()
        quality = nil

        if !ok {
            show(FriendlyError(title: "Disconnected, but the phone couldn’t be reached.",
                               advice: "Your Mac is disconnected. The phone may still be listening for wireless debugging until it restarts. To be sure: plug in the cable and click “Disconnect Wireless” again, or restart the phone."))
        }
    }

    /// The "switch wireless off" steps:
    ///  1. `adb -s <phone> usb`  → the phone stops listening on Wi-Fi (USB-only mode)
    ///  2. `adb disconnect <ip:port>` for every Wi-Fi connection
    /// Returns false if the phone couldn't be told to go USB-only.
    private static func switchOffWireless(_ devices: [Device], savedIP: String?, port: Int,
                                          run: ([String]) async -> ProcessResult) async -> Bool {
        let ready = devices.filter(\.isReady)
        let target = ready.first { $0.connection == .wifi } ?? ready.first { $0.connection == .usb }
        var phoneSwitched = false
        if let target {
            phoneSwitched = await run(["-s", target.serial, "usb"]).succeeded
        }

        var toDisconnect = devices.filter { $0.connection == .wifi }.map(\.serial)
        if let ip = savedIP { toDisconnect.append("\(ip):\(port)") }
        for serial in Set(toDisconnect) {
            _ = await run(["disconnect", serial])
        }
        return phoneSwitched
    }
}
