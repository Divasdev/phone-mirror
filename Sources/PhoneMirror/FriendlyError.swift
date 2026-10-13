import AppKit

/// A plain-English error: what went wrong, what to check, and the raw
/// technical output (shown only if you click "Show Details").
struct FriendlyError {
    var title: String
    var advice: String
    var details: String = ""

    // MARK: Common messages

    static func phoneNotFound(details: String = "") -> FriendlyError {
        FriendlyError(
            title: "Phone not found.",
            advice: """
            Check:
            • Plug in the USB cable, or
            • Make sure the Mac and phone are on the same Wi-Fi, and
            • USB debugging is still ON in Developer options.
            If you rebooted the phone, plug in the cable and click “Go Wireless” again.
            """,
            details: details)
    }

    static func unauthorized(details: String = "") -> FriendlyError {
        FriendlyError(
            title: "Your phone is waiting for permission.",
            advice: "Unlock your phone and tap “Allow” on the “Allow USB debugging?” popup (tick “Always allow from this computer”). Then try again.",
            details: details)
    }

    static let toolsMissing = FriendlyError(
        title: "scrcpy or adb is missing.",
        advice: """
        Phone Mirror only runs these tools from Homebrew (/opt/homebrew).
        Install them with:
          brew install scrcpy
          brew install --cask android-platform-tools
        """)

    /// Turn scrcpy's output into a helpful message.
    static func fromScrcpy(exitCode: Int32, output: String) -> FriendlyError {
        let text = output.lowercased()

        if text.contains("unauthorized") {
            return .unauthorized(details: output)
        }
        if text.contains("injecting input") || text.contains("inject_events") || text.contains("securityexception") {
            return FriendlyError(
                title: "The phone blocked mouse/keyboard control.",
                advice: "On Xiaomi/POCO phones, turn ON “USB debugging (Security settings)” in Developer options (it needs a SIM and a Mi account sign-in), then restart mirroring.",
                details: output)
        }
        if text.contains("could not find any adb device") || text.contains("no devices")
            || text.contains("device offline") || text.contains("not found") {
            return .phoneNotFound(details: output)
        }
        if exitCode == 2 {
            return FriendlyError(
                title: "The connection to your phone was lost.",
                advice: "The cable was unplugged or Wi-Fi dropped. Reconnect and click “Mirror Phone” again.",
                details: output)
        }
        return FriendlyError(
            title: "Mirroring stopped unexpectedly.",
            advice: "Try unplugging and replugging the cable, or choose the “Low lag” quality preset. Click “Show Details” to see scrcpy’s message.",
            details: output)
    }

    // MARK: Showing it

    /// Shows a native macOS alert with an optional "Show Details" button.
    @MainActor
    func present() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = advice
        alert.addButton(withTitle: "OK")
        if !details.isEmpty { alert.addButton(withTitle: "Show Details") }

        if alert.runModal() == .alertSecondButtonReturn {
            FriendlyError.showDetails(details)
        }
    }

    /// A scrollable window with the raw technical output.
    @MainActor
    static func showDetails(_ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Details"
        alert.informativeText = "Technical output from adb/scrcpy (kept in memory only, never saved to disk):"

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text.isEmpty ? "(no output)" : text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    /// A simple "good news" alert.
    @MainActor
    static func info(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
