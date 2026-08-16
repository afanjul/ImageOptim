//
//  AdvCompWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct AdvCompWorker: Worker {
    public let name = "AdvComp"
    let level: Int

    public init(level: Int) {
        self.level = max(1, min(4, level))
    }

    public var settingsIdentifier: Int { level }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        // advpng optimizes in place
        do {
            try FileManager.default.copyItem(at: file.url, to: temp)
        } catch {
            IOWarn("Can't make temp copy of \(file.url.path) in \(temp.path); \(error)")
            return nil
        }

        let executable = try Tools.requireExecutable(named: "advpng")
        let optimizedSize = Mutex(0)

        let status = try await Command.run(
            executable: executable,
            arguments: ["-\(level != 0 ? level : 4)", "-z", "--", temp.path],
            stdout: .capture,
            stderr: .capture,
            lowPriority: context.lowPriority
        ) { line in
            // advpng prints "<original> <optimized> <ratio> <name>"
            guard let numbers = Tools.leadingIntegers(in: line, count: 2) else {
                return .keepReading
            }
            optimizedSize.withLock { $0 = numbers[1] }
            return .stop
        }

        guard status == 0 else {
            IOWarn("Task AdvComp failed with status \(status)")
            return nil
        }

        let size = optimizedSize.withLock { $0 }
        guard let output = file.tempCopy(at: temp, byteSize: size) else { return nil }
        return WorkerResult(file: output, toolName: "AdvPNG")
    }
}
