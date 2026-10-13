import AppKit

/// "Receive with Quick Share": the switch in the menu, and what happens when a phone sends
/// something. The listening itself is in QuickShareReceiver.swift.
extension AppState {

    /// Hooks the receiver up to the menu and the cards. Called once at launch.
    func connectQuickShare() {
        quickShare.onStatus = { status in
            MainActor.assumeIsolated { AppState.shared.quickShareStatus = status }
        }
        quickShare.onRequest = { share in
            MainActor.assumeIsolated {
                let receiver = AppState.shared.quickShare
                QuickSharePrompts.shared.ask(share,
                                             answer: { receiver.answer(share.id, accept: $0) },
                                             stop: { receiver.stopTransfer(share.id) })
            }
        }
        quickShare.onProgress = { id, bytes in
            MainActor.assumeIsolated { QuickSharePrompts.shared.progress(id, bytes: bytes) }
        }
        quickShare.onFinished = { id, result in
            MainActor.assumeIsolated { QuickSharePrompts.shared.finished(id, result) }
        }
    }

    /// Starts or stops listening so that it matches the switch.
    func applyQuickShare() {
        guard quickShareOn else { return quickShare.stop() }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            quickShareStatus = .failed("the Downloads folder wasn’t found")
            return
        }
        quickShare.start(.init(name: QuickShareReceiver.macName(), saveFolder: downloads))
    }

    /// The line under the switch (nil while it is off).
    var quickShareLine: String? {
        switch quickShareStatus {
        case .off:
            return quickShareOn ? "Quick Share: starting…" : nil
        case .starting:
            return "Quick Share: starting…"
        case .on(let name):
            return "📥 Phones on this Wi-Fi see this Mac as “\(name)”"
        case .failed(let reason):
            return "⚠️ Quick Share isn’t working: \(reason)"
        }
    }
}
