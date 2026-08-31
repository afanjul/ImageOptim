//
//  SettingsView.swift
//  ImageOptim
//
//  The SwiftUI replacement for PrefsController.xib. It keeps the layout of the
//  old nib: a plain tab view, boxed groups, and NSSliders with tick marks.
//

import ImageOptimGPL
import SwiftUI

struct SettingsView: View {
    var body: some View {
        // SwiftUI's own TabView moves its tabs into the title bar on macOS 26,
        // so the tabs are an NSTabView, like the nib's
        ClassicTabView(tabs: [
            (String(localized: "General", comment: "Preferences tab"), { AnyView(GeneralSettings()) }),
            (String(localized: "Quality", comment: "Preferences tab"), { AnyView(QualitySettings()) }),
            (String(localized: "Optimization speed", comment: "Preferences tab"), { AnyView(SpeedSettings()) }),
        ])
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
        .frame(width: 663, height: 376)
    }
}

/// The nib's `smallSystem`/`miniSystem` label fonts.
private extension Font {
    static let smallLabel = Font.system(size: NSFont.smallSystemFontSize)
    static let miniLabel = Font.system(size: NSFont.systemFontSize(for: .mini))
}

/// The hint lines under the checkboxes, indented to line up with the checkbox title.
private struct Hint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.smallLabel)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(PrefKey.preservePermissions) private var preservePermissions = false
    @AppStorage(PrefKey.preserveDates) private var preserveDates = false
    @AppStorage(PrefKey.removePngChunks) private var removePngChunks = true
    @AppStorage(PrefKey.jpegTranStripAll) private var jpegTranStripAll = true

    @AppStorage(PrefKey.gifsicleEnabled) private var gifsicle = true
    @AppStorage(PrefKey.pngCrushEnabled) private var pngCrush = true
    @AppStorage(PrefKey.oxiPngEnabled) private var oxiPng = true
    @AppStorage(PrefKey.advPngEnabled) private var advPng = true
    @AppStorage(PrefKey.zopfliEnabled) private var zopfli = true
    @AppStorage(PrefKey.jpegOptimEnabled) private var jpegOptim = true
    @AppStorage(PrefKey.jpegTranEnabled) private var jpegTran = true
    @AppStorage(PrefKey.svgoEnabled) private var svgo = false
    @AppStorage(PrefKey.guetzliEnabled) private var guetzli = false
    @AppStorage(PrefKey.svgCleanerEnabled) private var svgCleaner = false

    @AppStorage(PrefKey.jpegOptimMaxQuality) private var jpegQuality = 80
    @AppStorage(PrefKey.jpegTranStripAllSetByGuetzli) private var stripAllSetByGuetzli = false

    @State private var showsGuetzliWarning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                enableBox
                    .frame(width: 131)
                    .frame(maxHeight: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 8) {
                    metadataBox
                    writingBox
                }
            }

            Spacer(minLength: 12)

            HStack {
                Spacer()
                HelpButton(anchor: "general")
            }
        }
        .onChange(of: guetzli) { _, isEnabled in
            guetzliChanged(isEnabled)
        }
        .onChange(of: jpegTranStripAll) { _, stripsAll in
            // Guetzli can't keep metadata, so turning stripping off turns Guetzli off
            if guetzli, !stripsAll {
                stripAllSetByGuetzli = false
                guetzli = false
            }
        }
        .alert(String(localized: "Guetzli is very slow", comment: "alert box"), isPresented: $showsGuetzliWarning) {
            Button(String(localized: "OK", comment: "alert box")) {}
        } message: {
            Text(String(localized: "It can take up to 30 minutes per image. Your system may be unresponsive while Guetzli is running.",
                        comment: "alert box"))
        }
    }

    private var enableBox: some View {
        GroupBox(String(localized: "Enable", comment: "Preferences group")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Zopfli", isOn: $zopfli)
                Toggle("OxiPNG", isOn: $oxiPng)
                Toggle("AdvPNG", isOn: $advPng)
                Toggle("PNGCrush", isOn: $pngCrush)
                Toggle("JPEGOptim", isOn: $jpegOptim)
                Toggle("Jpegtran", isOn: $jpegTran)
                Toggle("Guetzli", isOn: $guetzli)
                    .help(String(localized: "Guetzli always strips JPEG metadata", comment: "tooltip"))
                Toggle("Gifsicle", isOn: $gifsicle)
                Toggle("SVGO", isOn: $svgo)
                    .disabled(!NodeTools.svgSupported)
                    .help(String(localized: "Requires Node.js installed system-wide", comment: "tooltip"))
                Toggle("svgcleaner", isOn: $svgCleaner)
            }
            .padding(.leading, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataBox: some View {
        GroupBox(String(localized: "Metadata and color profiles", comment: "Preferences group")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Strip PNG metadata (gamma, color profiles, optional chunks)",
                              comment: "Preferences checkbox"), isOn: $removePngChunks)
                Hint(String(localized: "Web browsers require gamma chunks to be removed", comment: "Preferences hint"))
                Toggle(String(localized: "Strip JPEG metadata (EXIF, color profiles, GPS, rotation, etc.)",
                              comment: "Preferences checkbox"), isOn: $jpegTranStripAll)
                Hint(String(localized: "Not recommended if you rely on embedded copyright information",
                            comment: "Preferences hint"))
            }
            .padding(.leading, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var writingBox: some View {
        GroupBox(String(localized: "Writing files to disk", comment: "Preferences group")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Preserve file permissions, attributes and hardlinks",
                              comment: "Preferences checkbox"), isOn: $preservePermissions)
                Hint(String(localized: "Saving to network drives is faster when permissions are not preserved",
                            comment: "Preferences hint"))
                Toggle(String(localized: "Preserve file creation and modification dates",
                              comment: "Preferences checkbox"), isOn: $preserveDates)
            }
            .padding(.leading, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func guetzliChanged(_ isEnabled: Bool) {
        if isEnabled {
            if !NodeTools.warnedAboutGuetzli {
                NodeTools.warnedAboutGuetzli = true
                showsGuetzliWarning = true
            }
            if jpegQuality < 85 {
                jpegQuality = 85
            }
            if !jpegTranStripAll {
                stripAllSetByGuetzli = true
                jpegTranStripAll = true
            }
        } else if jpegTranStripAll, stripAllSetByGuetzli {
            stripAllSetByGuetzli = false
            jpegTranStripAll = false
        }
    }
}

// MARK: - Quality

private struct QualitySettings: View {
    @AppStorage(PrefKey.lossyEnabled) private var lossyEnabled = false
    @AppStorage(PrefKey.jpegOptimMaxQuality) private var jpegQuality = 80
    @AppStorage(PrefKey.pngMinQuality) private var pngQuality = 60
    @AppStorage(PrefKey.gifQuality) private var gifQuality = 80
    @AppStorage(PrefKey.jpegOptimEnabled) private var jpegOptim = true

    private static let labelWidth: CGFloat = 82

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Spacer()
                    .frame(width: Self.labelWidth)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(String(localized: "Enable lossy minification", comment: "Preferences checkbox"),
                           isOn: $lossyEnabled)
                    Hint(String(localized: "Makes files much smaller, but may change how images look",
                                comment: "Preferences hint"))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)

            HStack(alignment: .top, spacing: 8) {
                sliderLabel(String(localized: "JPEG quality", comment: "Preferences slider"))
                QualitySlider(value: $jpegQuality, range: 50...99, ticks: 25,
                              scale: ["50%", "75%", "99%"], isEnabled: lossyEnabled)
                valueLabel(jpegQuality)
            }
            .disabled(!lossyEnabled || !jpegOptim)
            .padding(.top, 27)

            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    sliderLabel(String(localized: "PNG quality", comment: "Preferences slider"))
                    QualitySlider(value: $pngQuality, range: 40...100, ticks: 7,
                                  scale: ["40%", "70%", "100%"], isEnabled: lossyEnabled)
                    valueLabel(pngQuality)
                }
                HStack(alignment: .top, spacing: 8) {
                    sliderLabel(String(localized: "GIF quality", comment: "Preferences slider"))
                    QualitySlider(value: $gifQuality, range: 40...100, ticks: 7,
                                  scale: ["40%", "70%", "100%"], isEnabled: lossyEnabled)
                    valueLabel(gifQuality)
                }
            }
            .disabled(!lossyEnabled)
            .padding(.top, 16)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                HelpButton(anchor: "jpegoptim")
            }
        }
    }

    private func sliderLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(lossyEnabled ? Color(nsColor: .controlTextColor) : Color(nsColor: .disabledControlTextColor))
            .frame(width: Self.labelWidth, alignment: .trailing)
            .padding(.top, 3)
    }

    private func valueLabel(_ value: Int) -> some View {
        Text(verbatim: "\(value)%")
            .font(.miniLabel)
            .monospacedDigit()
            .foregroundStyle(lossyEnabled ? Color(nsColor: .controlTextColor) : Color(nsColor: .disabledControlTextColor))
            .frame(width: 30, alignment: .leading)
            .padding(.top, 6)
    }
}

