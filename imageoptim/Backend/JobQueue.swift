//
//  JobQueue.swift
//  ImageOptim
//

import Foundation
import Observation

/// Replaces the three `NSOperationQueue`s (cpu, fileIO, dirWorker) with structured concurrency.
///
/// The queues themselves became `AsyncSemaphore`s owned here and handed down to the jobs,
/// so the concurrency limits are identical; this type only keeps track of the outstanding
/// tasks in order to report `isBusy` / `queueCount` and to be able to wait for or cancel them.
@MainActor
@Observable
public final class JobQueue {
    public private(set) var isBusy = false

    /// Number of outstanding jobs and directory scans. Exposed to AppleScript.
    public var queueCount: Int { tasks.count }

    /// Called every time the queue runs dry — the replacement for the `JobQueueFinished` notification.
    @ObservationIgnored public var onIdle: (@MainActor () -> Void)?

    @ObservationIgnored private let cpuLimiter: AsyncSemaphore
    @ObservationIgnored private let fileIOLimiter: AsyncSemaphore
    @ObservationIgnored private let dirScanLimiter: AsyncSemaphore
    /// Guetzli is a memory hog, so only one large image may be processed at a time.
    @ObservationIgnored private let guetzliGate = AsyncSemaphore(value: 1)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(cpus: Int, dirs: Int, files: Int, defaults: UserDefaults) {
        self.defaults = defaults
        cpuLimiter = AsyncSemaphore(value: cpus > 0 ? cpus : ProcessInfo.processInfo.activeProcessorCount)
        dirScanLimiter = AsyncSemaphore(value: dirs > 0 ? dirs : 1)
        fileIOLimiter = AsyncSemaphore(value: files > 0 ? files : 2)
    }

    // MARK: - Enqueueing

    public func add(_ job: Job) {
        // the settings are snapshotted at enqueue time, which is when the Objective-C
        // workers used to read them out of NSUserDefaults
        let settings = Settings(defaults: defaults)
        if settings.lossyEnabled {
            defaults.set(true, forKey: PrefKey.lossyUsed)
        }

        job.markEnqueued()
        track { [cpuLimiter, fileIOLimiter, guetzliGate] in
            await job.run(settings: settings,
                          cpuLimiter: cpuLimiter,
                          fileIOLimiter: fileIOLimiter,
                          guetzliGate: guetzliGate)
        }
    }

    /// Scans `url` recursively, handing every batch of matching files to `onFound` on the main actor.
    public func addDirectoryScan(url: URL, extensions: Set<String>, onFound: @escaping @MainActor @Sendable ([URL]) -> Void) {
        track { [dirScanLimiter] in
            await dirScanLimiter.withPermit {
                await DirScanner.scan(url: url, extensions: extensions) { batch in
                    await MainActor.run { onFound(batch) }
                }
            }
        }
    }

    private func track(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.finished(id)
        }
        isBusy = true
    }

    private func finished(_ id: UUID) {
        tasks[id] = nil
        guard tasks.isEmpty else { return }
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        onIdle?()
    }

    // MARK: - Lifecycle

    /// Waits until nothing is queued any more. Note that a job may enqueue more work
    /// while waiting (a directory scan adds files), which is why this checks again after waking up.
    public func wait() async {
        while !tasks.isEmpty {
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }
    }

    public func cleanup() {
        for task in tasks.values {
            task.cancel()
        }
    }
}
