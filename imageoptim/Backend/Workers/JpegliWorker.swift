//
//  JpegliWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct JpegliWorker: Worker {
    public let name = "Jpegli"
    let quality: Int
    let lossy: Bool

    public init(settings: Settings) {
        self.lossy = settings.lossyEnabled
        self.quality = settings.jpegOptimMaxQuality
    }

    public var makesNonOptimizingModifications: Bool { lossy && quality < 100 }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        guard let executable = Tools.executable(named: "cjpegli") else {
            return nil
        }

        var arguments = [
            file.url.path,
            temp.path,
            "-p", "2"
        ]

        if lossy && quality > 10 && quality < 100 {
            arguments.append(contentsOf: ["-q", "\(quality)"])
        } else {
            // High-fidelity perceptual visually lossless mode (Google butteraugli standard)
            arguments.append(contentsOf: ["-q", "95"])
        }

        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdout: .capture,
            stderr: .capture,
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("cjpegli failed with exit status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "Jpegli")
    }
}
