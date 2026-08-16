//
//  OxiPngWorker.swift
//  ImageOptim
//

import Foundation

public struct OxiPngWorker: Worker {
    public let name = "OxiPng"
    let optLevel: Int
    let strip: Bool

    public init(level: Int, stripMetadata: Bool) {
        optLevel = max(2, min(level, 6))
        strip = stripMetadata
    }

    public var settingsIdentifier: Int { 2 * (optLevel * 2 + (strip ? 1 : 0)) }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        var arguments = [
            "-o\(optLevel != 0 ? optLevel : 6)",
            "-i0", "-a",
            "--out", temp.path, "--", file.url.path,
        ]
        if strip {
            arguments.insert("--strip=safe", at: 0)
        }

        let executable = try Tools.requireExecutable(named: "oxipng")
        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task OxiPng failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "OxiPNG")
    }
}
