import Foundation

/// Async wrapper around Foundation.Process.
/// Never uses a shell: the executable is launched directly and every
/// argument is passed separately, so user input cannot inject commands.
///
/// Pipe discipline (important): stdout/stderr are drained *concurrently*
/// while the child runs via readabilityHandlers. Reading only after exit
/// deadlocks once output exceeds the 64 KB pipe buffer — `yt-dlp
/// --dump-json` for a single video emits hundreds of KB (every format),
/// so the child blocks on write forever while the parent waits for exit.
/// Small outputs (flat search lines) fit the buffer, which is why search
/// worked and stream resolution hung.
actor ProcessRunner {
    struct Result: Sendable {
        var stdout: String
        var stderr: String
        var terminationStatus: Int32
    }

    enum ProcessError: LocalizedError, Sendable {
        case launchFailed(String)
        case nonZeroExit(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): return message
            case .nonZeroExit(let status, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "Process exited with status \(status)" : detail
            }
        }
    }

    /// Runs an executable directly (no shell) and captures output.
    /// Supports cooperative cancellation by terminating the child process.
    func run(executableURL: URL, arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = nil

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outAccumulator = PipeAccumulator()
        let errAccumulator = PipeAccumulator()
        outHandle.readabilityHandler = { handle in
            outAccumulator.append(handle.availableData)
        }
        errHandle.readabilityHandler = { handle in
            errAccumulator.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        // Await exit; terminating the child when the outer task is cancelled
        // so debounced searches do not pile up zombie yt-dlp processes.
        let status: Int32 = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if !process.isRunning {
                    continuation.resume(returning: process.terminationStatus)
                    return
                }
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
            }
        }, onCancel: {
            process.terminate()
        })

        // Handlers off, then drain whatever remains buffered in the pipes.
        // (Already-delivered chunks were consumed via availableData; the
        // remainder call only picks up what's left — no duplication, no loss.)
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        outAccumulator.appendRemainder(from: outHandle)
        errAccumulator.appendRemainder(from: errHandle)

        return Result(
            stdout: String(data: outAccumulator.snapshot, encoding: .utf8) ?? "",
            stderr: String(data: errAccumulator.snapshot, encoding: .utf8) ?? "",
            terminationStatus: status
        )
    }

    /// Runs and throws on non-zero exit, returning stdout.
    func runChecked(executableURL: URL, arguments: [String]) async throws -> String {
        let result = try await run(executableURL: executableURL, arguments: arguments)
        guard result.terminationStatus == 0 else {
            throw ProcessError.nonZeroExit(status: result.terminationStatus, stderr: result.stderr)
        }
        return result.stdout
    }
}

/// Lock-protected byte accumulator for pipe drainage.
/// readabilityHandlers fire on a background queue while the caller awaits
/// exit, so shared Data must live behind a lock. A reference type keeps the
/// concurrently-executing closures from mutating captured value state.
private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }

    func appendRemainder(from handle: FileHandle) {
        let rest = handle.readDataToEndOfFile()
        if !rest.isEmpty {
            lock.withLock { data.append(rest) }
        }
    }

    var snapshot: Data {
        lock.withLock { data }
    }
}
