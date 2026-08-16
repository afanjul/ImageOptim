//
//  AsyncSemaphore.swift
//  ImageOptim
//

import Foundation
import Synchronization

/// Counting semaphore for structured concurrency — the replacement for
/// `NSOperationQueue.maxConcurrentOperationCount`.
public final class AsyncSemaphore: Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var value: Int
        var waiters: [Waiter] = []
    }

    public let limit: Int
    private let state: Mutex<State>

    public init(value: Int) {
        limit = max(1, value)
        state = Mutex(State(value: max(1, value)))
    }

    public func wait() async {
        let acquired = state.withLock { s -> Bool in
            if s.value > 0 {
                s.value -= 1
                return true
            }
            return false
        }
        if acquired { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquiredNow = state.withLock { s -> Bool in
                if s.value > 0 {
                    s.value -= 1
                    return true
                }
                s.waiters.append(Waiter(continuation: continuation))
                return false
            }
            if acquiredNow {
                continuation.resume()
            }
        }
    }

    public func signal() {
        let waiter = state.withLock { s -> Waiter? in
            if s.waiters.isEmpty {
                s.value += 1
                return nil
            }
            return s.waiters.removeFirst()
        }
        waiter?.continuation.resume()
    }

    /// True while there is spare capacity — the equivalent of the old
    /// `queue.operationCount < queue.maxConcurrentOperationCount` check.
    public var hasSpareCapacity: Bool {
        state.withLock { $0.value > 0 }
    }

    /// The `isolation` parameter keeps `body` in the caller's isolation region, so a
    /// `@MainActor` closure can be passed in without being sent across actors.
    public func withPermit<T>(isolation: isolated (any Actor)? = #isolation,
                              _ body: () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await body()
    }
}
