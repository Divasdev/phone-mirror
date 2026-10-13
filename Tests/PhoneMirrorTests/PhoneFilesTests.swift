import AppKit
import Testing
import UniformTypeIdentifiers
@testable @preconcurrency import PhoneMirror

// MARK: - Reading a folder

@Test func listingLinesAreUnderstood() {
    let text = """
    000041f9 00001000 66f6a1b2 .
    000041f9 00001000 66f6a1b2 ..
    000081b0 0003d090 66f6a1b2 Holiday photo.jpg
    000041f9 00001000 66f6a1b3 Camera
    000081b0 100000000 66f6a1b4 big video.mp4
    0000a1ff 00000015 66f6a1b2 a link
    000081b0 00000000 66f6a1b2 .nomedia
    000081b0 00000001 66f6a1b2  leading space.txt
    this line is not a listing
    """
    let parsed = ADB.parseListing(text)
    #expect(parsed.folderSeen)
    #expect(parsed.files.map(\.name) == ["Holiday photo.jpg", "Camera", "big video.mp4", "a link", ".nomedia",
                                         " leading space.txt"])
    #expect(parsed.files[0].kind == .file)
    #expect(parsed.files[0].size == 250_000)
    #expect(parsed.files[0].modified == Date(timeIntervalSince1970: 0x66f6a1b2))
    #expect(parsed.files[1].isFolder)
    #expect(parsed.files[2].size == 4_294_967_296) // bigger than 4 GB still fits
    #expect(parsed.files[3].kind == .other)

    // Only real files and folders, without hidden ones, are shown.
    #expect(parsed.files.filter(\.isListed).map(\.name) == ["Holiday photo.jpg", "Camera", "big video.mp4",
                                                            " leading space.txt"])
}

@Test func emptyOutputMeansTheFolderWasNotSeen() {
    let parsed = ADB.parseListing("")
    #expect(parsed.files.isEmpty)
    #expect(!parsed.folderSeen)
}

@Test func onlySharedStoragePathsAreAllowed() {
    #expect(Validation.isSafePhonePath("/sdcard"))
    #expect(Validation.isSafePhonePath("/sdcard/DCIM/Camera/IMG 1 (2).jpg"))
    #expect(Validation.isSafePhonePath("/sdcard/Download/; rm -rf x")) // odd, but only a name: no shell reads it

    #expect(!Validation.isSafePhonePath("/data/local/tmp"))
    #expect(!Validation.isSafePhonePath("/sdcardx/file"))
    #expect(!Validation.isSafePhonePath("/sdcard/../data"))
    #expect(!Validation.isSafePhonePath("/sdcard/Download/"))       // empty last name
    #expect(!Validation.isSafePhonePath("/sdcard//Download"))
    #expect(!Validation.isSafePhonePath("/sdcard/a\nb"))
    #expect(!Validation.isSafePhonePath("sdcard/Download"))
    #expect(!Validation.isSafePhonePath("-s/sdcard"))

    #expect(!Validation.isSafeFileName(""))
    #expect(!Validation.isSafeFileName(".."))
    #expect(!Validation.isSafeFileName("a/b"))
    #expect(Validation.isSafeFileName("résumé ✓.pdf"))
}

