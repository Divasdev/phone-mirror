import Foundation
import Testing

@testable @preconcurrency import PhoneMirror

/// These need the app that `./release.sh` builds (build/Phone Mirror.app with the engine
/// inside). Without it they are skipped.
private let releaseApp: URL = {
    var folder = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { folder.deleteLastPathComponent() } // Tests/PhoneMirrorTests/file → project
    return folder.appendingPathComponent("build/Phone Mirror.app")
}()

private var hasReleaseApp: Bool {
    FileManager.default.fileExists(atPath: releaseApp.appendingPathComponent("Contents/Helpers/scrcpy").path)
}

@Test(.enabled(if: hasReleaseApp)) func theAppUsesItsOwnToolsWhenItsSealIsIntact() {
    let tools = ToolLocator.BuiltInTools(appAt: releaseApp)
    #expect(tools.usable)
    #expect(tools.tool("scrcpy")?.path.hasSuffix("Phone Mirror.app/Contents/Helpers/scrcpy") == true)
    #expect(tools.tool("adb")?.path.hasSuffix("Phone Mirror.app/Contents/Helpers/adb") == true)
    #expect(tools.tool("something-else") == nil)
    #expect(tools.environment["SCRCPY_SERVER_PATH"]?.hasSuffix("Contents/Resources/Engine/scrcpy-server") == true)
    #expect(tools.environment["SCRCPY_ICON_DIR"]?.hasSuffix("Contents/Resources/Engine") == true)
}

@Test(.enabled(if: hasReleaseApp)) func aTamperedAppDoesNotGetToRunItsTools() throws {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("phonemirror-seal-\(UUID().uuidString)")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    // 1. Someone swaps the adb inside the app for another program.
    let swapped = work.appendingPathComponent("Swapped.app")
    try fm.copyItem(at: releaseApp, to: swapped)
    #expect(ToolLocator.BuiltInTools(appAt: swapped).usable) // an untouched copy is fine
    let adb = swapped.appendingPathComponent("Contents/Helpers/adb")
    try fm.removeItem(at: adb)
    try fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: adb)
    let afterSwap = ToolLocator.BuiltInTools(appAt: swapped)
    #expect(!afterSwap.usable)
    #expect(afterSwap.tool("adb") == nil)
    #expect(afterSwap.tool("scrcpy") == nil)
    #expect(afterSwap.environment.isEmpty)

    // 2. Someone edits the part of scrcpy that is sent to the phone.
    let edited = work.appendingPathComponent("Edited.app")
    try fm.copyItem(at: releaseApp, to: edited)
    let server = edited.appendingPathComponent("Contents/Resources/Engine/scrcpy-server")
    let handle = try FileHandle(forWritingTo: server)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("extra".utf8))
    try handle.close()
    #expect(!ToolLocator.BuiltInTools(appAt: edited).usable)

    // 3. Someone adds a program next to the real ones.
    let added = work.appendingPathComponent("Added.app")
    try fm.copyItem(at: releaseApp, to: added)
    try fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: added.appendingPathComponent("Contents/Helpers/extra"))
    #expect(!ToolLocator.BuiltInTools(appAt: added).usable)
}

@Test func anAppWithoutItsOwnToolsFallsBackToHomebrew() {
    // The test runner is not an app with a Helpers folder.
    let none = ToolLocator.BuiltInTools(appAt: FileManager.default.temporaryDirectory)
    #expect(!none.usable)
    #expect(none.tool("adb") == nil)
    #expect(none.environment.isEmpty)
}
