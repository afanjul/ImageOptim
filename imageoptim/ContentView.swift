//
//  ContentView.swift
//  ImageOptim
//

import ImageOptimGPL
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ZStack {
                if model.jobs.isEmpty {
                    DropZone(isTargeted: isDropTarget)
                } else {
                    jobsTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.setInsertRow(-1)
            Task { await model.addURLs(urls) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .onAppear {
            model.updateStoppableState()
        }
    }

    // MARK: - Table

    private var jobsTable: some View {
        @Bindable var model = model

        return Table(model.sortedJobs,
                     selection: $model.selection,
                     sortOrder: $model.sortOrder,
                     columnCustomization: $model.columnCustomization) {
            TableColumn(Text(verbatim: ""), sortUsing: JobComparator(field: .status)) { job in
                StatusIcon(name: job.statusImageName)
                    .help(job.statusText)
            }
            .width(22)
            .customizationID("status")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(Text(String(localized: "File", comment: "Table Column Title (MUST BE SHORT)")),
                        sortUsing: JobComparator(field: .fileName)) { job in
                FileNameCell(job: job)
            }
            .width(min: 100, ideal: 316, max: 1000)
            .customizationID("filename")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(Text(String(localized: "Original Size", comment: "Table Column Title (MUST BE SHORT)"))) { job in
                Text(Formatters.size(job.byteSizeOriginal))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 85, max: 120)
            .customizationID("originalsize")
            .defaultVisibility(.hidden)

            TableColumn(Text(String(localized: "Size", comment: "Table Column Title (MUST BE SHORT)"))) { job in
                Text(Formatters.size(job.byteSizeOptimized))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(85)
            .customizationID("size")

            TableColumn(Text(String(localized: "Savings", comment: "Table Column Title (MUST BE SHORT)"))) { job in
                Text(Formatters.savings(job.percentOptimized))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(85)
            .customizationID("savings")

            TableColumn(Text(String(localized: "Best tool", comment: "Table Column Title (MUST BE SHORT)"))) { job in
                Text(job.bestToolName ?? "")
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 85, max: 250)
            .customizationID("besttool")
            .defaultVisibility(.hidden)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { _ in
            model.revealSelectedInFinder()
        }
        .onDeleteCommand {
            model.deleteSelected()
        }
        .onChange(of: model.selection) {
            model.updateStoppableState()
        }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<Job.ID>) -> some View {
        Button(String(localized: "Show in Finder", comment: "Menu Item")) {
            model.revealSelectedInFinder()
        }
        Button(String(localized: "Quick Look", comment: "Menu Item")) {
            QuickLook.toggle()
        }
        Divider()
        Button(String(localized: "Revert to Original", comment: "Menu Item")) {
            Task { await model.revertSelected() }
        }
        .disabled(!model.canRevert)
        Button(String(localized: "Stop", comment: "Menu Item")) {
            model.stopSelected()
        }
        .disabled(!model.isStoppable)
        Divider()
        Button(String(localized: "Copy as Data URL", comment: "Menu Item")) {
            model.copySelectionAsDataURL()
        }
        .disabled(!model.canCopyAsDataURL)
        Button(String(localized: "Delete", comment: "Menu Item")) {
            model.remove(ids: ids)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.browseForFiles() }
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "Add new files or directories", comment: "Button Tooltip"))

            Button {
                model.startAgain(onlyOptimized: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            } label: {
                Label(String(localized: "Again", comment: "Button"), systemImage: "arrow.clockwise")
            }
            .help(String(localized: "Run optimizations again", comment: "Button tooltip"))
            .disabled(model.jobs.isEmpty)

            // `.enabled` and `.disabled` are different types, so the branch is on the view
            Group {
                if model.statusTextSelectable {
                    Text(model.statusText).textSelection(.enabled)
                } else {
                    Text(model.statusText).textSelection(.disabled)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help(String(localized: "Settings", comment: "Button Tooltip"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Cells

private struct StatusIcon: View {
    let name: String

    var body: some View {
        if let image = NSImage(named: name) {
            Image(nsImage: image)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

/// The filename column, with the "reveal in Finder" button that used to be RevealButtonCell.
private struct FileNameCell: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(job.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    model.reveal(job)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.plain)
                .help(job.filePath.path)
            }
        }
        .onHover { isHovering = $0 }
        .help(job.statusText)
    }
}

/// The empty state — what DragDropImageView used to draw.
private struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .opacity(isTargeted ? 1 : 0.6)
            Text(String(localized: "Drop images here", comment: "Drop zone"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(16)
        }
    }
}
