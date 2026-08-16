//
//  DirScanner.swift
//  ImageOptim
//

import Foundation
import Synchronization

/// `Atomic` is non-copyable, so it needs a reference to live in to be shared between closures.
private final class CancelFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}

public enum DirScanner {
    private static let bufferCapacity = 256

    /// Walks a directory tree and reports matching files in growing batches,
    /// so that optimization starts before the whole tree has been scanned.
    ///
    /// - Parameter extensions: lowercased path extensions to look for.
    public static func scan(url: URL, extensions: Set<String>, flush: @Sendable ([URL]) async -> Void) async {
        for await batch in enumerate(url: url, extensions: extensions) {
            await flush(batch)
        }
    }

    /// The enumeration itself is blocking file I/O, so it runs on a plain dispatch queue
    /// rather than hogging a thread of the cooperative pool.
    private static func enumerate(url: URL, extensions: Set<String>) -> AsyncStream<[URL]> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let cancelled = CancelFlag()
            DispatchQueue.global(qos: .userInitiated).async {
                var bufferSize = 16
                var buffer: [URL] = []
                buffer.reserveCapacity(bufferCapacity)

                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [], options: [])
                while let foundURL = enumerator?.nextObject() as? URL {
                    if cancelled.isCancelled {
                        continuation.finish()
                        return
                    }
                    guard extensions.contains(foundURL.pathExtension.lowercased()) else { continue }

                    buffer.append(foundURL)
                    if buffer.count >= bufferSize {
                        // assuming that previous buffer flushes created some work to do,
                        // the buffer size can be increased to lower the overhead
                        bufferSize = min(bufferCapacity, bufferSize * 4)
                        continuation.yield(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }

                if !buffer.isEmpty {
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in cancelled.cancel() }
        }
    }
}
