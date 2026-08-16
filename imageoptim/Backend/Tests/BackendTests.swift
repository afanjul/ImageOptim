//
//  BackendTests.swift
//  BackendTests
//

import Foundation
import ImageOptimGPL
import Testing

@MainActor
struct BackendTests {
    @Test func compressOne() async throws {
        let original = try #require(Bundle(for: BundleToken.self).url(forResource: "unoptimized", withExtension: "png"))
        var copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: original, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let job = Job(filePath: copy, resultsDatabase: nil)
        let queue = JobQueue(cpus: 4, dirs: 1, files: 4, defaults: Self.testDefaults())

        queue.add(job)
        #expect(job.isBusy)
        #expect(!job.isDone)
        #expect(!job.isFailed)
        await queue.wait()
        #expect(!job.isBusy)

        copy.removeAllCachedResourceValues()
        var originalURL = original
        originalURL.removeAllCachedResourceValues()

        let size = try #require(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let originalSize = try #require(try originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        #expect(job.isDone)
        #expect(!job.isFailed)
        #expect(!job.isStoppable)

        #expect(size < originalSize)
        #expect(size <= 5552)

        #expect(job.canRevert)

        #expect(job.byteSizeOptimized == size)
        #expect(job.byteSizeOriginal == originalSize)
    }

    /// An empty (never persisted) suite carrying only the registration domain, so the
    /// result doesn't depend on whichever preferences the developer's own ImageOptim has.
    private static func testDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "BackendTests-\(UUID().uuidString)")!
        defaults.register(defaults: [
            PrefKey.advPngEnabled: true,
            PrefKey.level: 4,
            PrefKey.gifQuality: 80,
            PrefKey.gifsicleEnabled: true,
            PrefKey.jpegOptimEnabled: true,
            PrefKey.jpegOptimMaxQuality: 80,
            PrefKey.jpegTranEnabled: true,
            PrefKey.jpegTranStripAll: true,
            PrefKey.lossyEnabled: false,
            PrefKey.oxiPngEnabled: true,
            PrefKey.pngCrushEnabled: false,
            PrefKey.pngMinQuality: 80,
            PrefKey.pngOutEnabled: true,
            PrefKey.pngOutRemoveChunks: true,
            PrefKey.preserveDates: false,
            PrefKey.preservePermissions: true,
            PrefKey.runConcurrentDirscans: 2,
            PrefKey.runConcurrentFiles: 4,
            PrefKey.runLowPriority: false,
            PrefKey.svgCleanerEnabled: true,
            PrefKey.zopfliEnabled: true,
        ])
        return defaults
    }
}

/// Only used to locate the test bundle.
private final class BundleToken {}
