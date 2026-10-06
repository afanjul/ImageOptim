//
//  Job.swift
//  ImageOptim
//

import CryptoKit
import Foundation
import Observation

private struct ToolStats {
    let fileSize: Int
    let ratio: Double
}

/// A counter bumped whenever any job's `statusOrder` actually changes.
///
/// Sorting the table by status has to happen again when the jobs move between status
/// groups, but walking every job to find out whether anything moved is itself O(n) at
/// the tick rate. This makes the check O(1): the model only re-sorts when the number
/// differs from the one it sorted at.
@MainActor
public enum JobStatusRevision {
    public private(set) static var current: UInt64 = 0

    static func bump() {
        current &+= 1
    }
}

public struct ToolTiming: Sendable, Identifiable, Hashable, Equatable, Codable {
    public var id: String { toolName }
    public let toolName: String
    public let durationSeconds: Double
    public let inputBytes: Int
    public let outputBytes: Int?
    public let didImprove: Bool
    public let error: String?

    public init(toolName: String, durationSeconds: Double, inputBytes: Int, outputBytes: Int?, didImprove: Bool, error: String? = nil) {
        self.toolName = toolName
        self.durationSeconds = durationSeconds
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.didImprove = didImprove
        self.error = error
    }

    public var savedBytes: Int {
        guard let outputBytes, didImprove else { return 0 }
        return max(0, inputBytes - outputBytes)
    }

    public var formatName: String {
        switch toolName.lowercased() {
        case "oxipng", "zopfli", "zopflipng", "advpng", "pngcrush", "pngquant":
            return "PNG"
        case "mozjpeg", "jpegoptim", "jpegtran", "guetzli", "jpegli", "cjpegli":
            return "JPEG"
        case "cwebp", "webp":
            return "WebP"
        case "avifoptim", "avifenc", "avif":
            return "AVIF"
        case "jxloptim", "cjxl", "jxl":
            return "JXL"
        case "heictojpeg", "heic":
            return "HEIC"
        case "gifsicle", "gif":
            return "GIF"
        case "svgo", "svgcleaner", "svg":
            return "SVG"
        default:
            return "IMG"
        }
    }

    public var formattedDuration: String {
        if durationSeconds < 0.001 {
            return "< 1 ms"
        } else if durationSeconds < 1.0 {
            return String(format: "%.0f ms", durationSeconds * 1000)
        } else if durationSeconds < 10.0 {
            return String(format: "%.2f s", durationSeconds)
        } else {
            return String(format: "%.1f s", durationSeconds)
        }
    }
}

public struct EngineBenchmark: Sendable, Identifiable, Hashable, Equatable, Codable {
    public var id: String { engineName }
    public let engineName: String
    public var runsCount: Int
    public var totalDurationSeconds: Double
    public var lastDurationSeconds: Double?
    public var totalSavedBytes: Int
    public var lastSavedBytes: Int?

    public init(engineName: String, runsCount: Int = 0, totalDurationSeconds: Double = 0, lastDurationSeconds: Double? = nil, totalSavedBytes: Int = 0, lastSavedBytes: Int? = nil) {
        self.engineName = engineName
        self.runsCount = runsCount
        self.totalDurationSeconds = totalDurationSeconds
        self.lastDurationSeconds = lastDurationSeconds
        self.totalSavedBytes = totalSavedBytes
        self.lastSavedBytes = lastSavedBytes
    }

    public var formatName: String {
        switch engineName.lowercased() {
        case "oxipng", "zopfli", "zopflipng", "advpng", "pngcrush", "pngquant":
            return "PNG"
        case "mozjpeg", "jpegoptim", "jpegtran", "guetzli", "jpegli", "cjpegli":
            return "JPEG"
        case "cwebp", "webp":
            return "WebP"
        case "avifoptim", "avifenc", "avif":
            return "AVIF"
        case "jxloptim", "cjxl", "jxl":
            return "JXL"
        case "heictojpeg", "heic":
            return "HEIC"
        case "gifsicle", "gif":
            return "GIF"
        case "svgo", "svgcleaner", "svg":
            return "SVG"
        default:
            return "IMG"
        }
    }

    public var averageDurationSeconds: Double {
        runsCount > 0 ? totalDurationSeconds / Double(runsCount) : 0
    }

    public var formattedAverageDuration: String {
        guard runsCount > 0 else { return "—" }
        return formatDuration(averageDurationSeconds)
    }

    public var formattedLastDuration: String {
        guard let last = lastDurationSeconds else { return "—" }
        return formatDuration(last)
    }

    public var speedCategory: String {
        guard runsCount > 0 else { return "Untested" }
        if averageDurationSeconds < 0.08 {
            return "⚡ Ultra-Fast"
        } else if averageDurationSeconds < 0.6 {
            return "🚀 Fast"
        } else if averageDurationSeconds < 2.0 {
            return "⏳ Moderate"
        } else {
            return "🐢 Exhaustive"
        }
    }

    private func formatDuration(_ sec: Double) -> String {
        if sec < 0.001 {
            return "< 1 ms"
        } else if sec < 1.0 {
            return String(format: "%.0f ms", sec * 1000)
        } else if sec < 10.0 {
            return String(format: "%.2f s", sec)
        } else {
            return String(format: "%.1f s", sec)
        }
    }
}

@MainActor
@Observable
public final class BenchmarkTracker {
    public static let shared = BenchmarkTracker()

    public private(set) var stats: [String: EngineBenchmark] = [:]

    private let userDefaultsKey = "ImageOptimEngineBenchmarks_v1"

    public init() {
        loadPersisted()
    }

    public var allBenchmarksSorted: [EngineBenchmark] {
        stats.values.sorted {
            if $0.runsCount != $1.runsCount {
                return $0.runsCount > $1.runsCount
            }
            return $0.averageDurationSeconds < $1.averageDurationSeconds
        }
    }

