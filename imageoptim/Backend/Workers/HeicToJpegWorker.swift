//
//  HeicToJpegWorker.swift
//  ImageOptim
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public struct HeicToJpegWorker: Worker {
    public let name = "HEIC"
    public var makesNonOptimizingModifications: Bool { true }

    public init() {}

    public func optimize(_ file: ImageFile, to temp: URL, context: WorkerContext) async throws -> WorkerResult? {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else {
            IOWarn("Could not open HEIC file \(file.url.path)")
            return nil
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            IOWarn("Could not decode HEIC image at index 0 for \(file.url.path)")
            return nil
        }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            IOWarn("Could not create JPEG destination at \(temp.path)")
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            IOWarn("Could not finalize JPEG write to \(temp.path)")
            return nil
        }

        let size = ImageFile.byteSize(of: temp)
        guard size > 0, let output = ImageFile(type: .jpeg, byteSize: size, url: temp, temporary: true) else {
            return nil
        }
        return WorkerResult(file: output, toolName: "HEIC")
    }
}
