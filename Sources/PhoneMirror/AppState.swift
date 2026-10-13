import AppKit
import ServiceManagement

/// One FPS reading from scrcpy's counter.
struct FPSReading: Equatable {
    var fps: Int
    var skipped: Int
}

/// The app's "brain": current status, saved settings, and the Mirror action.
/// Wireless/hotspot actions live in AppState+Wireless.swift and the connection
/// quality check in AppState+Quality.swift.
/// Everything here runs on the main thread; slow work (adb, ping) is awaited.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Live status (shown in the menu, changed only by AppState's own code)

    @Published var devices: [Device] = []
    @Published var isMirroring = false
    @Published var busyMessage: String?          // e.g. "Connecting…"
    @Published var lastError: FriendlyError?
    @Published var launchAtLogin = false
    @Published var quality: ConnectionQuality?   // measured only while the menu is open
    @Published var isCheckingQuality = false
    @Published var fps: FPSReading?              // live, while mirroring with "Show FPS" on
    @Published var mirroringLabel: String?       // which settings the running mirror uses
    @Published var mirroringInPocketMode = false // the running mirror keeps the phone's screen off
    @Published var macRouterIP: String?          // the Mac's Wi-Fi router (= phone on hotspot)
    @Published var quickShareStatus = QuickShareReceiver.Status.off

    // MARK: Saved settings (UserDefaults: only the phone IP and UI choices)

    let defaults = UserDefaults.standard

    @Published var preset: QualityPreset {
        didSet {
            defaults.set(preset.rawValue, forKey: "preset")
            if preset.turnsAudioOff { audio = false } // Wi-Fi presets are --no-audio
        }
    }
    @Published var pocketMode: Bool {
        didSet {
            defaults.set(pocketMode, forKey: "pocketMode")
            // Ticked or unticked while the phone is being mirrored: start the mirror again, so it
            // takes effect now and not only the next time.
            if isMirroring, pocketMode != mirroringInPocketMode { restartMirror() }
        }
    }
    @Published var stayAwake: Bool     { didSet { defaults.set(stayAwake, forKey: "stayAwake") } }
    @Published var realKeyboard: Bool  { didSet { defaults.set(realKeyboard, forKey: "realKeyboard") } }
    @Published var audio: Bool         { didSet { defaults.set(audio, forKey: "audio") } }
    @Published var showFPS: Bool       { didSet { defaults.set(showFPS, forKey: "showFPS") } }
    @Published var autoDisableWirelessOnQuit: Bool {
        didSet { defaults.set(autoDisableWirelessOnQuit, forKey: "autoDisableWirelessOnQuit") }
    }
    /// "Receive with Quick Share": off until the person switches it on.
    @Published var quickShareOn: Bool {
        didSet {
            defaults.set(quickShareOn, forKey: "quickShareReceive")
            applyQuickShare()
        }
    }

    /// Last known phone IP on the home Wi-Fi (validated before saving AND before using).
    var savedIP: String? {
        get {
            guard let ip = defaults.string(forKey: "lastPhoneIP"), Validation.isPrivateLANIPv4(ip) else { return nil }
            return ip
        }
        set {
            if let ip = newValue, Validation.isPrivateLANIPv4(ip) {
                defaults.set(ip, forKey: "lastPhoneIP")
            } else {
                defaults.removeObject(forKey: "lastPhoneIP")
            }
        }
    }
    /// Was the last wireless connection made through the phone's hotspot?
    var lastWasHotspot: Bool {
        get { defaults.bool(forKey: "lastWasHotspot") }
        set { defaults.set(newValue, forKey: "lastWasHotspot") }
    }
    let wirelessPort = 5555

    // MARK: Tools and helpers

    let adb: ADB?
    let scrcpyURL: URL?
    let scrcpy = ScrcpyRunner()
    let quickShare = QuickShareReceiver()
    var mirroredSerial: String?
    private var refreshTimer: Timer?

    /// Hardware encoder found per phone model (memory only; nil = none found).
    private var encoderCache: [String: String?] = [:]
    /// Phones whose encoder refused our extra encoder options this session.
    private var encoderTweaksRejected: Set<String> = []
    /// The connection check that is running right now, if any (see AppState+Quality.swift).
    var qualityCheck: (link: ConnectionQuality.Link, task: Task<ConnectionQuality, Never>)?
    /// What the running mirror was started with (used for the automatic retry).
    private var currentLaunch: (settings: StreamSettings, target: Device, usedTweaks: Bool, startedAt: Date)?
    /// Set while the app itself is starting the mirror again: what to start once the old one has ended.
    private var relaunchAfterStop: (settings: StreamSettings, target: Device)?
    /// Watches the phone while it is mirrored in Pocket mode (see `startPocketGuard`).
    private var pocketGuard: Task<Void, Never>?
    /// When the phone was woken again after its power button was pressed in Pocket mode.
    private var pocketWakeUps: [Date] = []

    /// True the very first time the app runs on this Mac (nothing saved yet).
    private let isFirstLaunch: Bool

    private init() {
        adb = ToolLocator.findADB().map { ADB(executable: $0) }
        scrcpyURL = ToolLocator.findScrcpy()
        isFirstLaunch = defaults.object(forKey: "settingsVersion") == nil

        // Version 2 of the settings introduced "Auto"; switch to it once.
        if defaults.integer(forKey: "settingsVersion") < 2 {
            defaults.set(QualityPreset.auto.rawValue, forKey: "preset")
            defaults.set(2, forKey: "settingsVersion")
        }
        preset = QualityPreset(rawValue: defaults.string(forKey: "preset") ?? "") ?? .auto
        // "Pocket mode" replaced the older "Turn phone screen off" choice.
        pocketMode = defaults.object(forKey: "pocketMode") as? Bool ?? defaults.bool(forKey: "turnScreenOff")
        stayAwake = defaults.object(forKey: "stayAwake") as? Bool ?? true
        realKeyboard = defaults.bool(forKey: "realKeyboard")
        audio = defaults.bool(forKey: "audio")
        showFPS = defaults.bool(forKey: "showFPS")
        autoDisableWirelessOnQuit = defaults.object(forKey: "autoDisableWirelessOnQuit") as? Bool ?? true
        quickShareOn = defaults.bool(forKey: "quickShareReceive")
    }

    // MARK: Derived values for the menu

    var toolsFound: Bool { adb != nil && scrcpyURL != nil }
    var isBusy: Bool { busyMessage != nil }
    var hasUSBDevice: Bool { devices.contains { $0.connection == .usb && $0.isReady } }
    /// Any Wi-Fi adb connection means wireless debugging is on.
    var wirelessActive: Bool { devices.contains { $0.connection == .wifi } }

    /// True when a connected phone's address is the Mac's Wi-Fi router, i.e. the Mac is
    /// joined to the phone's hotspot.
    func isHotspot(_ device: Device) -> Bool {
        guard device.connection == .wifi, let ip = ADB.ipAddress(ofSerial: device.serial) else { return false }
        return ip == macRouterIP
    }
    var isOnHotspot: Bool { devices.contains { $0.isReady && isHotspot($0) } }

    var statusText: String {
        guard toolsFound else { return "adb or scrcpy not found" }
        let ready = devices.filter(\.isReady)
        let usb = ready.first { $0.connection == .usb }
        let wifi = ready.first { $0.connection == .wifi }
        let name = (usb ?? wifi)?.model.map { " (\($0))" } ?? ""
        let wifiKind = wifi.map { isHotspot($0) ? "Hotspot" : "Wi-Fi" } ?? "Wi-Fi"

        if usb != nil && wifi != nil { return "Connected via USB + \(wifiKind)\(name)" }
        if usb != nil { return "Connected via USB\(name)" }
        if wifi != nil { return "Connected via \(wifiKind)\(name)" }
        if devices.contains(where: { $0.state == "unauthorized" }) { return "Tap “Allow” on your phone" }
        return "Phone not found"
    }

    /// e.g. "Mirroring: Low latency (Wi-Fi) · 58 fps (+2 skipped)"
    var mirroringLine: String? {
        guard isMirroring, let mirroringLabel else { return nil }
        var text = "Mirroring: \(mirroringLabel)"
        if let fps {
            text += " · \(fps.fps) fps"
            if fps.skipped > 0 { text += " (+\(fps.skipped) skipped)" }
        }
        return text
    }

    var menuBarSymbol: String {
        isMirroring ? "iphone.radiowaves.left.and.right" : "smartphone"
    }

    // MARK: Startup and status refresh

    /// Called once when the app launches.
    func start() {
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Refresh status only while the menu is open (no background polling).
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppState.shared.menuOpened() }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppState.shared.menuClosed() }
        }

        Task {
            await adb?.startServer()
            await refresh()
        }
        connectQuickShare()
        applyQuickShare()
        // New here? Show the three setup steps once.
        if isFirstLaunch { showSetup() }
    }

    private func menuOpened() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task {
            await refresh()
            checkQualityIfNeeded()
        }
        refreshTimer?.invalidate()
        // .common mode so the timer also fires while the menu is being shown.
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                await AppState.shared.refresh()
                AppState.shared.checkQualityIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func menuClosed() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Ask adb which phones are connected (and which router the Mac's Wi-Fi uses).
    func refresh() async {
        guard let adb else { return }
        devices = await adb.devices()
        macRouterIP = MacNetwork.wifiRouterIP()
    }

    // MARK: Mirror

    func mirror() {
        guard !isMirroring, !isBusy else { return }
        Task { await mirrorNow() }
    }

    private func mirrorNow() async {
        guard let adb, scrcpyURL != nil else { return show(.toolsMissing) }
        busyMessage = "Looking for your phone…"
        defer { busyMessage = nil }

        var found = await adb.devices()
        macRouterIP = MacNetwork.wifiRouterIP()
        var target = pickDevice(from: found)

        // No phone? Try reconnecting to the addresses we remember.
        var reconnectOutput = ""
        if target == nil {
            for ip in reconnectAddresses() {
                busyMessage = "Reconnecting to \(ip)…"
                reconnectOutput = await adb.connect(ip: ip, port: wirelessPort).output
                try? await Task.sleep(for: .milliseconds(500))
                found = await adb.devices()
                target = pickDevice(from: found)
                if target != nil { break }
            }
        }
        devices = found

        guard let target else {
            if found.contains(where: { $0.state == "unauthorized" }) { return show(.unauthorized()) }
            return show(.phoneNotFound(details: reconnectOutput))
        }

        let settings = await streamSettings(for: target)
        await launch(settings, on: target, safeMode: encoderTweaksRejected.contains(encoderKey(target)))
    }

    /// Last home Wi-Fi IP, and (if the last wireless connection was through the phone's
    /// hotspot) the Mac's current Wi-Fi router, which is the phone on a hotspot.
    private func reconnectAddresses() -> [String] {
        var addresses: [String] = []
        let hotspotIP = lastWasHotspot ? macRouterIP : nil
        if let hotspotIP { addresses.append(hotspotIP) }
        if let savedIP, savedIP != hotspotIP { addresses.append(savedIP) }
        return addresses
    }

    /// Prefer a ready USB phone, then a ready Wi-Fi phone (private IPs only).
    /// Passing its exact serial with `-s` avoids the "multiple devices" error.
    func pickDevice(from list: [Device]) -> Device? {
        let ready = list.filter(\.isReady)
        if let usb = ready.first(where: { $0.connection == .usb }) { return usb }
        return ready.first { device in
            device.connection == .wifi &&
            (Validation.privateHostPort(device.serial) != nil || device.serial.contains("._adb-tls-connect._tcp"))
        }
    }

    /// Turn the chosen preset into concrete settings. "Auto" looks at the connection:
    /// USB → Best, Wi-Fi → Low latency, weak Wi-Fi → Low latency at half the bitrate.
    private func streamSettings(for target: Device) async -> StreamSettings {
        switch preset {
        case .best:       return .best
        case .smooth:     return .smooth
        case .lowLag:     return .dataSaver
        case .lowLatency: return .lowLatency()
        case .auto:
            if target.connection == .usb {
                var settings = StreamSettings.best
                settings.label = "Auto → Best (USB)"
                return settings
            }
            busyMessage = "Checking Wi-Fi quality…"
            if await recentQuality(for: target)?.rating == .poor {
                return .lowLatency(bitRate: "2M", label: "Auto → Low latency, 2 Mbps (weak Wi-Fi)")
            }
            return .lowLatency(label: "Auto → Low latency (Wi-Fi)")
        }
    }

    /// Hardware encoders are looked up per phone model.
    private func encoderKey(_ device: Device) -> String { device.model ?? device.serial }

    /// Finds the phone's hardware H.264 encoder once (`scrcpy --list-encoders`), then
    /// remembers it in memory for this session.
    private func hardwareEncoder(for target: Device) async -> String? {
        let key = encoderKey(target)
        if let cached = encoderCache[key] { return cached }
        guard let adb, let scrcpyURL else { return nil }
        busyMessage = "Checking your phone’s video encoder…"
        let result = await ProcessRunner.run(scrcpyURL, ["-s", target.serial, "--list-encoders"],
                                             environment: adb.environment, timeout: 20)
        let name = ScrcpyOutput.hardwareH264Encoder(in: result.combinedOutput)
        encoderCache[key] = .some(name)
        return name
    }

    /// Start scrcpy with the given settings.
    /// - safeMode: leave out the extra encoder options (used after the phone rejected them).
    private func launch(_ settings: StreamSettings, on target: Device, safeMode: Bool) async {
        guard let adb, let scrcpyURL else { return show(.toolsMissing) }

        var encoder: String?
        if settings.wantsHardwareEncoder && !safeMode {
            encoder = await hardwareEncoder(for: target)
        }

        var arguments = MirrorOptions.basics(serial: target.serial)
        arguments += settings.scrcpyArguments(hardwareEncoder: encoder, safeMode: safeMode)
        let options = MirrorOptions(pocketMode: pocketMode, stayAwake: stayAwake, realKeyboard: realKeyboard,
                                    audio: audio, showFPS: showFPS, overWiFi: target.connection == .wifi)
        arguments += options.arguments

        do {
            fps = nil
            try scrcpy.start(executable: scrcpyURL, arguments: arguments, environment: adb.environment,
                             onLine: { line in
                                 guard let reading = ScrcpyOutput.fps(in: line) else { return }
                                 DispatchQueue.main.async {
                                     MainActor.assumeIsolated {
                                         AppState.shared.fps = FPSReading(fps: reading.fps, skipped: reading.skipped)
                                     }
                                 }
                             },
                             onExit: { [weak self] exitCode, output, stoppedByUser in
                                 self?.mirroringEnded(exitCode: exitCode, output: output, stoppedByUser: stoppedByUser)
                             })
            isMirroring = true
            mirroringInPocketMode = options.pocketMode
            mirroredSerial = target.serial
            mirroringLabel = settings.label + (safeMode && settings.usesEncoderTweaks(hardwareEncoder: nil) ? " – basic mode" : "")
            lastError = nil
            currentLaunch = (settings, target, !safeMode && settings.usesEncoderTweaks(hardwareEncoder: encoder), Date())
            startPocketGuard(for: target)
        } catch {
            show(FriendlyError(title: "Couldn't start scrcpy.",
                               advice: "Try reinstalling it with: brew reinstall scrcpy",
                               details: error.localizedDescription))
        }
    }

    private func mirroringEnded(exitCode: Int32, output: String, stoppedByUser: Bool) {
        isMirroring = false
        mirroringInPocketMode = false
        mirroredSerial = nil
        mirroringLabel = nil
        fps = nil
        let launched = currentLaunch
        currentLaunch = nil
        pocketGuard?.cancel()
        pocketGuard = nil

        // The app stopped this mirror itself in order to start it again (see `restartMirror`).
        if let again = relaunchAfterStop {
            relaunchAfterStop = nil
            Task { await launch(again.settings, on: again.target, safeMode: encoderTweaksRejected.contains(encoderKey(again.target))) }
            return
        }

        // Exit code 0 = you closed the window. Anything else is a problem.
        if !stoppedByUser && exitCode != 0 {
            // If the phone's encoder refused our extra options, quietly try once more
            // with plain settings (and remember that for this phone).
            if let launched, launched.usedTweaks,
               Date().timeIntervalSince(launched.startedAt) < 20,
               ScrcpyOutput.looksLikeEncoderError(output) {
                encoderTweaksRejected.insert(encoderKey(launched.target))
                Task { await launch(launched.settings, on: launched.target, safeMode: true) }
                return
            }
            show(.fromScrcpy(exitCode: exitCode, output: output))
        }
        Task { await refresh() }
    }

    func stopMirroring() {
        relaunchAfterStop = nil
        scrcpy.stop()
    }

    /// Stops the running mirror and starts it again with the same preset and the options as they
    /// are now. The window closes and comes back about two seconds later.
    func restartMirror() {
        guard isMirroring, let launched = currentLaunch else { return }
        relaunchAfterStop = (launched.settings, launched.target)
        scrcpy.stop()
    }

    // MARK: Pocket mode: the phone's own power button

    /// In Pocket mode the phone's screen is dark but the phone is awake. Its power button really
    /// puts it to sleep: nothing is drawn any more, so the mirror stands still. That is how Android
    /// works and can't be switched off. So while a Pocket mode mirror runs, the app asks the phone
    /// every few seconds whether it is still awake (one short read-only question), and when it has
    /// been put to sleep, starts the mirror again: starting wakes the phone and darkens its screen,
    /// and the mirror shows the lock screen, ready for the PIN from the Mac's keyboard.
    private func startPocketGuard(for target: Device) {
        pocketGuard?.cancel()
        pocketGuard = nil
        guard mirroringInPocketMode, let adb else { return }
        pocketGuard = Task { [weak self] in
            // A new mirror needs a moment: scrcpy is still waking the phone and darkening it.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.isMirroring, self.mirroringInPocketMode else { return }
                let awake = await adb.isAwake(serial: target.serial)
                guard !Task.isCancelled else { return }
                if awake == false {
                    self.phoneWasPutToSleepInPocketMode()
                    return
                }
            }
        }
    }

    private func phoneWasPutToSleepInPocketMode() {
        // Three times in two minutes means somebody wants this phone asleep: leave it alone.
        let now = Date()
        pocketWakeUps = pocketWakeUps.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard pocketWakeUps.count <= 3 else { return }
        restartMirror()
    }

    // MARK: Files

    /// Opens the "Phone Files" window (drag files in and out of the phone).
    func showFiles() {
        FilesWindowController.shared.show()
    }

    /// Opens the "Getting Started" window (engine, USB debugging, cable).
    func showSetup() {
        SetupWindowController.shared.show()
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show(FriendlyError(title: "Couldn’t change “Launch at login”.",
                               advice: "Make sure Phone Mirror is in your Applications folder, then try again. You can also check System Settings → General → Login Items.",
                               details: error.localizedDescription))
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Errors

    func show(_ error: FriendlyError) {
        lastError = error
        busyMessage = nil
        error.present()
    }

    func showLastErrorDetails() {
        guard let lastError else { return }
        FriendlyError.showDetails(lastError.details.isEmpty
                                  ? "\(lastError.title)\n\n\(lastError.advice)"
                                  : lastError.details)
    }

    func showScrcpyOutput() {
        FriendlyError.showDetails(scrcpy.recentOutput)
    }

    // MARK: Quit

    /// Called when the app quits: close the mirror window, and (if enabled)
    /// switch wireless debugging off. Runs synchronously with short timeouts.
    func cleanupForQuit() {
        scrcpy.stopAndWait()
        FileBrowser.shared.transfers.cancel() // don't leave a half-finished copy running
        quickShare.stopAndWait()              // stop listening; half-received files are removed

        guard autoDisableWirelessOnQuit, let adb else { return }
        let current = adb.devicesBlocking()
        guard current.contains(where: { $0.connection == .wifi }) else { return }

        let ready = current.filter(\.isReady)
        if let target = ready.first(where: { $0.connection == .wifi }) ?? ready.first(where: { $0.connection == .usb }) {
            _ = adb.runBlocking(["-s", target.serial, "usb"])
        }
        for device in current where device.connection == .wifi {
            _ = adb.runBlocking(["disconnect", device.serial])
        }
    }
}