@Test func foldersKnowTheirPaths() {
    let camera = PhoneFolder(names: ["DCIM", "Camera"])
    #expect(camera.path == "/sdcard/DCIM/Camera")
    #expect(camera.path(of: "a.jpg") == "/sdcard/DCIM/Camera/a.jpg")
    #expect(camera.parent == PhoneFolder(names: ["DCIM"]))
    #expect(camera.breadcrumb == "Internal storage › DCIM › Camera")
    #expect(PhoneFolder().path == "/sdcard")
    #expect(PhoneFolder().parent == nil)
    #expect(PhoneFolder().title == "Internal storage")
    for place in PhoneFolder.places { #expect(Validation.isSafePhonePath(place.folder.path)) }
}

@Test func aFreeNameIsChosenInsteadOfReplacing() {
    var taken: Set<String> = ["photo.jpg", "photo (2).jpg", "notes", ".hidden"]
    #expect(FileTransfers.freeName(for: "Photo.JPG", taken: &taken) == "Photo (3).JPG") // case is ignored
    #expect(FileTransfers.freeName(for: "notes", taken: &taken) == "notes (2)")
    #expect(FileTransfers.freeName(for: ".hidden", taken: &taken) == ".hidden (2)")
    #expect(FileTransfers.freeName(for: "new.txt", taken: &taken) == "new.txt")
    #expect(FileTransfers.freeName(for: "new.txt", taken: &taken) == "new (2).txt") // two drops in one go
}

@Test func adbErrorsBecomePlainReasons() {
    func reason(_ text: String, timedOut: Bool = false) -> String {
        FileTransfers.reason(from: ProcessResult(exitCode: 1, stdout: "", stderr: text, timedOut: timedOut))
    }
    #expect(reason("adb: error: failed to copy 'a' to 'b': remote No space left on device").contains("free space"))
    #expect(reason("adb: error: failed to copy: remote couldn't create file: Permission denied").contains("phone doesn't allow"))
    #expect(reason("adb: error: cannot create 'x': Operation not permitted").contains("macOS blocked"))
    #expect(reason("adb: device 'FAKE123' not found") == "the phone was disconnected")
    #expect(reason("adb: error: something new") == "something new")
    #expect(reason("", timedOut: true).contains("too long"))
}

// MARK: - Copying, against the pretend phone

@Test func aFolderOnThePhoneCanBeListed() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/report.pdf", "12345")
    try phone.add("Download/Trips/day1.jpg")
    try phone.add("Download/.hidden")

    guard case .files(let files, let folderSeen) = await phone.adb.list(.downloads, serial: phone.serial) else {
        Issue.record("listing failed")
        return
    }
    #expect(folderSeen)
    #expect(files.filter(\.isListed).map(\.name).sorted() == ["Trips", "report.pdf"])
    #expect(files.first { $0.name == "report.pdf" }?.size == 5)
    #expect(files.first { $0.name == "Trips" }?.isFolder == true)

    // A folder that isn't there: nothing at all comes back.
    guard case .files(let none, let seen) = await phone.adb.list(PhoneFolder(names: ["Nope"]), serial: phone.serial) else {
        Issue.record("listing failed")
        return
    }
    #expect(none.isEmpty && !seen)

    // Paths outside the shared storage are refused before adb is even started.
    guard case .failed = phone.adb.listBlocking(PhoneFolder(names: [".."]), serial: phone.serial) else {
        Issue.record("a path outside the storage was accepted")
        return
    }
}

@Test func sendingToThePhoneNeverReplacesAFile() throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/photo.jpg", "already on the phone")

    let mac = try phone.macFolder("mac")
    let photo = mac.appendingPathComponent("photo.jpg")
    try "from the Mac".write(to: photo, atomically: true, encoding: .utf8)
    let album = mac.appendingPathComponent("Album")
    try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
    try "inside".write(to: album.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

    let transfers = FileTransfers()
    transfers.send([photo, album], into: .downloads, using: phone.adb, serial: phone.serial)
    transfers.queue.waitUntilAllOperationsAreFinished()

    #expect(phone.read("Download/photo.jpg") == "already on the phone") // untouched
    #expect(phone.read("Download/photo (2).jpg") == "from the Mac")
    #expect(phone.read("Download/Album/one.txt") == "inside")            // folders go across whole
    #expect(transfers.lastSummary == FileTransfers.Summary(copied: 2, failures: [], cancelled: false, changedPhone: true))
}

