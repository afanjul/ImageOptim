//
//  Worker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct WorkerContext: Sendable {
    public let lowPriority: Bool
    /// Guetzli uses so much memory that it is dangerous to run several large images in parallel.
    public let guetzliGate: AsyncSemaphore

    public init(lowPriority: Bool, guetzliGate: AsyncSemaphore) {
        self.lowPriority = lowPriority
        self.guetzliGate = guetzliGate
    }
}

public struct WorkerResult: Sendable {
    public let file: ImageFile
    public let toolName: String
}

/// One optimization tool run. Workers are immutable value types, and `optimize` is
/// `nonisolated`, so the actual work happens off the main actor.
public protocol Worker: Sendable {
    /// Displayed in the status column ("Started Zopfli"), and used as the key for
    /// skipping repeated identical runs.
    var name: String { get }

    /// Mixed into the job's settings hash, so that changing any setting invalidates the results cache.
    var settingsIdentifier: Int { get }

    /// Non-idempotent tools are re-run even if they already saw a file of this size.
    var isIdempotent: Bool { get }

    /// Tools that change pixels (lossy) or strip chunks have to run before the pure optimizers.
    var makesNonOptimizingModifications: Bool { get }

    func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult?
}

public extension Worker {
    var settingsIdentifier: Int { 0 }
    var isIdempotent: Bool { true }
    var makesNonOptimizingModifications: Bool { false }
}

private final class BundleToken {}

public enum Tools {
    public static let bundle = Bundle(for: BundleToken.self)

    /// Bundled command-line tool, in `Contents/MacOS` or `Contents/Resources`.
    public static func executable(named name: String) -> URL? {
        if let path = bundle.url(forAuxiliaryExecutable: name) ?? bundle.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: path.path) {
            return path
        }
        if let path = Bundle.main.url(forAuxiliaryExecutable: name) ?? Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: path.path) {
            return path
        }
        let fallbackDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("jpegli").path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bin").path
        ]
        for dir in fallbackDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        IOWarn("Can't find working executable for \(name) - disabling")
        return nil
    }

    public static func requireExecutable(named name: String) throws -> URL {
        guard let url = executable(named: name) else {
            throw CommandError.executableMissing(name)
        }
        return url
    }

    private static let tempCounter = Mutex(0)

    /// `/tmp/ImageOptim.<Tool>.<n>.temp`
    public static func temporaryURL(for workerName: String) -> URL {
        let n = tempCounter.withLock { counter -> Int in
            counter += 1
            return counter
        }
        let filename = String(format: "ImageOptim.%@.%x.%x.temp", workerName, getpid(), n)
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
    }

    /// Zopfli is an open-ended search, so it gets a deadline proportional
    /// to the file size and the optimization level.
    public static func timeLimit(level: Int, byteSize: Int) -> Int {
        min(8 + level * 13, 10 + byteSize / 1024)
    }

    /// Reads the first integer that follows `marker` on a line of tool output.
    public static func number(after marker: String, in line: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        var digits = ""
        var seenDigit = false
        for character in line[range.upperBound...] {
            if character.isNumber {
                digits.append(character)
                seenDigit = true
            } else if character == "-" && !seenDigit && digits.isEmpty {
                digits.append(character)
            } else if seenDigit {
                break
            } else if character == " " {
                continue
            } else {
                break
            }
        }
        guard let value = Int(digits), value != 0 else { return nil }
        return value
    }

    /// Scans leading whitespace-separated integers, like `NSScanner scanInt:` did.
    public static func leadingIntegers(in line: String, count: Int) -> [Int]? {
        var result: [Int] = []
        var iterator = line.split(separator: " ", omittingEmptySubsequences: true).makeIterator()
        while result.count < count, let token = iterator.next() {
            guard let value = Int(token) else { return nil }
            result.append(value)
        }
        return result.count == count ? result : nil
    }
}