/// A tick-marked slider with the mini min/middle/max scale printed underneath, as in the nib.
private struct QualitySlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let ticks: Int
    let scale: [String]
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 6) {
            TickSlider(value: $value, range: range, ticks: ticks)
                .frame(height: 22)
            HStack(spacing: 0) {
                Text(scale[0])
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(scale[1])
                    .frame(maxWidth: .infinity, alignment: .center)
                Text(scale[2])
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.miniLabel)
            .foregroundStyle(isEnabled ? Color(nsColor: .controlTextColor) : Color(nsColor: .disabledControlTextColor))
        }
    }
}

// MARK: - Speed

private struct SpeedSettings: View {
    @AppStorage(PrefKey.level) private var level = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(String(localized: "Optimization level", comment: "Preferences slider"))
                    .frame(width: 113, alignment: .trailing)
                    .padding(.top, 3)

                VStack(spacing: 6) {
                    TickSlider(value: $level, range: 0...6, ticks: 7)
                        .frame(width: 227, height: 22)
                    HStack(spacing: 0) {
                        Text(String(localized: "Fast", comment: "Preferences slider label"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(localized: "Normal", comment: "Preferences slider label"))
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(String(localized: "Extra", comment: "Preferences slider label"))
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(String(localized: "Insane", comment: "Preferences slider label"))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.miniLabel)
                    .frame(width: 227)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 43)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                HelpButton(anchor: "optipng")
            }
        }
    }
}