    public func record(toolName: String, duration: Double, savedBytes: Int) {
        var stat = stats[toolName] ?? EngineBenchmark(engineName: toolName)
        stat.runsCount += 1
        stat.totalDurationSeconds += duration
        stat.lastDurationSeconds = duration
        stat.totalSavedBytes += savedBytes
        stat.lastSavedBytes = savedBytes
        stats[toolName] = stat
        savePersisted()
    }

    public func reset() {
        stats.removeAll()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    private func savePersisted() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadPersisted() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loaded = try? JSONDecoder().decode([String: EngineBenchmark].self, from: data) {
            stats = loaded
        }
    }
}

/// The values a table row shows, as one comparable snapshot.
///
/// Being `Equatable` is the point: the status is rewritten every time a tool starts or stops,
/// usually to what it already said, and a snapshot that compares equal never reaches SwiftUI.
public struct JobDisplay: Equatable, Sendable {
    public var statusImageName: String = "wait"
    public var statusText: String = ""
    public var byteSizeOriginal: Int?
    public var byteSizeOptimized: Int?
    public var percentOptimized: Double?
    public var bestToolName: String?
    public var toolTimings: [ToolTiming] = []
    public var totalDurationSeconds: Double?
}

/// One file being optimized, and everything the UI displays about it.
///
/// The whole class lives on the main actor — that's what makes the old `JobProxy`
/// KVO-forwarding shim unnecessary. Everything expensive (reading, hashing, running
/// tools, saving) happens in `nonisolated` code that hops off the main actor.
@MainActor
@Observable
public final class Job: Identifiable {
    public nonisolated let id = UUID()

    public private(set) var filePath: URL

    /// The name the Finder would show — localized, and with the extension hidden when the
    /// user asked for that. Resolving it is a LaunchServices lookup (a database hit, a
    /// sandbox check and a `getattrlist` per file), so it is computed on demand rather than
    /// in `init`: only the Quick Look panel title needs it, while `init` runs once per file
    /// on the main actor. On a folder of a quarter of a million images, doing it eagerly cost
    /// ~14% of the main thread before a single byte had been optimized.
    public var displayName: String {
        FileManager.default.displayName(atPath: filePathString)
    }

    /// `URL.path` goes through CFURL and allocates, and the path never changes; the row tooltip
    /// would otherwise re-derive it for every visible row on every scroll frame.
    @ObservationIgnored public let filePathString: String
    /// Likewise: the filename shown in the table is fixed for the lifetime of the job.
    @ObservationIgnored public let fileName: String

    /// Everything the table draws for one row, in a single observed value.
    ///
    /// SwiftUI installs an observation tracking when it builds a cell view and cancels it when
    /// the row is recycled, and the cost of both is proportional to how many properties the cell
    /// read. The size and savings columns are computed from four or five stored properties each,
    /// so a row used to register about fourteen key paths — and scrolling a few thousand rows
    /// spent most of the main thread inside `ObservationRegistrar.Context.registerTracking`
    /// and `.cancel`. One Equatable snapshot means one key path per cell instead.
    public private(set) var display = JobDisplay()

    // The individual pieces of state are not observed: `display` is what the UI watches, and
    // everything else here is read from AppModel's own bookkeeping pass, never from a view body.
    @ObservationIgnored public private(set) var statusImageName = "wait"
    @ObservationIgnored public private(set) var statusOrder = 0
    @ObservationIgnored public private(set) var statusText = ""
    @ObservationIgnored public private(set) var bestToolName: String?
    @ObservationIgnored public private(set) var isDone = false
    @ObservationIgnored public private(set) var isFailed = false

    @ObservationIgnored public private(set) var initialInput: ImageFile?
    @ObservationIgnored public private(set) var unoptimizedInput: ImageFile?
    @ObservationIgnored public private(set) var wipInput: ImageFile?
    @ObservationIgnored public private(set) var savedOutput: ImageFile?
    @ObservationIgnored public private(set) var revertFile: ImageFile?

    // Bookkeeping that no view reads. Without `@ObservationIgnored` every append to
    // `runningWorkerNames` and every entry in `workersPreviousResults` would go through
    // the observation registrar — pure overhead multiplied by files × tools.
    @ObservationIgnored public private(set) var toolTimings: [ToolTiming] = []
    @ObservationIgnored private var bestTools: [String: ToolStats] = [:]
    /// worker name -> settings identifier -> input size it has already seen
    @ObservationIgnored private var workersPreviousResults: [String: [Int: Int]] = [:]
    @ObservationIgnored private var runningWorkerNames: [String] = []

    @ObservationIgnored private var lossyConverted = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var workersTask: Task<Void, Never>?

    @ObservationIgnored private var settingsDigest = Data()
    @ObservationIgnored private var inputFileHash: ResultHash?
    @ObservationIgnored private var preservePermissions = true
    @ObservationIgnored private var preserveDates = false

    @ObservationIgnored private let db: ResultsDB?

    public init(filePath: URL, resultsDatabase: ResultsDB?) {
        let path = filePath.path
        self.filePath = filePath
        filePathString = path
        db = resultsDatabase
        // Deliberately not `FileManager.displayName(atPath:)` — see `displayName`.
        fileName = filePath.lastPathComponent
        setStatus("wait", order: 0, text: IOLocalized("Waiting to be optimized", comment: "tooltip"))
    }

    // MARK: - What the table draws

    public var timingsSummaryText: String {
        guard !display.toolTimings.isEmpty else { return display.statusText }
        var parts: [String] = []
        if let total = display.totalDurationSeconds {
            let totalStr = total < 1.0 ? String(format: "%.0f ms", total * 1000) : String(format: "%.2f s", total)
            parts.append("⏱️ Total: \(totalStr)")
        }
        for t in display.toolTimings {
            let change: String
            if t.didImprove, let out = t.outputBytes {
                let saved = t.inputBytes - out
                let pct = t.inputBytes > 0 ? (Double(saved) / Double(t.inputBytes)) * 100.0 : 0.0
                change = String(format: "saved %.1f%%", pct)
            } else if t.error != nil {
                change = "failed"
            } else {
                change = "0%"
            }
            parts.append("• \(t.toolName) [\(t.formatName)]: \(t.formattedDuration) (\(change))")
        }
        return parts.joined(separator: "\n")
    }

