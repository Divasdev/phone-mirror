import Foundation
import Security

/// Finds the `adb` and `scrcpy` programs — but ONLY in two trusted places:
///  1. inside this app itself (the download from the website carries its own copies), and
///     only while the app is still exactly as it was signed;
///  2. Homebrew's folder.
/// We never search the user's $PATH, so a fake "adb" dropped somewhere
/// else on the system can't be run by this app.
enum ToolLocator {

    /// The real (symlink-resolved) program must live under one of these folders.
    static let trustedPrefixes = ["/opt/homebrew/"]

    // MARK: Tools inside the app

    /// The tools shipped inside one copy of the app (normally the copy that is running).
    struct BuiltInTools {
        /// Programs: Phone Mirror.app/Contents/Helpers
        let helpers: URL
        /// Their data files: the part of scrcpy that runs on the phone, icons, licences.
        let engineFiles: URL
        /// True when the app carries its own tools AND its code seal is unbroken.
        let usable: Bool

        init(appAt app: URL) {
            helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true).resolvingSymlinksInPath()
            engineFiles = app.appendingPathComponent("Contents/Resources/Engine", isDirectory: true)
                .resolvingSymlinksInPath()
            // The seal check reads the whole app, so it is done once, here.
            usable = FileManager.default.fileExists(atPath: helpers.path) && BuiltInTools.isExactlyAsSigned(app)
        }

        /// Asks macOS to check the app against its code signature, helpers included. If a
        /// file inside the app was swapped, added or edited after signing, this fails and
        /// the built-in tools are not used.
        static func isExactlyAsSigned(_ app: URL) -> Bool {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
            let checks = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
            return SecStaticCodeCheckValidity(code, checks, nil) == errSecSuccess
        }

        func tool(_ name: String) -> URL? {
            guard usable else { return nil }
            return ToolLocator.verifiedExecutable(atPath: helpers.appendingPathComponent(name).path,
                                                  allowedPrefixes: [helpers.path + "/"])
        }

        /// The built-in scrcpy has to be told where its phone-side part and its icons are.
        var environment: [String: String] {
            let server = engineFiles.appendingPathComponent("scrcpy-server")
            guard tool("scrcpy") != nil, FileManager.default.fileExists(atPath: server.path) else { return [:] }
            return ["SCRCPY_SERVER_PATH": server.path, "SCRCPY_ICON_DIR": engineFiles.path]
        }
    }

    static let builtIn = BuiltInTools(appAt: Bundle.main.bundleURL)
    static let builtInEnvironment = builtIn.environment
    /// Is the scrcpy we run the one inside the app?
    static var usesBuiltInScrcpy: Bool { !builtInEnvironment.isEmpty }

    // MARK: Finding the tools

    static func findScrcpy() -> URL? {
        builtIn.tool("scrcpy") ?? firstTrusted(["/opt/homebrew/bin/scrcpy"])
    }

    /// macOS's own ping. /sbin is protected by System Integrity Protection,
    /// so no other program can replace it.
    static func findPing() -> URL? {
        verifiedExecutable(atPath: "/sbin/ping", allowedPrefixes: ["/sbin/"])
    }

    static func findADB() -> URL? {
        if let included = builtIn.tool("adb") { return included }
        var candidates = ["/opt/homebrew/bin/adb"]

        // The android-platform-tools cask lives at:
        // /opt/homebrew/Caskroom/android-platform-tools/<version>/platform-tools/adb
        let caskRoot = "/opt/homebrew/Caskroom/android-platform-tools"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: caskRoot) {
            let newestFirst = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in newestFirst {
                candidates.append("\(caskRoot)/\(version)/platform-tools/adb")
            }
        }
        return firstTrusted(candidates)
    }

    private static func firstTrusted(_ paths: [String]) -> URL? {
        for path in paths {
            if let url = verifiedExecutable(atPath: path) { return url }
        }
        return nil
    }

    /// Resolves symlinks, then checks that the real file:
    ///  - is inside a trusted folder,
    ///  - is a regular file and executable,
    ///  - is not writable by "everyone" (so nobody else could swap it).
    /// Returns the resolved URL, which is what we actually run.
    static func verifiedExecutable(atPath path: String,
                                   allowedPrefixes: [String] = trustedPrefixes) -> URL? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let realPath = resolved.path
        guard allowedPrefixes.contains(where: { realPath.hasPrefix($0) }) else { return nil }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: realPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fm.isExecutableFile(atPath: realPath) else { return nil }

        if let attributes = try? fm.attributesOfItem(atPath: realPath),
           let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o002 != 0 {
            return nil // world-writable: refuse
        }
        return resolved
    }
}
