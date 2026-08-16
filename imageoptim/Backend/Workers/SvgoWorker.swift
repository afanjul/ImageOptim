//
//  SvgoWorker.swift
//  ImageOptim
//

import Foundation

public struct SvgoWorker: Worker {
    public let name = "Svgo"
    let useLossy: Bool

    public init(lossy: Bool) {
        useLossy = lossy
    }

    public var settingsIdentifier: Int { useLossy ? 5 : 6 }

    /// SVGO is a Node script, so it needs Node installed. Preferences hide the option when it isn't.
    public static var nodePath: URL? {
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        guard let scriptPath = Tools.bundle.url(forResource: "svgo", withExtension: "js") else {
            IOWarn("Broken install, missing script")
            return nil
        }
        guard let node = Self.nodePath else {
            IOWarn("Node not installed at /usr/local/bin/node")
            return nil
        }

        let arguments = [
            scriptPath.path,
            useLossy ? "1" : "0",
            file.url.path,
            temp.path,
        ]

        let status = try await Command.run(
            executable: node,
            arguments: arguments,
            stdin: .inherit,
            stdout: .inherit,
            stderr: .inherit,
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task Svgo failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: useLossy ? "SVGO" : "SVGO lite")
    }
}
