import Foundation
import Testing
@testable import PhoneMirror

/// Small scripts stand in for scrcpy, to check how its output is read.
private func fakeScrcpy(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("phonemirror-fake-scrcpy-\(UUID().uuidString).sh")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// Collects lines with the moment each one arrived.
private final class Lines: @unchecked Sendable {
    private var items: [(text: String, at: Date)] = []
    private let lock = NSLock()
    func add(_ text: String) { lock.lock(); items.append((text, Date())); lock.unlock() }
    var all: [(text: String, at: Date)] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
@Test(.timeLimit(.minutes(1))) func scrcpyLinesArriveLiveAndTheExitIsReported() async throws {
    let script = try fakeScrcpy("""
    echo "INFO: 60 fps"
    sleep 1
    echo "INFO: 57 fps (+3 frames skipped)"
    printf "no newline at the end"
    exit 7
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let runner = ScrcpyRunner()
    let lines = Lines()
    let (exitCode, output, byUser): (Int32, String, Bool) = try await withCheckedThrowingContinuation { continuation in
        do {
            try runner.start(executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                             onLine: { lines.add($0) },
                             onExit: { continuation.resume(returning: ($0, $1, $2)) })
        } catch {
            continuation.resume(throwing: error)
        }
    }

    #expect(exitCode == 7)
    #expect(!byUser)
    #expect(!runner.isRunning)
    #expect(lines.all.map(\.text) == ["INFO: 60 fps", "INFO: 57 fps (+3 frames skipped)"])
    // The first line was delivered while the script was still sleeping, not together with
    // the second one at the end. (Measured between the lines, so a busy Mac that starts
    // the script late doesn't matter.)
    #expect(lines.all[1].at.timeIntervalSince(lines.all[0].at) > 0.6)
    #expect(output.contains("no newline at the end"))
    #expect(ScrcpyOutput.fps(in: lines.all[1].text)?.skipped == 3)
}

/// scrcpy can leave a helper running (the adb server) that keeps its terminal open.
/// The app must still notice straight away that scrcpy itself has ended.
@MainActor
@Test(.timeLimit(.minutes(1))) func aLeftoverHelperDoesNotDelayTheExit() async throws {
    let script = try fakeScrcpy("""
    echo "starting"
    ( sleep 15 ) &
    echo "INFO: 30 fps"
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let runner = ScrcpyRunner()
    let lines = Lines()
    let started = Date()
    let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
        do {
            try runner.start(executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                             onLine: { lines.add($0) },
                             onExit: { code, _, _ in continuation.resume(returning: code) })
        } catch {
            continuation.resume(throwing: error)
        }
    }
    #expect(exitCode == 0)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(lines.all.map(\.text) == ["starting", "INFO: 30 fps"])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func stoppingEndsScrcpyAndSaysItWasUs() async throws {
    let script = try fakeScrcpy("""
    echo "running"
    sleep 30
    """)
    defer { try? FileManager.default.removeItem(at: script) }

    let runner = ScrcpyRunner()
    let started = Date()
    let byUser: Bool = try await withCheckedThrowingContinuation { continuation in
        do {
            try runner.start(executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                             onLine: { line in
                                 if line == "running" { DispatchQueue.main.async { runner.stop() } }
                             },
                             onExit: { _, _, stoppedByUser in continuation.resume(returning: stoppedByUser) })
        } catch {
            continuation.resume(throwing: error)
        }
    }
    #expect(byUser)
    #expect(Date().timeIntervalSince(started) < 10)
}

@MainActor
@Test func aMissingScrcpyIsReportedNotCrashed() {
    let runner = ScrcpyRunner()
    #expect(throws: (any Error).self) {
        try runner.start(executable: URL(fileURLWithPath: "/nonexistent/scrcpy"), arguments: [], environment: [:],
                         onLine: { _ in }, onExit: { _, _, _ in })
    }
    #expect(!runner.isRunning)
}