@Test func savingToTheMacNeverReplacesAFile() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/notes.txt", "from the phone")
    try phone.add("Download/Trips/day1.jpg", "sunny")
    let downloads = try phone.macFolder("Downloads")
    try "already on the Mac".write(to: downloads.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let items = [PhoneItem(name: "notes.txt", path: "/sdcard/Download/notes.txt", isFolder: false, size: 14),
                 PhoneItem(name: "Trips", path: "/sdcard/Download/Trips", isFolder: true, size: 0),
                 PhoneItem(name: "gone.txt", path: "/sdcard/Download/gone.txt", isFolder: false, size: 1)]
    let transfers = FileTransfers()
    let saved: [URL] = await withCheckedContinuation { continuation in
        transfers.save(items, into: downloads, using: phone.adb, serial: phone.serial) { continuation.resume(returning: $0) }
    }

    #expect(saved.map(\.lastPathComponent) == ["notes (2).txt", "Trips"])
    #expect(try String(contentsOf: downloads.appendingPathComponent("notes.txt"), encoding: .utf8) == "already on the Mac")
    #expect(try String(contentsOf: downloads.appendingPathComponent("notes (2).txt"), encoding: .utf8) == "from the phone")
    #expect(try String(contentsOf: downloads.appendingPathComponent("Trips/day1.jpg"), encoding: .utf8) == "sunny")
    #expect(transfers.lastSummary?.copied == 2)
    #expect(transfers.lastSummary?.failures == ["gone.txt: it is no longer there"])
    #expect(transfers.lastSummary?.changedPhone == false)
}

@Test func aDroppedRowIsNotWrittenOverAnExistingFile() throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/notes.txt", "from the phone")
    let desktop = try phone.macFolder("Desktop")
    let existing = desktop.appendingPathComponent("notes.txt")
    try "keep me".write(to: existing, atomically: true, encoding: .utf8)
    // An empty file holds nothing to lose (the Mac may put one there as a placeholder).
    let placeholder = desktop.appendingPathComponent("empty.txt")
    FileManager.default.createFile(atPath: placeholder.path, contents: nil)

    let transfers = FileTransfers()
    let item = PhoneItem(name: "notes.txt", path: "/sdcard/Download/notes.txt", isFolder: false, size: 14)
    var refused: Error?, intoPlaceholder: Error?
    transfers.queue.addOperation {
        refused = transfers.writePromised(item, to: existing, using: phone.adb, serial: phone.serial)
    }
    transfers.queue.addOperation {
        intoPlaceholder = transfers.writePromised(item, to: placeholder, using: phone.adb, serial: phone.serial)
    }
    transfers.queue.waitUntilAllOperationsAreFinished()

    #expect(refused != nil)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    #expect(intoPlaceholder == nil)
    #expect(try String(contentsOf: placeholder, encoding: .utf8) == "from the phone")
    #expect(transfers.lastSummary?.copied == 1)
    #expect(transfers.lastSummary?.failures.count == 1)
}

@Test func stoppingACopyLeavesNoHalfFileBehind() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("Download/movie.mp4", "a long movie")
    try phone.add("Download/second.mp4", "another")
    phone.setSlow(true)
    let downloads = try phone.macFolder("Downloads")

    let items = [PhoneItem(name: "movie.mp4", path: "/sdcard/Download/movie.mp4", isFolder: false, size: 12),
                 PhoneItem(name: "second.mp4", path: "/sdcard/Download/second.mp4", isFolder: false, size: 7)]
    let transfers = FileTransfers()
    let started = Date()
    async let saved: [URL] = withCheckedContinuation { continuation in
        transfers.save(items, into: downloads, using: phone.adb, serial: phone.serial) { continuation.resume(returning: $0) }
    }
    // Wait until the pretend phone has written half a file, then press "Stop".
    let half = downloads.appendingPathComponent("movie.mp4")
    while !FileManager.default.fileExists(atPath: half.path), Date().timeIntervalSince(started) < 10 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(FileManager.default.fileExists(atPath: half.path))
    transfers.cancel()

    #expect(await saved.isEmpty)
    #expect(Date().timeIntervalSince(started) < 10)            // it did not wait for the 30 s copy
    #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    #expect(transfers.lastSummary == FileTransfers.Summary(copied: 0, failures: [], cancelled: true, changedPhone: false))

    // "Stop" is over once the batch ends: the next copy works normally.
    phone.setSlow(false)
    let again: [URL] = await withCheckedContinuation { continuation in
        transfers.save([items[1]], into: downloads, using: phone.adb, serial: phone.serial) { continuation.resume(returning: $0) }
    }
    #expect(again.map(\.lastPathComponent) == ["second.mp4"])
    #expect(transfers.lastSummary?.cancelled == false)
}

