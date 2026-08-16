//
//  ZopfliWorker.swift
//  ImageOptim
//

import Foundation

public struct ZopfliWorker: Worker {
    public let name = "Zopfli"
    let iterations: Int
    let baseTimeLimit: Int
    let strip: Bool
    let alternativeStrategy: Bool

    public init(level: Int, byteSize: Int, settings: Settings, alternativeStrategy: Bool) {
        iterations = 3 + 3 * level
        strip = settings.removePngChunks
        baseTimeLimit = Tools.timeLimit(level: level, byteSize: byteSize)
        self.alternativeStrategy = alternativeStrategy
    }

    public var settingsIdentifier: Int {
        iterations * 4 + (strip ? 2 : 0) + (alternativeStrategy ? 1 : 0)
    }

    public var isIdempotent: Bool { false }

    public var makesNonOptimizingModifications: Bool { true }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        var arguments = ["--lossy_transparent", "-y", file.url.path, temp.path]

        if !strip {
            // FIXME: that's crappy. Should list actual chunks in file :/
            arguments.insert("--keepchunks=tEXt,zTXt,iTXt,gAMA,sRGB,iCCP,bKGD,pHYs,sBIT,tIME,oFFs,acTL,fcTL,fdAT,prVW,mkBF,mkTS,mkBS,mkBT", at: 0)
        }

        var actualIterations = iterations
        var filters = "--filters=0pme"
        var timeLimit = Double(baseTimeLimit)

        if file.isLarge {
            actualIterations = 5 + actualIterations / 3 // use faster setting for large files
            filters = "--filters=p"
        }

        if alternativeStrategy {
            timeLimit *= 1.4
            filters = "--filters=bp"
        } else {
            timeLimit *= 0.8
        }

        arguments.insert(filters, at: 0)
        if actualIterations != 0 {
            arguments.insert("--iterations=\(actualIterations)", at: 0)
        }
        arguments.insert("--timelimit=\(Int(timeLimit))", at: 0)

        let executable = try Tools.requireExecutable(named: "zopflipng")
        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            stdout: .capture,
            stderr: .capture,
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task Zopfli failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp), output.byteSize > 70 else { return nil }
        return WorkerResult(file: output, toolName: "Zopfli")
    }
}
