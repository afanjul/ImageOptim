//
//  ContentView.swift
//  ImageOptim
//

import ImageOptimGPL
import SwiftUI

/// The model is passed down explicitly rather than through the environment: `@Environment(AppModel.self)`
/// traps with "No Observable object of type AppModel found" whenever SwiftUI evaluates a subview
/// (a table cell, a context menu) in a graph the app's `.environment(_:)` hasn't reached.
struct ContentView: View {
    let model: AppModel
    @State private var isDropTarget = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.hasJobs {
                    VStack(spacing: 0) {
                        FilterBar(model: model)
                        Divider()
                        JobsTable(model: model)
                    }
                } else {
                    ByteCruncherDropZone(isTargeted: isDropTarget) {
                        Task { await model.browseForFiles() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.hasJobs && isDropTarget {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.accentColor.opacity(0.1))
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                        HStack(spacing: 8) {
                            LucideIcon(.plus, size: 18, color: Color.accentColor)
                            Text(String(localized: "Soltar para añadir a la cola", comment: "Drop overlay"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: Color.black.opacity(0.1), radius: 8, y: 3)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }

            Divider()
            BottomBar(model: model)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.setInsertRow(-1)
            Task { await model.addURLs(urls) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .onAppear {
            model.updateSelectionState()
        }
    }
}

// MARK: - Filter Bar

private struct FilterBar: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 8) {
            Picker("Filter", selection: $model.queueFilter) {
                Text(verbatim: "All (\(model.jobs.count))").tag(QueueFilter.all)
                Text(verbatim: "Active (\(model.countActive))").tag(QueueFilter.active)
                Text(verbatim: "Done (\(model.countCompleted))").tag(QueueFilter.completed)
                Text(verbatim: "Failed (\(model.countFailed))").tag(QueueFilter.failed)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 360)

            Spacer()

            if model.countFailed > 0 {
                Button {
                    model.retryFailed()
                } label: {
                    HStack(spacing: 4) {
                        LucideIcon(.refreshCw, size: 11)
                        Text(String(localized: "Retry Failed", comment: "Button"))
                    }
                }
                .controlSize(.small)
            }

            if model.canClearComplete {
                Button {
                    model.clearComplete()
                } label: {
                    HStack(spacing: 4) {
                        LucideIcon(.trash2, size: 11)
                        Text(String(localized: "Clear Done", comment: "Button"))
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Table

/// The column headers, resolved once instead of on every pass of `JobsTable.body`:
/// `String(localized:)` is a bundle lookup, and the body runs on every selection change
/// and every batch of rows a directory scan delivers.
private enum ColumnTitle {
    static let file = String(localized: "File", comment: "Table Column Title (MUST BE SHORT)")
    static let originalSize = String(localized: "Original Size", comment: "Table Column Title (MUST BE SHORT)")
    static let size = String(localized: "Size", comment: "Table Column Title (MUST BE SHORT)")
    static let savings = String(localized: "Savings", comment: "Table Column Title (MUST BE SHORT)")
    static let bestTool = String(localized: "Best tool", comment: "Table Column Title (MUST BE SHORT)")
}

/// A view of its own, so that the status bar ticking away below it does not invalidate
/// (and re-diff every row of) the table. Its body reads the row array and the table's own
/// bindings — nothing that changes several times a second.
private struct JobsTable: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        return Table(model.visibleJobs,
                     selection: $model.selection,
                     sortOrder: $model.sortOrder,
                     columnCustomization: $model.columnCustomization) {
            TableColumn(Text(verbatim: ""), sortUsing: JobComparator(field: .status)) { job in
                StatusIcon(name: job.display.statusImageName)
                    .help(job.timingsSummaryText)
            }
            .width(22)
            .customizationID("status")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(Text(ColumnTitle.file),
                        sortUsing: JobComparator(field: .fileName)) { job in
                FileNameCell(model: model, job: job)
            }
            .width(min: 100, ideal: 316, max: 1000)
            .customizationID("filename")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(Text(ColumnTitle.originalSize)) { job in
                Text(Formatters.size(job.display.byteSizeOriginal))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 85, max: 120)
            .customizationID("originalsize")
            .defaultVisibility(.hidden)

            TableColumn(Text(ColumnTitle.size)) { job in
                Text(Formatters.size(job.display.byteSizeOptimized))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(85)
            .customizationID("size")

            TableColumn(Text(ColumnTitle.savings)) { job in
                HStack(spacing: 5) {
                    if job.display.totalDurationSeconds != nil && !job.display.toolTimings.isEmpty {
                        JobTimingsButton(job: job)
                    }

                    let pct = job.display.percentOptimized
                    if let pct, pct > 0 {
                        HStack(spacing: 2) {
                            LucideIcon(.arrowDown, size: 9, color: .green)
                            Text(Formatters.savings(pct))
                                .monospacedDigit()
                                .font(.system(size: 11.5, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.green)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text(Formatters.savings(pct))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .help(job.timingsSummaryText)
            }
            .width(min: 85, ideal: 100, max: 130)
            .customizationID("savings")

            TableColumn(Text(ColumnTitle.bestTool)) { job in
                Text(job.display.bestToolName ?? "")
                    .monospacedDigit()
                    .help(job.timingsSummaryText)
            }
            .width(min: 40, ideal: 85, max: 250)
            .customizationID("besttool")
            .defaultVisibility(.hidden)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            RowMenu(model: model, ids: ids)
        } primaryAction: { _ in
            model.revealSelectedInFinder()
        }
        .onDeleteCommand {
            model.deleteSelected()
        }
        .background(FixedRowHeight())
    }
}

/// Takes the table off automatic row heights.
///
/// `Table` leaves the `NSOutlineView` underneath it on `usesAutomaticRowHeights`, so every row
/// that scrolls into view is measured: `_uncachedAutomaticRowHeight` runs an Auto Layout pass and
/// a SwiftUI `sizeThatFits` over the row's hosting views. Sampling a scroll through a few thousand
/// rows put ~25% of the main thread in that measurement alone. Every row here is a single line of
/// text of the same size, so the height is a constant and measuring it per row buys nothing.
///
/// The height is read back from the table rather than hard-coded, so the rows keep exactly the
/// size AppKit had already decided on and the list looks unchanged.
private struct FixedRowHeight: NSViewRepresentable {
    /// Remembers that the height has already been fixed.
    ///
    /// `updateNSView` runs on every update pass of the table — several times a second while a
    /// folder is being scanned — and finding the table view means a recursive walk of the whole
    /// window's view hierarchy. Without this flag that walk, and the hop onto the main actor that
    /// precedes it, went on forever for a job that is done after the first successful pass.
    @MainActor
    final class Coordinator {
        var isApplied = false
        var isScheduled = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.isApplied, !coordinator.isScheduled else { return }

        // The table has usually not laid out its rows yet at this point in the update, and it may
        // have none at all, so this runs after the current pass and gives up until the next one.
        coordinator.isScheduled = true
        Task { @MainActor in
            coordinator.isScheduled = false
            coordinator.isApplied = apply(near: view)
        }
    }

    /// Returns true when there is nothing left to do — either the height was fixed, or the table
    /// is already off automatic heights.
    private func apply(near view: NSView) -> Bool {
        guard let root = view.window?.contentView,
              let table = Self.firstTableView(in: root)
        else { return false }

        guard table.usesAutomaticRowHeights else { return true }
        guard table.numberOfRows > 0 else { return false }

        let measured = table.rect(ofRow: 0).height
        guard measured > 4, measured < 200 else { return false } // not laid out yet; try again next update

        table.usesAutomaticRowHeights = false
        table.rowHeight = measured
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< table.numberOfRows))
        return true
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView {
            return table
        }
        for subview in view.subviews {
            if let table = firstTableView(in: subview) {
                return table
            }
        }
        return nil
    }
}

/// Its own view so the enablement flags it reads stay out of the table's dependencies.
private struct RowMenu: View {
    let model: AppModel
    let ids: Set<Job.ID>

    var body: some View {
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
}

// MARK: - Bottom bar

/// Add button, status text, then the settings button (swapped for the progress spinner
/// while busy) and "Again" on the trailing edge — the order the xib laid out.
///
/// Separate from `ContentView` because the status text is rewritten several times a second:
/// in one body with the table, every one of those ticks rebuilt the table too.
private struct BottomBar: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.browseForFiles() }
            } label: {
                LucideIcon(.plus, size: 13)
            }
            .frame(width: 30, height: 24)
            .help(String(localized: "Add new files or directories", comment: "Button Tooltip"))
            .accessibilityLabel(Text(String(localized: "Add new files or directories", comment: "Button Tooltip")))

            // `.enabled` and `.disabled` are different types, so the branch is on the view
            Group {
                if let summary = model.selectionSummaryText {
                    Text(summary).foregroundStyle(.secondary)
                } else if model.statusTextSelectable {
                    Text(model.statusText).textSelection(.enabled)
                } else {
                    Text(model.statusText).textSelection(.disabled)
                }
            }
            .font(.system(size: NSFont.smallSystemFontSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Both are 16×16 and share the same slot, so the bar doesn't shift when a run starts
            ZStack {
                if model.isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Button {
                        openWindow(id: WindowID.prefs)
                    } label: {
                        LucideIcon(.sliders, size: 15)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Settings", comment: "Button Tooltip"))
                }
            }
            .frame(width: 18, height: 18)
            .padding(.trailing, 2)

            Button {
                model.startAgain(onlyOptimized: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            } label: {
                HStack(spacing: 5) {
                    LucideIcon(.refreshCw, size: 11)
                    Text(String(localized: "Again", comment: "Button"))
                }
            }
            .frame(minWidth: 90)
            .help(String(localized: "Run optimizations again", comment: "Button tooltip"))
            .disabled(!model.hasJobs)
        }
        .controlSize(.regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Cells

private struct StatusIcon: View {
    let name: String

    var body: some View {
        switch name {
        case "ok":
            LucideIcon(.checkCircle, size: 15, color: .green)
        case "err":
            LucideIcon(.alertCircle, size: 15, color: .red)
        case "noopt":
            LucideIcon(.check, size: 14, color: .secondary)
        case "progress":
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case "wait":
            LucideIcon(.clock, size: 13, color: .secondary.opacity(0.7))
        default:
            if let image = NSImage(named: name) {
                Image(nsImage: image)
            } else {
                Color.clear.frame(width: 15, height: 15)
            }
        }
    }
}

/// The filename column, with format badge and the "reveal in Finder" button.
private struct FileNameCell: View {
    let model: AppModel
    let job: Job
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            let ext = (job.fileName as NSString).pathExtension.uppercased()
            if !ext.isEmpty {
                FormatBadge(format: ext)
            }

            Text(job.fileName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                model.reveal(job)
            } label: {
                LucideIcon(.externalLink, size: 11, color: .secondary)
            }
            .buttonStyle(.plain)
            .help(job.filePathString)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .onHover { isHovering = $0 }
        .help(job.timingsSummaryText)
    }
}

// MARK: - Tool Timings Popover

private struct JobTimingsPopoverView: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .foregroundStyle(.blue)
                Text(job.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let total = job.display.totalDurationSeconds {
                    Text(formatDuration(total))
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(.primary)
                }
            }

            Divider()

            if job.display.toolTimings.isEmpty {
                Text(String(localized: "No engine execution times recorded yet.", comment: "Popover text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(job.display.toolTimings) { timing in
                        HStack(spacing: 6) {
                            Text(timing.toolName)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 80, alignment: .leading)

                            FormatBadge(format: timing.formatName)

                            Text(timing.formattedDuration)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)

                            Spacer(minLength: 4)

                            if timing.didImprove, let out = timing.outputBytes {
                                let saved = timing.inputBytes - out
                                let pct = timing.inputBytes > 0 ? (Double(saved) / Double(timing.inputBytes)) * 100.0 : 0.0
                                Text(String(format: "-%.1f%%", pct))
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.green)
                            } else if timing.error != nil {
                                Text(String(localized: "failed", comment: "Tool failed"))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Text("0%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let percent = job.display.percentOptimized, percent > 0 {
                Divider()
                HStack {
                    Text(String(localized: "Total saved:", comment: "Popover label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.savings(percent))
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(12)
        .frame(width: 295)
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

private struct JobTimingsButton: View {
    let job: Job
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 10))
                .foregroundStyle(isShowingPopover ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPopover, arrowEdge: .trailing) {
            JobTimingsPopoverView(job: job)
        }
        .help(job.timingsSummaryText)
    }
}