    /// Rebuilds `display` and publishes it only if something actually changed. Called from the
    /// two funnels every state change goes through (`setStatus` and `setFileOptimized`), plus
    /// the few places that set `isDone`/`bestToolName` on their own.
    private func updateDisplay() {
        let totalDuration = toolTimings.isEmpty ? nil : toolTimings.reduce(0.0) { $0 + $1.durationSeconds }
        let updated = JobDisplay(statusImageName: statusImageName,
                                 statusText: statusText,
                                 byteSizeOriginal: byteSizeOriginal,
                                 byteSizeOptimized: byteSizeOptimized,
                                 percentOptimized: percentOptimized,
                                 bestToolName: bestToolName,
                                 toolTimings: toolTimings,
                                 totalDurationSeconds: totalDuration)
        if display != updated {
            display = updated
        }
    }

    // MARK: - Reported sizes

    private func optimizedFile(fallback: Bool) -> ImageFile? {
        wipInput ?? savedOutput ?? (fallback ? unoptimizedInput : nil)
    }

    public var percentOptimized: Double? {
        if wipInput === unoptimizedInput, savedOutput == nil {
            return nil // early work in progress, don't display anything
        }
        guard let optimized = optimizedFile(fallback: false) else {
            return isDone && !isFailed ? 0 : nil
        }
        guard let original = initialInput?.byteSize, original > 0, optimized.byteSize > 0 else {
            return nil
        }
        let percent = 100.0 - 100.0 * Double(optimized.byteSize) / Double(original)
        return max(0, percent)
    }

    public var isOptimized: Bool {
        guard let unoptimizedInput, let optimized = optimizedFile(fallback: false), optimized !== unoptimizedInput else {
            return false
        }
        if unoptimizedInput.type == .heic, optimized.type == .jpeg {
            return true
        }
        return optimized.byteSize < unoptimizedInput.byteSize
    }

    public var byteSizeOptimized: Int? {
        optimizedFile(fallback: true)?.byteSize
    }

    public var byteSizeOriginal: Int? {
        initialInput?.byteSize
    }

    /// The best file to hand out to other apps (e.g. as a data: URL).
    public var savedOutputOrInput: ImageFile? {
        savedOutput ?? unoptimizedInput
    }

    public var isBusy: Bool { running }

    public var isStoppable: Bool { stopping || (!isDone && isBusy) }

    public var canRevert: Bool { revertFile != nil && isDone && !stopping }

    // MARK: - Status

    public func setStatus(_ imageName: String, order: Int, text: String) {
        // Keep the failed status visible instead of replacing it with progress/noopt/etc
        if isFailed, imageName != "ok", imageName != "err" {
            return
        }
        // Every worker starting and finishing calls this, usually with the status it already
        // has. Writing an identical value still invalidates every view observing it, so the
        // whole table would be rebuilt tools × files times for nothing.
        if statusOrder != order {
            statusOrder = order
            JobStatusRevision.bump()
        }
        if statusText != text {
            statusText = text
        }
        if statusImageName != imageName {
            statusImageName = imageName
        }
        updateDisplay()
    }

    public func setError(_ text: String) {
        if !isFailed {
            isFailed = true
        }
        setStatus("err", order: 9, text: text)
    }

    private func setNooptStatus() {
        setFileOptimized(nil) // Needed to update the 0% optimized display
        setStatus("noopt", order: 5, text: IOLocalized("File cannot be optimized any further", comment: "tooltip"))
        if !isDone {
            isDone = true
            updateDisplay() // isDone feeds percentOptimized
        }
        stopAllWorkers()
    }

    private func updateRunningStatus() {
        if let name = runningWorkerNames.first {
            setStatus("progress", order: 4, text: IOLocalized("Started \(name)", comment: "command name, tooltip"))
        } else {
            setStatus("wait", order: 1, text: IOLocalized("Waiting to be optimized", comment: "tooltip"))
        }
    }

    // MARK: - File bookkeeping

    private func setNewFileInitial(_ initial: ImageFile?) {
        initialInput = initial
        unoptimizedInput = initial
        revertFile = nil
        savedOutput = nil
        bestToolName = nil
        lossyConverted = false
        bestTools.removeAll()
        toolTimings.removeAll()
        setFileOptimized(initial)
    }

    /// Every change to the files a row reports its sizes from funnels through here, so this is
    /// where the snapshot is refreshed — unconditionally, because the caller may have changed
    /// `initialInput` or `savedOutput` without `wipInput` moving.
    private func setFileOptimized(_ newFile: ImageFile?) {
        if wipInput !== newFile {
            wipInput = newFile
        }
        updateDisplay()
    }

    /// Accepts a tool's output if it is smaller than what we have so far.
    @discardableResult
    private func setFileOptimized(_ newFile: ImageFile, toolName: String) -> Bool {
        let newSize = newFile.byteSize
        let oldSize = wipInput?.byteSize ?? 0
        let isSmaller = newSize > 0 && newSize < oldSize

        IODebug("\(toolName) \(isSmaller ? "optimized" : "did not optimize") file \(unoptimizedInput?.url.path ?? "?") from \(oldSize) to \(newSize) in \(newFile.url.path)")

        guard isSmaller else { return false }
        setFileOptimized(newFile)
        updateBestToolName(toolName, oldSize: oldSize, newSize: newSize)
        return true
    }

