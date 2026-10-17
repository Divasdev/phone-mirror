import SwiftUI

/// What the "Getting Started" window shows. It looks for the phone every two seconds, but
/// only while the window is open.
@MainActor
final class SetupGuide: ObservableObject {
    static let shared = SetupGuide()

    enum PhoneStatus: Equatable {
        case looking          // first check not finished yet
        case notFound
        case waitingForAllow  // plugged in, but the popup on the phone wasn't answered
        case ready(String)    // how it is connected, e.g. "USB cable"

        /// Reads the status off adb's list of phones.
        static func from(_ devices: [Device]) -> PhoneStatus {
            let ready = devices.filter(\.isReady)
            if ready.contains(where: { $0.connection == .usb }) { return .ready("USB cable") }
            if ready.contains(where: { $0.connection == .wifi }) { return .ready("Wi-Fi") }
            if devices.contains(where: { $0.state == "unauthorized" }) { return .waitingForAllow }
            return .notFound
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
        /// A phone that answers at all has USB debugging switched on.
        var debuggingIsOn: Bool { isReady || self == .waitingForAllow }
    }

    @Published private(set) var phone = PhoneStatus.looking
    @Published private(set) var engineLine = "Checking…"
    let engineFound: Bool

    private var timer: Timer?

    private init() {
        engineFound = AppState.shared.toolsFound
    }

    /// A fixed state, for pictures of the window (nothing is looked up).
    init(engineFound: Bool, engineLine: String, phone: PhoneStatus) {
        self.engineFound = engineFound
        self.engineLine = engineLine
        self.phone = phone
    }

    func windowOpened() {
        describeEngine()
        check()
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SetupGuide.shared.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowClosed() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard let adb = AppState.shared.adb else {
            phone = .notFound
            return
        }
        Task { phone = PhoneStatus.from(await adb.devices()) }
    }

    /// e.g. "scrcpy 5.0, included in the app"
    private func describeEngine() {
        guard let scrcpy = AppState.shared.scrcpyURL, let adb = AppState.shared.adb else {
            engineLine = "Not found on this Mac"
            return
        }
        let place = ToolLocator.usesBuiltInScrcpy ? "included in the app" : "from Homebrew"
        engineLine = "Found, \(place)"
        Task {
            let output = await ProcessRunner.run(scrcpy, ["--version"], environment: adb.environment, timeout: 5).stdout
            // First line: "scrcpy 5.0 <https://github.com/Genymobile/scrcpy>"
            let words = output.split(separator: "\n").first?.split(separator: " ") ?? []
            if words.count >= 2, words[0] == "scrcpy" { engineLine = "scrcpy \(words[1]), \(place)" }
        }
    }
}

/// Opens the "Getting Started" window.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = FilesWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Getting Started"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SetupView().environmentObject(SetupGuide.shared))
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        SetupGuide.shared.windowOpened()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        SetupGuide.shared.windowClosed()
    }
}

/// Three steps: the engine, the phone's setting, the cable.
struct SetupView: View {
    @EnvironmentObject private var guide: SetupGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Phone Mirror").font(.title2.bold())
                Text("Three steps. You only do this once.").foregroundStyle(.secondary)
            }

            step(1, "The mirroring engine", done: guide.engineFound, problem: !guide.engineFound) {
                Text(guide.engineLine)
                if !guide.engineFound {
                    Text("Open Terminal and run these two lines, then quit and reopen Phone Mirror:")
                    Text("brew install scrcpy\nbrew install --cask android-platform-tools")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            step(2, "On your phone: turn on USB debugging", done: guide.phone.debuggingIsOn) {
                Text("1. Open Settings → About phone and tap “Build number” seven times.")
                Text("2. Go back to Settings → System → Developer options and turn on “USB debugging”.")
                Text("Xiaomi, POCO and Redmi: tap “OS version” instead of “Build number”, find Developer options under Additional settings, and also turn on “USB debugging (Security settings)” so the Mac can click and type.")
                    .foregroundStyle(.secondary)
            }

            step(3, "Plug in the cable and tap “Allow”", done: guide.phone.isReady) {
                Text("Connect the phone to this Mac with a USB cable and unlock it. Tick “Always allow from this computer”, then tap Allow.")
                Text(phoneLine).fontWeight(.medium)
            }

            HStack {
                Text("After this, “Go Wireless” in the menu lets you unplug the cable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Mirror Phone") {
                    SetupWindowController.shared.close()
                    AppState.shared.mirror()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!guide.phone.isReady || !guide.engineFound)
            }

            Divider()
            Text("Only want to send files from the phone to this Mac? Tick “Receive with Quick Share” in the menu. That needs none of these steps: no cable and no USB debugging.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Once a day Phone Mirror sends an anonymous count, so I know how many people use it: the app and macOS version, nothing about you, your phone or your files. To stop it, untick “Send anonymous usage count” in the menu.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var phoneLine: String {
        switch guide.phone {
        case .looking:         return "Looking for your phone…"
        case .notFound:        return "Waiting for your phone… (some cables only charge: try another one if nothing happens)"
        case .waitingForAllow: return "Almost there: tap “Allow” on your phone."
        case .ready(let link): return "Your phone is connected (\(link))."
        }
    }

    /// One numbered step with a tick when it's done.
    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, problem: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill"
                                   : (problem ? "exclamationmark.triangle.fill" : "\(number).circle"))
                .font(.title2)
                .foregroundStyle(done ? Color.green : (problem ? Color.orange : Color.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
