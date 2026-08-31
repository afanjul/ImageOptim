//
//  AppModel.swift
//  ImageOptim
//
//  The Swift replacement for FilesController.
//

import AppKit
import ImageOptimGPL
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// How the app was launched. `ImageOptim <files>` from a shell means "optimize and quit".
enum Launch {
    /// Unfortunately `NSApplicationLaunchIsDefaultLaunchKey` doesn't cover a bare CLI launch.
    static let isCommandLine: Bool = {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }
        // a normal macOS launch passes -psn or other dashed arguments
        return !args.contains { $0.hasPrefix("-") }
    }()

    static var quitWhenDone: Bool { isCommandLine }
}

/// A URL after its symlinks have been resolved and its existence checked.
struct ResolvedURL: Sendable {
    let url: URL
    let isDirectory: Bool
    let exists: Bool
}

/// Sorting a `Table` happens on the main actor, but `SortComparator.compare` is nonisolated,
/// hence the `assumeIsolated`.
struct JobComparator: SortComparator {
    enum Field: Sendable, Equatable {
        case status
        case fileName
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: Job, _ rhs: Job) -> ComparisonResult {
        let result = MainActor.assumeIsolated { () -> ComparisonResult in
            switch field {
            case .status:
                // plain integer comparison — boxing both sides into NSNumber allocated
                // two objects for every one of the n·log n comparisons
                return Self.order(lhs.statusOrder, rhs.statusOrder)
            case .fileName:
                return lhs.fileName.caseInsensitiveCompare(rhs.fileName)
            }
        }
        return applyingOrder(to: result)
    }

    /// The same ordering over a snapshot instead of a live `Job`, so that a long sort can run
    /// off the main actor — `Job` is `@MainActor` and can't be touched from there. Not an
    /// overload of `compare`: that name is the `SortComparator` requirement, and a second one
    /// would leave `Compared` ambiguous.
    fileprivate func order(_ lhs: JobSortKey, _ rhs: JobSortKey) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .status: result = Self.order(lhs.statusOrder, rhs.statusOrder)
        case .fileName: result = lhs.fileName.caseInsensitiveCompare(rhs.fileName)
        }
        return applyingOrder(to: result)
    }

    private static func order(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private func applyingOrder(to result: ComparisonResult) -> ComparisonResult {
        switch self.order {
        case .forward: return result
        case .reverse: return result == .orderedAscending ? .orderedDescending
            : result == .orderedDescending ? .orderedAscending : .orderedSame
        }
    }
}

/// Everything `JobComparator` needs from a `Job`, as a value that can leave the main actor.
fileprivate struct JobSortKey: Sendable {
    let statusOrder: Int
    let fileName: String
}

