//
//  SettingsView.swift
//  ImageOptim
//
//  The SwiftUI replacement for PrefsController.xib.
//

import ImageOptimGPL
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(String(localized: "General", comment: "Preferences tab"), systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab(String(localized: "Quality", comment: "Preferences tab"), systemImage: "dial.medium") {
                QualitySettings()
            }
            Tab(String(localized: "Optimization speed", comment: "Preferences tab"), systemImage: "speedometer") {
                SpeedSettings()
            }
        }
        .frame(width: 620)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(PrefKey.preservePermissions) private var preservePermissions = false
    @AppStorage(PrefKey.preserveDates) private var preserveDates = false
    @AppStorage(PrefKey.pngOutRemoveChunks) private var pngOutRemoveChunks = true
    @AppStorage(PrefKey.jpegTranStripAll) private var jpegTranStripAll = true

    @AppStorage(PrefKey.gifsicleEnabled) private var gifsicle = true
    @AppStorage(PrefKey.pngOutEnabled) private var pngOut = true
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
        Form {
            Section(String(localized: "Writing files to disk", comment: "Preferences group")) {
                Toggle(String(localized: "Preserve file permissions, attributes and hardlinks",
                              comment: "Preferences checkbox"), isOn: $preservePermissions)
                Text(String(localized: "Saving to network drives is faster when permissions are not preserved",
                            comment: "Preferences hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "Preserve file creation and modification dates",
                              comment: "Preferences checkbox"), isOn: $preserveDates)
            }

            Section(String(localized: "Metadata and color profiles", comment: "Preferences group")) {
                Toggle(String(localized: "Strip PNG metadata (gamma, color profiles, optional chunks)",
                              comment: "Preferences checkbox"), isOn: $pngOutRemoveChunks)
                Text(String(localized: "Web browsers require gamma chunks to be removed", comment: "Preferences hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "Strip JPEG metadata (EXIF, color profiles, GPS, rotation, etc.)",
                              comment: "Preferences checkbox"), isOn: $jpegTranStripAll)
                Text(String(localized: "Not recommended if you rely on embedded copyright information",
                            comment: "Preferences hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Enable", comment: "Preferences group")) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Toggle("Gifsicle", isOn: $gifsicle)
                        Toggle("JPEGOptim", isOn: $jpegOptim)
                    }
                    GridRow {
                        Toggle("PNGOUT", isOn: $pngOut)
                        Toggle("Jpegtran", isOn: $jpegTran)
                    }
                    GridRow {
                        Toggle("PNGCrush", isOn: $pngCrush)
                        Toggle("SVGO", isOn: $svgo)
                            .disabled(!NodeTools.svgSupported)
                            .help(String(localized: "Requires Node.js installed system-wide", comment: "tooltip"))
                    }
                    GridRow {
                        Toggle("OxiPNG", isOn: $oxiPng)
                        Toggle("Guetzli", isOn: $guetzli)
                            .help(String(localized: "Guetzli always strips JPEG metadata", comment: "tooltip"))
                    }
                    GridRow {
                        Toggle("AdvPNG", isOn: $advPng)
                        Toggle("svgcleaner", isOn: $svgCleaner)
                    }
                    GridRow {
                        Toggle("Zopfli", isOn: $zopfli)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HelpButton(anchor: "general")
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

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable lossy minification", comment: "Preferences checkbox"), isOn: $lossyEnabled)
                Text(String(localized: "Makes files much smaller, but may change how images look", comment: "Preferences hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                QualitySlider(title: String(localized: "JPEG quality", comment: "Preferences slider"),
                              value: $jpegQuality, range: 50...99, ticks: 25)
                    .disabled(!lossyEnabled || !jpegOptim)
                QualitySlider(title: String(localized: "PNG quality", comment: "Preferences slider"),
                              value: $pngQuality, range: 40...100, ticks: 7)
                    .disabled(!lossyEnabled)
                QualitySlider(title: String(localized: "GIF quality", comment: "Preferences slider"),
                              value: $gifQuality, range: 40...100, ticks: 7)
                    .disabled(!lossyEnabled)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HelpButton(anchor: "jpegoptim")
        }
    }
}

private struct QualitySlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let ticks: Int

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: Binding(get: { Double(value) },
                                      set: { value = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(range.upperBound),
                       step: max(1, (Double(range.upperBound - range.lowerBound) / Double(ticks - 1)).rounded())) {
                    Text(verbatim: "")
                } minimumValueLabel: {
                    Text(verbatim: "\(range.lowerBound)%")
                } maximumValueLabel: {
                    Text(verbatim: "\(range.upperBound)%")
                }
                Text(verbatim: "\(value)%")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - Speed

private struct SpeedSettings: View {
    @AppStorage(PrefKey.level) private var level = 4

    private static let labels = [
        String(localized: "Fast", comment: "Preferences slider label"),
        String(localized: "Normal", comment: "Preferences slider label"),
        String(localized: "Extra", comment: "Preferences slider label"),
        String(localized: "Insane", comment: "Preferences slider label"),
    ]

    var body: some View {
        Form {
            Section(String(localized: "Optimization level", comment: "Preferences group")) {
                Slider(value: Binding(get: { Double(level) }, set: { level = Int($0.rounded()) }),
                       in: 0...6, step: 1) {
                    Text(verbatim: "")
                } minimumValueLabel: {
                    Text(Self.labels[0])
                } maximumValueLabel: {
                    Text(Self.labels[3])
                }
                HStack {
                    Text(Self.labels[1])
                    Spacer()
                    Text(Self.labels[2])
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HelpButton(anchor: "optipng")
        }
    }
}

// MARK: - Shared bits

private struct HelpButton: View {
    let anchor: String

    var body: some View {
        HStack {
            Spacer()
            Button {
                Help.show(anchor: anchor)
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.plain)
            .help(String(localized: "ImageOptim Help", comment: "Menu Item"))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
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
