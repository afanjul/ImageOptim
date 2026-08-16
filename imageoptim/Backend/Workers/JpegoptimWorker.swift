//
//  JpegoptimWorker.swift
//  ImageOptim
//

import Foundation
import Synchronization

public struct JpegoptimWorker: Worker {
    public let name = "Jpegoptim"
    let maxQuality: Int
    let strip: Bool

    public init(settings: Settings) {
        // Sharing setting with jpegtran
        strip = settings.jpegTranStripAll
        maxQuality = settings.lossyEnabled ? settings.jpegOptimMaxQuality : 100
    }

    public var settingsIdentifier: Int { maxQuality * 2 + (strip ? 1 : 0) }

    public var makesNonOptimizingModifications: Bool { maxQuality < 100 }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        // jpegoptim optimizes in place
        do {
            try FileManager.default.copyItem(at: file.url, to: temp)
        } catch {
            IOWarn("Can't make temp copy of \(file.url.path) in \(temp.path)")
        }

        let lossy = maxQuality > 10 && maxQuality < 100

        var arguments = [
            strip ? "--strip-all" : "--strip-none",
            // lossless progressive is redundant with jpegtran, but lossy baseline would prevent parallelisation
            lossy ? "--all-progressive" : "--all-normal",
            "-v", // needed for parsing output size
            "--", temp.path,
        ]
        if lossy {
            arguments.insert("-m\(maxQuality)", at: 0)
        }

        let executable = try Tools.requireExecutable(named: "jpegoptim")
        let optimizedSize = Mutex(0)

        _ = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdout: .capture,
            stderr: .capture,
            lowPriority: context.lowPriority
        ) { line in
            guard let size = Tools.number(after: " --> ", in: line) else {
                return .keepReading
            }
            optimizedSize.withLock { $0 = size }
            return .stop
        }

        let size = optimizedSize.withLock { $0 }

        if makesNonOptimizingModifications {
            // require at least 5% gain when doing lossy optimization
            let isSignificantlySmaller = Double(file.byteSize) * 0.95 > Double(size)
            guard isSignificantlySmaller else { return nil }
        }

        guard let output = file.tempCopy(at: temp, byteSize: size) else { return nil }
        let toolName = lossy ? "JpegOptim \(maxQuality)%" : "JpegOptim"
        return WorkerResult(file: output, toolName: toolName)
    }
}
