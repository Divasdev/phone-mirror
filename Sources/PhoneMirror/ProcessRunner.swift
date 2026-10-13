import Foundation

/// The result of running a short command like `adb devices`.
struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }
    /// stdout + stderr together, handy for "Show details".
    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A thread-safe byte buffer that keeps only the newest `limit` bytes.
/// Used to collect program output in memory (never written to disk).
final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 64 * 1024) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs programs SAFELY:
///  - explicit executable URL + an arguments array (no shell, so no command injection),
///  - a small, controlled set of environment variables,
///  - a timeout so a stuck command can't hang the app.
enum ProcessRunner {

    /// Environment passed to adb/scrcpy. We copy only what they need.
    /// HOME matters: adb keeps its pairing key in ~/.android, so without it
    /// the phone would ask you to "Allow USB debugging" again.
    static func safeEnvironment(adbPath: String?) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = current[key] { env[key] = value }
        }
        // Fixed, trusted PATH (not the user's PATH).
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
        // Tell scrcpy exactly which adb to use.
        if let adbPath { env["ADB"] = adbPath }
        // The scrcpy inside the app needs to know where its own files are.
        env.merge(ToolLocator.builtInEnvironment) { _, builtIn in builtIn }
        return env
    }

    /// Async wrapper so the UI never freezes while a command runs.
    static func run(_ executable: URL, _ arguments: [String],
                    environment: [String: String], timeout: TimeInterval = 15,
                    outputLimit: Int = 64 * 1024) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runBlocking(executable, arguments, environment: environment, timeout: timeout,
                                         outputLimit: outputLimit)
                continuation.resume(returning: result)
            }
        }
    }

    /// Runs a command and waits for it (used on a background thread, or at quit time).
    /// - outputLimit: how much output to keep (the newest bytes). Raise it for long lists.
    /// - onStart: called with the running process, so a long copy can be cancelled.
    static func runBlocking(_ executable: URL, _ arguments: [String],
                            environment: [String: String], timeout: TimeInterval,
                            outputLimit: Int = 64 * 1024,
                            onStart: ((Process) -> Void)? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read output as it arrives (so a chatty command can't fill the pipe and stall).
        let outBuffer = OutputBuffer(limit: outputLimit), errBuffer = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { outBuffer.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errBuffer.append(chunk) }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(exitCode: -1, stdout: "",
                                 stderr: "Could not start \(executable.lastPathComponent): \(error.localizedDescription)",
                                 timedOut: false)
        }
        onStart?(process)

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()                                  // polite SIGTERM
            if finished.wait(timeout: .now() + 2) == .timedOut { // still alive? force it
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }

        // Collect whatever output is still sitting in the pipes. We read in
        // non-blocking mode because a background helper (the adb server) may
        // keep the pipe open after the command itself has exited.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        drainNonBlocking(outPipe.fileHandleForReading, into: outBuffer)
        drainNonBlocking(errPipe.fileHandleForReading, into: errBuffer)

        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: outBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines),
                             stderr: errBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines),
                             timedOut: timedOut)
    }

    private static func drainNonBlocking(_ handle: FileHandle, into buffer: OutputBuffer) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count <= 0 { break }
            buffer.append(Data(bytes[0..<count]))
        }
    }
}
