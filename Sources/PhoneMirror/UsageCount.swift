import CryptoKit
import Foundation

/// The anonymous usage count. The owner's decision of 2026-10-17, an exception to the rule
/// "no analytics": they want to know how many people install and use the app after the launch.
///
/// What is sent, to TelemetryDeck, at most once a day for each kind of event:
///  - that a copy was opened, that it mirrored a phone, that it received a Quick Share;
///  - once per Mac: that it is a new install;
///  - with each: the app version, the macOS version and the chip type (arm64 or x86_64).
/// The copy is told apart from others by a random number made on this Mac, hashed before it
/// leaves. Nothing about the person, the phone, the network, the screen or any file is sent.
/// "Send anonymous usage count" in the menu switches it off (and forgets the random number).
///
/// Apple frameworks only: one plain HTTPS request, no SDK.
@MainActor
final class UsageCount {

    enum Event: String, CaseIterable {
        case installed = "TelemetryDeck.Acquisition.newInstallDetected"
        case opened = "TelemetryDeck.Session.started"
        case mirrored = "Feature.mirrorStarted"
        case quickShareReceived = "Feature.quickShareReceived"
    }

    struct Config {
        /// TelemetryDeck's ID for this app (Info.plist `PMUsageCountAppID`). Empty: nothing is sent.
        var appID: String
        /// The owner's own copy (`build.sh` sets `PMUsageCountTestMode`): kept out of the real numbers.
        var testMode: Bool
        var appVersion: String
        var buildNumber: String
        var macOSVersion: OperatingSystemVersion
        var architecture: String

        /// The values of the running app.
        static var current: Config {
            let info = Bundle.main.infoDictionary ?? [:]
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            return Config(appID: (info["PMUsageCountAppID"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                          testMode: info["PMUsageCountTestMode"] as? Bool ?? false,
                          appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
                          buildNumber: info["CFBundleVersion"] as? String ?? "?",
                          macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
                          architecture: architecture)
        }
    }

    /// Sends one request; true when the server took it.
    typealias Sender = @Sendable (URLRequest) async -> Bool

    static let endpoint = URL(string: "https://nom.telemetrydeck.com/v2/")!

    // UserDefaults keys
    static let onKey = "usageCountOn"            // the menu switch (missing = on)
    static let idKey = "usageCountID"            // the random number for this Mac
    static let sentKey = "usageCountSentDays"    // event → the last day it was sent ("2026-10-17")
    static let installKey = "usageCountInstallSent"

    private let defaults: UserDefaults
    private let config: Config
    private let send: Sender
    private let now: () -> Date
    private let sessionID = UUID().uuidString
    private var inFlight: Set<Event> = []

    init(defaults: UserDefaults = .standard, config: Config = .current,
         send: @escaping Sender = UsageCount.sendOverHTTPS, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.config = config
        self.send = send
        self.now = now
    }

    // MARK: The switch

    var isOn: Bool {
        get { defaults.object(forKey: Self.onKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.onKey)
            if newValue {
                record(.opened)
            } else {
                // Off means off: forget this Mac's random number and the dates.
                defaults.removeObject(forKey: Self.idKey)
                defaults.removeObject(forKey: Self.sentKey)
            }
        }
    }

    // MARK: Recording

    /// Called once at launch.
    func appStarted() {
        if !defaults.bool(forKey: Self.installKey) { record(.installed) }
        record(.opened)
    }

    /// Sends the event unless it was already sent today (an install only ever once).
    /// Returns the sending task, so tests can wait for it.
    @discardableResult
    func record(_ event: Event) -> Task<Void, Never>? {
        guard isOn, !config.appID.isEmpty, !inFlight.contains(event) else { return nil }
        let today = Self.day(now())
        if event == .installed {
            guard !defaults.bool(forKey: Self.installKey) else { return nil }
        } else {
            guard sentDays[event.rawValue] != today else { return nil }
        }
        guard let request = request(for: event, today: today) else { return nil }

        inFlight.insert(event)
        let send = self.send
        return Task { @MainActor in
            let accepted = await send(request)
            self.inFlight.remove(event)
            // Not taken (offline, server trouble): nothing is marked, so it is tried again next time.
            guard accepted, self.isOn else { return }
            if event == .installed {
                self.defaults.set(true, forKey: Self.installKey)
            } else {
                var days = self.sentDays
                days[event.rawValue] = today
                self.defaults.set(days, forKey: Self.sentKey)
            }
        }
    }

    // MARK: The request

    /// The JSON that TelemetryDeck's ingest API takes: an array of signals.
    func request(for event: Event, today: String) -> URLRequest? {
        let signal: [String: Any] = [
            "appID": config.appID,
            "clientUser": clientUser,
            "sessionID": sessionID,
            "type": event.rawValue,
            "isTestMode": config.testMode,
            "payload": payload(for: event, today: today),
        ]
        guard JSONSerialization.isValidJSONObject([signal]),
              let body = try? JSONSerialization.data(withJSONObject: [signal], options: [.sortedKeys]) else { return nil }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = body
        return request
    }

    /// Everything that goes with an event. Keys are TelemetryDeck's own names, so its ready-made
    /// charts (versions, macOS versions) work.
    func payload(for event: Event, today: String) -> [String: String] {
        let os = config.macOSVersion
        var payload = [
            "TelemetryDeck.AppInfo.version": config.appVersion,
            "TelemetryDeck.AppInfo.buildNumber": config.buildNumber,
            "TelemetryDeck.AppInfo.versionAndBuildNumber": "\(config.appVersion) (build \(config.buildNumber))",
            "TelemetryDeck.Device.platform": "macOS",
            "TelemetryDeck.Device.operatingSystem": "macOS",
            "TelemetryDeck.Device.systemVersion": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "TelemetryDeck.Device.systemMajorVersion": "macOS \(os.majorVersion)",
            "TelemetryDeck.Device.systemMajorMinorVersion": "macOS \(os.majorVersion).\(os.minorVersion)",
            "TelemetryDeck.Device.architecture": config.architecture,
        ]
        if event == .installed { payload["TelemetryDeck.Acquisition.firstSessionDate"] = today }
        return payload
    }

    /// This Mac's random number, hashed. Made the first time it is needed.
    private var clientUser: String {
        var id = defaults.string(forKey: Self.idKey) ?? ""
        if UUID(uuidString: id) == nil {
            id = UUID().uuidString
            defaults.set(id, forKey: Self.idKey)
        }
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var sentDays: [String: String] {
        defaults.dictionary(forKey: Self.sentKey) as? [String: String] ?? [:]
    }

    /// The day on this Mac's calendar, e.g. "2026-10-17".
    nonisolated static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Sending

    /// No cookies, no cache, nothing kept between requests.
    nonisolated private static let session = URLSession(configuration: .ephemeral)

    nonisolated static let sendOverHTTPS: Sender = { request in
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status)
    }
}
