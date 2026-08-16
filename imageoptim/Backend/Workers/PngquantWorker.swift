//
//  PngquantWorker.swift
//  ImageOptim
//

import Foundation

public struct PngquantWorker: Worker {
    public let name = "Pngquant"
    let minQuality: Int
    let speed: Int

    public init(level: Int, minQuality: Int) {
        self.minQuality = minQuality
        speed = min(3, 7 - level)
    }

    public var settingsIdentifier: Int { minQuality }

    public var makesNonOptimizingModifications: Bool { minQuality < 100 }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        let maxQuality = min(100, minQuality + 20)
        let arguments = [
            "256", "--skip-if-larger",
            "-s\(speed)",
            "--quality", "\(minQuality)-\(maxQuality)",
            "-",
        ]

        let executable = try Tools.requireExecutable(named: "pngquant")
        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdin: .readFile(file.url),
            stdout: .writeFile(temp),
            stderr: .capture,
            lowPriority: context.lowPriority
        )

        // 98/99 == written 24-bit instead (which is fine too, because it applies color profiles)
        switch status {
        case 0:
            break
        case 99:
            IODebug("pngquant skipped image due to low quality")
        case 98:
            IODebug("pngquant skipped image due to poor compression")
        default:
            IODebug("pngquant error \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "pngquant")
    }
}
