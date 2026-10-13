import AppKit
import SwiftUI
import Testing

@testable @preconcurrency import PhoneMirror

/// Drives the Files window's model against the pretend phone, the way the window does.
@MainActor
private func browser(for phone: FakePhone, connected: Bool = true) -> FileBrowser {
    let browser = FileBrowser()
    let adb = phone.adb, device = phone.device
    browser.findPhone = { connected ? (adb, [device], device) : (adb, [], nil) }
    return browser
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let start = Date()
    while !condition(), Date().timeIntervalSince(start) < 10 {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theWindowShowsAFolderAndFollowsDoubleClicks() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/report.pdf")
    try phone.add("Download/.secret")
    try phone.add("Download/Trips/day1.jpg")

    let browser = browser(for: phone)
    browser.reload()
    try await waitUntil { !browser.isLoading }
    #expect(browser.files.map(\.name).sorted() == ["Trips", "report.pdf"])
    #expect(browser.notice == nil)
    #expect(browser.linkLine == "USB cable")
    #expect(browser.isConnected)

    browser.open(browser.folder.child("Trips"))
    try await waitUntil { !browser.isLoading }
    #expect(browser.folder.path == "/sdcard/Download/Trips")
    #expect(browser.files.map(\.name) == ["day1.jpg"])

    browser.goUp()
    browser.goUp()
    browser.goUp() // can't go above the shared storage
    try await waitUntil { !browser.isLoading }
    #expect(browser.folder == PhoneFolder())
    #expect(!browser.canGoUp)
    #expect(browser.files.map(\.name) == ["Download"])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theWindowExplainsEmptyFoldersAndAMissingPhone() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }

    let connected = browser(for: phone)
    connected.reload()
    try await waitUntil { !connected.isLoading }
    #expect(connected.notice?.hasPrefix("This folder is empty.") == true)

    connected.open(PhoneFolder(names: ["DCIM", "Screenshots"])) // not on this phone
    try await waitUntil { !connected.isLoading }
    #expect(connected.notice?.hasPrefix("Nothing to show here.") == true)

    let unplugged = browser(for: phone, connected: false)
    unplugged.reload()
    try await waitUntil { !unplugged.isLoading }
    #expect(unplugged.notice?.hasPrefix("Phone not found.") == true)
    #expect(!unplugged.isConnected)
    unplugged.send([URL(fileURLWithPath: "/etc/hosts")])
    #expect(unplugged.resultLine == "Connect your phone first, then drop the files again.")
}

@MainActor
@Test(.timeLimit(.minutes(1))) func droppedFilesArriveAndTheListUpdates() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/Trips/day1.jpg")
    let mac = try phone.macFolder("mac")
    let song = mac.appendingPathComponent("song.mp3")
    try "la la".write(to: song, atomically: true, encoding: .utf8)

    let browser = browser(for: phone)
    browser.reload()
    try await waitUntil { !browser.isLoading }

    // Dropped on the list: goes into the folder on screen, and the list shows it.
    browser.send([song])
    try await waitUntil { browser.resultLine != nil && !browser.isLoading }
    #expect(browser.resultLine == "✓ Copied 1 item")
    #expect(browser.activity == nil)
    #expect(browser.files.map(\.name).sorted() == ["Trips", "song.mp3"])

    // Dropped on a folder row: goes inside that folder.
    browser.send([song], to: browser.folder.child("Trips"))
    try await waitUntil { browser.resultLine != nil && !browser.isLoading && !browser.transfers.isBusy }
    #expect(phone.names(in: "Download/Trips") == ["day1.jpg", "song.mp3"])

    // The same file again is kept next to the first one, not written over it.
    browser.send([song])
    try await waitUntil { browser.files.count == 3 }
    #expect(phone.names(in: "Download") == ["Trips", "song (2).mp3", "song.mp3"])
}

