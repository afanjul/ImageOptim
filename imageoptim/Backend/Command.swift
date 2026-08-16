//
//  Command.swift
//  ImageOptim
//

import Foundation

public enum Stdio: Sendable {
    case null
    case inherit
    /// Feed the child's stdin from this file.
    case readFile(URL)
    /// Truncate this file and write the child's output into it.
    case writeFile(URL)
    /// Pipe into `onLine` (or just drain, when no parser is given).
    case capture
}

public enum LineAction: Sendable {
    case keepReading
    case stop
}

public enum CommandError: Error, Sendable {
    case executableMissing(String)
    case launchFailed(String, String)
    case cannotOpen(URL)
}

/// Wraps `Process` so it can be terminated from a cancellation handler on another thread.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Returns false when cancellation already happened, so the process is never launched.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func interrupt() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.interrupt()
        }
    }
}

/// One-shot await of the process' termination handler.
private final class ExitNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markExited() {
        lock.lock()
        exited = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

public enum Command {
    /// Launches a command-line tool and waits for it, without blocking a thread.
    ///
    /// - Parameters:
    ///   - timeLimit: sends SIGINT after this many seconds (PNGOUT prints its best result and exits).
    ///   - onLine: called for every line of the `.capture` streams; return `.stop` to stop parsing.
    /// - Returns: the termination status.
    @discardableResult
    public static func run(
        executable: URL,
        arguments: [String],
        stdin: Stdio = .null,
        stdout: Stdio = .null,
        stderr: Stdio = .null,
        currentDirectory: URL? = nil,
        lowPriority: Bool,
        timeLimit: TimeInterval? = nil,
        onLine: (@Sendable (String) -> LineAction)? = nil
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = lowPriority ? .utility : .userInitiated
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        var environment = ProcessInfo.processInfo.environment
        environment["NSUnbufferedIO"] = "YES"
        process.environment = environment

        IODebug("Launching \(executable.path) \(arguments.joined(separator: " "))")

        // A single pipe is shared when both streams are captured, matching the old NSTask setup.
        var capturePipe: Pipe?
        var openedHandles: [FileHandle] = []

        func attach(_ io: Stdio, writing: Bool) throws -> Any? {
            switch io {
            case .inherit:
                return nil
            case .null:
                return FileHandle.nullDevice
            case .readFile(let url):
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    throw CommandError.cannotOpen(url)
                }
                openedHandles.append(handle)
                return handle
            case .writeFile(let url):
                try? Data().write(to: url, options: [])
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    throw CommandError.cannotOpen(url)
                }
                openedHandles.append(handle)
                return handle
            case .capture:
                if capturePipe == nil {
                    capturePipe = Pipe()
                }
                return capturePipe
            }
        }

        process.standardInput = try attach(stdin, writing: false)
        process.standardOutput = try attach(stdout, writing: true)
        process.standardError = try attach(stderr, writing: true)

        defer {
            for handle in openedHandles {
                try? handle.close()
            }
        }

        let box = ProcessBox()
        let notifier = ExitNotifier()
        process.terminationHandler = { _ in notifier.markExited() }

        return try await withTaskCancellationHandler {
            guard box.adopt(process) else {
                throw CancellationError()
            }

            do {
                try process.run()
            } catch {
                throw CommandError.launchFailed(executable.lastPathComponent, "\(error)")
            }

            // On Apple Silicon, setpriority causes the scheduler to pin the process to E-cores,
            // so it is only applied when the user explicitly asked for low priority.
            if lowPriority {
                let pid = process.processIdentifier
                if pid > 1 {
                    setpriority(PRIO_PROCESS, id_t(pid), PRIO_MAX / 2)
                }
            }

            let timeoutTask: Task<Void, Never>? = timeLimit.map { limit in
                Task {
                    try? await Task.sleep(for: .seconds(limit))
                    if !Task.isCancelled {
                        box.interrupt()
                    }
                }
            }
            defer { timeoutTask?.cancel() }

            if let capturePipe {
                await drain(capturePipe.fileHandleForReading, onLine: onLine)
            }

            await notifier.wait()

            if let capturePipe {
                try? capturePipe.fileHandleForReading.close()
            }
            for handle in openedHandles {
                try? handle.close()
            }
            openedHandles.removeAll()

            return process.terminationStatus
        } onCancel: {
            box.terminate()
        }
    }

    /// Reads the pipe on a background thread, splitting on CR/LF exactly like the old
    /// hand-rolled 4 KB line splitter did.
    private static func drain(_ handle: FileHandle, onLine: (@Sendable (String) -> LineAction)?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8]()
                buffer.reserveCapacity(4096)

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }

                    guard let onLine else { continue }

                    var stopped = false
                    for byte in chunk {
                        if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || buffer.count == 4095 {
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            if case .stop = onLine(line) {
                                stopped = true
                                break
                            }
                        } else {
                            buffer.append(byte)
                        }
                    }

                    if stopped {
                        _ = try? handle.readToEnd()
                        break
                    }
                }
                continuation.resume()
            }
        }
    }
}