    private func updateBestToolName(_ toolName: String, oldSize: Int, newSize: Int) {
        bestTools[toolName] = ToolStats(fileSize: newSize, ratio: Double(oldSize) / Double(newSize))

        var smallestFileToolName: String?
        var smallestFile = unoptimizedInput?.byteSize ?? 0
        var bestRatioToolName: String?
        var bestRatio = 0.0

        for (name, stats) in bestTools {
            if stats.ratio > bestRatio {
                bestRatioToolName = name
                bestRatio = stats.ratio
            }
            if stats.fileSize < smallestFile {
                smallestFileToolName = name
                smallestFile = stats.fileSize
            }
        }

        let newBestToolName: String?
        if let smallestFileToolName, let bestRatioToolName, bestRatioToolName != smallestFileToolName {
            newBestToolName = IOLocalized("\(bestRatioToolName)+\(smallestFileToolName)", comment: "toolname+toolname in Best Tool column")
        } else {
            newBestToolName = smallestFileToolName ?? bestRatioToolName
        }
        if newBestToolName != bestToolName {
            bestToolName = newBestToolName
            updateDisplay()
        }
    }

    // MARK: - Running

    /// Marks the job as queued, so the UI shows it as busy right away.
    public func markEnqueued() {
        if isDone { isDone = false }
        if isFailed { isFailed = false }
        if stopping { stopping = false }
        if !running { running = true }
        toolTimings.removeAll()
        updateDisplay() // a re-run clears the savings the previous one left on screen
    }

    public func run(settings: Settings, cpuLimiter: AsyncSemaphore, fileIOLimiter: AsyncSemaphore, trashLimiter: AsyncSemaphore, guetzliGate: AsyncSemaphore) async {
        preservePermissions = settings.preservePermissions
        preserveDates = settings.preserveDates
        defer {
            if running { running = false }
            runningWorkerNames.removeAll()
            if stopping { stopping = false }
        }

        setStatus("progress", order: 3, text: IOLocalized("Inspecting file", comment: "tooltip"))

        let path = filePath
        // Nothing below is worth a permit if the run is already being torn down.
        guard !Task.isCancelled else { return }
        let loaded: (data: Data, file: ImageFile)? = await fileIOLimiter.withPermit {
            await offMainActor(priority: .userInitiated) { () -> (data: Data, file: ImageFile)? in
                guard let data = try? Data(contentsOf: path, options: .mappedIfSafe),
                      let file = ImageFile(data: data, url: path)
                else { return nil }
                return (data, file)
            }
        }

        guard let loaded else {
            IOWarn("Can't open the file \(path.path)")
            setNewFileInitial(nil)
            setError(IOLocalized("Can't open the file", comment: "tooltip, generic loading error"))
            return
        }

        let input = loaded.file
        let hasChangedSinceLastSave = savedOutput != nil && savedOutput?.byteSize != input.byteSize
        let hasBeenRunBefore = initialInput != nil && !hasChangedSinceLastSave

        // if the file hasn't changed since the last optimization, keep the previous byteSizeOriginal etc.
        if !hasBeenRunBefore || hasChangedSinceLastSave {
            setNewFileInitial(input)
        } else {
            unoptimizedInput = input
            setFileOptimized(input)
        }

        let destinationURL = computeDestinationURL(settings: settings)
        let writesInPlace = !settings.preserveOriginal && destinationURL == filePath
        if writesInPlace, !FileManager.default.isWritableFile(atPath: filePath.path) {
            setError(IOLocalized("Optimized file could not be saved", comment: "tooltip"))
            return
        }

        guard let plan = buildWorkers(input: input, settings: settings, hasBeenRunBefore: hasBeenRunBefore, queueHasSpareCapacity: cpuLimiter.hasSpareCapacity) else {
            return
        }

        guard !plan.first.isEmpty || !plan.later.isEmpty else {
            isDone = true
            setError(IOLocalized("All neccessary tools have been disabled in Preferences", comment: "tooltip"))
            cleanup()
            return
        }

        // A hash of all the optimization settings, so that changing any of them invalidates the file cache
        settingsDigest = Self.settingsDigest(for: plan.first + plan.later)

        let fileData = loaded.data
        let digest = settingsDigest
        let hash = await offMainActor(priority: .utility) {
            var md5 = Insecure.MD5()
            md5.update(data: digest)
            md5.update(data: fileData)
            return ResultHash(digest: md5.finalize())
        }
        inputFileHash = hash

        if await db?.hasResult(hash: hash) == true {
            IODebug("Skipping \(filePath.path), because it has been optimized before")
            setNooptStatus()
            return
        }

        updateRunningStatus()

        let context = WorkerContext(lowPriority: settings.runLowPriority, guetzliGate: guetzliGate)
        await runWorkers(plan.first, plan.later, cpuLimiter: cpuLimiter, context: context)

        await saveResultAndUpdateStatus(settings: settings, destinationURL: destinationURL, fileIOLimiter: fileIOLimiter, trashLimiter: trashLimiter)
    }

