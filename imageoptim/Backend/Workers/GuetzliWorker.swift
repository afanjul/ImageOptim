//
//  GuetzliWorker.swift
//  ImageOptim
//

import AppKit
import Foundation

public struct GuetzliWorker: Worker {
    public let name = "Guetzli"
    let level: Int

    public init(settings: Settings) {
        let quality = settings.lossyEnabled ? settings.jpegOptimMaxQuality : 95
        level = max(84, quality)
    }

    public var makesNonOptimizingModifications: Bool { true }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        let executable = try Tools.requireExecutable(named: "guetzli")

        // guetzli only understands sRGB, so the input is re-encoded into the temp file first
        guard let inputRep = NSImageRep(contentsOf: file.url) as? NSBitmapImageRep,
              let sRGBRep = inputRep.converting(to: .sRGB, renderingIntent: .relativeColorimetric),
              let sRGBPNGData = sRGBRep.representation(using: .png, properties: [:])
        else {
            IOWarn("Guetzli can't read \(file.url.path)")
            return nil
        }
        try sRGBPNGData.write(to: temp, options: [])

        let arguments = [
            "--quality", "\(level)",
            "--memlimit", file.isSmall ? "2000" : "6000",
            temp.path,
            temp.path,
        ]

        let run = {
            try await Command.run(
                executable: executable,
                arguments: arguments,
                stdout: .capture,
                stderr: .capture,
                lowPriority: context.lowPriority
            )
        }

        // Guetzli uses so much memory that it's dangerous to run all images in parallel
        let status: Int32
        if file.isLarge {
            status = try await context.guetzliGate.withPermit(run)
        } else {
            status = try await run()
        }

        guard status == 0 else {
            IOWarn("Task Guetzli failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }
        return WorkerResult(file: output, toolName: "Guetzli")
    }
}
