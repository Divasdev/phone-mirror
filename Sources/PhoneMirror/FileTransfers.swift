import Foundation

/// Something on the phone that is about to be copied to the Mac.
struct PhoneItem {
    let name: String
    let path: String      // full phone path, e.g. /sdcard/DCIM/Camera/IMG_1.jpg
    let isFolder: Bool
    let size: Int64
}

/// Copies files between the Mac and the phone, one at a time, in the background.
/// It never replaces a file: on the phone (and in the Mac's Downloads) a new name is
/// chosen, like "photo (2).jpg", and a copy that would land on an existing Mac file is
/// refused.
final class FileTransfers: @unchecked Sendable {

    /// How one batch of copies went.
    struct Summary: Equatable {
        var copied = 0
        var failures: [String] = []   // one plain-English line per item that failed
        var cancelled = false
        var changedPhone = false      // something was sent to the phone
    }

    /// A reason that can be shown to the person (also what Finder gets for a failed drag).
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Every copy waits its turn here. Files dragged out of the window are written on
    /// this queue too (AppKit asks for it), so they line up with everything else.
    let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "phonemirror.transfers"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Both are called on the main thread: what is being copied right now, and how the
    /// batch went once nothing is left to copy.
    var onActivity: ((String) -> Void)?
    var onFinished: ((Summary) -> Void)?

    private let lock = NSLock()
    private var running: Process?
    private var cancelRequested = false
    private var summary = Summary()
    private var finished: Summary?

    var isBusy: Bool { queue.operationCount > 0 }

    /// The result of the most recent batch (nil while one is running or before the first).
    var lastSummary: Summary? {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    // MARK: Mac → phone

    /// Copies Mac files or folders into a folder on the phone.
    func send(_ urls: [URL], into folder: PhoneFolder, using adb: ADB, serial: String) {
        queue.addOperation { [self] in
            defer { jobEnded() }
            begin(changesPhone: true)

            // Look at what is already in the folder, so nothing gets replaced.
            announce("Checking the folder on your phone…")
            guard case .files(let existing, _) = adb.listBlocking(folder, serial: serial) else {
                record(folder.title, failure: "couldn't look inside that folder on the phone, so nothing was copied")
                return
            }
            var taken = Set(existing.map { $0.name.lowercased() })

            for (index, url) in urls.enumerated() {
                if isCancelled { break }
                let original = url.lastPathComponent
                guard Validation.isSafeFileName(original) else {
                    record(original, failure: "its name has characters the phone can't use")
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
                    record(original, failure: "it can't be read on this Mac")
                    continue
                }
                let name = Self.freeName(for: original, taken: &taken)
                announce("Copying to your phone: \(original)" + Self.counter(index, of: urls.count))

                let bytes = values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
                let result = adb.pushBlocking(url, to: folder.path(of: name), serial: serial,
                                              timeout: Self.timeout(forBytes: bytes), onStart: track)
                record(name, failure: result.succeeded ? nil : failureText(for: result))
            }
        }
    }

    // MARK: Phone → Mac

    /// Copies phone files or folders into a folder on the Mac (used by "Save to Downloads").
    /// `whenDone` gets the new files, on the main thread.
    func save(_ items: [PhoneItem], into directory: URL, using adb: ADB, serial: String,
              whenDone: @escaping ([URL]) -> Void) {
        queue.addOperation { [self] in
            begin(changesPhone: false)
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            var taken = Set(existing.map { $0.lowercased() })
            var saved: [URL] = []

            for (index, item) in items.enumerated() {
                if isCancelled { break }
                let destination = directory.appendingPathComponent(Self.freeName(for: item.name, taken: &taken))
                announce("Copying to your Mac: \(item.name)" + Self.counter(index, of: items.count))
                let failure = pull(item, to: destination, using: adb, serial: serial)
                record(item.name, failure: failure)
                if failure == nil { saved.append(destination) }
            }

            let result = saved
            jobEnded()
            DispatchQueue.main.async { whenDone(result) }
        }
    }

    /// Writes one file that was dragged out of the window to the place it was dropped.
    /// AppKit calls this on `queue`; it returns nil when the copy worked.
    func writePromised(_ item: PhoneItem, to destination: URL, using adb: ADB, serial: String) -> Error? {
        defer { jobEnded() }
        begin(changesPhone: false)
        announce("Copying to your Mac: \(item.name)")
        let failure = pull(item, to: destination, using: adb, serial: serial)
        record(item.name, failure: failure)
        guard let failure else { return nil }
        return failure == Self.stopped ? CocoaError(.userCancelled) : Failure(reason: "\(item.name): \(failure)")
    }

    /// One `adb pull`. Returns nil when it worked, otherwise the reason.
    private func pull(_ item: PhoneItem, to destination: URL, using adb: ADB, serial: String) -> String? {
        if isCancelled { return Self.stopped }
        // Never replace something that is already on the Mac. (An empty file is fine: it
        // holds nothing, and may be a placeholder put there for this very copy.)
        guard !FileManager.default.fileExists(atPath: destination.path) || Self.isEmptyFile(destination) else {
            return "something with that name is already there"
        }
        let result = adb.pullBlocking(item.path, to: destination, serial: serial,
                                      timeout: Self.timeout(forBytes: item.isFolder ? nil : item.size),
                                      onStart: track)
        if result.succeeded { return nil }
        try? FileManager.default.removeItem(at: destination) // a half-copied file is of no use
        return failureText(for: result)
    }

    // MARK: Cancel

    /// Stops the copy that is running and skips the ones still waiting.
    func cancel() {
        guard isBusy else { return }
        lock.lock()
        cancelRequested = true
        let process = running
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    /// Remembers the running adb so `cancel()` can stop it.
    private func track(_ process: Process) {
        lock.lock()
        running = process
        let stopNow = cancelRequested
        lock.unlock()
        if stopNow { process.terminate() }
    }

    // MARK: Keeping score

    private static let stopped = "stopped"

    private func begin(changesPhone: Bool) {
        lock.lock()
        finished = nil
        if changesPhone { summary.changedPhone = true }
        lock.unlock()
    }

    private func failureText(for result: ProcessResult) -> String {
        isCancelled ? Self.stopped : Self.reason(from: result)
    }

    private func record(_ name: String, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        running = nil
        if let failure {
            if failure != Self.stopped { summary.failures.append("\(name): \(failure)") }
        } else {
            summary.copied += 1
        }
    }

    private func announce(_ text: String) {
        let waiting = queue.operationCount - 1 // everything except the copy that is running
        let line = waiting > 0 ? "\(text) · \(waiting) more waiting" : text
        DispatchQueue.main.async { self.onActivity?(line) }
    }

    /// Called at the end of every job. When it was the last one, the batch is over.
    private func jobEnded() {
        lock.lock()
        running = nil
        let isLast = queue.operationCount <= 1 // only this job is left
        var result = summary
        if isLast {
            result.cancelled = cancelRequested
            summary = Summary()
            cancelRequested = false
            finished = result
        }
        lock.unlock()
        if isLast { DispatchQueue.main.async { self.onFinished?(result) } }
    }

    // MARK: Small helpers

    /// " (2 of 5)" when several things are copied together.
    private static func counter(_ index: Int, of total: Int) -> String {
        total > 1 ? " (\(index + 1) of \(total))" : ""
    }

    /// "photo.jpg" → "photo (2).jpg" → "photo (3).jpg" … until the name is free.
    /// `taken` holds lowercase names, because phone storage and Mac disks treat
    /// "Photo.JPG" and "photo.jpg" as the same file.
    static func freeName(for name: String, taken: inout Set<String>) -> String {
        var base = name, ending = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ending = String(name[dot...])
        }
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) (\(number))\(ending)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private static func isEmptyFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && values?.fileSize == 0
    }