    private func runWorkers(_ runFirst: [any Worker], _ runLater: [any Worker], cpuLimiter: AsyncSemaphore, context: WorkerContext) async {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // Optimizers with side effects run one at a time, before the rest
            for worker in runFirst {
                if Task.isCancelled { return }
                await execute(worker, cpuLimiter: cpuLimiter, context: context)
            }
            await withTaskGroup(of: Void.self) { group in
                for worker in runLater {
                    group.addTask {
                        await self.execute(worker, cpuLimiter: cpuLimiter, context: context)
                    }
                }
            }
        }
        workersTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        workersTask = nil
    }

    private func execute(_ worker: any Worker, cpuLimiter: AsyncSemaphore, context: WorkerContext) async {
        guard !Task.isCancelled, let input = wipInput else { return }

        if worker.isIdempotent,
           let previousSize = workersPreviousResults[worker.name]?[worker.settingsIdentifier],
           previousSize == input.byteSize {
            IODebug("Skipping \(worker.name), because it already optimized \(fileName)")
            return
        }

        runningWorkerNames.append(worker.name)
        updateRunningStatus()
        defer {
            if let index = runningWorkerNames.firstIndex(of: worker.name) {
                runningWorkerNames.remove(at: index)
            }
            updateRunningStatus()
        }

        await cpuLimiter.wait()
        defer { cpuLimiter.signal() }

        guard !Task.isCancelled else { return }

        let temp = Tools.temporaryURL(for: worker.name)
        var producedOutput = false
        let startTime = CFAbsoluteTimeGetCurrent()
        let inputSize = input.byteSize
        var outputSize: Int? = nil
        var didImprove = false
        var toolError: String? = nil

        do {
            if let result = try await worker.optimize(input, to: temp, context: context) {
                producedOutput = true
                outputSize = result.file.byteSize
                didImprove = setFileOptimized(result.file, toolName: result.toolName)
            }
        } catch is CancellationError {
            // stopped by the user
            toolError = "Cancelled"
        } catch CommandError.executableMissing(let tool) {
            IOWarn("Cannot launch \(tool)")
            setError(IOLocalized("\(tool) failed to start", comment: "tooltip"))
            toolError = "\(tool) failed to start"
        } catch {
            IOWarn("\(worker.name) failed: \(error)")
            setError("Internal Error: \(error)")
            toolError = "\(error)"
        }

        let duration = max(0.0001, CFAbsoluteTimeGetCurrent() - startTime)
        let timing = ToolTiming(toolName: worker.name,
                                durationSeconds: duration,
                                inputBytes: inputSize,
                                outputBytes: outputSize,
                                didImprove: didImprove,
                                error: toolError)
        recordToolTiming(timing)

        // When the worker produced an ImageFile, that object owns (and deletes) the temp file
        if !producedOutput {
            try? FileManager.default.removeItem(at: temp)
        }

        if !Task.isCancelled, !isFailed, let currentSize = wipInput?.byteSize {
            workersPreviousResults[worker.name, default: [:]][worker.settingsIdentifier] = currentSize
        }
    }

    private func recordToolTiming(_ timing: ToolTiming) {
        if let index = toolTimings.firstIndex(where: { $0.toolName == timing.toolName }) {
            toolTimings[index] = timing
        } else {
            toolTimings.append(timing)
        }
        BenchmarkTracker.shared.record(toolName: timing.toolName,
                                       duration: timing.durationSeconds,
                                       savedBytes: timing.savedBytes)
        updateDisplay()
    }

    private static func settingsDigest(for workers: [any Worker]) -> Data {
        var md5 = Insecure.MD5()
        md5.update(data: Data("3".utf8)) // to update when programs change
        for worker in workers {
            var identifier = worker.settingsIdentifier
            withUnsafeBytes(of: &identifier) { md5.update(bufferPointer: $0) }
        }
        return Data(md5.finalize())
    }

    // MARK: - Choosing the tools

    private func buildWorkers(input: ImageFile, settings: Settings, hasBeenRunBefore: Bool, queueHasSpareCapacity: Bool) -> (first: [any Worker], later: [any Worker])? {
        var runFirst: [any Worker] = []
        var workerList: [any Worker] = []

        var level = settings.level
        let lossyEnabled = settings.lossyEnabled

        switch input.type {
        case .png:
            if hasBeenRunBefore {
                level += 1
            }

            if lossyEnabled, !lossyConverted, settings.pngMinQuality < 100, settings.pngMinQuality > 30 {
                runFirst.append(PngquantWorker(level: level, minQuality: settings.pngMinQuality))
                lossyConverted = true
            }

            var pngcrushEnabled = settings.pngCrushEnabled
            let oxipngEnabled = settings.oxiPngEnabled
            let zopfliEnabled = settings.zopfliEnabled

            if level < 2, oxipngEnabled {
                pngcrushEnabled = false
            }

            if pngcrushEnabled {
                workerList.append(PngCrushWorker(level: level, settings: settings))
            }
            if oxipngEnabled {
                workerList.append(OxiPngWorker(level: level, stripMetadata: settings.removePngChunks))
            }
            if settings.advPngEnabled, settings.removePngChunks {
                workerList.append(AdvCompWorker(level: level))
            }
            if zopfliEnabled {
                workerList.append(ZopfliWorker(level: level, byteSize: input.byteSize, settings: settings, alternativeStrategy: hasBeenRunBefore))
            }

        case .jpeg:
            if !lossyConverted, !hasBeenRunBefore, settings.guetzliEnabled, settings.jpegOptimMaxQuality >= 80 {
                workerList.append(GuetzliWorker(settings: settings))
                lossyConverted = true
            }
            if settings.jpegliEnabled {
                workerList.append(JpegliWorker(settings: settings))
            }
            if settings.jpegOptimEnabled {
                workerList.append(JpegoptimWorker(settings: settings))
            }
            if settings.jpegTranEnabled {
                workerList.append(JpegtranWorker(settings: settings))
            }

        case .gif:
            if settings.gifsicleEnabled {
                let gifQuality = settings.gifQuality
                if lossyEnabled, !lossyConverted, gifQuality < 100, gifQuality > 30 {
                    runFirst.append(GifsicleWorker(interlace: false, quality: gifQuality))
                    lossyConverted = true
                } else {
                    workerList.append(GifsicleWorker(interlace: false, quality: 100))
                    if level > 1 {
                        workerList.append(GifsicleWorker(interlace: true, quality: 100))
                    }
                }
            }

        case .svg:
            if settings.svgoEnabled {
                workerList.append(SvgoWorker(lossy: lossyEnabled))
            }
            if settings.svgCleanerEnabled {
                workerList.append(SvgcleanerWorker(lossy: lossyEnabled))
            }

        case .webp:
            if settings.webpEnabled {
                workerList.append(WebpWorker())
            }

        case .avif:
            if settings.avifEnabled {
                workerList.append(AvifWorker())
            }

        case .jxl:
            if settings.jxlEnabled {
                workerList.append(JxlWorker())
            }

        case .heic:
            if settings.heicToJpegEnabled {
                runFirst.append(HeicToJpegWorker())
                if settings.jpegliEnabled {
                    workerList.append(JpegliWorker(settings: settings))
                }
                if settings.jpegOptimEnabled {
                    workerList.append(JpegoptimWorker(settings: settings))
                }
                if settings.jpegTranEnabled {
                    workerList.append(JpegtranWorker(settings: settings))
                }
            }

        case nil:
            setError(IOLocalized("File format not supported", comment: "tooltip"))
            cleanup()
            return nil
        }

        var runLater: [any Worker] = []
        for worker in workerList {
            // Generally, optimizers that have side effects should always be run first, one at a time.
            // Unfortunately that makes the whole process single-core serial when there are very few
            // files, so for small queues they're allowed to run alongside the others.
            if worker.makesNonOptimizingModifications, !queueHasSpareCapacity || input.isSmall {
                runFirst.append(worker)
            } else {
                runLater.append(worker)
            }
        }

        return (runFirst, runLater)
    }

    // MARK: - Stopping

    public func stop() -> Bool {
        guard isStoppable else { return false }
        if !isDone {
            stopping = true
            workersTask?.cancel()
        }
        return true
    }

    private func stopAllWorkers() {
        workersTask?.cancel()
        runningWorkerNames.removeAll()
        if stopping { stopping = false }
    }

    public func cleanup() {
        stopAllWorkers()
        setFileOptimized(nil)
    }

    // MARK: - Destination and Tokens

    private func computeDestinationURL(settings: Settings) -> URL {
        let isHeicConversion = unoptimizedInput?.type == .heic
        let ext = isHeicConversion ? "jpg" : filePath.pathExtension
        let base = filePath.deletingPathExtension().lastPathComponent

        // Si preserveOriginal está desactivado, el modo es estrictamente sobrescribir el original in situ
        guard settings.preserveOriginal else {
            if isHeicConversion {
                return filePath.deletingPathExtension().appendingPathExtension("jpg")
            }
            return filePath
        }

        let now = Date()
        let prefix = expandDateTokens(in: settings.filenamePrefix, at: now)
        var suffix = expandDateTokens(in: settings.filenameSuffix, at: now)
        let destDir = settings.outputFolderPath.isEmpty
            ? filePath.deletingLastPathComponent()
            : URL(fileURLWithPath: settings.outputFolderPath, isDirectory: true)

        let isSameFolder = destDir.standardizedFileURL == filePath.deletingLastPathComponent().standardizedFileURL
        if isSameFolder && prefix.isEmpty && suffix.isEmpty && !isHeicConversion {
            suffix = "-optimized"
        }

        let newName = "\(prefix)\(base)\(suffix)"
        var destination = destDir.appendingPathComponent(newName).appendingPathExtension(ext)

        if destination == filePath {
            let fallbackName = "\(prefix)\(base)\(suffix)-optimized"
            destination = destDir.appendingPathComponent(fallbackName).appendingPathExtension(ext)
        }
        return destination
    }

    private func expandDateTokens(in template: String, at date: Date) -> String {
        guard template.contains("{date") else { return template }
        guard let regex = try? NSRegularExpression(pattern: "\\{date(?::([^}]+))?\\}") else {
            return template
        }
        let nsTemplate = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length))
        var result = template
        for match in matches.reversed() {
            let formatSpec: String
            if match.range(at: 1).location != NSNotFound {
                formatSpec = nsTemplate.substring(with: match.range(at: 1))
            } else {
                formatSpec = "yy.MM.dd"
            }
            let formatter = DateFormatter()
            formatter.dateFormat = formatSpec
            let formatted = formatter.string(from: date).replacingOccurrences(of: "/", with: "-")
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: formatted)
            }
        }
        return result
    }

    // MARK: - Saving

    private func saveResultAndUpdateStatus(settings: Settings, destinationURL: URL, fileIOLimiter: AsyncSemaphore, trashLimiter: AsyncSemaphore) async {
        if isOptimized {
            let saved = await save(settings: settings, destinationURL: destinationURL, fileIOLimiter: fileIOLimiter, trashLimiter: trashLimiter)
            if !isDone { isDone = true }
            stopAllWorkers()
            if saved {
                setStatus("ok", order: 7, text: IOLocalized("Optimized successfully with \(bestToolName ?? "")", comment: "tooltip"))
            } else {
                setError(IOLocalized("Optimized file could not be saved", comment: "tooltip"))
            }
        } else {
            let wasStopping = stopping
            setNooptStatus()
            if !wasStopping, !isFailed, let hash = inputFileHash, let size = unoptimizedInput?.byteSize {
                await db?.setUnoptimizableFile(hash: hash, size: size)
            }
        }
    }

    private func save(settings: Settings, destinationURL: URL, fileIOLimiter: AsyncSemaphore, trashLimiter: AsyncSemaphore) async -> Bool {
        guard let fileToSave = wipInput, let unoptimizedInput else { return false }

        let request = SaveRequest(
            filePath: filePath,
            destinationURL: destinationURL,
            fileToSave: fileToSave,
            unoptimizedInput: unoptimizedInput,
            needsRevertFile: revertFile == nil,
            preservePermissions: preservePermissions,
            preserveDates: preserveDates,
            preserveOriginal: settings.preserveOriginal
        )

        // Not gated on `Task.isCancelled`: by this point the file has already been optimized,
        // and dropping the write would throw that work away and leave the file untouched.
        let prepared = await fileIOLimiter.withPermit {
            await offMainActor(priority: .userInitiated) { Self.prepareSave(request) }
        }
        guard let prepared else { return false }

        // The file-I/O permit is gone by now: the second phase is bounded by `trashLimiter`
        // instead, so that a slow `trashItem` no longer keeps the next job from reading its
        // input. Dropbox is the exception — it never reaches the Trash and pays two one-second
        // sleeps instead, which have no business holding up everybody else's trashing.
        let commitLimiter = prepared.isDropboxFolder ? fileIOLimiter : trashLimiter
        let outcome = await commitLimiter.withPermit {
            await offMainActor(priority: .userInitiated) { Self.commitSave(request, prepared) }
        }

        guard outcome.success else { return false }

        if let newRevertFile = outcome.revertFile {
            revertFile = newRevertFile
        }
        savedOutput = outcome.savedOutput
        setFileOptimized(nil)
        return true
    }

    private struct SaveRequest: Sendable {
        let filePath: URL
        let destinationURL: URL
        let fileToSave: ImageFile
        let unoptimizedInput: ImageFile
        let needsRevertFile: Bool
        let preservePermissions: Bool
        let preserveDates: Bool
        let preserveOriginal: Bool
    }

    private struct SaveOutcome: Sendable {
        var success = false
        var savedOutput: ImageFile?
        var revertFile: ImageFile?
    }

    /// What the second half of the save needs to know about the first half.
    private struct SavePreparation: Sendable {
        /// The file holding the optimized bytes, to be moved onto `filePath` once the original
        /// is out of the way. Either the worker's temp file, or — when permissions are being
        /// preserved — the original file with the optimized bytes written into it.
        let moveFromPath: URL
        let isDropboxFolder: Bool
        let isSeparateDestination: Bool
    }

    /// Everything about saving that is genuinely disk-bound, and so belongs under a file-I/O permit:
    /// it gets the optimized bytes onto the volume, next to the original, without touching the
    /// original's own path. `commitSave` then does the swap.
    ///
    /// If the app dies between the two, the result is a stale `.name~imageoptim.ext` next to an
    /// untouched original — the same leftover the single-phase version could produce, and the same
    /// one the `preservePermissions` branch below cleans up on the next run.
    private nonisolated static func prepareSave(_ request: SaveRequest) -> SavePreparation? {
        let fm = FileManager.default
        let filePath = request.filePath
        let destinationURL = request.destinationURL
        let isSeparateDestination = request.preserveOriginal || destinationURL != filePath
        let fileToSave = request.fileToSave

        var moveFromPath = fileToSave.url
        let enclosingDir = destinationURL.deletingLastPathComponent()

        if isSeparateDestination {
            if !fm.fileExists(atPath: enclosingDir.path) {
                try? fm.createDirectory(at: enclosingDir, withIntermediateDirectories: true)
            }
        }

        // Dropbox is super buggy and actually loses files when they're moved/trashed quickly
        let isDropboxFolder = fm.fileExists(atPath: enclosingDir.appendingPathComponent(".dropbox").path)
            || destinationURL.path.contains("/Dropbox/")
        if isDropboxFolder {
            IOWarn("Detected path \(destinationURL.path) is inside Dropbox. Will try to avoid Dropbox's bugs.")
        }

        guard fm.isWritableFile(atPath: enclosingDir.path) else {
            IOWarn("The destination \(destinationURL.path) is in non-writeable directory \(enclosingDir.path)")
            return nil
        }

        if !isSeparateDestination, !isDropboxFolder, request.preservePermissions {
            let baseName = filePath.deletingPathExtension().lastPathComponent
            let writeToURL = enclosingDir
                .appendingPathComponent(".\(baseName)~imageoptim")
                .appendingPathExtension(filePath.pathExtension)

            if fm.fileExists(atPath: writeToURL.path) {
                if !trashFile(at: writeToURL).trashed {
                    do {
                        try fm.removeItem(at: writeToURL)
                    } catch {
                        IOWarn("\(error)")
                        return nil
                    }
                }
            }

            // move the destination to a temporary location that will be overwritten
            do {
                try fm.moveItem(at: filePath, to: writeToURL)
            } catch {
                IOWarn("Can't move to \(writeToURL.path) \(error)")
                return nil
            }

            // copy the original data back, so it can be trashed under the original file name
            do {
                try fm.copyItem(at: writeToURL, to: filePath)
            } catch {
                IOWarn("Can't write to \(filePath.path) \(error)")
                return nil
            }

            guard let data = try? Data(contentsOf: fileToSave.url) else {
                IOWarn("Unable to read \(fileToSave.url.path)")
                return nil
            }
            guard data.count == fileToSave.byteSize else {
                IOWarn("Temp file size \(data.count) does not match expected \(fileToSave.byteSize) in \(fileToSave.url.path) for \(filePath.path)")
                return nil
            }
            guard data.count >= 30 else {
                IOWarn("File \(fileToSave.url.path) is suspiciously small, could be truncated")
                return nil
            }

            // overwrite the old file that is under the temporary name,
            // so that only the content is replaced, not the file metadata
            guard let writeHandle = try? FileHandle(forWritingTo: writeToURL) else {
                IOWarn("Unable to open \(filePath.path) for writing. Check file permissions.")
                return nil
            }
            do {
                try writeHandle.write(contentsOf: data)
                try writeHandle.truncate(atOffset: UInt64(data.count))
                try writeHandle.close()
            } catch {
                IOWarn("Failed to write \(writeToURL.path) \(error)")
                return nil
            }

            moveFromPath = writeToURL
        }

        if request.preserveDates {
            do {
                let originalAttributes = try fm.attributesOfItem(atPath: filePath.path)
                var attributesToTransfer: [FileAttributeKey: Any] = [:]
                attributesToTransfer[.creationDate] = originalAttributes[.creationDate]
                attributesToTransfer[.modificationDate] = originalAttributes[.modificationDate]
                try fm.setAttributes(attributesToTransfer, ofItemAtPath: moveFromPath.path)
            } catch {
                IOWarn("Could not transfer creation and modification date for \(filePath.path) \(error)")
                return nil
            }
        }

        return SavePreparation(moveFromPath: moveFromPath, isDropboxFolder: isDropboxFolder, isSeparateDestination: isSeparateDestination)
    }

    /// Moves the original to the Trash and puts the optimized file in its place.
    ///
    /// Split out of `prepareSave` because of `trashFile`: see `JobQueue.trashLimiter` for why
    /// that call is the slowest thing in a large batch and why it must not be holding a file-I/O
    /// permit while it runs. Nothing here is disk-bound — it is two renames and a DesktopServices
    /// round-trip — so the original still ends up in the Trash under its own name, and `revert()`
    /// still gets a real Trash URL to restore from.
    private nonisolated static func commitSave(_ request: SaveRequest, _ preparation: SavePreparation) -> SaveOutcome {
        var outcome = SaveOutcome()
        let fm = FileManager.default
        let filePath = request.filePath
        let destinationURL = request.destinationURL
        let fileToSave = request.fileToSave
        let moveFromPath = preparation.moveFromPath
        let isDropboxFolder = preparation.isDropboxFolder
        let isSeparateDestination = preparation.isSeparateDestination

        if isSeparateDestination {
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try? fm.removeItem(at: destinationURL)
            }
            do {
                try fm.moveItem(at: moveFromPath, to: destinationURL)
            } catch {
                do {
                    try fm.copyItem(at: moveFromPath, to: destinationURL)
                    try? fm.removeItem(at: moveFromPath)
                } catch {
                    IOWarn("Failed to copy to \(destinationURL.path); \(error)")
                    return outcome
                }
            }

            outcome.savedOutput = fileToSave.copy(at: destinationURL, byteSize: fileToSave.byteSize)
            outcome.success = true

            if isDropboxFolder {
                sleep(1)
            }
            removeExtendedAttributes(at: destinationURL)
            return outcome
        }

        let enclosingDir = filePath.deletingLastPathComponent()
        let trashResult = isDropboxFolder ? (trashed: false, url: nil as URL?) : trashFile(at: filePath)
        if trashResult.trashed {
            if request.needsRevertFile, let trashedURL = trashResult.url {
                outcome.revertFile = request.unoptimizedInput.copy(at: trashedURL, byteSize: request.unoptimizedInput.byteSize)
            }
        } else {
            IOWarn("Can't trash \(filePath.path)")
            var backupPath = enclosingDir
                .appendingPathComponent(filePath.lastPathComponent + "~bak")
                .appendingPathExtension(filePath.pathExtension)

            var moved = (try? fm.moveItem(at: filePath, to: backupPath)) != nil
            if !moved {
                try? fm.removeItem(at: backupPath)
                moved = (try? fm.moveItem(at: filePath, to: backupPath)) != nil
            }

            guard moved else {
                IOWarn("Can't move to \(backupPath.path)")
                return outcome
            }

            if isDropboxFolder {
                sleep(1) // give the buggy thing time to sync
            }
            var trashedURL: NSURL?
            if (try? fm.trashItem(at: backupPath, resultingItemURL: &trashedURL)) != nil, let trashedURL = trashedURL as URL? {
                backupPath = trashedURL
            }
            if request.needsRevertFile {
                outcome.revertFile = request.unoptimizedInput.copy(at: backupPath)
            }
        }

        do {
            try fm.moveItem(at: moveFromPath, to: filePath)
        } catch {
            IOWarn("Failed to move from \(moveFromPath.path) to \(filePath.path); \(error)")
            return outcome
        }

        outcome.savedOutput = fileToSave.copy(at: filePath, byteSize: fileToSave.byteSize)
        outcome.success = true

        if isDropboxFolder {
            sleep(1) // give the buggy thing time to sync
        }
        removeExtendedAttributes(at: filePath)
        return outcome
    }

    private nonisolated static func trashFile(at url: URL) -> (trashed: Bool, url: URL?) {
        let fm = FileManager.default
        var resultingURL: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &resultingURL)
            return (true, resultingURL as URL?)
        } catch {
            IOWarn("Recovering trashing error \(error)") // may fail on network drives
        }
        sleep(1) // network drives lag?

        if !fm.fileExists(atPath: url.path) {
            return (true, nil) // the file got deleted anyway?
        }

        let trashedPath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash")
            .appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: trashedPath)

        if (try? fm.moveItem(at: url, to: trashedPath)) != nil {
            return (true, trashedPath)
        }
        return (false, nil)
    }

    @discardableResult
    private nonisolated static func removeExtendedAttributes(at url: URL) -> Bool {
        let toRemove: Set<String> = [
            "com.apple.FinderInfo",
            "com.apple.ResourceFork",
            "com.apple.quarantine",
            "com.apple.metadata:kMDItemWhereFroms",
        ]

        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }

            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return true } // no attributes to remove

            var nameBuffer = [CChar](repeating: 0, count: size)
            let readSize = listxattr(path, &nameBuffer, size, 0)
            guard readSize > 0 else { return false } // failed to read promised attrs

            var index = 0
            while index < readSize {
                let nameBytes = nameBuffer[index...].prefix { $0 != 0 }
                let name = String(decoding: nameBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                index += nameBytes.count + 1 // attrs are 0-terminated one after another
                guard toRemove.contains(name) else { continue }
                if removexattr(path, name, 0) == 0 {
                    IODebug("Removed \(name) from \(url.path)")
                } else {
                    IOWarn("Can't remove \(name) from \(url.path)")
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Revert

    private enum ReplaceOutcome: Sendable {
        case failed
        case replaced(URL?)
    }

    public func revert() async -> Bool {
        guard canRevert, let revertFile else { return false }
        cleanup()

        let expectedSize = revertFile.byteSize
        let actualSize = ImageFile.byteSize(of: revertFile.url)
        guard expectedSize == actualSize else {
            IOWarn("Revert path '\(revertFile.url.path)' has wrong size, \(expectedSize) expected")
            return false
        }

        let target = filePath
        let source = revertFile.url
        let replacement: ReplaceOutcome = await offMainActor(priority: .userInitiated) {
            var resultingURL: NSURL?
            do {
                try FileManager.default.replaceItem(at: target, withItemAt: source, backupItemName: nil, options: .usingNewMetadataOnly, resultingItemURL: &resultingURL)
            } catch {
                IOWarn("Can't revert: \(source.path) due to \(error)")
                return .failed
            }
            return .replaced(resultingURL as URL?)
        }

        guard case .replaced(let resultingURL) = replacement else { return false }

        if let resultingURL {
            filePath = resultingURL
        }
        filePath.removeAllCachedResourceValues()
        setNewFileInitial(revertFile.copy(at: filePath))
        setStatus("noopt", order: 6, text: IOLocalized("Reverted to original", comment: "tooltip"))
        return true
    }

    // MARK: - Quick Look

    public var previewItemURL: URL? {
        optimizedFile(fallback: true)?.url
    }

    public var previewItemTitle: String { displayName }
}
