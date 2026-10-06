//
//  AvifWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct AvifWorker: Worker {
    public let name = "AVIF"

    public init() {}

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        if let executable = Tools.executable(named: "avifoptim") {
            let status = try await Command.run(
                executable: executable,
                arguments: [file.url.path, temp.path],
                lowPriority: context.lowPriority
            )
            guard status == 0 else {
                if status != 2 {
                    IOWarn("avifoptim failed with exit status \(status)")
                }
                return nil
            }
            guard let output = file.tempCopy(at: temp) else { return nil }
            return WorkerResult(file: output, toolName: "avifoptim")
        }

        if let executable = Tools.executable(named: "avifenc") {
            let status = try await Command.run(
                executable: executable,
                arguments: ["-s", "0", "-l", file.url.path, "-o", temp.path],
                lowPriority: context.lowPriority
            )
            guard status == 0 else {
                IOWarn("avifenc failed with exit status \(status)")
                return nil
            }
            guard let output = file.tempCopy(at: temp) else { return nil }
            return WorkerResult(file: output, toolName: "avifenc")
        }

        return nil
    }
}
