//
//  ImageFile.swift
//  ImageOptim
//

import Foundation

public enum ImageFileType: Int, Sendable, CaseIterable {
    case png = 1
    case jpeg = 2
    case gif = 3
    case svg = 4
    case webp = 5
    case avif = 6
    case jxl = 7
    case heic = 8

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .gif: "image/gif"
        case .svg: "image/svg"
        case .webp: "image/webp"
        case .avif: "image/avif"
        case .jxl: "image/jxl"
        case .heic: "image/heic"
        }
    }

    public var pathExtensions: [String] {
        switch self {
        case .png: ["png"]
        case .jpeg: ["jpg", "jpeg"]
        case .gif: ["gif"]
        case .svg: ["svg"]
        case .webp: ["webp"]
        case .avif: ["avif"]
        case .jxl: ["jxl"]
        case .heic: ["heic", "heif"]
        }
    }
}

/// An immutable pointer to an image on disk together with its size and sniffed type.
///
/// Instances created with `temporary: true` delete the file they point at when the
/// last reference goes away — this replaces the old `TempFile` subclass.
public final class ImageFile: Sendable {
    public let url: URL
    public let byteSize: Int
    public let type: ImageFileType?
    private let temporary: Bool

    init?(type: ImageFileType?, byteSize: Int, url: URL, temporary: Bool = false) {
        guard byteSize > 0 else { return nil }
        self.type = type
        self.byteSize = byteSize
        self.url = url
        self.temporary = temporary
    }

    /// Sniffs the file type out of the first bytes of the file, exactly like the
    /// Objective-C version did — the magic numbers must not change, because the
    /// type decides which tools get to run.
    public convenience init?(data: Data, url: URL) {
        guard data.count >= 6 else { return nil }

        let header = [UInt8](data.prefix(16))
        let ext = url.pathExtension.lowercased()
        let type: ImageFileType?

        if header.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]) {
            type = .png
        } else if header.starts(with: [0xff, 0xd8, 0xff]) {
            type = .jpeg
        } else if header.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            type = .gif
        } else if header.starts(with: Array("<svg".utf8)) || ext == "svg" {
            type = .svg
        } else if data.count >= 12,
                  header.starts(with: Array("RIFF".utf8)),
                  data[8...11].elementsEqual(Array("WEBP".utf8)) {
            type = .webp
        } else if header.starts(with: [0xff, 0x0a]) ||
                  header.starts(with: [0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 0x0d, 0x0a, 0x87, 0x0a]) ||
                  ext == "jxl" {
            type = .jxl
        } else if data.count >= 16, data[4...7].elementsEqual(Array("ftyp".utf8)) {
            let brand = String(decoding: data[8...11], as: UTF8.self)
            let heicBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]
            if brand == "avif" || brand == "avis" || ext == "avif" {
                type = .avif
            } else if heicBrands.contains(brand) || ext == "heic" || ext == "heif" {
                type = .heic
            } else {
                type = nil
            }
        } else if ext == "webp" {
            type = .webp
        } else if ext == "avif" {
            type = .avif
        } else if ext == "jxl" {
            type = .jxl
        } else if ext == "heic" || ext == "heif" {
            type = .heic
        } else {
            type = nil
        }

        self.init(type: type, byteSize: data.count, url: url, temporary: false)
    }

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data, url: url)
    }

    deinit {
        if temporary {
            let url = url
            DispatchQueue.global().async {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Does not copy anything — only makes an instance pointing at a new location.
    public func copy(at url: URL) -> ImageFile? {
        ImageFile(type: type, byteSize: Self.byteSize(of: url), url: url)
    }

    public func copy(at url: URL, byteSize: Int) -> ImageFile? {
        ImageFile(type: type, byteSize: byteSize, url: url)
    }

    public func tempCopy(at url: URL) -> ImageFile? {
        ImageFile(type: type, byteSize: Self.byteSize(of: url), url: url, temporary: true)
    }

    public func tempCopy(at url: URL, byteSize: Int) -> ImageFile? {
        guard byteSize > 0 else { return nil }
        let actualSize = Self.byteSize(of: url)
        guard byteSize == actualSize else {
            IOWarn("Expected size \(byteSize), but file is actually \(actualSize)")
            return nil
        }
        return ImageFile(type: type, byteSize: byteSize, url: url, temporary: true)
    }

    public var isLarge: Bool {
        type == .png ? byteSize > 250 * 1024 : byteSize > 1024 * 1024
    }

    public var isSmall: Bool {
        type == .png ? byteSize < 2048 : byteSize < 10 * 1024
    }

    public var mimeType: String? { type?.mimeType }

    public static func byteSize(of url: URL) -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize ?? 0
        } catch {
            IOWarn("Could not stat \(url.path): \(error)")
            return 0
        }
    }
}