// MARK: - AppKit controls

/// `NSTabView` with the tabs drawn above the content, hosting SwiftUI pages.
private struct ClassicTabView: NSViewRepresentable {
    /// The pages are closures, not built views: opening Preferences used to evaluate all three
    /// bodies — every slider, every `@AppStorage` read — for the two tabs nobody has clicked yet.
    let tabs: [(title: String, content: () -> AnyView)]

    @MainActor
    final class Coordinator: NSObject, NSTabViewDelegate {
        var pages: [() -> AnyView] = []

        func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
            guard let tabViewItem,
                  let index = tabView.tabViewItems.firstIndex(of: tabViewItem)
            else { return }
            host(page: index, in: tabViewItem)
        }

        /// Builds the page the first time its tab is shown, and leaves it alone afterwards.
        func host(page index: Int, in item: NSTabViewItem) {
            guard pages.indices.contains(index),
                  let container = item.view, container.subviews.isEmpty
            else { return }

            let hosting = NSHostingView(rootView: pages[index]())
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTabView {
        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        context.coordinator.pages = tabs.map(\.content)
        tabView.delegate = context.coordinator

        for tab in tabs {
            let item = NSTabViewItem(identifier: tab.title)
            item.label = tab.title
            item.view = NSView()
            tabView.addTabViewItem(item)
        }

        // `willSelect` is not sent for the tab the view opens on.
        if let first = tabView.tabViewItems.first {
            context.coordinator.host(page: 0, in: first)
        }
        return tabView
    }

    func updateNSView(_ tabView: NSTabView, context: Context) {
        // Deliberately not reassigning any `rootView`: each hosted page is a self-contained view
        // that observes its own defaults, so it updates itself. Pushing a freshly built `AnyView`
        // into all three hosting views from here re-rendered the whole Preferences window.
        context.coordinator.pages = tabs.map(\.content)
        for (item, tab) in zip(tabView.tabViewItems, tabs) where item.label != tab.title {
            item.label = tab.title
        }
    }
}

/// `NSSlider` with tick marks; SwiftUI's `Slider` can't draw them.
private struct TickSlider: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let ticks: Int

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value),
                              minValue: Double(range.lowerBound),
                              maxValue: Double(range.upperBound),
                              target: context.coordinator,
                              action: #selector(Coordinator.sliderMoved(_:)))
        slider.numberOfTickMarks = ticks
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        if Int(slider.doubleValue.rounded()) != value {
            slider.doubleValue = Double(value)
        }
        slider.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 22)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Int>

        init(value: Binding<Int>) {
            self.value = value
        }

        @objc func sliderMoved(_ sender: NSSlider) {
            let rounded = Int(sender.doubleValue.rounded())
            if value.wrappedValue != rounded {
                value.wrappedValue = rounded
            }
        }
    }
}

/// The round "?" button of the old nib.
private struct HelpButton: NSViewRepresentable {
    let anchor: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.pressed))
        button.bezelStyle = .helpButton
        button.toolTip = String(localized: "ImageOptim Help", comment: "Menu Item")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.anchor = anchor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(anchor: anchor)
    }

    @MainActor
    final class Coordinator: NSObject {
        var anchor: String

        init(anchor: String) {
            self.anchor = anchor
        }

        @objc func pressed() {
            Help.show(anchor: anchor)
        }
    }
}

/// Named `NodeTools` so it doesn't shadow the framework's `Tools`.
enum NodeTools {
    /// Node is needed by SVGO, and it isn't bundled. This doesn't belong here :(
    static var svgSupported: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: "/usr/local/bin/node") || fm.isExecutableFile(atPath: "/opt/homebrew/bin/node")
    }

    /// The Guetzli slowness warning is shown at most once per launch.
    @MainActor static var warnedAboutGuetzli = false
}
