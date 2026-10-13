import Foundation

/// One file or folder on the phone, as reported by `adb ls`.
struct PhoneFile: Equatable {
    enum Kind { case file, folder, other }

    let name: String
    let kind: Kind
    let size: Int64
    let modified: Date

    var isFolder: Bool { kind == .folder }
    /// Shown in the Files window: real files and folders, without hidden "dot" files.
    var isListed: Bool { kind != .other && !name.hasPrefix(".") }
}

/// A folder inside the phone's shared storage, e.g. DCIM › Camera.
struct PhoneFolder: Equatable {
    /// The folder names below the shared storage; empty = the top of it.
    var names: [String] = []

    /// e.g. "/sdcard/DCIM/Camera"
    var path: String { ([Validation.phoneStorageRoot] + names).joined(separator: "/") }
    var title: String { names.last ?? "Internal storage" }
    /// e.g. "Internal storage › DCIM › Camera"
    var breadcrumb: String { (["Internal storage"] + names).joined(separator: " › ") }
    var parent: PhoneFolder? { names.isEmpty ? nil : PhoneFolder(names: Array(names.dropLast())) }

    func child(_ name: String) -> PhoneFolder { PhoneFolder(names: names + [name]) }
    /// The full phone path of something inside this folder.
    func path(of name: String) -> String { path + "/" + name }

    static let downloads = PhoneFolder(names: ["Download"])

    /// Shortcuts offered in the Files window.
    static let places: [(title: String, folder: PhoneFolder)] = [
        ("Downloads", .downloads),
        ("Camera", PhoneFolder(names: ["DCIM", "Camera"])),
        ("Screenshots", PhoneFolder(names: ["DCIM", "Screenshots"])),
        ("Pictures", PhoneFolder(names: ["Pictures"])),
        ("Movies", PhoneFolder(names: ["Movies"])),
        ("Documents", PhoneFolder(names: ["Documents"])),
        ("Internal storage", PhoneFolder()),
    ]
}

/// What `adb ls` found in a folder.
enum FolderListing {
    /// `folderSeen` is false when the phone sent nothing at all: the folder is empty,
    /// missing, or the phone doesn't allow reading it.
    case files([PhoneFile], folderSeen: Bool)
    case failed(String)
}

/// File commands. Like everything else in ADB, each one is an arguments array (no
/// shell on the Mac). They also use adb's own file service, so no shell runs on the
/// phone either: a file name can never be misread as a command.
extension ADB {

    private static func refused(_ why: String) -> ProcessResult {
        ProcessResult(exitCode: -1, stdout: "", stderr: "Refused: \(why)", timedOut: false)
    }

    /// Lists a folder (read-only).
    func list(_ folder: PhoneFolder, serial: String) async -> FolderListing {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: listBlocking(folder, serial: serial))
            }
        }
    }

    func listBlocking(_ folder: PhoneFolder, serial: String) -> FolderListing {
        guard Validation.isSafeSerial(serial), Validation.isSafePhonePath(folder.path) else {
            return .failed("Refused: that is not a folder in the phone's shared storage.")
        }
        // A camera folder can hold thousands of photos, so keep a long output.
        let result = ProcessRunner.runBlocking(executable, ["-s", serial, "ls", folder.path],
                                               environment: environment, timeout: 20,
                                               outputLimit: 8 * 1024 * 1024)
        guard result.succeeded else { return .failed(result.combinedOutput) }
        let parsed = ADB.parseListing(result.stdout)
        return .files(parsed.files, folderSeen: parsed.folderSeen)
    }

    /// `adb ls` prints one line per entry: three hexadecimal numbers (type and
    /// permissions, size, date), then the name exactly as it is:
    ///   000081b0 0003d090 66f6a1b2 Holiday photo.jpg
    static func parseListing(_ text: String) -> (files: [PhoneFile], folderSeen: Bool) {
        var files: [PhoneFile] = []
        var folderSeen = false
        for line in text.split(separator: "\n") {
            // At most 3 cuts, so a name with spaces stays in one piece.
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let mode = UInt32(fields[0], radix: 16),
                  let size = UInt64(fields[1], radix: 16),
                  let seconds = UInt64(fields[2], radix: 16) else { continue }

            let name = String(fields[3])
            if name == "." || name == ".." { // the folder itself and its parent
                folderSeen = true
                continue
            }
            guard Validation.isSafeFileName(name) else { continue }

            let kind: PhoneFile.Kind
            switch mode & 0o170000 { // the "what is it" part of the number
            case 0o040000: kind = .folder
            case 0o100000: kind = .file
            default:       kind = .other // links and other special entries
            }
            files.append(PhoneFile(name: name, kind: kind,
                                   size: Int64(clamping: size),
                                   modified: Date(timeIntervalSince1970: TimeInterval(seconds))))
        }
        return (files, folderSeen)
    }

    /// `adb push`: copies a Mac file or folder to this exact path on the phone.
    func pushBlocking(_ local: URL, to phonePath: String, serial: String, timeout: TimeInterval,
                      onStart: ((Process) -> Void)? = nil) -> ProcessResult {
        guard Validation.isSafeSerial(serial), Validation.isSafePhonePath(phonePath),
              phonePath != Validation.phoneStorageRoot else {
            return ADB.refused("that is not a place in the phone's shared storage.")
        }
        guard local.isFileURL, local.path.hasPrefix("/") else { return ADB.refused("not a file on this Mac.") }
        return ProcessRunner.runBlocking(executable, ["-s", serial, "push", local.path, phonePath],
                                         environment: environment, timeout: timeout, onStart: onStart)
    }

    /// `adb pull -a`: copies a phone file or folder to this exact path on the Mac,
    /// keeping its date.
    func pullBlocking(_ phonePath: String, to local: URL, serial: String, timeout: TimeInterval,
                      onStart: ((Process) -> Void)? = nil) -> ProcessResult {
        guard Validation.isSafeSerial(serial), Validation.isSafePhonePath(phonePath),
              phonePath != Validation.phoneStorageRoot else {
            return ADB.refused("that is not a file in the phone's shared storage.")
        }
        guard local.isFileURL, local.path.hasPrefix("/") else { return ADB.refused("not a place on this Mac.") }
        return ProcessRunner.runBlocking(executable, ["-s", serial, "pull", "-a", phonePath, local.path],
                                         environment: environment, timeout: timeout, onStart: onStart)
    }
}
