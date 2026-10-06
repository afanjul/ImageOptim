//
//  JxlWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct JxlWorker: Worker {
    public let name = "JPEG XL"

    public init() {}

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        if let executable = Tools.executable(named: "jxloptim") {
            let status = try await Command.run(
                executable: executable,
                arguments: [file.url.path, temp.path],
                lowPriority: context.lowPriority
            )
            guard status == 0 else {
                if status != 2 {
                    IOWarn("jxloptim failed with exit status \(status)")
                }
                return nil
            }
            guard let output = file.tempCopy(at: temp) else { return nil }
            return WorkerResult(file: output, toolName: "jxloptim")
        }

        if let executable = Tools.executable(named: "cjxl") {
            let status = try await Command.run(
                executable: executable,
                arguments: ["-d", "0", "-e", "7", file.url.path, temp.path],
                lowPriority: context.lowPriority
            )
            guard status == 0 else {
                IOWarn("cjxl failed with exit status \(status)")
                return nil
            }
            guard let output = file.tempCopy(at: temp) else { return nil }
            return WorkerResult(file: output, toolName: "cjxl")
        }

        return nil
    }
}
