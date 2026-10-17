import Foundation

struct ProcessResult: Hashable, Sendable {
    let exitCode: Int32
    let wasCancelled: Bool
    var succeeded: Bool { exitCode == 0 && !wasCancelled }
}

enum ProcessRunnerError: LocalizedError {
    case alreadyStarted
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: "Ce processus a déjà été lancé."
        case .launchFailed(let reason): "Impossible de lancer le processus : \(reason)"
        }
    }
}

/// Launches a process and streams its output (stdout and stderr merged) as
/// it arrives. One instance per launch.
///
/// stdin is connected to /dev/null: if gamdl asks an interactive question
/// (artist menu, etc.), it reads EOF and exits instead of waiting forever
/// for an answer nobody will type.
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    var processIdentifier: Int32 { process.processIdentifier }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        separateErrorOutput: (@Sendable (String) -> Void)? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try lock.withLock {
            guard !started else { throw ProcessRunnerError.alreadyStarted }
            started = true
        }

        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        // stderr is merged into stdout unless the caller wants it apart
        // (e.g. a script printing JSON on stdout and logs on stderr).
        let errorPipe = separateErrorOutput.map { _ in Pipe() }
        process.standardError = errorPipe ?? pipe

        // A serial queue keeps output chunks in order and ensures the UTF-8
        // decoder (mutable state) is only touched from one thread.
        let queue = DispatchQueue(label: "eu.vitalys.gamdlstudio.process-output")
        let reader = pipe.fileHandleForReading
        let decoderBox = DecoderBox()

        reader.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async {
                let text = decoderBox.decoder.decode(data)
                if !text.isEmpty { onOutput(text) }
            }
        }
        let errorReader = errorPipe?.fileHandleForReading
        if let errorReader, let separateErrorOutput {
            errorReader.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                queue.async { separateErrorOutput(String(decoding: data, as: UTF8.self)) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { [weak self] proc in
                    reader.readabilityHandler = nil
                    errorReader?.readabilityHandler = nil
                    // Whatever was left in the pipes after the process exited. Read
                    // without blocking: an orphaned grandchild may still hold the
                    // pipe open, and waiting for EOF would wait for it to exit.
                    let rest = Self.drain(reader)
                    let errorRest = errorReader.map(Self.drain) ?? Data()
                    queue.async {
                        if !errorRest.isEmpty { separateErrorOutput?(String(decoding: errorRest, as: UTF8.self)) }
                        var text = decoderBox.decoder.decode(rest)
                        text += decoderBox.decoder.finish()
                        if !text.isEmpty { onOutput(text) }
                        let wasCancelled = self?.lock.withLock { self?.cancelled ?? false } ?? false
                        continuation.resume(returning: ProcessResult(exitCode: proc.terminationStatus, wasCancelled: wasCancelled))
                    }
                }
                do {
                    try process.run()
                    // Cancelled between the start of `run` and the actual launch.
                    if lock.withLock({ cancelled }) { process.interrupt() }
                } catch {
                    reader.readabilityHandler = nil
                    errorReader?.readabilityHandler = nil
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// SIGINT first, so Python raises KeyboardInterrupt and gamdl cleans up
    /// its temporary files. Then SIGTERM, then SIGKILL if nothing happened.
    ///
    /// The signal also goes to descendants (ffmpeg, N_m3u8DL-RE…). Otherwise
    /// an orphaned child keeps the output pipe open and the final read waits
    /// for it to exit on its own (30 s measured with a `sleep`).
    func cancel() {
        let shouldSignal: Bool = lock.withLock {
            guard started, !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldSignal, process.isRunning else { return }
        let tree = ProcessTree(root: process.processIdentifier)
        tree.signal(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { tree.signal(SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { tree.signal(SIGKILL) }
    }

    /// Remembers every descendant seen so far. If the root dies first, its
    /// children are reparented to launchd and no longer show up under it, but
    /// they still hold the output pipe open, so they must still be signalled.
    private final class ProcessTree: @unchecked Sendable {
        private let root: pid_t
        private var known: [pid_t] = []
        private let lock = NSLock()

        init(root: pid_t) { self.root = root }

        func signal(_ signal: Int32) {
            let pids: [pid_t] = lock.withLock {
                for pid in ProcessRunner.descendants(of: root) where !known.contains(pid) { known.append(pid) }
                return known
            }
            for pid in pids.reversed() { kill(pid, signal) }
            kill(root, signal)
        }
    }

    static func drain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [root]
        while let pid = pending.popLast() {
            let estimate = proc_listchildpids(pid, nil, 0)
            guard estimate > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(estimate) + 8)
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
            }
            let children = buffer.prefix(max(Int(count), 0)).filter { $0 > 0 }
            result += children
            pending += children
        }
        return result
    }

    private final class DecoderBox: @unchecked Sendable {
        var decoder = UTF8StreamDecoder()
    }
}

extension ProcessRunner {
    /// Runs a short command and returns all its output (a tool's version, etc.).
    static func capture(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> (output: String, exitCode: Int32)? {
        let collected = OutputCollector()
        let runner = ProcessRunner()
        guard let result = try? await runner.run(executable: executable, arguments: arguments, environment: environment, onOutput: { collected.append($0) }) else {
            return nil
        }
        return (collected.value, result.exitCode)
    }
}

/// Text accumulator shared across threads.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ s: String) { lock.withLock { storage += s } }
    var value: String { lock.withLock { storage } }
}
