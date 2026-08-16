//
//  PngoutWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct PngoutWorker: Worker {
    public let name = "Pngout"
    let level: Int
    let removeChunks: Bool
    let timeLimit: Int

    public init(level rawLevel: Int, byteSize: Int, settings: Settings) {
        level = rawLevel == 0 ? 2 : (rawLevel >= 4 ? 0 : 1)
        removeChunks = settings.removePngChunks
        timeLimit = Tools.timeLimit(level: rawLevel, byteSize: byteSize)
    }

    public var settingsIdentifier: Int {
        level * 4 + (removeChunks ? 2 : 0) + (timeLimit < 60 ? 1 : 0)
    }

    public var makesNonOptimizingModifications: Bool { removeChunks }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        // uses stdout for the file, to force progress output onto unbuffered stderr
        var arguments = ["-r", "-v", file.url.path, "-"]

        var actualLevel = level
        if file.isLarge, level < 2 {
            actualLevel += 1 // use faster setting for large files
        }
        if actualLevel != 0 { // s0 is the default
            arguments.insert("-s\(actualLevel)", at: 0)
        }
        if !removeChunks { // -k0 (remove) is the default
            arguments.insert("-k1", at: 0)
        }

        let executable = try Tools.requireExecutable(named: "pngout")
        let optimizedSize = Mutex(0)

        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdout: .writeFile(temp),
            stderr: .capture,
            lowPriority: context.lowPriority,
            timeLimit: TimeInterval(timeLimit)
        ) { line in
            if line.hasPrefix("Out:"), let size = Tools.number(after: "Out:", in: line) {
                optimizedSize.withLock { $0 = size }
            } else if line.hasPrefix("Took") {
                return .stop
            }
            return .keepReading
        }

        let size = optimizedSize.withLock { $0 }

        // status 2 means it exited early (interrupted), which still leaves a usable file
        if status != 0, status != 2 || size == 0 {
            return nil
        }
        guard size != 0, let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "PNGOUT")
    }
}
