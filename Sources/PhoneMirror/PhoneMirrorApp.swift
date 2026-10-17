import SwiftUI

/// App entry point. A MenuBarExtra puts our icon in the menu bar;
/// LSUIElement in Info.plist hides the Dock icon.
@main
struct PhoneMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            // With "Show FPS" on, the live frame rate appears next to the icon.
            if state.showFPS, state.isMirroring, let fps = state.fps {
                HStack(spacing: 3) {
                    Image(systemName: state.menuBarSymbol)
                    Text("\(fps.fps)")
                }
            } else {
                Image(systemName: state.menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.menu) // a normal dropdown menu
    }
}

/// Handles app launch and quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }

    /// Closing the Phone Files window must not quit the app: it lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Runs when you click Quit (or log out): kill scrcpy, maybe turn off wireless.
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.cleanupForQuit()
    }
}

/// The dropdown menu itself.
struct MenuContent: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // --- Status ---
        Text(state.statusText)
        if let mirroring = state.mirroringLine {
            Text(mirroring)
        }
        if state.mirroringInPocketMode {
            Text("🌙 Pocket mode: the phone’s screen is off. Don’t press its power button.")
            Text("     Stopping the mirror locks the phone.")
        }
        if state.wirelessActive {
            Text("⚠️ Wireless debugging is ON – only use on your home Wi-Fi")
        }
        if state.isOnHotspot {
            Text("📶 Mac is using your phone’s data while on hotspot")
        }

        // --- Connection quality (measured only while this menu is open) ---
        if let quality = state.quality {
            Text(quality.summaryLine)
            if let bandLine = quality.bandLine {
                Text(bandLine)
            }
            if quality.needsTip {
                Text("💡 Switch to 5 GHz or use Hotspot mode")
            }
        } else if state.isCheckingQuality {
            Text("Connection: checking…")
        }
        if let busy = state.busyMessage {
            Text("⏳ \(busy)")
        }

        Divider()

        // --- Main actions ---
        Button(state.isMirroring ? "Mirroring…" : "Mirror Phone") { state.mirror() }
            .keyboardShortcut("m")
            .disabled(state.isMirroring || state.isBusy || !state.toolsFound)
        Button("Stop Mirroring") { state.stopMirroring() }
            .disabled(!state.isMirroring)
        // Copy files both ways. (Files can also be dropped straight onto the mirror window.)
        Button("Phone Files (drag & drop)…") { state.showFiles() }
            .keyboardShortcut("f")
            .disabled(state.adb == nil)

        Divider()

        // --- Wireless ---
        Button("Go Wireless (home Wi-Fi)") { state.goWireless() }
            .disabled(!state.hasUSBDevice || state.isBusy)
        Menu("Hotspot Mode (direct link)") {
            Text("Fastest wireless option: phone → Mac directly.")
            Text("1. On your phone, turn on Hotspot (5 GHz band if available)")
            Text("2. On this Mac, join the phone’s hotspot Wi-Fi")
            Text("3. Click “Connect via Hotspot” below")
            Text("   If it fails: plug in the USB cable once and click it again")
            Divider()
            Button("Connect via Hotspot") { state.connectHotspot() }
                .disabled(state.isBusy)
            Divider()
            Text("Note: your Mac uses the phone’s mobile data while on its hotspot.")
        }
        Button("Disconnect Wireless") { state.disconnectWireless() }
            .disabled(!state.wirelessActive || state.isBusy)

        Divider()

        // --- Quick Share (phone → Mac, no cable and no USB debugging needed) ---
        Toggle("Receive with Quick Share", isOn: $state.quickShareOn)
        if let line = state.quickShareLine {
            Text(line)
        }

        Divider()

        // --- Quality (radio choices) ---
        Picker("Quality", selection: $state.preset) {
            ForEach(QualityPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.inline)

        Divider()

        // --- Options (checkmarks) ---
        Toggle("Pocket mode (phone screen off, use it from the Mac)", isOn: $state.pocketMode)
        Toggle("Stay awake while charging", isOn: $state.stayAwake)
        Toggle("Real keyboard mode", isOn: $state.realKeyboard)
        Toggle("Audio", isOn: $state.audio)
        Toggle("Show FPS (menu bar + menu)", isOn: $state.showFPS)

        Divider()

        Toggle("Auto-disable wireless when I quit", isOn: $state.autoDisableWirelessOnQuit)
        Toggle("Launch at login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }))
        // Once a day: "a copy of Phone Mirror was used", the app and macOS version. See UsageCount.swift.
        Toggle("Send anonymous usage count", isOn: $state.usageCountOn)

        Divider()

        Button("Getting Started…") { state.showSetup() }
        if state.lastError != nil {
            Button("Show details of last error…") { state.showLastErrorDetails() }
        }
        Button("Show scrcpy output…") { state.showScrcpyOutput() }

        Divider()

        // There is no updater, so the app doesn't know about a newer version. This opens the
        // download page in the browser, where the newest version number is shown.
        Text("Phone Mirror \(AppState.appVersion)")
        Button("Check for Updates…") { state.openDownloadPage() }

        Divider()

        Button("Quit Phone Mirror") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
