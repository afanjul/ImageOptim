//
//  SvgcleanerWorker.swift
//  ImageOptim
//

import Foundation

public struct SvgcleanerWorker: Worker {
    public let name = "Svgcleaner"
    let useLossy: Bool

    public init(lossy: Bool) {
        useLossy = lossy
    }

    public var settingsIdentifier: Int { useLossy ? 5 : 6 }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        let executable = try Tools.requireExecutable(named: "svgcleaner")

        let status = try await Command.run(
            executable: executable,
            arguments: ["--stdout", "--", file.url.path],
            stdout: .writeFile(temp),
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task Svgcleaner failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "Svgcleaner")
    }
}
