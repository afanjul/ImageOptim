//
//  JpegtranWorker.swift
//  ImageOptim
//

import Foundation

public struct JpegtranWorker: Worker {
    public let name = "Jpegtran"
    let strip: Bool

    public init(settings: Settings) {
        strip = settings.jpegTranStripAll
    }

    public var settingsIdentifier: Int { strip ? 1 : 0 }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        let executable = try Tools.requireExecutable(named: "jpegtran")

        // eh, handling of paths starting with "-" is unsafe here.
        // Hopefully all paths from dropped files will be absolute...
        let arguments = [
            "-copy", strip ? "none" : "all",
            "-optimize",
            "-outfile", temp.path,
            file.url.path,
        ]

        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdout: .capture,
            stderr: .capture,
            currentDirectory: executable.deletingLastPathComponent(),
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task Jpegtran failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "MozJPEG")
    }
}
