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
                    JobsTable(model: model)
                } else {
                    DropZone(isTargeted: isDropTarget)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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

        return Table(model.sortedJobs,
                     selection: $model.selection,
                     sortOrder: $model.sortOrder,
                     columnCustomization: $model.columnCustomization) {
            TableColumn(Text(verbatim: ""), sortUsing: JobComparator(field: .status)) { job in
                StatusIcon(name: job.display.statusImageName)
                    .help(job.display.statusText)
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
                Text(Formatters.savings(job.display.percentOptimized))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(85)
            .customizationID("savings")

            TableColumn(Text(ColumnTitle.bestTool)) { job in
                Text(job.display.bestToolName ?? "")
                    .monospacedDigit()
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
        HStack(spacing: 7) {
            Button {
                Task { await model.browseForFiles() }
            } label: {
                Image(systemName: "plus")
            }
            .frame(width: 30)
            .help(String(localized: "Add new files or directories", comment: "Button Tooltip"))
            .accessibilityLabel(Text(String(localized: "Add new files or directories", comment: "Button Tooltip")))

            // `.enabled` and `.disabled` are different types, so the branch is on the view
            Group {
                if model.statusTextSelectable {
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
                        ActionIcon()
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Settings", comment: "Button Tooltip"))
                }
            }
            .frame(width: 16, height: 16)
            .padding(.trailing, 1)

            Button {
                model.startAgain(onlyOptimized: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            } label: {
                Label(String(localized: "Again", comment: "Button"), systemImage: "arrow.clockwise")
            }
            .frame(minWidth: 90)
            .help(String(localized: "Run optimizations again", comment: "Button tooltip"))
            .disabled(!model.hasJobs)
        }
        .controlSize(.regular)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Cells

private struct StatusIcon: View {
    let name: String

    /// There are only a handful of status images, but `NSImage(named:)` is an AppKit round trip
    /// that the status column would otherwise make for every visible row on every redraw.
    @MainActor private static var cache: [String: Image?] = [:]

    private static func image(named name: String) -> Image? {
        if let cached = cache[name] {
            return cached
        }
        let image = NSImage(named: name).map { Image(nsImage: $0) }
        cache[name] = image
        return image
    }

    var body: some View {
        if let image = Self.image(named: name) {
            image
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

/// The filename column, with the "reveal in Finder" button that used to be RevealButtonCell.
private struct FileNameCell: View {
    let model: AppModel
    let job: Job
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(job.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Hidden rather than absent: scrolling drags rows under a stationary pointer, so this
            // toggles constantly, and changing opacity is much cheaper for SwiftUI than inserting
            // and removing the button from the view hierarchy each time.
            Button {
                model.reveal(job)
            } label: {
                Image(systemName: "arrow.right.circle.fill")
            }
            .buttonStyle(.plain)
            .help(job.filePathString)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .onHover { isHovering = $0 }
        .help(job.display.statusText)
    }
}

/// The trailing settings button's icon: the same `NSActionTemplate` the xib used.
private struct ActionIcon: View {
    var body: some View {
        if let image = NSImage(named: NSImage.actionTemplateName) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "gearshape")
        }
    }
}

/// The empty state — a port of what DragDropImageView's `drawRect:` used to draw:
/// a dashed rounded square a quarter of the window wide, with a solid arrow pointing into it.
private struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        Canvas { context, canvas in
            let side = min(canvas.width / 4, canvas.height / 1.5)
            let lineWidth = max(2, side / 32)
            let color = Color(nsColor: .secondaryLabelColor).opacity(isTargeted ? 1.0 / 4.0 : 1.0 / 8.0)
            let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)

            let box = CGRect(x: mid.x - side / 2, y: mid.y - side / 2, width: side, height: side)
            context.stroke(Path(roundedRect: box, cornerRadius: side / 14),
                           with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth,
                                              dash: [side / 10, side / 16],
                                              dashPhase: 2))

            // Stem half-width and shoulder half-width; the arrow spans side/2 vertically,
            // sitting a touch above centre exactly like the old offset of -size/8 did.
            let stem = side / 8
            let shoulder = stem * 2
            var arrow = Path()
            arrow.move(to: CGPoint(x: mid.x - stem, y: mid.y - side / 4))
            arrow.addLine(to: CGPoint(x: mid.x + stem, y: mid.y - side / 4))
            arrow.addLine(to: CGPoint(x: mid.x + stem, y: mid.y))
            arrow.addLine(to: CGPoint(x: mid.x + shoulder, y: mid.y))
            arrow.addLine(to: CGPoint(x: mid.x, y: mid.y + side / 4))
            arrow.addLine(to: CGPoint(x: mid.x - shoulder, y: mid.y))
            arrow.addLine(to: CGPoint(x: mid.x - stem, y: mid.y))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(color))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text(String(localized: "Drop images here", comment: "Drop zone")))
    }
}
