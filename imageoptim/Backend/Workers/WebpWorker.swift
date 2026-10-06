//
//  WebpWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct WebpWorker: Worker {
    public let name = "cwebp"

    public init() {}

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        guard let executable = Tools.executable(named: "cwebp") else {
            return nil
        }

        let status = try await Command.run(
            executable: executable,
            arguments: [
                "-lossless",
                "-m", "6",
                "-exact",
                "-metadata", "all",
                "-quiet",
                file.url.path,
                "-o", temp.path
            ],
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("cwebp failed with exit status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "cwebp")
    }
}
