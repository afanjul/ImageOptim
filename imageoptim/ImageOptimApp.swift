//
//  ImageOptimApp.swift
//  ImageOptim
//

import ImageOptimGPL
import QuickLookUI
import SwiftUI

@main
struct ImageOptimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("ImageOptim", id: WindowID.main) {
            ContentView(model: model)
                .frame(minWidth: 480, minHeight: 260)
        }
        .defaultSize(width: 640, height: 420)
        .commands {
            AppCommands(model: model)
        }

        Window(String(localized: "About ImageOptim", comment: "Window Title"), id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)

        // A plain window rather than the `Settings` scene, so the prefs keep the
        // title and the tabbed layout of the old PrefsController.xib
        Window(String(localized: "ImageOptim Preferences", comment: "Window Title"), id: WindowID.prefs) {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let main = "main"
    static let about = "about"
    static let prefs = "prefs"
}

/// Everything that used to live in the ImageOptim.xib main menu.
struct AppCommands: Commands {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About ImageOptim", comment: "Menu Item")) {
                openWindow(id: WindowID.about)
            }
            Divider()
            Button(String(localized: "Web API…", comment: "Menu Item")) {
                openURL(URL(string: "https://imageoptim.com/app-api")!)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Preferences…", comment: "Menu Item")) {
                openWindow(id: WindowID.prefs)
            }
            .keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Add Files…", comment: "Menu Item")) {
                Task { await model.browseForFiles() }
            }
            .keyboardShortcut("o")
        }

        CommandGroup(after: .newItem) {
            Button(String(localized: "Optimize Again", comment: "Menu Item")) {
                model.startAgain(onlyOptimized: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            }
            .keyboardShortcut("r")
            .disabled(!model.canStartAgainAny)

            Button(String(localized: "Optimize Optimized", comment: "Menu Item")) {
                model.startAgain(onlyOptimized: true)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!model.canStartAgainOptimized)

            Divider()

            Button(String(localized: "Stop", comment: "Menu Item")) {
                model.stopSelected()
            }
            .keyboardShortcut("s")
            .disabled(!model.isStoppable)

            Button(String(localized: "Revert to Original", comment: "Menu Item")) {
                Task { await model.revertSelected() }
            }
            .disabled(!model.canRevert)

            Divider()

            Button(String(localized: "Quick Look", comment: "Menu Item")) {
                QuickLook.toggle()
            }
            .keyboardShortcut("y")
            .disabled(!model.hasSelection)

            Button(String(localized: "Show in Finder", comment: "Menu Item")) {
                model.revealSelectedInFinder()
            }
            .disabled(!model.hasSelection)
        }

        CommandGroup(replacing: .pasteboard) {
            Button(String(localized: "Cut", comment: "Menu Item")) {
                model.cutSelection()
            }
            .keyboardShortcut("x")
            .disabled(!model.hasSelection)

            Button(String(localized: "Copy", comment: "Menu Item")) {
                model.copySelection()
            }
            .keyboardShortcut("c")
            .disabled(!model.hasSelection)

            Button(String(localized: "Paste", comment: "Menu Item")) {
                Task { await model.paste() }
            }
            .keyboardShortcut("v")
            .disabled(!model.canPaste)

            Button(String(localized: "Copy as Data URL", comment: "Menu Item")) {
                model.copySelectionAsDataURL()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.canCopyAsDataURL)

            Divider()

            Button(String(localized: "Delete", comment: "Menu Item")) {
                model.deleteSelected()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!model.hasSelection)

            Button(String(localized: "Delete Completed", comment: "Menu Item")) {
                model.clearComplete()
            }
            .disabled(!model.canClearComplete)

            Divider()

            Button(String(localized: "Select All", comment: "Menu Item")) {
                model.selectAll()
            }
            .keyboardShortcut("a")
        }

        CommandGroup(after: .toolbar) {
            Menu(String(localized: "Show Columns", comment: "Menu Item")) {
                ColumnToggle(String(localized: "Original Size", comment: "Menu Item"), id: "originalsize", model: model)
                ColumnToggle(String(localized: "Optimized Size", comment: "Menu Item"), id: "size", model: model)
                ColumnToggle(String(localized: "Savings", comment: "Menu Item"), id: "savings", model: model)
                ColumnToggle(String(localized: "Best tool", comment: "Menu Item"), id: "besttool", model: model)
            }
        }

        CommandMenu(String(localized: "Tools", comment: "Top-level Main Menu")) {
            LossyQualityMenuItems()
            Divider()
            DefaultsToggle("Zopfli", key: PrefKey.zopfliEnabled)
            DefaultsToggle("OxiPNG", key: PrefKey.oxiPngEnabled)
            DefaultsToggle("AdvPNG", key: PrefKey.advPngEnabled)
            DefaultsToggle("PNGCrush", key: PrefKey.pngCrushEnabled)
            Divider()
            DefaultsToggle("JPEGOptim", key: PrefKey.jpegOptimEnabled)
            DefaultsToggle("Jpegtran", key: PrefKey.jpegTranEnabled)
            Divider()
            DefaultsToggle("Gifsicle", key: PrefKey.gifsicleEnabled)
        }

        CommandGroup(replacing: .help) {
            Button(String(localized: "ImageOptim Help", comment: "Menu Item")) {
                Help.show(anchor: "main")
            }
            .keyboardShortcut("?")
            Divider()
            Button(String(localized: "ImageOptim Website", comment: "Menu Item")) {
                openURL(URL(string: "https://imageoptim.com")!)
            }
            Button(String(localized: "Donate", comment: "Menu Item")) {
                openURL(URL(string: "https://imageoptim.com/donate.html")!)
            }
            Button(String(localized: "View Source", comment: "Menu Item")) {
                openURL(URL(string: "https://imageoptim.com/source")!)
            }
        }
    }
}

/// One entry of the old Window ▸ Show Columns submenu, driving the table's customization state.
private struct ColumnToggle: View {
    private let title: String
    private let id: String
    private let model: AppModel

    init(_ title: String, id: String, model: AppModel) {
        self.title = title
        self.id = id
        self.model = model
    }

    var body: some View {
        @Bindable var model = model

        Toggle(title, isOn: Binding {
            model.columnCustomization[visibility: id] == .visible
        } set: { isVisible in
            model.columnCustomization[visibility: id] = isVisible ? .visible : .hidden
        })
    }
}

/// The "Lossy minification" toggle plus the quality readout that used to be a bound menu item.
private struct LossyQualityMenuItems: View {
    @AppStorage(PrefKey.lossyEnabled) private var lossyEnabled = false
    @AppStorage(PrefKey.jpegOptimMaxQuality) private var jpegQuality = 80

    var body: some View {
        Text(verbatim: lossyEnabled ? "Quality: \(jpegQuality)%" : String(localized: "Quality: 100%", comment: "Menu Item"))
        Toggle(String(localized: "Lossy minification", comment: "Menu Item"), isOn: $lossyEnabled)
            .keyboardShortcut("l")
    }
}

private struct DefaultsToggle: View {
    private let title: String
    @AppStorage private var isOn: Bool

    init(_ title: String, key: String) {
        self.title = title
        _isOn = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
    }
}

@MainActor
enum Help {
    static func show(anchor: String) {
        let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String
        NSHelpManager.shared.openHelpAnchor(NSHelpManager.AnchorName(anchor), inBook: book.map { NSHelpManager.BookName($0) })
    }
}

@MainActor
enum QuickLook {
    static func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