    /// How long one copy may take before it is stopped. Generous: slow 2.4 GHz Wi-Fi
    /// manages about 1 MB a second, and this allows a tenth of that.
    static func timeout(forBytes bytes: Int64?) -> TimeInterval {
        guard let bytes else { return 2 * 3600 } // a folder: size not known
        return min(4 * 3600, 120 + Double(bytes) / 100_000)
    }

    /// Turns adb's output into a short reason.
    static func reason(from result: ProcessResult) -> String {
        if result.timedOut { return "it took too long and was stopped" }
        let text = result.combinedOutput.lowercased()
        let blocked = text.contains("permission denied") || text.contains("not permitted")

        if text.contains("no space left") { return "there isn't enough free space" }
        if blocked && text.contains("remote") { return "the phone doesn't allow using that folder" }
        if text.contains("operation not permitted") {
            return "macOS blocked that folder (allow Phone Mirror in System Settings → Privacy & Security → Files and Folders)"
        }
        if blocked { return "that folder can't be used" }
        if text.contains("device offline") || text.contains("no devices") || text.contains("connection reset")
            || (text.contains("device") && text.contains("not found")) || text.hasSuffix("closed") {
            return "the phone was disconnected"
        }
        if text.contains("does not exist") || text.contains("no such file") { return "it is no longer there" }

        // Anything else: adb's own last line.
        let lastLine = result.combinedOutput.split(separator: "\n").last.map(String.init) ?? "adb gave no reason"
        return lastLine.replacingOccurrences(of: "adb: error: ", with: "")
    }
}
