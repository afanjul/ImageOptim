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
    enum Field: Sendable {
        case status
        case fileName
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: Job, _ rhs: Job) -> ComparisonResult {
        let result = MainActor.assumeIsolated { () -> ComparisonResult in
            switch field {
            case .status:
                return NSNumber(value: lhs.statusOrder).compare(NSNumber(value: rhs.statusOrder))
            case .fileName:
                return lhs.fileName.caseInsensitiveCompare(rhs.fileName)
            }
        }
        switch order {
        case .forward: return result
        case .reverse: return result == .orderedAscending ? .orderedDescending
            : result == .orderedDescending ? .orderedAscending : .orderedSame
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var jobs: [Job] = []
    var selection: Set<Job.ID> = []
    var sortOrder: [JobComparator] = []
    /// Lives here rather than in the view so that the "Show Columns" menu can toggle it too.
    var columnCustomization = TableColumnCustomization<Job>()

    /// Status bar text, throttled to avoid spending all the CPU on redrawing a label.
    private(set) var statusText: String
    private(set) var statusTextSelectable = false
    private(set) var isStoppable = false

    @ObservationIgnored let queue: JobQueue
    @ObservationIgnored private let db: ResultsDB?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var jobsByPath: [String: Job] = [:]
    @ObservationIgnored private var isEnabled = true
    /// Insertion point for the next batch of files (drag&drop between rows). -1 means "append".
    @ObservationIgnored private var nextInsertRow = -1
    /// Whether the status bar shows the overall or the per-file average ratio. Sticky, with hysteresis.
    @ObservationIgnored private var showsOverallAverage = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?

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
        let resolved = await Task.detached(priority: .userInitiated) { resolve(urls) }.value
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
                toAdd.append(job)
                queue.add(job)
            }
        }

        insert(toAdd)
        return allOK
    }

    private func insert(_ newJobs: [Job]) {
        guard !newJobs.isEmpty else { return }
        if nextInsertRow < 0 || nextInsertRow >= jobs.count {
            jobs.append(contentsOf: newJobs)
        } else {
            jobs.insert(contentsOf: newJobs, at: nextInsertRow)
            nextInsertRow += newJobs.count
        }
        setNeedsStatusUpdate()
    }

    func setInsertRow(_ row: Int) {
        nextInsertRow = row
    }

    // MARK: - Removing

    func remove(ids: Set<Job.ID>) {
        guard !ids.isEmpty else { return }
        let removed = jobs.filter { ids.contains($0.id) }
        jobs.removeAll { ids.contains($0.id) }
        for job in removed {
            jobsByPath.removeValue(forKey: job.filePath.path)
            job.cleanup()
        }
        selection.subtract(ids)
        nextInsertRow = -1
        setNeedsStatusUpdate()
    }

    func selectAll() {
        selection = Set(jobs.map(\.id))
        updateStoppableState()
    }

    var canClearComplete: Bool {
        jobs.contains { $0.isDone }
    }

    func clearComplete() {
        remove(ids: Set(jobs.filter(\.isDone).map(\.id)))
    }

    // MARK: - Running

    /// The jobs the menu commands act on: the selection, or everything when nothing is selected.
    private var actionTargets: [Job] {
        let selected = selectedJobs
        return selected.isEmpty ? jobs : selected
    }

    var selectedJobs: [Job] {
        sortedJobs.filter { selection.contains($0.id) }
    }

    func canStartAgain(onlyOptimized: Bool) -> Bool {
        actionTargets.contains { !$0.isBusy && (!onlyOptimized || $0.isOptimized) }
    }

    func startAgain(onlyOptimized: Bool) {
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
        for job in selectedJobs {
            _ = job.stop()
        }
        updateStoppableState()
    }

    var canRevert: Bool {
        selectedJobs.contains(where: \.canRevert)
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
        queue.cleanup()
        for job in jobs {
            job.cleanup()
        }
    }

    private func queueFinished() {
        setNeedsStatusUpdate()
        guard !queue.isBusy else { return }
        if Launch.quitWhenDone {
            NSApp.terminate(nil)
        } else if defaults.bool(forKey: PrefKey.bounceDock) {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: - Sorting

    var sortedJobs: [Job] {
        sortOrder.isEmpty ? jobs : jobs.sorted(using: sortOrder)
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

        if defaults.bool(forKey: PrefKey.pngCrushEnabled) || defaults.bool(forKey: PrefKey.pngOutEnabled)
            || defaults.bool(forKey: PrefKey.oxiPngEnabled) || defaults.bool(forKey: PrefKey.advPngEnabled)
            || defaults.bool(forKey: PrefKey.zopfliEnabled) {
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
    /// 1/10th of a second after every run. This does the same, and idles at 2 Hz.
    private func runStatusUpdates() async {
        while !Task.isCancelled {
            if statusNeedsUpdate || queue.isBusy {
                statusNeedsUpdate = false
                updateStatus()
            }
            try? await Task.sleep(for: .milliseconds(queue.isBusy ? 100 : 500))
        }
    }

    private func updateStatus() {
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

        for job in jobs {
            if !anyBusyFiles, job.isBusy {
                anyBusyFiles = true
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

        statusText = text
        statusTextSelectable = selectable
        updateStoppableState()
    }

    private func appendQuality(_ name: String, key: String, to list: inout [String]) {
        let quality = defaults.integer(forKey: key)
        if quality > 0, quality < 100 {
            list.append("\(name) \(quality)%")
        }
    }

    func updateStoppableState() {
        isStoppable = queue.isBusy && selectedJobs.contains(where: \.isStoppable)
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
