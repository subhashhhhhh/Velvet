import Foundation

nonisolated struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

nonisolated enum ProcessError: LocalizedError {
    case timedOut(String)
    case failed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let name): "\(name) took too long and was stopped."
        case .failed(let name, let code, let message):
            "\(name) failed (exit \(code)): \(message.split(separator: "\n").last(where: { !$0.isEmpty }) ?? "")"
        }
    }
}

/// Runs a helper executable to completion without blocking any thread.
nonisolated enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Drain pipes concurrently so a chatty process can't fill the pipe buffer and stall.
        async let stdout = Self.readAll(out.fileHandleForReading)
        async let stderr = Self.readAll(err.fileHandleForReading)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    await withCheckedContinuation { cont in
                        process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                        do { try process.run() } catch {
                            process.terminationHandler = nil
                            // Never launched: close write ends so the pipe readers see EOF.
                            try? out.fileHandleForWriting.close()
                            try? err.fileHandleForWriting.close()
                            cont.resume(returning: -1)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next()!
                group.cancelAll()
                guard let code = first else {
                    process.terminate()
                    throw ProcessError.timedOut(executable.lastPathComponent)
                }
                return code
            }
        } onCancel: {
            process.terminate()
        }

        return ProcessResult(status: status, stdout: await stdout, stderr: await stderr)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }
}
