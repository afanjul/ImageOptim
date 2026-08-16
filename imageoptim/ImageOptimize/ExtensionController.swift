//
//  ExtensionController.swift
//  ImageOptimize
//
//  The share extension: optimize one image in place and hand it back to the host app.
//

import ImageOptimGPL
import SwiftUI
import UniformTypeIdentifiers

@objc(ExtensionController)
final class ExtensionController: NSViewController {
    private let model = ExtensionModel()
    private var tempFileURL: URL?
    private var work: Task<Void, Never>?

    override func loadView() {
        model.onStop = { [weak self] in self?.stop() }
        view = NSHostingView(rootView: ExtensionView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        work = Task { await run() }
    }

    private func run() async {
        guard let inputItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = inputItem.attachments?.first else {
            IOWarn("No items sent to the extension, nothing to optimize")
            cancel()
            return
        }

        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            IOWarn("Invoked on non-image")
            cancel()
            return
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        tempFileURL = url

        do {
            let loaded = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
            guard let data = loaded as? Data else {
                IOWarn("Received something that's not Data")
                cancel()
                return
            }
            IODebug("Writing to \(url.path)")
            try data.write(to: url)
        } catch {
            IOWarn("Failed writing \(url.path): \(error)")
            cancel()
            return
        }

        let defaults = SharedPrefs.defaults() ?? .standard
        defaults.register(defaults: Self.extensionDefaults)

        let job = Job(filePath: url, resultsDatabase: nil)
        model.job = job

        let queue = JobQueue(cpus: 0, dirs: 1, files: 1, defaults: defaults)
        queue.add(job)
        await queue.wait()

        let optimized = job.isOptimized
        model.status = optimized
            ? String(localized: "Optimized with \(job.bestToolName ?? "")", comment: "extension status")
            : String(localized: "Already optimized", comment: "extension status")

        // let the result stay on screen for a moment before the sheet disappears
        try? await Task.sleep(for: .seconds(1))

        guard optimized, let result = NSItemProvider(contentsOf: url) else {
            IODebug("Could not optimize, giving up")
            cancel()
            return
        }

        IODebug("Returned image \(job.byteSizeOriginal ?? 0) > \(job.byteSizeOptimized ?? 0)")
        inputItem.attachments = [result]
        extensionContext?.completeRequest(returningItems: [inputItem])
        cleanUpTempFile()
    }

    private static let extensionDefaults: [String: Any] = [
        PrefKey.advPngEnabled: true,
        PrefKey.level: 4,
        PrefKey.zopfliEnabled: true,
        PrefKey.removePngChunks: true,
        PrefKey.preservePermissions: false,
        PrefKey.preserveDates: false,
        PrefKey.runLowPriority: false,
        PrefKey.jpegTranEnabled: true,
        PrefKey.jpegTranStripAll: true,
        PrefKey.gifsicleEnabled: true,
        PrefKey.pngMinQuality: 70,
        PrefKey.jpegOptimMaxQuality: 80,
        PrefKey.lossyEnabled: true,
    ]

    private func stop() {
        if let job = model.job, job.isStoppable, job.isBusy {
            IODebug("Stopping")
            _ = job.stop()
        } else {
            IODebug("User cancelled")
            cancel()
        }
    }

    private func cancel() {
        IODebug("Cancelled")
        work?.cancel()
        cleanUpTempFile()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func cleanUpTempFile() {
        guard let tempFileURL else { return }
        try? FileManager.default.removeItem(at: tempFileURL)
        self.tempFileURL = nil
    }
}

@MainActor
@Observable
final class ExtensionModel {
    var status = String(localized: "Optimizing…", comment: "extension status")
    @ObservationIgnored var job: Job?
    @ObservationIgnored var onStop: (@MainActor () -> Void)?
}

private struct ExtensionView: View {
    @Bindable var model: ExtensionModel

    var body: some View {
        VStack(spacing: 16) {
            Text(model.status)
                .lineLimit(2)
            ProgressView()
                .progressViewStyle(.linear)
            Button(String(localized: "Stop", comment: "extension button")) {
                model.onStop?()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 320)
    }
}
