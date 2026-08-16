//
//  AppModel+Commands.swift
//  ImageOptim
//
//  The menu actions that used to live in MyTableView and ImageOptimController.
//

import AppKit
import ImageOptimGPL
import UniformTypeIdentifiers

extension AppModel {
    // MARK: - Opening

    func browseForFiles() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = contentTypes + [.folder]

        guard await panel.begin() == .OK else { return }
        setInsertRow(-1)
        await addURLs(panel.urls)
    }

    func revealSelectedInFinder() {
        let urls = selectedJobs.map(\.filePath)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([job.filePath])
    }

    // MARK: - Editing

    func deleteSelected() {
        remove(ids: selection)
    }

    func copySelection() {
        let jobs = selectedJobs
        let filePaths = jobs.map(\.filePath.path)
        guard !filePaths.isEmpty else { return }

        let names = jobs.map { job in
            job.filePath.lastPathComponent
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.filePath.lastPathComponent
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(jobs.map { $0.filePath as NSURL })
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
    }

    func cutSelection() {
        copySelection()
        deleteSelected()
    }

    func paste() async {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        await addURLsBelowSelection(urls)
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self])
    }

    // MARK: - Data URLs

    /// Small, finished files only — a data: URL of a 10 MB image helps nobody.
    private var filesForDataURL: [ImageFile] {
        var files: [ImageFile] = []
        var totalSize = 0
        for job in selectedJobs where job.isDone {
            guard let file = job.savedOutputOrInput, file.byteSize <= 100_000 else { continue }
            totalSize += file.byteSize
            if totalSize > 1_000_000 { break }
            files.append(file)
        }
        return files
    }

    var canCopyAsDataURL: Bool {
        !filesForDataURL.isEmpty
    }

    func copySelectionAsDataURL() {
        let urls = filesForDataURL.compactMap { file -> String? in
            guard let type = file.type, let data = try? Data(contentsOf: file.url) else { return nil }
            return "data:\(type.mimeType);base64,\(data.base64EncodedString())"
        }
        guard !urls.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
    }
}
