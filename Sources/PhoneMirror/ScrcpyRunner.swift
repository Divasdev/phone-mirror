import Foundation

/// Starts and stops the scrcpy mirror window as a child process of this app.
final class ScrcpyRunner {
    private var process: Process?
    private var output = OutputBuffer()
    private var stoppedByUser = false

    var isRunning: Bool { process?.isRunning ?? false }

    /// Everything scrcpy printed (kept in memory only, for "Show details").
    var recentOutput: String { output.text }

    /// Launch scrcpy.
    /// - onLine: called (on a background thread) for every line scrcpy prints, as it prints it.
    /// - onExit: called on the main thread when scrcpy has ended, with its exit code, its
    ///   output, and whether *we* asked it to stop.
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (String) -> Void,
               onExit: @escaping (_ exitCode: Int32, _ output: String, _ stoppedByUser: Bool) -> Void) throws {
        guard !isRunning else { return }

        // scrcpy only prints its log lines immediately when its output is a terminal
        // (with a plain pipe it holds them back), so give it a pseudo-terminal ("pty").
        var primary: Int32 = -1, secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var settings = termios()
        if tcgetattr(secondary, &settings) == 0 {
            settings.c_oflag &= ~tcflag_t(OPOST)  // keep "\n" as is (no "\r\n")
            settings.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(secondary, TCSANOW, &settings)
        }

        let process = Process()
        process.executableURL = executable     // absolute, verified path
        process.arguments = arguments          // array, no shell
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        process.standardOutput = terminal
        process.standardError = terminal

        let buffer = OutputBuffer()
        let finished = DispatchGroup()
        finished.enter() // the process has exited
        finished.enter() // all output has been read

        let reader = PTYReader(fd: primary, buffer: buffer, onLine: onLine, onClosed: { finished.leave() })
        process.terminationHandler = { _ in
            reader.processExited()
            finished.leave()
        }

        do {
            try process.run()
        } catch {
            close(primary)
            close(secondary)
            finished.leave() // nothing started: balance the two enter() calls above
            finished.leave()
            throw error
        }
        close(secondary) // scrcpy has its own copy now
        reader.start()

        finished.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let byUser = self.stoppedByUser
            self.process = nil
            onExit(process.terminationStatus, buffer.text, byUser)
        }

        output = buffer
        stoppedByUser = false
        self.process = process
    }

    /// Ask scrcpy to close (like pressing Ctrl+C). If it hasn't quit
    /// within 3 seconds, force it.
    func stop() {
        guard let process, process.isRunning else { return }
        stoppedByUser = true
        process.interrupt() // SIGINT: scrcpy shuts down cleanly on this
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Used when the app quits: stop and wait (briefly) until it's really gone.
    func stopAndWait() {
        guard let process, process.isRunning else { return }
        stoppedByUser = true
        process.interrupt()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

/// Reads scrcpy's output from the pty as it arrives and splits it into lines.
/// It is woken only when there is something to read, so while scrcpy is quiet it uses
/// no CPU at all. Everything here runs on its own background queue.
private final class PTYReader: @unchecked Sendable {
    private let fd: Int32
    private let buffer: OutputBuffer
    private let onLine: (String) -> Void
    private let onClosed: () -> Void
    private let queue = DispatchQueue(label: "phonemirror.scrcpy-output", qos: .utility)
    private var source: DispatchSourceRead?
    private var pending = Data()
    private var closed = false

    init(fd: Int32, buffer: OutputBuffer, onLine: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        self.fd = fd
        self.buffer = buffer
        self.onLine = onLine
        self.onClosed = onClosed
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) // read() never waits
    }

    /// Start listening (call once scrcpy is running).
    func start() {
        queue.async { [self] in
            guard !closed else { return } // scrcpy already ended; processExited() cleaned up
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in
                if !readAvailable() { finish() }
            }
            source.setCancelHandler { [self] in
                close(fd)
                onClosed()
            }
            self.source = source
            source.resume()
        }
    }

    /// scrcpy has ended, so everything it printed is already waiting in the pty: read
    /// that and stop. We can't wait for the pty to close by itself, because a helper
    /// scrcpy started (the adb server) may keep it open for hours.
    func processExited() {
        queue.async { [self] in
            _ = readAvailable()
            finish()
        }
    }

    /// Reads everything that is waiting. Returns false once the pty is closed.
    private func readAvailable() -> Bool {
        guard !closed else { return false }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            let problem = errno
            if count > 0 {
                handle(Data(chunk[0..<count]))
            } else if count < 0 && problem == EINTR {
                continue
            } else if count < 0 && problem == EAGAIN {
                return true  // nothing more for now
            } else {
                return false // scrcpy's side of the pty is closed
            }
        }
    }

    private func handle(_ data: Data) {
        buffer.append(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            pending.removeSubrange(pending.startIndex...newline)
            onLine(line)
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        if let source {
            source.cancel() // closes the pty in its cancel handler
        } else {
            close(fd)
            onClosed()
        }
    }
}
