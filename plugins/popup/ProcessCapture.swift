import AppKit

// The first executable with this name on PATH, as the shell would find it.
func executableOnPath(_ name: String) -> URL? {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { "\($0)/\(name)" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}

// Owns the child and both pipes until their EOFs and termination have arrived.
final class ProcessCapture {
    nonisolated enum Event: Sendable {
        case output(Data), error(Data), outputEnd, errorEnd, exit(Int32), readFailure(any Error)
    }
    nonisolated struct Result: Sendable {
        let output: Data
        let errors: Data
        let status: Int32
    }
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    private static var running: [ObjectIdentifier: Process] = [:]

    static func terminateRunningChildren() {
        for process in running.values where process.isRunning { process.terminate() }
    }

    // Takes only the bytes that are ready. FileHandle.read(upToCount:) waits for the full
    // count or EOF, and a process that streams sends neither.
    nonisolated static func reader(_ continuation: AsyncStream<Event>.Continuation, _ descriptor: Int32,
                                   bytes: @escaping @Sendable (Data) -> Event, end: Event) -> @Sendable (FileHandle) -> Void {
        { handle in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            let code = errno
            if count > 0 {
                continuation.yield(bytes(Data(buffer[..<count])))
            } else if count == 0 || (code != EAGAIN && code != EINTR) {
                handle.readabilityHandler = nil
                continuation.yield(count == 0 ? end : .readFailure(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
            }
        }
    }

    // With `lines`, each complete stdout line goes to the handler instead of the result.
    func run(_ executable: URL, _ arguments: [String], lines: ((Data) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = Self.reader(continuation, output.fileHandleForReading.fileDescriptor,
                                                                    bytes: Event.output, end: .outputEnd)
        errors.fileHandleForReading.readabilityHandler = Self.reader(continuation, errors.fileHandleForReading.fileDescriptor,
                                                                    bytes: Event.error, end: .errorEnd)
        process.terminationHandler = { process in continuation.yield(.exit(process.terminationStatus)) }
        defer {
            Self.running.removeValue(forKey: ObjectIdentifier(process))
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            continuation.finish()
        }
        try process.run()
        Self.running[ObjectIdentifier(process)] = process
        var data = Data(), failure = Data()
        var outputEnded = false, errorEnded = false
        var status: Int32?
        for await event in events {
            switch event {
            case .output(let bytes):
                data.append(bytes)
                while let lines, let end = data.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(data[data.startIndex..<end])
                    data.removeSubrange(data.startIndex...end)
                    lines(line)
                }
            case .error(let bytes): failure.append(bytes)
            case .outputEnd: outputEnded = true
            case .errorEnd: errorEnded = true
            case .exit(let value): status = value
            case .readFailure(let error): throw error
            }
            if outputEnded && errorEnded, let status {
                try Task.checkCancellation()
                return Result(output: data, errors: failure, status: status)
            }
        }
        throw CancellationError()
    }
}
