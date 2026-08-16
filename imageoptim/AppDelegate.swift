//
//  AppDelegate.swift
//  ImageOptim
//
//  What used to be ImageOptimController: defaults registration, the Services
//  provider, Dock/CLI file opening and the Quick Look panel plumbing.
//

import AppKit
import ImageOptimGPL
import QuickLookUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    private var previewPanel: QLPreviewPanel?
    private var handledLaunchFiles = false

    override init() {
        IOLog.hideLogs = Launch.isCommandLine
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.registrationDefaults())
        model = AppModel(defaults: defaults)
        super.init()
    }

    /// `defaults.plist` plus the concurrency limits, which depend on the machine.
    private static func registrationDefaults() -> [String: Any] {
        var defs: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: "defaults", withExtension: "plist"),
           let plist = NSDictionary(contentsOf: url) as? [String: Any] {
            defs = plist
        }

        // Performance cores minus one, not every logical core — see `JobQueue.defaultConcurrency`.
        let maxTasks = JobQueue.defaultConcurrency
        defs[PrefKey.runConcurrentFiles] = maxTasks
        defs[PrefKey.runConcurrentDirscans] = Int((Double(maxTasks) / 3.9).rounded(.up))

        // Use lighter defaults on slower machines
        if ProcessInfo.processInfo.activeProcessorCount <= 2 {
            defs[PrefKey.pngCrushEnabled] = false
        }
        return defs
    }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Launch.quitWhenDone {
            NSApp.hide(self)
        }
        SharedPrefs.startMirroring(from: UserDefaults.standard)
        NSApp.servicesProvider = self
    }

    /// `NSApplicationMain` used to turn bare command-line paths into an open-files event.
    /// SwiftUI's launch doesn't, so `ImageOptim *.png` from a shell is handled here.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Launch.isCommandLine, !handledLaunchFiles else { return }
        let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cleanup()
    }

    // MARK: - Opening files

    /// Invoked by the Dock and by `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    private func open(_ urls: [URL]) {
        handledLaunchFiles = true
        model.setInsertRow(-1)
        Task { await model.addURLs(urls) }
    }

    // MARK: - Services

    @objc func handleServices(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        Task { await model.addURLs(urls) }
    }

    // MARK: - Quick Look

    // NSObject declares these as nonisolated, so the overrides have to be too.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            // This object is now responsible for the preview panel:
            // it may set the delegate, the data source, and refresh the panel.
            previewPanel = panel
            panel.delegate = self
            panel.dataSource = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewPanel = nil
        }
    }

    /// The selection can change while the panel is open, and its contents follow along.
    func reloadPreviewPanel() {
        previewPanel?.reloadData()
    }
}

// MARK: - Quick Look data source & delegate

// The panel only ever calls these on the main thread, but the Objective-C protocols
// carry no isolation, hence `@preconcurrency` (which checks it at runtime instead).
extension AppDelegate: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private var previewItems: [PreviewItem] {
        model.selectedJobs.compactMap { job in
            job.previewItemURL.map { PreviewItem(url: $0, title: job.previewItemTitle) }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = previewItems
        return index < items.count ? items[index] : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Escape and the arrow keys are handled by the panel itself; the space bar
        // closes it again, matching the old table view's keyDown: handler.
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        panel.orderOut(nil)
        return true
    }
}

/// `QLPreviewItem` is an Objective-C protocol, so `Job` (a pure Swift class) can't adopt it directly.
private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}
