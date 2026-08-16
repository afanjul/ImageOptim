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
///
/// Jobs are admitted a few at a time rather than all at once. `NSOperationQueue` used to hold
/// the backlog as cheap operation objects; a `Task` per queued file is not cheap — dropping a
/// folder of ten thousand images would spawn ten thousand tasks that all immediately hop to the
/// main actor to report "Inspecting file" before parking on a semaphore.
@MainActor
@Observable
public final class JobQueue {
    public private(set) var isBusy = false

    /// Number of outstanding jobs and directory scans. Exposed to AppleScript.
    public var queueCount: Int { tasks.count + (pending.count - pendingHead) }

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

    /// The backlog of jobs that have been added but not started yet, as a queue with a
    /// moving head so that starting a job is O(1) rather than an O(n) `removeFirst`.
    @ObservationIgnored private var pending: [@MainActor () -> Void] = []
    @ObservationIgnored private var pendingHead = 0
    /// How many jobs may be in flight at once. Enough to keep every limiter saturated
    /// while a job waits on file I/O, and small enough that the backlog stays cheap.
    @ObservationIgnored private let maxJobsInFlight: Int
    @ObservationIgnored private var jobsInFlight = 0

    /// Snapshot of the preferences, reused for a whole batch. Reading 22 defaults keys per
    /// file on the main actor is what makes dropping a large folder stall before anything runs.
    @ObservationIgnored private var cachedSettings: Settings?
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    public init(cpus: Int, dirs: Int, files: Int, defaults: UserDefaults) {
        self.defaults = defaults
        let cpuCount = cpus > 0 ? cpus : ProcessInfo.processInfo.activeProcessorCount
        cpuLimiter = AsyncSemaphore(value: cpuCount)
        dirScanLimiter = AsyncSemaphore(value: dirs > 0 ? dirs : 1)
        fileIOLimiter = AsyncSemaphore(value: files > 0 ? files : 2)
        maxJobsInFlight = max(8, cpuCount * 4)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread
            MainActor.assumeIsolated { self?.cachedSettings = nil }
        }
    }

    // MARK: - Enqueueing

    public func add(_ job: Job) {
        // the settings are snapshotted at enqueue time, which is when the Objective-C
        // workers used to read them out of NSUserDefaults
        let settings = currentSettings()
        if settings.lossyEnabled, !defaults.bool(forKey: PrefKey.lossyUsed) {
            defaults.set(true, forKey: PrefKey.lossyUsed)
        }

        job.markEnqueued()
        pending.append { [weak self] in
            guard let self else { return }
            jobsInFlight += 1
            track { [cpuLimiter, fileIOLimiter, guetzliGate] in
                await job.run(settings: settings,
                              cpuLimiter: cpuLimiter,
                              fileIOLimiter: fileIOLimiter,
                              guetzliGate: guetzliGate)
            } whenFinished: { [weak self] in
                guard let self else { return }
                jobsInFlight -= 1
                startPendingJobs()
            }
        }
        setBusy(true)
        startPendingJobs()
    }

    private func currentSettings() -> Settings {
        if let cachedSettings {
            return cachedSettings
        }
        let settings = Settings(defaults: defaults)
        cachedSettings = settings
        return settings
    }

    private func startPendingJobs() {
        while jobsInFlight < maxJobsInFlight, pendingHead < pending.count {
            let start = pending[pendingHead]
            pendingHead += 1
            start()
        }
        // reclaim the consumed prefix once it dominates the array
        if pendingHead > 512, pendingHead * 2 > pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        if pendingHead >= pending.count, !pending.isEmpty {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
        }
    }

    /// Scans `url` recursively, handing every batch of matching files to `onFound` on the main actor.
    ///
    /// Scans are not part of the pending backlog: they are already limited by `dirScanLimiter`,
    /// and they are what produces the jobs, so they must not queue behind them.
    public func addDirectoryScan(url: URL, extensions: Set<String>, onFound: @escaping @MainActor @Sendable ([URL]) -> Void) {
        setBusy(true)
        track { [dirScanLimiter] in
            await dirScanLimiter.withPermit {
                await DirScanner.scan(url: url, extensions: extensions) { batch in
                    await MainActor.run { onFound(batch) }
                }
            }
        }
    }

    private func track(_ operation: @escaping @Sendable () async -> Void,
                       whenFinished: (@MainActor () -> Void)? = nil) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            whenFinished?()
            self?.finished(id)
        }
        setBusy(true)
    }

    /// Assigning the same value still invalidates every view observing it.
    private func setBusy(_ busy: Bool) {
        if isBusy != busy {
            isBusy = busy
        }
    }

    private func finished(_ id: UUID) {
        tasks[id] = nil
        guard tasks.isEmpty, pendingHead >= pending.count else { return }
        setBusy(false)
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
        while !tasks.isEmpty || pendingHead < pending.count {
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }
    }

    public func cleanup() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        pending.removeAll()
        pendingHead = 0
        for task in tasks.values {
            task.cancel()
        }
    }
}
