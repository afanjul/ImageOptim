//
//  PngCrushWorker.swift
//  ImageOptim
//

import Foundation

public struct PngCrushWorker: Worker {
    public let name = "PngCrush"
    let strip: Bool
    let brute: Bool

    public init(level: Int, settings: Settings) {
        strip = settings.removePngChunks
        brute = level >= 6
    }

    public var settingsIdentifier: Int { strip ? 1 : 0 }

    public var makesNonOptimizingModifications: Bool { strip }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        var arguments = ["-nofilecheck", "-bail", "-blacken", "-reduce", "-cc", "--", file.url.path, temp.path]

        if strip {
            arguments.insert(contentsOf: ["-rem", "alla"], at: 0)
        }
        if file.isSmall || (brute && !file.isLarge) {
            arguments.insert("-brute", at: 0)
        }

        let executable = try Tools.requireExecutable(named: "pngcrush")
        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdout: .capture,
            stderr: .capture,
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task PngCrush failed with status \(status)")
            return nil
        }

        // pngcrush sometimes writes only a PNG header (70 bytes)!
        guard let output = file.tempCopy(at: temp), output.byteSize > 70 else { return nil }
        return WorkerResult(file: output, toolName: "Pngcrush")
    }
}