/// Saves a picture of the window so its layout can be looked at:
///   PHONEMIRROR_SNAPSHOTS=/some/folder swift test
@MainActor
@Test(.timeLimit(.minutes(1))) func pictureOfTheWindow() async throws {
    guard let folder = ProcessInfo.processInfo.environment["PHONEMIRROR_SNAPSHOTS"] else { return }
    let phone = try FakePhone()
    defer { phone.remove() }
    for name in ["IMG_20261005_184502.jpg", "IMG_20261005_184733.jpg", "VID_20261004_201145.mp4",
                 "Screenshot_2026-10-06-07-12-44-812_com.android.chrome.jpg", "notes for class.pdf", "song.mp3"] {
        try phone.add("Download/" + name, String(repeating: "x", count: 1000 + name.count * 9000))
    }
    try phone.add("Download/Trips/day1.jpg")
    try phone.add("Download/WhatsApp Documents/a.pdf")

    _ = NSApplication.shared
    let browser = browser(for: phone)
    let host = NSHostingView(rootView: FilesView().environmentObject(browser))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Phone Files"
    window.isReleasedWhenClosed = false // ARC owns it; AppKit must not free it a second time
    window.appearance = pictureAppearance
    window.contentView = host
    window.orderBack(nil)

    func snap(_ name: String) throws {
        host.layoutSubtreeIfNeeded()
        try savePicture(of: window, to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    browser.reload()
    try await waitUntil { !browser.isLoading }
    try await Task.sleep(for: .milliseconds(400))
    try snap("files-window.png")

    browser.open(PhoneFolder(names: ["Movies"]))
    try await waitUntil { !browser.isLoading }
    try await Task.sleep(for: .milliseconds(400))
    try snap("files-window-empty.png")
    window.close()
}

@Test func setupGuideReadsThePhoneStatusFromAdb() {
    typealias Status = SetupGuide.PhoneStatus
    func device(_ serial: String, _ state: String) -> Device {
        Device(serial: serial, state: state, model: nil, connection: ADB.connectionType(for: serial))
    }
    #expect(Status.from([]) == .notFound)
    #expect(Status.from([device("abc123", "unauthorized")]) == .waitingForAllow)
    #expect(Status.from([device("abc123", "offline")]) == .notFound)
    #expect(Status.from([device("abc123", "device")]) == .ready("USB cable"))
    #expect(Status.from([device("192.168.1.50:5555", "device")]) == .ready("Wi-Fi"))
    #expect(Status.from([device("192.168.1.50:5555", "device"), device("abc123", "device")]) == .ready("USB cable"))

    #expect(Status.waitingForAllow.debuggingIsOn && !Status.waitingForAllow.isReady)
    #expect(!Status.notFound.debuggingIsOn)
}

/// Saves pictures of the Getting Started window:
///   PHONEMIRROR_SNAPSHOTS=/some/folder swift test --filter pictureOfTheSetupWindow
@MainActor
@Test(.timeLimit(.minutes(1))) func pictureOfTheSetupWindow() async throws {
    guard let folder = ProcessInfo.processInfo.environment["PHONEMIRROR_SNAPSHOTS"] else { return }
    _ = NSApplication.shared
    let states: [(String, SetupGuide)] = [
        ("setup-waiting.png", SetupGuide(engineFound: true, engineLine: "scrcpy 5.0, included in the app", phone: .notFound)),
        ("setup-ready.png", SetupGuide(engineFound: true, engineLine: "scrcpy 5.0, included in the app", phone: .ready("USB cable"))),
        ("setup-no-engine.png", SetupGuide(engineFound: false, engineLine: "Not found on this Mac", phone: .notFound)),
    ]
    for (name, guide) in states {
        let host = NSHostingView(rootView: SetupView().environmentObject(guide))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Getting Started"
        window.isReleasedWhenClosed = false // ARC owns it; AppKit must not free it a second time
        window.appearance = pictureAppearance
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()

        try savePicture(of: window, to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        window.close()
    }
}

/// Pictures of the Quick Share card in its three main states, for the website:
///   PHONEMIRROR_SNAPSHOTS=/some/folder swift test --filter pictureOfTheQuickShareCard
@MainActor
@Test(.timeLimit(.minutes(1))) func pictureOfTheQuickShareCard() async throws {
    guard let folder = ProcessInfo.processInfo.environment["PHONEMIRROR_SNAPSHOTS"] else { return }
    _ = NSApplication.shared
    let share = IncomingShare(id: UUID(), sender: "Pixel 8", senderKind: .phone, code: "4821",
                              contents: .files([.init(name: "IMG_20261012_101502.jpg", size: 3_400_000),
                                                .init(name: "IMG_20261012_101733.jpg", size: 3_100_000),
                                                .init(name: "notes for class.pdf", size: 900_000)]),
                              totalBytes: 7_400_000)
    let saved = ["IMG_20261012_101502.jpg", "IMG_20261012_101733.jpg", "notes for class.pdf"]
        .map { URL(fileURLWithPath: "/Users/you/Downloads/" + $0) }
    let states: [(String, ShareCard)] = [
        ("quick-share-ask.png", ShareCard(share: share)),
        ("quick-share-receiving.png", ShareCard(share: share, phase: .receiving, receivedBytes: 4_600_000)),
        ("quick-share-saved.png", ShareCard(share: share, phase: .done(.saved(saved)), receivedBytes: 7_400_000)),
    ]
    for (name, card) in states {
        let host = NSHostingView(rootView: ShareCardView(card: card))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Quick Share"
        window.isReleasedWhenClosed = false // ARC owns it; AppKit must not free it a second time
        window.appearance = pictureAppearance
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()

        try savePicture(of: window, to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        window.close()
    }
}

/// PHONEMIRROR_SNAPSHOT_LOOK=light or =dark picks the look of the pictures; without it they
/// follow the Mac's current setting. (The website uses the light ones.)
@MainActor
private var pictureAppearance: NSAppearance? {
    switch ProcessInfo.processInfo.environment["PHONEMIRROR_SNAPSHOT_LOOK"] {
    case "light": return NSAppearance(named: .aqua)
    case "dark":  return NSAppearance(named: .darkAqua)
    default:      return nil
    }
}

/// Draws a whole window (title bar included) into a PNG file.
@MainActor
private func savePicture(of window: NSWindow, to file: URL) throws {
    let frame = try #require(window.contentView?.superview)
    let layer = try #require(frame.layer)
    let size = frame.bounds.size
    let context = try #require(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2)
    (window.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
        context.setFillColor(window.backgroundColor.cgColor)
    }
    context.fill(CGRect(origin: .zero, size: size))
    layer.render(in: context)
    let image = try #require(context.makeImage())
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: file)
}