// MARK: - Drag and drop

/// What a dragged row does when it is dropped, without a mouse: the same calls AppKit
/// makes on a real drop (ask for the file name and the queue, then "write it here").
/// AppKit only lets a real drag deliver a promise, so the mouse part is checked by hand.
@MainActor
@Test(.timeLimit(.minutes(1))) func aDroppedRowIsCopiedToWhereItLands() async throws {
    let phone = try FakePhone()
    defer { phone.remove() }
    try phone.add("DCIM/Camera/IMG_1.jpg", "a photo")
    try phone.add("DCIM/Camera/Trip/day1.jpg", "sunny")
    let desktop = try phone.macFolder("Desktop")

    let transfers = FileTransfers()
    let writer = PromiseWriter(transfers: transfers)
    func provider(_ name: String, isFolder: Bool) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: (isFolder ? UTType.folder : .jpeg).identifier, delegate: writer)
        provider.userInfo = PromisedFile(item: PhoneItem(name: name, path: "/sdcard/DCIM/Camera/" + name,
                                                         isFolder: isFolder, size: 7),
                                         adb: phone.adb, serial: phone.serial, transfers: transfers)
        return provider
    }
    let photo = provider("IMG_1.jpg", isFolder: false)
    let folder = provider("Trip", isFolder: true)

    // The promises can be put on a drag pasteboard (this is what starting a drag does).
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects([photo, folder]))
    #expect(pasteboard.pasteboardItems?.count == 2)

    #expect(writer.filePromiseProvider(photo, fileNameForType: UTType.jpeg.identifier) == "IMG_1.jpg")
    #expect(writer.operationQueue(for: photo) === transfers.queue)

    for (promise, name) in [(photo, "IMG_1.jpg"), (folder, "Trip")] {
        let dropped = Unchecked(promise)
        let error: Error? = await withCheckedContinuation { continuation in
            writer.operationQueue(for: promise).addOperation {
                writer.filePromiseProvider(dropped.value, writePromiseTo: desktop.appendingPathComponent(name)) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(error == nil)
    }
    #expect(try String(contentsOf: desktop.appendingPathComponent("IMG_1.jpg"), encoding: .utf8) == "a photo")
    #expect(try String(contentsOf: desktop.appendingPathComponent("Trip/day1.jpg"), encoding: .utf8) == "sunny")
}

/// Lets a test hand an AppKit object to a background queue, as AppKit itself does.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Settings

@Test func usbPresetIsCappedAt60Frames() {
    #expect(StreamSettings.best.scrcpyArguments(hardwareEncoder: nil, safeMode: false) == ["--max-fps=60"])
}

@Test func pocketModeDarkensThePhoneKeepsItAwakeAndLocksItAfterwards() {
    let pocket = MirrorOptions(pocketMode: true, stayAwake: false, audio: true, overWiFi: true).arguments
    #expect(pocket == ["--turn-screen-off", "--keep-active", "--power-off-on-close", "--no-mouse-hover"])

    // Without it, nothing about the phone's screen or lock is touched.
    let normal = MirrorOptions(stayAwake: true, realKeyboard: true, audio: false, showFPS: true).arguments
    #expect(normal == ["--stay-awake", "--keyboard=uhid", "--no-audio", "--print-fps"])
}