/// Sorts *indices* rather than jobs: the jobs themselves are main-actor-bound, and a permutation
/// is all the caller needs to reorder the array it is already holding. Ties fall back to the
/// original position, which keeps the sort stable the way `sorted(using:)` is.
private func sortedIndices(of keys: [JobSortKey], using comparators: [JobComparator]) -> [Int] {
    keys.indices.sorted { lhs, rhs in
        for comparator in comparators {
            switch comparator.order(keys[lhs], keys[rhs]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return lhs < rhs
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var jobs: [Job] = [] {
        // Bumped here rather than at each mutation site, so a sort that is still running off the
        // main actor can always tell that the list it was given has moved under it.
        didSet { jobsRevision &+= 1 }
    }
    var selection: Set<Job.ID> = [] {
        didSet {
            if selection != oldValue {
                updateSelectionState()
                onSelectionChanged?()
            }
        }
    }

    /// Called after the selection changed, so the Quick Look panel can follow it.
    /// A callback rather than an observation, because the delegate that owns the panel is
    /// not a view and has no update pass to hang a `withObservationTracking` off.
    @ObservationIgnored var onSelectionChanged: (@MainActor () -> Void)?

    var sortOrder: [JobComparator] = [] {
        didSet { resort(force: true) }
    }

    /// The table's rows. Stored rather than computed: sorting inside `body` made the sort run
    /// on every invalidation, and — because the comparator reads `statusOrder` while SwiftUI is
    /// tracking — subscribed the view to *every* job's status, so each of the thousands of status
    /// writes a run produces re-sorted the whole list.
    private(set) var sortedJobs: [Job] = []

    /// Lives here rather than in the view so that the "Show Columns" menu can toggle it too.
    var columnCustomization = TableColumnCustomization<Job>()

    /// Status bar text, throttled to avoid spending all the CPU on redrawing a label.
    private(set) var statusText: String
    private(set) var statusTextSelectable = false

    // Menu and toolbar enablement. These used to be computed properties that walked (and sorted)
    // the whole job list every time the main menu was rebuilt — which is every time any job's
    // status changed. They are now plain flags, refreshed by the throttled status pass.
    private(set) var hasJobs = false
    private(set) var hasSelection = false
    private(set) var isStoppable = false
    private(set) var canRevert = false
    private(set) var canClearComplete = false
    private(set) var canCopyAsDataURL = false
    private(set) var canStartAgainAny = false
    private(set) var canStartAgainOptimized = false
    private(set) var canPaste = false

    @ObservationIgnored let queue: JobQueue
    @ObservationIgnored private let db: ResultsDB?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var jobsByPath: [String: Job] = [:]
    @ObservationIgnored private var jobsByID: [Job.ID: Job] = [:]
    @ObservationIgnored private var isEnabled = true
    /// Insertion point for the next batch of files (drag&drop between rows). -1 means "append".
    @ObservationIgnored private var nextInsertRow = -1
    /// Whether the status bar shows the overall or the per-file average ratio. Sticky, with hysteresis.
    @ObservationIgnored private var showsOverallAverage = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// `JobStatusRevision` at the last re-sort, so a status sort is only redone when a job moved.
    @ObservationIgnored private var sortedAtStatusRevision: UInt64 = 0
    /// Incremented on every change to `jobs`; see the property's `didSet`.
    @ObservationIgnored private var jobsRevision: UInt64 = 0
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    /// `jobsRevision` at the last reconciliation, so a repeated status sort doesn't redo it.
    @ObservationIgnored private var reconciledAtRevision: UInt64 = .max
    @ObservationIgnored private var pasteboardChangeCount = -1

    var isBusy: Bool { queue.isBusy }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        db = ResultsDB()
        queue = JobQueue(cpus: defaults.integer(forKey: PrefKey.runConcurrentFiles),
                         dirs: defaults.integer(forKey: PrefKey.runConcurrentDirscans),
                         files: defaults.integer(forKey: PrefKey.runConcurrentFileops),
                         defaults: defaults)
        statusText = Launch.quitWhenDone
            ? String(localized: "ImageOptim will quit when optimizations are complete", comment: "status bar")
            : String(localized: "Drag and drop image files onto the area above", comment: "status bar")

        queue.onIdle = { [weak self] in
            self?.queueFinished()
        }
        statusTask = Task { [weak self] in
            await self?.runStatusUpdates()
        }
    }

    // MARK: - Adding files

    func addPaths(_ paths: [String]) async {
        await addURLs(paths.map { URL(fileURLWithPath: $0) })
    }

    func addURLsBelowSelection(_ urls: [URL]) async {
        nextInsertRow = jobs.firstIndex { selection.contains($0.id) } ?? -1
        await addURLs(urls)
    }

    @discardableResult
    func addURLs(_ urls: [URL]) async -> Bool {
        guard isEnabled, !urls.isEmpty else { return false }
        let resolved = await offMainActor(priority: .userInitiated) { resolve(urls) }
        return add(resolved)
    }

    /// For URLs that are known to be plain files (that's all a directory scan produces),
    /// which lets this skip the file system checks and stay synchronous.
    func addFiles(_ urls: [URL]) {
        guard isEnabled, !urls.isEmpty else { return }
        _ = add(urls.map { ResolvedURL(url: $0, isDirectory: false, exists: true) })
    }

    @discardableResult
    private func add(_ items: [ResolvedURL]) -> Bool {
        var toAdd: [Job] = []
        var allOK = true

        for item in items {
            guard item.exists else {
                IOWarn("\(item.url.path) doesn't exist")
                allOK = false
                continue
            }

            if item.isDirectory {
                queue.addDirectoryScan(url: item.url, extensions: extensions) { [weak self] found in
                    self?.addFiles(found)
                }
                continue
            }

            if let existing = jobsByPath[item.url.path] {
                if !existing.isBusy {
                    queue.add(existing)
                }
            } else {
                let job = Job(filePath: item.url, resultsDatabase: db)
                jobsByPath[item.url.path] = job
                jobsByID[job.id] = job
                toAdd.append(job)
                queue.add(job)
            }
        }

        insert(toAdd)
        return allOK
    }

    /// Publishing a batch of rows costs `Table` a walk of *every* row it already has:
    /// `AppKitOutlineTableCoordinator` re-diffs the whole outline and AttributeGraph
    /// re-evaluates the `ForEach`. A directory scan delivers hundreds of batches, so doing
    /// that per batch is quadratic in the number of files — on a folder of a quarter of a
    /// million images it pinned the main thread at 100% and the window stopped drawing.
    ///
    /// Batches are therefore accumulated and published a few times a second. The jobs have
    /// already been handed to the queue by `add(_:)`, so nothing waits on this: only the
    /// moment the rows appear in the table is delayed.
    private func insert(_ newJobs: [Job]) {
        guard !newJobs.isEmpty else { return }

        // Drag&drop between rows: a batch aimed at a different row can't be merged with
        // what is already waiting, so publish that first.
        if !pendingRows.isEmpty, pendingInsertRow != nextInsertRow {
            flushPendingRows()
        }
        if pendingRows.isEmpty {
            pendingInsertRow = nextInsertRow
        }
        pendingRows.append(contentsOf: newJobs)

        // A small list re-diffs in no time, and dropping a handful of files has to feel
        // instant, so coalescing only kicks in once the table is big enough to be worth it.
        if jobs.count + pendingRows.count <= Self.immediateInsertLimit {
            flushPendingRows()
        } else {
            scheduleRowFlush()
        }
    }

    /// Rows added but not yet published to `jobs`, and the row they go in front of.
    @ObservationIgnored private var pendingRows: [Job] = []
    @ObservationIgnored private var pendingInsertRow = -1
    @ObservationIgnored private var rowFlushTask: Task<Void, Never>?

    private static let immediateInsertLimit = 1000
    private static let rowFlushInterval = Duration.milliseconds(250)

    private func scheduleRowFlush() {
        guard rowFlushTask == nil else { return }
        rowFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rowFlushInterval)
            guard let self, !Task.isCancelled else { return }
            rowFlushTask = nil
            flushPendingRows()
        }
    }

    /// Moves everything accumulated by `insert(_:)` into `jobs` in one go.
    func flushPendingRows() {
        rowFlushTask?.cancel()
        rowFlushTask = nil
        guard !pendingRows.isEmpty else { return }

        let newJobs = pendingRows
        pendingRows.removeAll(keepingCapacity: true)

        if pendingInsertRow < 0 || pendingInsertRow >= jobs.count {
            jobs.append(contentsOf: newJobs)
        } else {
            jobs.insert(contentsOf: newJobs, at: pendingInsertRow)
            if nextInsertRow >= 0 {
                nextInsertRow += newJobs.count
            }
        }
        pendingInsertRow = nextInsertRow

        if !hasJobs {
            hasJobs = true
        }
        resort(force: true)
        setNeedsStatusUpdate()
    }

    func setInsertRow(_ row: Int) {
        nextInsertRow = row
    }

    // MARK: - Removing

    func remove(ids: Set<Job.ID>) {
        guard !ids.isEmpty else { return }
        flushPendingRows()
        let removed = jobs.filter { ids.contains($0.id) }
        jobs.removeAll { ids.contains($0.id) }
        for job in removed {
            jobsByPath.removeValue(forKey: job.filePath.path)
            jobsByID.removeValue(forKey: job.id)
            job.cleanup()
        }
        if hasJobs != !jobs.isEmpty {
            hasJobs = !jobs.isEmpty
        }
        selection.subtract(ids)
        nextInsertRow = -1
        resort(force: true)
        setNeedsStatusUpdate()
    }

    /// The commands below act on `jobs`, so anything still waiting to be published has to
    /// land first — otherwise "Select All" or "Again" would quietly skip the newest rows.
    func selectAll() {
        flushPendingRows()
        selection = Set(jobs.map(\.id))
    }

    func clearComplete() {
        flushPendingRows()
        remove(ids: Set(jobs.filter(\.isDone).map(\.id)))
    }

    // MARK: - Running

    /// The jobs the menu commands act on: the selection, or everything when nothing is selected.
    private var actionTargets: [Job] {
        let selected = selectedJobs
        return selected.isEmpty ? jobs : selected
    }

    /// The selection in the order it is displayed in — for copying, revealing and reverting.
    /// Only ever called from a user action, never from the status pass.
    var selectedJobs: [Job] {
        guard !selection.isEmpty else { return [] }
        return sortedJobs.filter { selection.contains($0.id) }
    }

    /// The selection in no particular order, which is all the enablement checks need,
    /// and costs `selection.count` lookups instead of a scan of every job.
    private var selectedJobsUnordered: [Job] {
        selection.compactMap { jobsByID[$0] }
    }

    func startAgain(onlyOptimized: Bool) {
        flushPendingRows()
        let targets = actionTargets

        // The UI doesn't give a way to deselect all, so here's a substitute:
        // clicking "again" on a file that doesn't need it deselects instead.
        if selection.count == 1, let job = targets.first, job.isBusy || !job.isOptimized {
            selection.removeAll()
        }

        var anyStarted = false
        for job in targets where !job.isBusy && (!onlyOptimized || job.isOptimized) {
            queue.add(job)
            anyStarted = true
        }

        if !anyStarted {
            NSSound.beep()
        }
        setNeedsStatusUpdate()
    }

    func stopSelected() {
        for job in selectedJobsUnordered {
            _ = job.stop()
        }
        updateSelectionState()
    }

    func revertSelected() async {
        var beep = false
        for job in selectedJobs {
            if await !job.revert() {
                beep = true
            }
        }
        if beep {
            NSSound.beep()
        }
        setNeedsStatusUpdate()
    }

    func cleanup() {
        isEnabled = false
        statusTask?.cancel()
        sortTask?.cancel()
        sortTask = nil
        rowFlushTask?.cancel()
        rowFlushTask = nil
        queue.cleanup()
        for job in pendingRows {
            job.cleanup()
        }
        pendingRows.removeAll()
        for job in jobs {
            job.cleanup()
        }
    }

    private func queueFinished() {
        // Nothing is going to be added any more, so the last partial batch must not sit
        // in the buffer waiting for a timer that has nothing left to coalesce.
        flushPendingRows()
        setNeedsStatusUpdate()
        guard !queue.isBusy else { return }
        if Launch.quitWhenDone {
            NSApp.terminate(nil)
        } else if defaults.bool(forKey: PrefKey.bounceDock) {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: - Sorting

    private var sortsByStatus: Bool {
        sortOrder.contains { $0.field == .status }
    }

    /// Above this many rows the sort moves off the main actor. Below it the hop costs more than
    /// the sort does: a few hundred comparisons are microseconds, and running them inline keeps
    /// a click on a column header instant instead of landing a frame later.
    private static let asyncSortThreshold = 2000

    /// Recomputes the row order. With no sort selected this is just `jobs`, so the common
    /// case costs nothing; the result is only assigned when the order actually changed,
    /// which keeps the array's identity stable and the table from re-diffing every row.
    ///
    /// A long list is sorted off the main actor. `n·log n` comparisons, each of them a read of a
    /// job's status or file name, is not work to do between two frames — and on a status sort it
    /// is work that repeats for as long as the queue is running.
    private func resort(force: Bool = false) {
        sortTask?.cancel()
        sortedAtStatusRevision = JobStatusRevision.current

        guard !sortOrder.isEmpty else {
            setSortedJobs(jobs, force: force)
            return
        }
        guard jobs.count > Self.asyncSortThreshold else {
            setSortedJobs(jobs.sorted(using: sortOrder), force: force)
            return
        }

        // The order is a frame or two behind now, so the contents are brought in line straight
        // away: the table and the selection care about *which* rows exist much more than where.
        reconcileSortedJobs()

        let keys = jobs.map { JobSortKey(statusOrder: $0.statusOrder, fileName: $0.fileName) }
        let comparators = sortOrder
        let revision = jobsRevision
        sortTask = Task { [weak self] in
            let permutation = await offMainActor(priority: .userInitiated) {
                sortedIndices(of: keys, using: comparators)
            }
            guard let self, !Task.isCancelled, jobsRevision == revision else { return }
            setSortedJobs(permutation.map { jobs[$0] }, force: force)
        }
    }

    private func setSortedJobs(_ ordered: [Job], force: Bool) {
        reconciledAtRevision = jobsRevision
        if force || !ordered.elementsEqual(sortedJobs, by: ===) {
            sortedJobs = ordered
        }
    }

    /// Makes `sortedJobs` hold exactly the jobs `jobs` holds, without sorting: rows that were
    /// removed go (they have been cleaned up and must not stay on screen), rows that were added
    /// land at the end until the background sort says where they belong.
    private func reconcileSortedJobs() {
        guard reconciledAtRevision != jobsRevision else { return }
        reconciledAtRevision = jobsRevision

        let live = Set(jobs.map(ObjectIdentifier.init))
        var kept = sortedJobs.filter { live.contains(ObjectIdentifier($0)) }
        if kept.count != jobs.count {
            let present = Set(kept.map(ObjectIdentifier.init))
            kept.append(contentsOf: jobs.filter { !present.contains(ObjectIdentifier($0)) })
        }
        setSortedJobs(kept, force: false)
    }

    /// Jobs move between status groups as they run, so a status sort has to be redone —
    /// but only from the throttled pass, and only when a job really did change status.
    private func resortIfStatusChanged() {
        guard sortsByStatus, JobStatusRevision.current != sortedAtStatusRevision else { return }
        resort()
    }

    // MARK: - Supported file types

    private struct EnabledTypes: OptionSet {
        let rawValue: Int
        static let png = EnabledTypes(rawValue: 1)
        static let jpeg = EnabledTypes(rawValue: 2)
        static let gif = EnabledTypes(rawValue: 4)
        static let svg = EnabledTypes(rawValue: 8)
    }

    private var typesEnabled: EnabledTypes {
        var types: EnabledTypes = []

        if defaults.bool(forKey: PrefKey.pngCrushEnabled) || defaults.bool(forKey: PrefKey.oxiPngEnabled)
            || defaults.bool(forKey: PrefKey.advPngEnabled) || defaults.bool(forKey: PrefKey.zopfliEnabled) {
            types.insert(.png)
        }
        if defaults.bool(forKey: PrefKey.jpegOptimEnabled) || defaults.bool(forKey: PrefKey.jpegTranEnabled) {
            types.insert(.jpeg)
        }
        if defaults.bool(forKey: PrefKey.gifsicleEnabled) {
            types.insert(.gif)
        }
        if defaults.bool(forKey: PrefKey.svgoEnabled) || defaults.bool(forKey: PrefKey.svgCleanerEnabled) {
            types.insert(.svg)
        }

        return types.isEmpty ? .png : types // will show an error in the list
    }

    /// Lowercased extensions a directory scan looks for.
    var extensions: Set<String> {
        let types = typesEnabled
        var extensions: Set<String> = []
        if types.contains(.png) { extensions.insert("png") }
        if types.contains(.jpeg) { extensions.formUnion(["jpg", "jpeg"]) }
        if types.contains(.gif) { extensions.insert("gif") }
        if types.contains(.svg) { extensions.insert("svg") }
        return extensions
    }

    var contentTypes: [UTType] {
        let types = typesEnabled
        var contentTypes: [UTType] = []
        if types.contains(.png) { contentTypes.append(.png) }
        if types.contains(.jpeg) { contentTypes.append(.jpeg) }
        if types.contains(.gif) { contentTypes.append(.gif) }
        if types.contains(.svg) { contentTypes.append(.svg) }
        return contentTypes
    }

    // MARK: - Status bar

    func setNeedsStatusUpdate() {
        statusNeedsUpdate = true
    }

    @ObservationIgnored private var statusNeedsUpdate = true

    /// The Objective-C version coalesced status updates onto a dispatch source that slept
    /// 1/10th of a second after every run. This does the same, and idles at 2 Hz — but the
    /// pass walks every job, so with a big queue it backs off to keep the main actor free.
    private func runStatusUpdates() async {
        while !Task.isCancelled {
            if statusNeedsUpdate || queue.isBusy {
                statusNeedsUpdate = false
                await updateStatus()
                resortIfStatusChanged()
                updateSelectionState()
            }
            try? await Task.sleep(for: .milliseconds(tickInterval))
        }
    }

    /// 100 ms while busy, stretched towards a second as the list grows: at ten thousand files
    /// a single pass is ten thousand property reads, and doing that ten times a second leaves
    /// nothing for the UI.
    private var tickInterval: Int {
        guard queue.isBusy else { return 500 }
        return min(1000, max(100, jobs.count / 10))
    }

    /// How many jobs the status pass walks before letting the main actor breathe.
    /// The whole walk is a handful of property reads per job, so the chunk can be large;
    /// what it must not be is unbounded, or a ten-thousand-file list drops frames on every tick.
    private static let statusChunkSize = 2000

    private func updateStatus() async {
        var text = Launch.quitWhenDone
            ? String(localized: "ImageOptim will quit when optimizations are complete", comment: "status bar")
            : String(localized: "Drag and drop image files onto the area above", comment: "status bar")
        var selectable = false

        var bytesTotal = 0
        var optimizedTotal = 0
        var optimizedFractionTotal = 0.0
        var maxOptimizedFraction = 0.0
        var optimizedFileCount = 0
        var anyBusyFiles = false
        // folded into the same pass rather than costing a walk of the job list each:
        // these back the "Optimize Again" / "Delete Completed" menu items
        var anyDone = false
        var anyRestartable = false
        var anyOptimizedRestartable = false
        let restartTargetsAreSelection = !selection.isEmpty

        // A snapshot, because the walk below suspends: rows can be inserted while it runs, and
        // this pass is throttled anyway — whatever it misses the next tick picks up.
        let snapshot = jobs
        for (index, job) in snapshot.enumerated() {
            if index > 0, index.isMultiple(of: Self.statusChunkSize) {
                await Task.yield()
                if Task.isCancelled { return }
            }
            if !anyBusyFiles, job.isBusy {
                anyBusyFiles = true
            }
            if !anyDone, job.isDone {
                anyDone = true
            }
            if !anyRestartable || !anyOptimizedRestartable,
               !job.isBusy, !restartTargetsAreSelection || selection.contains(job.id) {
                anyRestartable = true
                if job.isOptimized {
                    anyOptimizedRestartable = true
                }
            }
            guard let bytes = job.byteSizeOriginal, let optimized = job.byteSizeOptimized,
                  bytes > 0, optimized > 0, bytes != optimized || job.isDone else {
                continue
            }
            let optimizedFraction = 1.0 - Double(optimized) / Double(bytes)
            maxOptimizedFraction = max(maxOptimizedFraction, optimizedFraction)
            optimizedFractionTotal += optimizedFraction
            bytesTotal += bytes
            optimizedTotal += optimized
            optimizedFileCount += 1
        }

        if optimizedFileCount > 1, bytesTotal > 0 {
            let savedTotal = 1.0 - Double(optimizedTotal) / Double(bytesTotal)
            let savedAvg = optimizedFractionTotal / Double(optimizedFileCount)
            if savedTotal > 0.001 {
                if savedTotal * 0.8 > savedAvg {
                    showsOverallAverage = true
                } else if savedAvg * 0.8 > savedTotal {
                    showsOverallAverage = false
                }

                let saved = Self.sizeFormatter.string(fromByteCount: Int64(bytesTotal - optimizedTotal))
                let total = Self.sizeFormatter.string(fromByteCount: Int64(bytesTotal))
                let avg = Self.percentFormatter.string(from: showsOverallAverage ? savedTotal as NSNumber : savedAvg as NSNumber) ?? ""
                let best = Self.percentFormatter.string(from: maxOptimizedFraction as NSNumber) ?? ""

                text = showsOverallAverage
                    ? String(localized: "Saved \(saved) out of \(total). \(avg) overall (up to \(best) per file)", comment: "total ratio, status bar")
                    : String(localized: "Saved \(saved) out of \(total). \(avg) per file on average (up to \(best))", comment: "per file avg, status bar")
                selectable = true
            }
        } else if defaults.bool(forKey: PrefKey.guetzliEnabled) {
            text = "Warning: Guetzli tool enabled. Optimizations may take a very long time."
        } else if defaults.bool(forKey: PrefKey.lossyEnabled) {
            var enabled: [String] = []
            appendQuality("JPEG", key: PrefKey.jpegOptimMaxQuality, to: &enabled)
            appendQuality("PNG", key: PrefKey.pngMinQuality, to: &enabled)
            appendQuality("GIF", key: PrefKey.gifQuality, to: &enabled)
            if !enabled.isEmpty {
                let title = String(localized: "Lossy minification enabled", comment: "status bar")
                text = "\(title) (\(enabled.joined(separator: ", ")))"
            }
        } else if anyBusyFiles {
            text = ""
        }

        // Guard every write: assigning an identical value is a full invalidation in SwiftUI,
        // and this runs several times a second.
        if statusText != text {
            statusText = text
        }
        if statusTextSelectable != selectable {
            statusTextSelectable = selectable
        }
        if canClearComplete != anyDone {
            canClearComplete = anyDone
        }
        if canStartAgainAny != anyRestartable {
            canStartAgainAny = anyRestartable
        }
        if canStartAgainOptimized != anyOptimizedRestartable {
            canStartAgainOptimized = anyOptimizedRestartable
        }
        updatePasteState()
    }

    /// `NSPasteboard.canReadObject` is an IPC round trip to the pasteboard server. It used to
    /// happen inside the menu's `body`, i.e. on every rebuild; `changeCount` is the cheap check.
    private func updatePasteState() {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = changeCount
        let canRead = NSPasteboard.general.canReadObject(forClasses: [NSURL.self])
        if canPaste != canRead {
            canPaste = canRead
        }
    }

    private func appendQuality(_ name: String, key: String, to list: inout [String]) {
        let quality = defaults.integer(forKey: key)
        if quality > 0, quality < 100 {
            list.append("\(name) \(quality)%")
        }
    }

    /// Everything the menus derive from the selection, in one pass over the selected jobs
    /// (not over every job, and without sorting). Called on selection changes and from the tick.
    func updateSelectionState() {
        let busy = queue.isBusy

        var stoppable = false
        var revertable = false
        var dataURLBytes = 0
        var dataURLPossible = false
        var selectionExists = false

        // Walks the id set rather than `selectedJobsUnordered`, which allocated an array of every
        // selected job — on every tick, and Select All on a big folder makes that the whole list.
        // Nothing here needs an order, and all four answers are booleans, so it stops as soon as
        // they are all settled.
        for id in selection {
            guard let job = jobsByID[id] else { continue }
            selectionExists = true

            if busy, !stoppable, job.isStoppable {
                stoppable = true
            }
            if !revertable, job.canRevert {
                revertable = true
            }
            if !dataURLPossible, job.isDone,
               let file = job.savedOutputOrInput, file.byteSize <= 100_000 {
                dataURLBytes += file.byteSize
                if dataURLBytes <= 1_000_000 {
                    dataURLPossible = true
                }
            }

            // `stoppable` can only ever become true while the queue is running.
            if revertable, dataURLPossible, stoppable || !busy { break }
        }

        if hasSelection != selectionExists { hasSelection = selectionExists }
        if isStoppable != stoppable { isStoppable = stoppable }
        if canRevert != revertable { canRevert = revertable }
        if canCopyAsDataURL != dataURLPossible { canCopyAsDataURL = dataURLPossible }
    }

    private static let sizeFormatter = ByteCountFormatter()
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.numberStyle = .percent
        return formatter
    }()
}

/// Runs off the main actor — `fileExists` and symlink resolution hit the disk.
private func resolve(_ urls: [URL]) -> [ResolvedURL] {
    let fileManager = FileManager.default
    return urls.map { url in
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
        return ResolvedURL(url: resolved, isDirectory: isDirectory.boolValue, exists: exists)
    }
}
