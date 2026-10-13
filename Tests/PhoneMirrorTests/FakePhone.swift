import Foundation
@testable import PhoneMirror

/// A pretend phone for the tests: a small script that answers the adb file commands
/// (`ls`, `push`, `pull`) from a folder on the Mac. No real phone is touched.
struct FakePhone {
    let root: URL
    let serial = "FAKE123"

    var adb: ADB { ADB(executable: root.appendingPathComponent("adb")) }
    /// The folder that plays the phone's /sdcard.
    var storage: URL { root.appendingPathComponent("phone") }
    var device: Device { Device(serial: serial, state: "device", model: "Fake_Phone", connection: .usb) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonemirror-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("Download"),
                                                withIntermediateDirectories: true)
        let script = root.appendingPathComponent("adb")
        try FakePhone.script.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Puts a file on the pretend phone, e.g. add("Download/a.txt", "hello").
    func add(_ path: String, _ contents: String = "x") throws {
        let url = storage.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: storage.appendingPathComponent(path), encoding: .utf8)
    }

    func names(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    /// While this is on, every copy first writes a few bytes and then hangs.
    func setSlow(_ slow: Bool) {
        let flag = root.appendingPathComponent("slow")
        if slow { FileManager.default.createFile(atPath: flag.path, contents: nil) }
        else { try? FileManager.default.removeItem(at: flag) }
    }

    /// A fresh empty folder on the Mac side.
    func macFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static let script = #"""
    #!/usr/bin/python3
    import os, shutil, sys, time

    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.join(here, "phone")
    slow = os.path.exists(os.path.join(here, "slow"))

    def fail(message):
        sys.stderr.write("adb: error: " + message + "\n")
        sys.exit(1)

    def local(path):
        if path != "/sdcard" and not path.startswith("/sdcard/"):
            fail("bad path " + path)
        return root + path[len("/sdcard"):]

    args = sys.argv[1:]
    if args[:1] == ["-s"]:
        args = args[2:]
    command, rest = args[0], args[1:]

    if command == "devices":
        print("List of devices attached")
        print("FAKE123 device usb:1-1 product:fake model:Fake_Phone device:fake transport_id:1")
    elif command == "ls":
        folder = local(rest[0])
        if os.path.isdir(folder):
            for name in [".", ".."] + sorted(os.listdir(folder)):
                info = os.lstat(os.path.join(folder, name))
                print("%08x %08x %08x %s" % (info.st_mode, info.st_size, int(info.st_mtime), name))
    elif command == "push":
        source, target = rest[0], local(rest[1])
        if os.path.isdir(target):
            target = os.path.join(target, os.path.basename(source))
        if slow:
            time.sleep(30)
        if os.path.isdir(source):
            shutil.copytree(source, target)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)
        print("1 file pushed, 0 skipped.")
    elif command == "pull":
        rest = [a for a in rest if a != "-a"]
        source, target = local(rest[0]), rest[1]
        if not os.path.exists(source):
            fail("failed to stat remote object '%s': No such file or directory" % rest[0])
        if os.path.isdir(target):
            target = os.path.join(target, os.path.basename(source))
        if slow:
            with open(target, "wb") as partial:
                partial.write(b"half")
            time.sleep(30)
        if os.path.isdir(source):
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
        print("1 file pulled, 0 skipped.")
    else:
        fail("unknown command")
    """#
}
