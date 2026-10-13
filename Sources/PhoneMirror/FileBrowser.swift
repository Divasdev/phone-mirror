import AppKit

/// What the "Phone Files" window shows: one folder of the phone's shared storage, plus
/// the copies that are running. Nothing is read from the phone unless the window is open.
@MainActor
final class FileBrowser: ObservableObject {
    static let shared = FileBrowser()

    // MARK: Shown in the window

    @Published private(set) var folder = PhoneFolder.downloads
    @Published private(set) var files: [PhoneFile] = []
    @Published private(set) var notice: String?         // shown in the middle when there is no list
    @Published private(set) var isLoading = false
    @Published private(set) var linkLine = ""           // e.g. "USB cable"
    @Published private(set) var activity: String?       // a copy is running
    @Published private(set) var resultLine: String?     // how the last copy went
    @Published private(set) var failureDetails: String? // for the "Details…" button
    @Published var selectedNames: Set<String> = []
    @Published var isDropTarget = false                 // files are being dragged over the window

    // MARK: Tools

    let transfers = FileTransfers()

    /// Finds adb and the phone to use (the same choice as "Mirror Phone": USB first).
    /// It can be replaced, so the window can be tested without a real phone.
    var findPhone: @MainActor () async -> (adb: ADB?, devices: [Device], phone: Device?) = {
        guard let adb = AppState.shared.adb else { return (nil, [], nil) }
        let devices = await adb.devices()
        return (adb, devices, AppState.shared.pickDevice(from: devices))
    }

    private var adb: ADB?
    private var phone: Device?
    private var loadNumber = 0

    init() {
        transfers.onActivity = { [weak self] text in
            MainActor.assumeIsolated {
                self?.activity = text
                self?.resultLine = nil
                self?.failureDetails = nil
            }
        }
        transfers.onFinished = { [weak self] summary in
            MainActor.assumeIsolated { self?.finished(summary) }
        }
    }

    // MARK: Looking around

    var canGoUp: Bool { folder.parent != nil }
    var isConnected: Bool { phone != nil }

    func open(_ newFolder: PhoneFolder) {
        guard Validation.isSafePhonePath(newFolder.path) else { return }
        folder = newFolder
        files = []
        notice = nil
        selectedNames = []
        reload()
    }

    func goUp() {
        if let parent = folder.parent { open(parent) }
    }

    /// Reads the current folder again.
    func reload() {
        loadNumber += 1
        let number = loadNumber
        let folder = folder
        isLoading = true
        Task {
            let found = await findPhone()
            var listing: FolderListing?
            if let adb = found.adb, let phone = found.phone {
                listing = await adb.list(folder, serial: phone.serial)
            }
            guard number == loadNumber else { return } // a newer reload has taken over
            isLoading = false
            adb = found.adb
            phone = found.phone
            show(listing, devices: found.devices)
        }
    }

    private func show(_ listing: FolderListing?, devices: [Device]) {
        guard adb != nil else { return showNotice("adb is missing.\nInstall it with: brew install --cask android-platform-tools") }
        guard let phone else {
            linkLine = ""
            if devices.contains(where: { $0.state == "unauthorized" }) {
                return showNotice("Unlock your phone and tap “Allow”,\nthen click ↻")
            }
            return showNotice("Phone not found.\nPlug in the USB cable (or connect wirelessly from the menu bar icon), then click ↻")
        }
        linkLine = phone.connection == .usb ? "USB cable"
                                            : "Wi-Fi – slower; use the cable for big files"

        switch listing {
        case .files(let all, let folderSeen):
            files = all.filter(\.isListed)
            if !files.isEmpty {
                notice = nil
            } else if folderSeen {
                notice = "This folder is empty.\nDrag files here to copy them to your phone."
            } else {
                notice = "Nothing to show here.\nThis folder is empty, or it isn’t on your phone."
            }
        case .failed(let details):
            showNotice("Couldn’t read this folder.\n" + (details.split(separator: "\n").last.map(String.init) ?? ""))
        case nil:
            showNotice("Couldn’t read this folder.")
        }
        selectedNames.formIntersection(files.map(\.name))
    }

    private func showNotice(_ text: String) {
        files = []
        notice = text
    }

    // MARK: Mac → phone

    /// Copies Mac files or folders to the phone: into `target`, or the folder on screen.
    func send(_ urls: [URL], to target: PhoneFolder? = nil) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        guard let adb, let phone else {
            resultLine = "Connect your phone first, then drop the files again."
            return
        }
        transfers.send(urls, into: target ?? folder, using: adb, serial: phone.serial)
    }

    /// The "Send Files…" button: pick files instead of dragging them.
    func chooseFilesToSend(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to Phone"
        panel.message = "Choose what to copy to “\(folder.title)” on your phone"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { self?.send(panel.urls) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    // MARK: Phone → Mac

    /// What a dragged row needs to copy itself to wherever it is dropped.
    func promise(for file: PhoneFile) -> PromisedFile? {
        guard let adb, let phone, file.isListed else { return nil }
        return PromisedFile(item: item(for: file), adb: adb, serial: phone.serial, transfers: transfers)
    }

    private func item(for file: PhoneFile) -> PhoneItem {
        PhoneItem(name: file.name, path: folder.path(of: file.name), isFolder: file.isFolder, size: file.size)
    }

    /// The "Save to Downloads" button: copies the selected rows to the Mac's Downloads
    /// folder and shows them in Finder.
    func saveSelectionToDownloads() {
        let chosen = files.filter { selectedNames.contains($0.name) }.map(item(for:))
        guard !chosen.isEmpty, let adb, let phone,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        transfers.save(chosen, into: downloads, using: adb, serial: phone.serial) { saved in
            if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        }
    }

    // MARK: Progress

    func cancelTransfers() {
        transfers.cancel()
    }

    func showFailureDetails() {
        if let failureDetails { FriendlyError.showDetails(failureDetails) }
    }

    private func finished(_ summary: FileTransfers.Summary) {
        activity = nil
        failureDetails = summary.failures.isEmpty ? nil : summary.failures.joined(separator: "\n")
        resultLine = Self.resultText(for: summary)
        if summary.changedPhone { reload() } // show what just arrived
    }

    static func resultText(for summary: FileTransfers.Summary) -> String {
        let copied = summary.copied == 1 ? "1 item" : "\(summary.copied) items"
        if summary.cancelled {
            return summary.copied > 0 ? "Stopped. \(copied) copied before that." : "Stopped. Nothing was copied."
        }
        if summary.failures.isEmpty { return "✓ Copied \(copied)" }

        let failed = summary.failures.count
        if summary.copied > 0 { return "Copied \(copied), but \(failed) couldn’t be copied" }
        // One problem: say what it was. Several: the "Details…" button lists them.
        return failed == 1 ? "⚠️ \(summary.failures[0])" : "⚠️ \(failed) items couldn’t be copied"
    }
}

/// Travels with a dragged row: everything needed to copy that file to the Mac once it
/// is dropped somewhere.
struct PromisedFile {
    let item: PhoneItem
    let adb: ADB
    let serial: String
    let transfers: FileTransfers
}
