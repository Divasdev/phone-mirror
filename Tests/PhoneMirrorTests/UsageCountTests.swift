import Foundation
import Testing
@testable import PhoneMirror

// The anonymous usage count (UsageCount.swift). Nothing here goes online: the sender is a fake
// that only remembers what it was given.

private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []
    var accepts = true

    var bodies: [Data] { lock.withLock { _bodies } }
    var signals: [[String: Any]] {
        bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] }.flatMap { $0 }
    }
    var types: [String] { signals.compactMap { $0["type"] as? String } }

    var sender: UsageCount.Sender {
        { request in
            self.lock.withLock { self._bodies.append(request.httpBody ?? Data()) }
            return self.accepts
        }
    }
}

@MainActor
private final class Setup {
    let suite = "phonemirror-usage-\(UUID().uuidString)"
    let defaults: UserDefaults
    let server = FakeServer()
    var date = Date(timeIntervalSince1970: 1_792_000_000) // a fixed day
    var config = UsageCount.Config(appID: "TEST-APP-ID", testMode: false, appVersion: "1.4", buildNumber: "9",
                                   macOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0),
                                   architecture: "arm64")

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    func make() -> UsageCount {
        UsageCount(defaults: defaults, config: config, send: server.sender, now: { [unowned self] in self.date })
    }
}

@MainActor
@Test func theFirstStartCountsAnInstallAndADay() async {
    let setup = Setup()
    let usage = setup.make()
    await usage.record(.installed)?.value
    await usage.record(.opened)?.value
    #expect(setup.server.types == ["TelemetryDeck.Acquisition.newInstallDetected", "TelemetryDeck.Session.started"])

    // The same day again, and a later launch: nothing more. An install is never sent twice.
    #expect(usage.record(.opened) == nil)
    let later = setup.make()
    later.appStarted()
    #expect(later.record(.installed) == nil)
    #expect(setup.server.bodies.count == 2)
}

@MainActor
@Test func eachKindGoesAtMostOnceADay() async {
    let setup = Setup()
    let usage = setup.make()
    await usage.record(.mirrored)?.value
    #expect(usage.record(.mirrored) == nil)
    await usage.record(.quickShareReceived)?.value
    #expect(usage.record(.quickShareReceived) == nil)
    #expect(setup.server.bodies.count == 2)

    setup.date += 24 * 3600 // the next day
    await usage.record(.mirrored)?.value
    #expect(setup.server.types.last == "Feature.mirrorStarted")
    #expect(setup.server.bodies.count == 3)
}

@MainActor
@Test func nothingIsSentWhenSwitchedOffOrWithoutAnAppID() async {
    let setup = Setup()
    let usage = setup.make()
    usage.isOn = false
    usage.appStarted()
    #expect(usage.record(.mirrored) == nil)

    setup.config.appID = ""
    let noID = setup.make()
    noID.isOn = true // switching it back on tries to count the day, but there is no ID to send to
    #expect(noID.record(.opened) == nil)
    noID.appStarted()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(setup.server.bodies.isEmpty)
}

@MainActor
@Test func switchingOffForgetsTheRandomNumber() async {
    let setup = Setup()
    let usage = setup.make()
    await usage.record(.opened)?.value
    let firstUser = setup.server.signals.first?["clientUser"] as? String
    #expect(setup.defaults.string(forKey: UsageCount.idKey) != nil)

    usage.isOn = false
    #expect(setup.defaults.string(forKey: UsageCount.idKey) == nil)
    #expect(setup.defaults.dictionary(forKey: UsageCount.sentKey) == nil)

    usage.isOn = true
    try? await Task.sleep(for: .milliseconds(50))
    let secondUser = setup.server.signals.last?["clientUser"] as? String
    #expect(firstUser != nil && secondUser != nil && firstUser != secondUser)
}

@MainActor
@Test func aCountThatDidNotArriveIsTriedAgain() async {
    let setup = Setup()
    setup.server.accepts = false // offline, or the server said no
    let usage = setup.make()
    await usage.record(.opened)?.value
    setup.server.accepts = true
    await usage.record(.opened)?.value
    #expect(usage.record(.opened) == nil)
    #expect(setup.server.bodies.count == 2)
}

@MainActor
@Test func onlyTheAppAndMacOSVersionsGoOut() async throws {
    let setup = Setup()
    setup.config.testMode = true
    let usage = setup.make()
    await usage.record(.installed)?.value

    let request = try #require(usage.request(for: .opened, today: "2026-10-17"))
    #expect(request.url?.absoluteString == "https://nom.telemetrydeck.com/v2/")
    #expect(request.httpMethod == "POST")
    #expect(request.httpShouldHandleCookies == false)

    let signal = try #require(setup.server.signals.first)
    #expect(Set(signal.keys) == ["appID", "clientUser", "sessionID", "type", "isTestMode", "payload"])
    #expect(signal["appID"] as? String == "TEST-APP-ID")
    #expect(signal["isTestMode"] as? Bool == true)

    // The random number leaves only as a SHA-256 hash.
    let id = try #require(setup.defaults.string(forKey: UsageCount.idKey))
    let user = try #require(signal["clientUser"] as? String)
    #expect(user.count == 64 && user != id && !user.contains(id))

    let payload = try #require(signal["payload"] as? [String: String])
    #expect(payload["TelemetryDeck.AppInfo.version"] == "1.4")
    #expect(payload["TelemetryDeck.Device.systemVersion"] == "macOS 15.1.0")
    #expect(payload["TelemetryDeck.Acquisition.firstSessionDate"] != nil)
    #expect(payload.keys.allSatisfy {
        $0.hasPrefix("TelemetryDeck.AppInfo.") || $0.hasPrefix("TelemetryDeck.Device.")
            || $0 == "TelemetryDeck.Acquisition.firstSessionDate"
    })

    // Nothing that names the person or the Mac.
    let text = String(decoding: setup.server.bodies[0], as: UTF8.self)
    for private_ in [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName, Host.current().localizedName ?? ""]
        where private_.count > 2 {
        #expect(!text.contains(private_), "\(private_) was in the count")
    }
}

@Test func daysFollowTheMacsCalendar() {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 10; parts.day = 17; parts.hour = 23; parts.minute = 59
    let date = Calendar(identifier: .gregorian).date(from: parts)!
    #expect(UsageCount.day(date) == "2026-10-17")
    #expect(UsageCount.day(date + 120) == "2026-10-18")
}
