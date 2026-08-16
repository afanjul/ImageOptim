//
//  GifsicleWorker.swift
//  ImageOptim
//

import Foundation

public struct GifsicleWorker: Worker {
    public let name = "Gifsicle"
    let interlace: Bool
    let quality: Int

    public init(interlace: Bool, quality: Int) {
        self.interlace = interlace
        self.quality = quality
    }

    public var settingsIdentifier: Int { (interlace ? 1 : 0) + 2 * quality }

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        var arguments = [
            "-o", temp.path,
            interlace ? "--interlace" : "--no-interlace",
            "-O3",
            "--careful", // needed for Safari/Preview decoding bug
            "--no-comments", "--no-names", "--same-delay", "--same-loopcount", "--no-warnings",
            "--", file.url.path,
        ]

        let isLossy = quality < 100
        if isLossy {
            var loss = Int(pow(Double(100 - quality), 1.8) / 5.0)
            if file.isSmall {
                loss = 1 + loss / 8 // Spare GIF icons
            } else if !file.isLarge {
                loss = 1 + loss / 2 // Spare GIF images
            }
            arguments.insert("--lossy=\(loss)", at: 0)
        }

        let executable = try Tools.requireExecutable(named: "gifsicle")
        let status = try await Command.run(
            executable: executable,
            arguments: arguments,
            lowPriority: context.lowPriority
        )

        guard status == 0 else {
            IOWarn("Task Gifsicle failed with status \(status)")
            return nil
        }

        guard let output = file.tempCopy(at: temp) else { return nil }

        if isLossy {
            let allowance: Int = 105 + (100 - quality) / 2
            let adjustedSize: Int = output.byteSize * allowance / 100
            if adjustedSize >= file.byteSize {
                return nil
            }
        }

        let toolName = isLossy ? "Giflossy" : (interlace ? "Gifsicle interlaced" : "Gifsicle")
        return WorkerResult(file: output, toolName: toolName)
    }
}
